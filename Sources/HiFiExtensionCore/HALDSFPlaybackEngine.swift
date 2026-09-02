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
    public let failureDescription: String?
}

public enum HALDSFPlaybackError: Error, Equatable, Sendable {
    case unsupportedSource
    case invalidStartPosition
    case outputBufferLayout
}

/// Phase 0 的进程内播放引擎；文件读取与 DoP 封装在 worker，HAL callback 只消费固定缓冲。
public final class HALDSFPlaybackEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSession: PlaybackSession?
    private var lastStatus = HALDSFPlaybackStatus(
        state: .idle,
        samplePosition: 0,
        sampleCount: 0,
        underrunCount: 0,
        failureDescription: nil
    )

    public init() {}

    deinit {
        _ = try? stop()
    }

    public func play(fileAt url: URL, deviceUID: String, startingSample: UInt64 = 0) throws {
        try stop()
        let descriptor = try DSDContainerParser.parse(fileAt: url)
        guard descriptor.kind == .dsf,
              descriptor.compression == .rawDSD,
              descriptor.channelCount == 2,
              let sampleCount = descriptor.sampleCount else {
            throw HALDSFPlaybackError.unsupportedSource
        }
        guard startingSample <= sampleCount, startingSample.isMultiple(of: 16) else {
            throw HALDSFPlaybackError.invalidStartPosition
        }

        let plan = try CoreAudioHALFormatProbe.plan(
            deviceUID: deviceUID,
            dsdSampleRate: descriptor.sampleRate
        )
        let configured = try ConfiguredDevice(plan: plan)
        do {
            let source = try DSFDoPSource(
                fileAt: url,
                physicalFormat: CoreAudioHALFormatProbe.describe(configured.physicalFormat)
            )
            try source.seek(toSample: startingSample)
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
            lock.unlock()
            session.startProducer { [weak self, weak session] failure in
                guard let self, let session else { return }
                self.finish(session: session, failure: failure)
            }
        } catch {
            try? configured.restore()
            throw error
        }
    }

    @discardableResult
    public func stop() throws -> HALDSFPlaybackStatus {
        lock.lock()
        let session = activeSession
        activeSession = nil
        lock.unlock()
        guard let session else { return status() }

        session.requestStop()
        let cleanupError = session.stopIOAndRestore()
        let stopped = session.status(
            state: cleanupError == nil ? .stopped : .failed,
            failureDescription: cleanupError.map(String.init(describing:))
        )
        lock.lock()
        lastStatus = stopped
        lock.unlock()
        if let cleanupError { throw cleanupError }
        return stopped
    }

    public func status() -> HALDSFPlaybackStatus {
        lock.lock()
        defer { lock.unlock() }
        return activeSession?.status(state: .playing) ?? lastStatus
    }

    private func finish(session: PlaybackSession, failure: Error?) {
        lock.lock()
        guard activeSession === session else {
            lock.unlock()
            return
        }
        activeSession = nil
        lock.unlock()

        session.requestStop()
        let cleanupError = session.stopIOAndRestore()
        let finalError = failure ?? cleanupError
        let finalStatus = session.status(
            state: finalError == nil ? .stopped : .failed,
            failureDescription: finalError.map(String.init(describing:))
        )
        lock.lock()
        lastStatus = finalStatus
        lock.unlock()
    }
}

private final class ConfiguredDevice: @unchecked Sendable {
    let deviceID: AudioDeviceID
    let streamID: AudioStreamID
    let physicalFormat: AudioStreamBasicDescription
    let virtualFormat: AudioStreamBasicDescription

    private let originalPhysical: AudioStreamBasicDescription
    private let originalVirtual: AudioStreamBasicDescription
    private let acquiredHogMode: Bool
    private let restored = Atomic<Bool>(false)

    init(plan: DoPTransportPlan) throws {
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
        acquiredHogMode = try CoreAudioHALFormatProbe.acquireHogModeIfAvailable(deviceID: deviceID)

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

    private let ring = SPSCFloatRingBuffer(capacityFrames: ringCapacityFrames, channelCount: 2)
    private let stopRequested = Atomic<Bool>(false)
    private let consumedFrames = Atomic<UInt64>(0)
    private let underrunCount = Atomic<UInt64>(0)
    private let ioStopped = Atomic<Bool>(false)
    private var ioProcID: AudioDeviceIOProcID?
    private var renderedTimelineFrames: UInt64 = 0
    private let silence05: Float32
    private let silenceFA: Float32

    init(configuredDevice: ConfiguredDevice, source: DSFDoPSource, startingSample: UInt64) {
        self.configuredDevice = configuredDevice
        self.source = source
        self.startingSample = startingSample
        let format = CoreAudioHALFormatProbe.describe(configuredDevice.physicalFormat)
        let packed05 = DoPFrameEncoder.pack(0x0005_6969, for: format)
        let packedFA = DoPFrameEncoder.pack(0x00FA_6969, for: format)
        silence05 = DoPFrameEncoder.float32Sample(forPackedPhysicalWord: packed05)
        silenceFA = DoPFrameEncoder.float32Sample(forPackedPhysicalWord: packedFA)
    }

    func prefill() throws {
        while ring.availableFrames < Self.prebufferFrames {
            let writable = min(Self.workerChunkFrames, ring.writableFrames)
            guard writable > 0 else { break }
            let samples = try source.read(maximumDoPFrames: writable)
            guard !samples.isEmpty else { break }
            let written = samples.withUnsafeBufferPointer { ring.write(interleavedSamples: $0) }
            guard written == samples.count / 2 else { break }
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
                    guard written == samples.count / 2 else { continue }
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
            failureDescription: failureDescription
        )
    }

    /// HAL realtime callback：只从预分配 ring 复制并在 underrun 时补合法 DoP 静音。
    private func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard buffers.count == 1,
              let data = buffers[0].mData,
              buffers[0].mNumberChannels == 2 else {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let frameCount = Int(buffers[0].mDataByteSize) / (2 * MemoryLayout<Float32>.size)
        let output = data.assumingMemoryBound(to: Float32.self)
        let readFrames = ring.read(into: output, maximumFrames: frameCount)
        consumedFrames.wrappingAdd(UInt64(readFrames), ordering: .relaxed)
        if readFrames < frameCount {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            for frame in readFrames..<frameCount {
                let value = (renderedTimelineFrames + UInt64(frame)).isMultiple(of: 2)
                    ? silence05
                    : silenceFA
                output[frame * 2] = value
                output[frame * 2 + 1] = value
            }
        }
        renderedTimelineFrames += UInt64(frameCount)
    }
}
