import CoreAudio
import Foundation

public struct PCMExclusiveDeviceStatus: Equatable, Sendable {
    public let deviceUID: String
    public let sourceSampleRate: Double
    public let activeSampleRate: Double
    public let sampleRateMatched: Bool
}

/// 为宿主 AVAudioEngine 持有 PCM 独占和设备格式；音频帧不会跨扩展 ABI。
public final class PCMExclusiveDeviceLease: @unchecked Sendable {
    public private(set) var status: PCMExclusiveDeviceStatus

    private let deviceID: AudioDeviceID
    private let streamID: AudioStreamID
    private let originalNominalSampleRate: Double
    private let originalPhysicalFormat: AudioStreamBasicDescription
    private let originalVirtualFormat: AudioStreamBasicDescription
    private let acquiredHogMode: Bool
    private let lock = NSLock()
    private var restored = false

    public init(deviceUID: String, sourceSampleRate: Double, channelCount: Int) throws {
        guard sourceSampleRate.isFinite, sourceSampleRate > 0, channelCount > 0 else {
            throw CoreAudioHALFormatProbeError.propertyNotSettable
        }
        deviceID = try CoreAudioHALFormatProbe.resolveDeviceID(uid: deviceUID)
        let streams = try CoreAudioHALFormatProbe.outputStreams(deviceID: deviceID)
        guard let selected = try Self.selectStream(
            streams,
            sourceSampleRate: sourceSampleRate,
            channelCount: channelCount
        ) else {
            throw CoreAudioHALFormatProbeError.noOutputStream
        }
        streamID = selected.streamID
        originalNominalSampleRate = try Self.nominalSampleRate(deviceID: deviceID)
        originalPhysicalFormat = try CoreAudioHALFormatProbe.currentFormat(
            streamID: streamID,
            selector: kAudioStreamPropertyPhysicalFormat
        )
        originalVirtualFormat = try CoreAudioHALFormatProbe.currentFormat(
            streamID: streamID,
            selector: kAudioStreamPropertyVirtualFormat
        )
        acquiredHogMode = try CoreAudioHALFormatProbe.acquireHogModeIfAvailable(deviceID: deviceID)
        guard acquiredHogMode else { throw CoreAudioHALFormatProbeError.hogModeAcquireFailed }
        status = PCMExclusiveDeviceStatus(
            deviceUID: deviceUID,
            sourceSampleRate: sourceSampleRate,
            activeSampleRate: originalNominalSampleRate,
            sampleRateMatched: abs(originalNominalSampleRate - sourceSampleRate) < 0.5
        )

        do {
            if let target = selected.targetFormat {
                if abs(originalNominalSampleRate - sourceSampleRate) >= 0.5 {
                    try Self.setNominalSampleRate(sourceSampleRate, deviceID: deviceID)
                    _ = try Self.waitForNominalSampleRate(sourceSampleRate, deviceID: deviceID)
                }
                let activePhysicalFormat = try CoreAudioHALFormatProbe.currentFormat(
                    streamID: streamID,
                    selector: kAudioStreamPropertyPhysicalFormat
                )
                if !CoreAudioHALFormatProbe.matches(activePhysicalFormat, target) {
                    try CoreAudioHALFormatProbe.setStreamFormat(
                        target,
                        streamID: streamID,
                        selector: kAudioStreamPropertyPhysicalFormat
                    )
                    _ = try CoreAudioHALFormatProbe.waitForFormat(
                        target,
                        streamID: streamID,
                        selector: kAudioStreamPropertyPhysicalFormat
                    )
                }
            }
            let activeRate = try Self.nominalSampleRate(deviceID: deviceID)
            status = PCMExclusiveDeviceStatus(
                deviceUID: deviceUID,
                sourceSampleRate: sourceSampleRate,
                activeSampleRate: activeRate,
                sampleRateMatched: abs(activeRate - sourceSampleRate) < 0.5
            )
        } catch {
            try? restore()
            throw error
        }
    }

    deinit { try? restore() }

    @discardableResult
    public func refreshStatus() throws -> PCMExclusiveDeviceStatus {
        let activeRate = try Self.nominalSampleRate(deviceID: deviceID)
        status = PCMExclusiveDeviceStatus(
            deviceUID: status.deviceUID,
            sourceSampleRate: status.sourceSampleRate,
            activeSampleRate: activeRate,
            sampleRateMatched: abs(activeRate - status.sourceSampleRate) < 0.5
        )
        return status
    }

    public func restore() throws {
        lock.lock()
        guard !restored else {
            lock.unlock()
            return
        }
        restored = true
        lock.unlock()

        guard CoreAudioHALFormatProbe.isDeviceAlive(deviceID) else {
            if acquiredHogMode { try? CoreAudioHALFormatProbe.releaseHogMode(deviceID: deviceID) }
            return
        }
        var firstError: Error?
        do {
            let current = try CoreAudioHALFormatProbe.currentFormat(
                streamID: streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            if !CoreAudioHALFormatProbe.matches(current, originalVirtualFormat) {
                try CoreAudioHALFormatProbe.setStreamFormat(
                    originalVirtualFormat,
                    streamID: streamID,
                    selector: kAudioStreamPropertyVirtualFormat
                )
                _ = try CoreAudioHALFormatProbe.waitForFormat(
                    originalVirtualFormat,
                    streamID: streamID,
                    selector: kAudioStreamPropertyVirtualFormat
                )
            }
        } catch { firstError = error }
        do {
            let current = try CoreAudioHALFormatProbe.currentFormat(
                streamID: streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            if !CoreAudioHALFormatProbe.matches(current, originalPhysicalFormat) {
                try CoreAudioHALFormatProbe.setStreamFormat(
                    originalPhysicalFormat,
                    streamID: streamID,
                    selector: kAudioStreamPropertyPhysicalFormat
                )
                _ = try CoreAudioHALFormatProbe.waitForFormat(
                    originalPhysicalFormat,
                    streamID: streamID,
                    selector: kAudioStreamPropertyPhysicalFormat
                )
            }
        } catch { firstError = firstError ?? error }
        do {
            let current = try Self.nominalSampleRate(deviceID: deviceID)
            if abs(current - originalNominalSampleRate) >= 0.5 {
                try Self.setNominalSampleRate(originalNominalSampleRate, deviceID: deviceID)
                _ = try Self.waitForNominalSampleRate(originalNominalSampleRate, deviceID: deviceID)
            }
        } catch { firstError = firstError ?? error }
        if acquiredHogMode {
            do { try CoreAudioHALFormatProbe.releaseHogMode(deviceID: deviceID) }
            catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    private struct StreamSelection {
        let streamID: AudioStreamID
        let targetFormat: AudioStreamBasicDescription?
    }

    private static func selectStream(
        _ streams: [AudioStreamID],
        sourceSampleRate: Double,
        channelCount: Int
    ) throws -> StreamSelection? {
        var fallback: StreamSelection?
        for streamID in streams {
            let current = try CoreAudioHALFormatProbe.currentFormat(
                streamID: streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            if fallback == nil { fallback = StreamSelection(streamID: streamID, targetFormat: nil) }
            let candidates = try CoreAudioHALFormatProbe.availableFormats(streamID: streamID)
                .compactMap { ranged -> AudioStreamBasicDescription? in
                    var format = ranged.mFormat
                    guard format.mFormatID == kAudioFormatLinearPCM,
                          format.mChannelsPerFrame >= UInt32(channelCount),
                          ranged.mSampleRateRange.mMinimum <= sourceSampleRate,
                          sourceSampleRate <= ranged.mSampleRateRange.mMaximum else { return nil }
                    format.mSampleRate = sourceSampleRate
                    return format
                }
                .sorted { lhs, rhs in
                    let lhsCurrent = lhs.mFormatFlags == current.mFormatFlags
                        && lhs.mBitsPerChannel == current.mBitsPerChannel
                        && lhs.mChannelsPerFrame == current.mChannelsPerFrame
                    let rhsCurrent = rhs.mFormatFlags == current.mFormatFlags
                        && rhs.mBitsPerChannel == current.mBitsPerChannel
                        && rhs.mChannelsPerFrame == current.mChannelsPerFrame
                    if lhsCurrent != rhsCurrent { return lhsCurrent }
                    return lhs.mBitsPerChannel > rhs.mBitsPerChannel
                }
            if let target = candidates.first {
                return StreamSelection(streamID: streamID, targetFormat: target)
            }
        }
        return fallback
    }

    private static func nominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = nominalSampleRateAddress
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        let result = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard result == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(result) }
        return rate
    }

    private static func setNominalSampleRate(_ rate: Double, deviceID: AudioDeviceID) throws {
        var address = nominalSampleRateAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else {
            throw CoreAudioHALFormatProbeError.propertyNotSettable
        }
        var rate = rate
        let result = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &rate
        )
        guard result == noErr else { throw CoreAudioHALFormatProbeError.propertyWrite(result) }
    }

    private static func waitForNominalSampleRate(
        _ expected: Double,
        deviceID: AudioDeviceID
    ) throws -> Double {
        for _ in 0..<50 {
            let actual = try nominalSampleRate(deviceID: deviceID)
            if abs(actual - expected) < 0.5 { return actual }
            usleep(20_000)
        }
        throw CoreAudioHALFormatProbeError.formatChangeTimedOut
    }

    private static var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
