//
//  HALPCMPlaybackEngine.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import CoreAudio
import Foundation
import Synchronization

public enum HALPCMPlaybackState: String, Codable, Sendable {
    case idle
    case playing
    case stopped
    case failed
}

public struct HALPCMPlaybackStatus: Codable, Equatable, Sendable {
    public let state: HALPCMPlaybackState
    public let samplePosition: UInt64
    public let sampleCount: UInt64
    public let underrunCount: UInt64
    public let outputChannelCount: Int
    public let failureDescription: String?
    public var currentItemID: String? = nil

    func stoppedClearingFailure() -> Self {
        Self(
            state: .stopped,
            samplePosition: samplePosition,
            sampleCount: sampleCount,
            underrunCount: underrunCount,
            outputChannelCount: outputChannelCount,
            failureDescription: nil,
            currentItemID: currentItemID
        )
    }
}

public enum HALPCMPlaybackError: Error, Equatable, Sendable {
    case unsupportedSource
    case invalidStartPosition
    case outputBufferLayout
}

/// APE 等 PCM 的进程内独占播放引擎；解码与文件读取在 worker，HAL callback 只消费固定缓冲。
public final class HALPCMPlaybackEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(label: "foofoil.hifi.pcm-device-events")
    private var activeSession: PlaybackSession?
    private var deviceWatch: DeviceLifecycleWatch?
    private var lastStatus = HALPCMPlaybackStatus(
        state: .idle,
        samplePosition: 0,
        sampleCount: 0,
        underrunCount: 0,
        outputChannelCount: 0,
        failureDescription: nil
    )

    public init() {}

    public static func supportsPlayback(_ descriptor: APEAudioDescriptor) -> Bool {
        guard (1...8).contains(descriptor.channelCount),
              [8, 16, 24, 32].contains(descriptor.bitsPerSample),
              descriptor.sampleRate > 0,
              descriptor.totalBlocks > 0 else {
            return false
        }
        // 大端浮点超出当前流转换范围，其余组合由设备规划决定。
        if descriptor.isFloat, (descriptor.formatFlags & (1 << 9)) != 0 {
            return false
        }
        return true
    }

    public func play(
        fileAt url: URL,
        deviceUID: String,
        startBlock: UInt64 = 0,
        endBlock: UInt64? = nil,
        startingSample: UInt64 = 0,
        itemID: String? = nil,
        successors: [APEPlaybackItem] = []
    ) throws {
        try stop()
        let stream: APERawStream
        do {
            stream = try APERawStream(fileAt: url, startBlock: startBlock, endBlock: endBlock)
        } catch {
            throw HALPCMPlaybackError.unsupportedSource
        }
        let descriptor = try APEParser.parse(fileAt: url)
        guard Self.supportsPlayback(descriptor),
              startingSample <= stream.sampleCount else {
            throw HALPCMPlaybackError.invalidStartPosition
        }
        let plan = try CoreAudioHALFormatProbe.planPCM(
            deviceUID: deviceUID,
            sampleRate: Double(descriptor.sampleRate),
            channelCount: descriptor.channelCount,
            bitsPerSample: UInt32(descriptor.bitsPerSample)
        )
        if startingSample > 0 {
            try stream.seek(toSample: startingSample)
        }
        let configured = try ConfiguredPCMDevice(plan: plan)
        do {
            let sequence = PCMPlaybackSequence(
                source: stream, itemID: itemID, startingSample: startingSample, successors: successors
            ) { item in
                guard item.descriptor.sampleRate == descriptor.sampleRate,
                      item.descriptor.channelCount == descriptor.channelCount,
                      item.descriptor.bitsPerSample == descriptor.bitsPerSample,
                      item.descriptor.isFloat == descriptor.isFloat else { return nil }
                return try APERawStream(fileAt: item.url, startBlock: item.startBlock, endBlock: item.endBlock)
            }
            let session = PlaybackSession(
                configuredDevice: configured,
                source: sequence
            )
            try session.prefill()
            try session.startIO()

            lock.lock()
            activeSession = session
            lastStatus = session.status(state: .playing)
            let watch = DeviceLifecycleWatch(
                deviceID: configured.deviceID,
                deviceUID: configured.deviceUID,
                holdsHogMode: configured.acquiredHogMode,
                queue: eventQueue
            ) { [weak self] event in
                self?.handleDeviceEvent(event)
            }
            deviceWatch = watch
            lock.unlock()
            watch.start()
            session.startProducer { [weak self, weak session] failure in
                guard let self, let session else { return }
                self.finish(session: session, failure: failure)
            }
        } catch {
            try? configured.restore()
            throw HiFiPlaybackError.from(error)
        }
    }

    @discardableResult
    public func stop() throws -> HALPCMPlaybackStatus {
        let status = teardown(
            expectedSession: nil,
            failure: nil,
            stateIfClean: .stopped,
            resetInactiveFailure: true
        )
        if status.state == .failed {
            throw HiFiPlaybackError(localizationKey: status.failureDescription ?? "")
                ?? HiFiPlaybackError.outputInitializationFailure
        }
        return status
    }

    public func status() -> HALPCMPlaybackStatus {
        lock.lock()
        defer { lock.unlock() }
        return activeSession?.status(state: .playing) ?? lastStatus
    }

    private func handleDeviceEvent(_ event: DeviceLifecycleWatch.Event) {
        switch event {
        case .disconnected:
            _ = teardown(expectedSession: nil, failure: HiFiPlaybackError.deviceDisconnected, stateIfClean: .failed)
        case .busy:
            _ = teardown(expectedSession: nil, failure: HiFiPlaybackError.deviceBusy, stateIfClean: .failed)
        case .exclusiveModeLost:
            _ = teardown(expectedSession: nil, failure: HiFiPlaybackError.exclusiveModeFailure, stateIfClean: .failed)
        case .systemWillSleep:
            _ = teardown(expectedSession: nil, failure: nil, stateIfClean: .stopped)
        }
    }

    private func finish(session: PlaybackSession, failure: Error?) {
        _ = teardown(
            expectedSession: session,
            failure: failure,
            stateIfClean: .stopped
        )
    }

    /// 先摘掉监听再停 IO / 恢复格式，避免拔出路径和用户暂停在锁上互等。
    @discardableResult
    private func teardown(
        expectedSession: PlaybackSession?,
        failure: Error?,
        stateIfClean: HALPCMPlaybackState,
        resetInactiveFailure: Bool = false
    ) -> HALPCMPlaybackStatus {
        lock.lock()
        if let expectedSession, activeSession !== expectedSession {
            lock.unlock()
            return status()
        }
        guard let session = activeSession else {
            if resetInactiveFailure {
                // 拔出设备后的失败属于已结束会话；显式 stop 必须可重入，下一次 play 才能重新探测同一 UID。
                lastStatus = lastStatus.stoppedClearingFailure()
            }
            let status = lastStatus
            lock.unlock()
            return status
        }
        activeSession = nil
        let watch = deviceWatch
        deviceWatch = nil
        lock.unlock()

        watch?.stop()
        session.requestStop()
        let cleanupError = session.stopIOAndRestore()
        let finalError = failure ?? cleanupError
        let stopped = session.status(
            state: finalError == nil ? stateIfClean : .failed,
            failureDescription: finalError.map { HiFiPlaybackError.from($0).localizationKey }
        )
        lock.lock()
        lastStatus = stopped
        lock.unlock()
        return stopped
    }
}

private final class ConfiguredPCMDevice: @unchecked Sendable {
    let deviceUID: String
    let deviceID: AudioDeviceID
    let streamID: AudioStreamID
    let physicalFormat: AudioStreamBasicDescription
    let virtualFormat: AudioStreamBasicDescription
    let acquiredHogMode: Bool

    private let originalPhysical: AudioStreamBasicDescription
    private let originalVirtual: AudioStreamBasicDescription
    private let restored = Atomic<Bool>(false)

    init(plan: PCMTransportPlan) throws {
        deviceUID = plan.deviceUID
        deviceID = try CoreAudioHALFormatProbe.resolveDeviceID(uid: plan.deviceUID)
        streamID = plan.streamID
        guard try CoreAudioHALFormatProbe.outputStreams(deviceID: deviceID).contains(streamID) else {
            throw CoreAudioHALFormatProbeError.noOutputStream
        }
        originalPhysical = try CoreAudioHALFormatProbe.currentFormat(
            streamID: streamID,
            selector: kAudioStreamPropertyPhysicalFormat
        )
        originalVirtual = try CoreAudioHALFormatProbe.currentFormat(
            streamID: streamID,
            selector: kAudioStreamPropertyVirtualFormat
        )
        physicalFormat = try CoreAudioHALFormatProbe.targetFormat(for: plan)
        virtualFormat = CoreAudioHALFormatProbe.float32VirtualFormat(for: physicalFormat)
        let acquiredHogMode = try CoreAudioHALFormatProbe.acquireHogModeIfAvailable(deviceID: deviceID)
        self.acquiredHogMode = acquiredHogMode

        do {
            try CoreAudioHALFormatProbe.setStreamFormat(
                physicalFormat,
                streamID: streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            _ = try CoreAudioHALFormatProbe.waitForFormat(
                physicalFormat,
                streamID: streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            try CoreAudioHALFormatProbe.setStreamFormat(
                virtualFormat,
                streamID: streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            _ = try CoreAudioHALFormatProbe.waitForFormat(
                virtualFormat,
                streamID: streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
        } catch {
            try? restore()
            throw error
        }
    }

    func restore() throws {
        let exchanged = restored.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard exchanged.exchanged else { return }
        // 设备已消失时不要再写 physical/virtual format，以免把断开误报成格式恢复失败。
        guard CoreAudioHALFormatProbe.isDeviceAlive(deviceID) else {
            if acquiredHogMode {
                try? CoreAudioHALFormatProbe.releaseHogMode(deviceID: deviceID)
            }
            return
        }
        var firstError: Error?
        do {
            try CoreAudioHALFormatProbe.setStreamFormat(
                originalVirtual,
                streamID: streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            _ = try CoreAudioHALFormatProbe.waitForFormat(
                originalVirtual,
                streamID: streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
        } catch {
            firstError = error
        }
        do {
            try CoreAudioHALFormatProbe.setStreamFormat(
                originalPhysical,
                streamID: streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            _ = try CoreAudioHALFormatProbe.waitForFormat(
                originalPhysical,
                streamID: streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
        } catch {
            firstError = firstError ?? error
        }
        if acquiredHogMode {
            do {
                try CoreAudioHALFormatProbe.releaseHogMode(deviceID: deviceID)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}

private final class PlaybackSession: @unchecked Sendable {
    private static let ringCapacityFrames = 131_072
    private static let workerChunkFrames = 4_096
    private static let prebufferFrames = 32_768

    let configuredDevice: ConfiguredPCMDevice
    let source: PCMPlaybackSequence
    let channelCount: Int

    private let ring: SPSCFloatRingBuffer
    private let stopRequested = Atomic<Bool>(false)
    private let consumedFrames = Atomic<UInt64>(0)
    private let underrunCount = Atomic<UInt64>(0)
    private let ioStopped = Atomic<Bool>(false)
    private var ioProcID: AudioDeviceIOProcID?

    init(configuredDevice: ConfiguredPCMDevice, source: PCMPlaybackSequence) {
        self.configuredDevice = configuredDevice
        self.source = source
        channelCount = max(1, Int(configuredDevice.physicalFormat.mChannelsPerFrame))
        ring = SPSCFloatRingBuffer(capacityFrames: Self.ringCapacityFrames, channelCount: channelCount)
    }

    func prefill() throws {
        while ring.availableFrames < Self.prebufferFrames {
            let writable = min(Self.workerChunkFrames, ring.writableFrames)
            guard writable > 0 else { break }
            let samples = try source.read(maximumFrames: writable)
            guard !samples.isEmpty else { break }
            let written = samples.withUnsafeBufferPointer { ring.write(interleavedSamples: $0) }
            guard written == samples.count / channelCount else { break }
        }
    }

    func startIO() throws {
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            configuredDevice.deviceID,
            nil
        ) { [weak self] _, _, _, outputData, _ in
            self?.render(outputData)
        }
        guard createStatus == noErr else { throw CoreAudioHALFormatProbeError.ioProcCreate(createStatus) }
        let startStatus = AudioDeviceStart(configuredDevice.deviceID, ioProcID)
        guard startStatus == noErr else {
            if let ioProcID { AudioDeviceDestroyIOProcID(configuredDevice.deviceID, ioProcID) }
            ioProcID = nil
            throw CoreAudioHALFormatProbeError.ioStart(startStatus)
        }
    }

    func startProducer(completion: @escaping @Sendable (Error?) -> Void) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            do {
                while !stopRequested.load(ordering: .acquiring) {
                    let writable = min(Self.workerChunkFrames, ring.writableFrames)
                    if writable == 0 {
                        usleep(2_000)
                        continue
                    }
                    let samples = try source.read(maximumFrames: writable)
                    if samples.isEmpty { break }
                    let written = samples.withUnsafeBufferPointer { ring.write(interleavedSamples: $0) }
                    guard written == samples.count / channelCount else { continue }
                }
                while !stopRequested.load(ordering: .acquiring), ring.availableFrames > 0 {
                    usleep(2_000)
                }
                if !stopRequested.load(ordering: .acquiring) { completion(nil) }
            } catch {
                if !stopRequested.load(ordering: .acquiring) { completion(error) }
            }
        }
        thread.name = "foofoil.hifi.ape-reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func requestStop() {
        stopRequested.store(true, ordering: .releasing)
    }

    func stopIOAndRestore() -> Error? {
        let exchanged = ioStopped.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard exchanged.exchanged else { return nil }
        var firstError: Error?
        if let ioProcID {
            let stopStatus = AudioDeviceStop(configuredDevice.deviceID, ioProcID)
            if stopStatus != noErr { firstError = CoreAudioHALFormatProbeError.ioStop(stopStatus) }
            let destroyStatus = AudioDeviceDestroyIOProcID(configuredDevice.deviceID, ioProcID)
            if destroyStatus != noErr, firstError == nil {
                firstError = CoreAudioHALFormatProbeError.ioProcDestroy(destroyStatus)
            }
            self.ioProcID = nil
        }
        do {
            try configuredDevice.restore()
        } catch {
            firstError = firstError ?? error
        }
        return firstError
    }

    func status(
        state: HALPCMPlaybackState,
        failureDescription: String? = nil
    ) -> HALPCMPlaybackStatus {
        let position = source.position(consumedFrames: consumedFrames.load(ordering: .acquiring))
        return HALPCMPlaybackStatus(
            state: state,
            samplePosition: position.samplePosition,
            sampleCount: position.sampleCount,
            underrunCount: underrunCount.load(ordering: .acquiring),
            outputChannelCount: channelCount,
            failureDescription: failureDescription,
            currentItemID: position.itemID
        )
    }

    /// HAL realtime callback：只从预分配 ring 复制，underrun 补零（PCM 静音）。
    private func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard buffers.count == 1,
              let data = buffers[0].mData,
              buffers[0].mNumberChannels == UInt32(channelCount) else {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let frameCount = Int(buffers[0].mDataByteSize) / (channelCount * MemoryLayout<Float32>.size)
        let output = data.assumingMemoryBound(to: Float32.self)
        let readFrames = ring.read(into: output, maximumFrames: frameCount)
        consumedFrames.wrappingAdd(UInt64(readFrames), ordering: .relaxed)
        if readFrames < frameCount {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            let missing = (frameCount - readFrames) * channelCount
            output.advanced(by: readFrames * channelCount).initialize(repeating: 0, count: missing)
        }
    }
}
