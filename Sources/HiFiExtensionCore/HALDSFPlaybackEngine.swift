import CoreAudio
import Foundation
import Synchronization

public enum HALDSFPlaybackState: String, Codable, Sendable {
    case idle
    case playing
    case stopped
    case failed
}

public struct HALDSFPlaybackStatus: Codable, Equatable, Sendable {
    public let state: HALDSFPlaybackState
    public let samplePosition: UInt64
    public let sampleCount: UInt64
    public let underrunCount: UInt64
    public let outputChannelCount: Int
    public let failureDescription: String?

    func stoppedClearingFailure() -> Self {
        Self(
            state: .stopped,
            samplePosition: samplePosition,
            sampleCount: sampleCount,
            underrunCount: underrunCount,
            outputChannelCount: outputChannelCount,
            failureDescription: nil
        )
    }
}

public enum HALDSFPlaybackError: Error, Equatable, Sendable {
    case unsupportedSource
    case invalidStartPosition
    case outputBufferLayout
}

/// Phase 0 的进程内播放引擎；文件读取与 DoP 封装在 worker，HAL callback 只消费固定缓冲。
public final class HALDSFPlaybackEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(label: "foofoil.hifi.device-events")
    private var activeSession: PlaybackSession?
    private var deviceWatch: DeviceLifecycleWatch?
    private var lastStatus = HALDSFPlaybackStatus(
        state: .idle,
        samplePosition: 0,
        sampleCount: 0,
        underrunCount: 0,
        outputChannelCount: 0,
        failureDescription: nil
    )

    public init() {}

    public static func supportsStereoPlayback(_ descriptor: DSDContainerDescriptor) -> Bool {
        switch descriptor.kind {
        case .dsf, .sacd:
            descriptor.channelCount == 2
        case .dff:
            descriptor.stereoChannelIndices != nil
        }
    }

    deinit {
        _ = try? stop()
    }

    public func play(
        fileAt url: URL,
        deviceUID: String,
        startingSample: UInt64 = 0,
        sacdTrackNumber: Int? = nil
    ) throws {
        try stop()
        let descriptor: DSDContainerDescriptor
        if SACDISOParser.sniff(fileAt: url) {
            descriptor = try SACDISOParser.parse(fileAt: url).containerDescriptor(trackNumber: sacdTrackNumber)
        } else {
            descriptor = try DSDContainerParser.parse(fileAt: url)
        }
        guard descriptor.compression == .rawDSD,
              let sampleCount = descriptor.sampleCount,
              Self.supportsStereoPlayback(descriptor) else {
            throw HALDSFPlaybackError.unsupportedSource
        }
        guard startingSample <= sampleCount, startingSample.isMultiple(of: 16) else {
            throw HALDSFPlaybackError.invalidStartPosition
        }

        var selected: (plan: DoPTransportPlan, outputMap: [Int?])?
        var lastProbeError: Error?
        for outputMap in descriptor.playbackOutputMaps() {
            do {
                let plan = try CoreAudioHALFormatProbe.plan(
                    deviceUID: deviceUID,
                    dsdSampleRate: descriptor.sampleRate,
                    channelCount: outputMap.count
                )
                selected = (plan, outputMap)
                break
            } catch {
                lastProbeError = error
            }
        }
        guard let selected else {
            throw lastProbeError ?? HALDSFPlaybackError.unsupportedSource
        }
        let stream = try DSDStreamFactory.make(
            fileAt: url,
            outputMap: selected.outputMap,
            sacdTrackNumber: sacdTrackNumber
        )
        if startingSample > 0 {
            try stream.seek(toSample: startingSample)
        }
        let configured = try ConfiguredDevice(plan: selected.plan)
        do {
            let source = try DSFDoPSource(
                stream: stream,
                physicalFormat: CoreAudioHALFormatProbe.describe(configured.physicalFormat)
            )
            let session = PlaybackSession(
                configuredDevice: configured,
                source: source,
                startingSample: startingSample
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
    public func stop() throws -> HALDSFPlaybackStatus {
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

    public func status() -> HALDSFPlaybackStatus {
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
        stateIfClean: HALDSFPlaybackState,
        resetInactiveFailure: Bool = false
    ) -> HALDSFPlaybackStatus {
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

private final class ConfiguredDevice: @unchecked Sendable {
    let deviceUID: String
    let deviceID: AudioDeviceID
    let streamID: AudioStreamID
    let physicalFormat: AudioStreamBasicDescription
    let virtualFormat: AudioStreamBasicDescription
    let acquiredHogMode: Bool

    private let originalPhysical: AudioStreamBasicDescription
    private let originalVirtual: AudioStreamBasicDescription
    private let restored = Atomic<Bool>(false)

    init(plan: DoPTransportPlan) throws {
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

    let configuredDevice: ConfiguredDevice
    let source: DSFDoPSource
    let startingSample: UInt64
    let channelCount: Int

    private let ring: SPSCFloatRingBuffer
    private let stopRequested = Atomic<Bool>(false)
    private let consumedFrames = Atomic<UInt64>(0)
    private let underrunCount = Atomic<UInt64>(0)
    private let ioStopped = Atomic<Bool>(false)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputTimeline: DoPOutputTimeline

    init(configuredDevice: ConfiguredDevice, source: DSFDoPSource, startingSample: UInt64) {
        self.configuredDevice = configuredDevice
        self.source = source
        self.startingSample = startingSample
        channelCount = max(1, Int(configuredDevice.physicalFormat.mChannelsPerFrame))
        ring = SPSCFloatRingBuffer(capacityFrames: Self.ringCapacityFrames, channelCount: channelCount)
        let format = CoreAudioHALFormatProbe.describe(configuredDevice.physicalFormat)
        outputTimeline = DoPOutputTimeline(format: format, channelCount: channelCount)
    }

    func prefill() throws {
        while ring.availableFrames < Self.prebufferFrames {
            let writable = min(Self.workerChunkFrames, ring.writableFrames)
            guard writable > 0 else { break }
            let samples = try source.read(maximumDoPFrames: writable)
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
                    let samples = try source.read(maximumDoPFrames: writable)
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
        thread.name = "foofoil.hifi.dsf-reader"
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
        state: HALDSFPlaybackState,
        failureDescription: String? = nil
    ) -> HALDSFPlaybackStatus {
        HALDSFPlaybackStatus(
            state: state,
            samplePosition: min(
                startingSample + consumedFrames.load(ordering: .acquiring) * 16,
                source.sampleCount
            ),
            sampleCount: source.sampleCount,
            underrunCount: underrunCount.load(ordering: .acquiring),
            outputChannelCount: channelCount,
            failureDescription: failureDescription
        )
    }

    /// HAL realtime callback：只从预分配 ring 复制并在 underrun 时补合法 DoP 静音。
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
        }
        // ring 内 marker 属于 producer 时间线；发生 underrun 后必须按 HAL 时间线重写相位。
        outputTimeline.render(
            interleavedSamples: output,
            sourceFrameCount: readFrames,
            totalFrameCount: frameCount
        )
    }
}
