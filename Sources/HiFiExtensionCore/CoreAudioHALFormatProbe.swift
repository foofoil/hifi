import CoreAudio
import Darwin
import Foundation
import Synchronization

public struct DoPTransportPlan: Codable, Equatable, Sendable {
    public let deviceUID: String
    public let streamID: UInt32
    public let dsdSampleRate: Int
    public let pcmCarrierSampleRate: Double
    public let physicalFormat: HiFiAudioPhysicalFormat
}

public struct HALFormatProbeResult: Codable, Equatable, Sendable {
    public let plan: DoPTransportPlan
    public let appliedFormat: HiFiAudioPhysicalFormat
    public let restoredFormat: HiFiAudioPhysicalFormat
}

public struct HALDoPSilenceProbeResult: Codable, Equatable, Sendable {
    public let plan: DoPTransportPlan
    public let duration: TimeInterval
    public let appliedPhysicalFormat: HiFiAudioPhysicalFormat
    public let appliedVirtualFormat: HiFiAudioPhysicalFormat
    public let restoredPhysicalFormat: HiFiAudioPhysicalFormat
    public let restoredVirtualFormat: HiFiAudioPhysicalFormat
    public let callbackDiagnostics: HALIOCallbackDiagnostics
    public let usedHogMode: Bool
}

public struct HALIOCallbackDiagnostics: Codable, Equatable, Sendable {
    public let callbackCount: UInt64
    public let firstBufferCount: UInt32
    public let firstActiveBufferCount: UInt32
    public let firstChannelCount: UInt32
    public let firstMaximumFrameCount: UInt32
    public let totalRenderedFrames: UInt64
    public let packedMarker05Word: UInt32
    public let packedMarkerFAWord: UInt32
}

public enum CoreAudioHALFormatProbeError: Error, Equatable, Sendable {
    case unsupportedDSDRate(Int)
    case deviceNotFound(String)
    case noOutputStream
    case noDoPTransport(Int)
    case propertyRead(OSStatus)
    case propertyNotSettable
    case propertyWrite(OSStatus)
    case formatChangeTimedOut
    case formatRestoreFailed
    case invalidProbeDuration
    case unsupportedBufferLayout
    case ioProcCreate(OSStatus)
    case ioStart(OSStatus)
    case ioStop(OSStatus)
    case ioProcDestroy(OSStatus)
    case deviceInUse(pid_t)
    case hogModeAcquireFailed
    case hogModeReleaseFailed
}

public enum CoreAudioHALFormatProbe {
    public static func plan(deviceUID: String, dsdSampleRate: Int) throws -> DoPTransportPlan {
        let carrierRate = try carrierSampleRate(for: dsdSampleRate)
        let deviceID = try resolveDeviceID(uid: deviceUID)
        let streams = try outputStreams(deviceID: deviceID)
        guard !streams.isEmpty else { throw CoreAudioHALFormatProbeError.noOutputStream }

        let candidates = try streams.flatMap { streamID in
            try availableFormats(streamID: streamID).compactMap { ranged -> RawCandidate? in
                let format = ranged.mFormat
                guard ranged.mSampleRateRange.mMinimum <= carrierRate,
                      carrierRate <= ranged.mSampleRateRange.mMaximum,
                      format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                      format.mChannelsPerFrame >= 2,
                      format.mBitsPerChannel >= 24 else { return nil }
                var exact = format
                exact.mSampleRate = carrierRate
                return RawCandidate(streamID: streamID, format: exact)
            }
        }
        guard let selected = candidates.sorted(by: preferredCandidate).first else {
            throw CoreAudioHALFormatProbeError.noDoPTransport(dsdSampleRate)
        }
        return DoPTransportPlan(
            deviceUID: deviceUID,
            streamID: selected.streamID,
            dsdSampleRate: dsdSampleRate,
            pcmCarrierSampleRate: carrierRate,
            physicalFormat: describe(selected.format)
        )
    }

    /// 仅用于显式诊断：设置后立即读回，并在返回前恢复原格式。
    public static func applyAndRestore(_ plan: DoPTransportPlan) throws -> HALFormatProbeResult {
        let deviceID = try resolveDeviceID(uid: plan.deviceUID)
        guard try outputStreams(deviceID: deviceID).contains(plan.streamID) else {
            throw CoreAudioHALFormatProbeError.noOutputStream
        }
        let original = try currentFormat(streamID: plan.streamID)
        let candidates = try availableFormats(streamID: plan.streamID)
        guard let target = candidates.compactMap({ ranged -> AudioStreamBasicDescription? in
            var format = ranged.mFormat
            guard ranged.mSampleRateRange.mMinimum <= plan.pcmCarrierSampleRate,
                  plan.pcmCarrierSampleRate <= ranged.mSampleRateRange.mMaximum,
                  describe(format).formatFlags == plan.physicalFormat.formatFlags,
                  format.mBitsPerChannel == plan.physicalFormat.bitsPerChannel,
                  format.mBytesPerFrame == plan.physicalFormat.bytesPerFrame else { return nil }
            format.mSampleRate = plan.pcmCarrierSampleRate
            return format
        }).first else {
            throw CoreAudioHALFormatProbeError.noDoPTransport(plan.dsdSampleRate)
        }

        do {
            try setPhysicalFormat(target, streamID: plan.streamID)
            let applied = try waitForFormat(target, streamID: plan.streamID)
            do {
                try setPhysicalFormat(original, streamID: plan.streamID)
                let restored = try waitForFormat(original, streamID: plan.streamID)
                _ = deviceID
                return HALFormatProbeResult(
                    plan: plan,
                    appliedFormat: describe(applied),
                    restoredFormat: describe(restored)
                )
            } catch {
                throw CoreAudioHALFormatProbeError.formatRestoreFailed
            }
        } catch {
            try? setPhysicalFormat(original, streamID: plan.streamID)
            _ = try? waitForFormat(original, streamID: plan.streamID)
            throw error
        }
    }

    /// 输出短时 DoP 静音；只允许显式诊断调用，并在退出前恢复 virtual/physical format。
    public static func outputDoPSilenceAndRestore(
        _ plan: DoPTransportPlan,
        duration: TimeInterval
    ) throws -> HALDoPSilenceProbeResult {
        guard duration.isFinite, (0.1...5).contains(duration) else {
            throw CoreAudioHALFormatProbeError.invalidProbeDuration
        }
        let deviceID = try resolveDeviceID(uid: plan.deviceUID)
        guard try outputStreams(deviceID: deviceID).contains(plan.streamID) else {
            throw CoreAudioHALFormatProbeError.noOutputStream
        }
        let originalPhysical = try currentFormat(
            streamID: plan.streamID,
            selector: kAudioStreamPropertyPhysicalFormat
        )
        let originalVirtual = try currentFormat(
            streamID: plan.streamID,
            selector: kAudioStreamPropertyVirtualFormat
        )
        let physicalTarget = try targetFormat(for: plan)
        let virtualTarget = float32VirtualFormat(for: physicalTarget)
        guard physicalTarget.mBytesPerFrame / max(physicalTarget.mChannelsPerFrame, 1) == 4,
              physicalTarget.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              virtualTarget.mBytesPerFrame / max(virtualTarget.mChannelsPerFrame, 1) == 4,
              virtualTarget.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            throw CoreAudioHALFormatProbeError.unsupportedBufferLayout
        }

        var ioProcID: AudioDeviceIOProcID?
        var ioStarted = false
        let renderState = DoPSilenceRenderState(physicalFormat: describe(physicalTarget))
        var appliedPhysical: AudioStreamBasicDescription?
        var appliedVirtual: AudioStreamBasicDescription?
        var primaryError: Error?
        let acquiredHogMode = try acquireHogModeIfAvailable(deviceID: deviceID)
        var hogModeHeld = acquiredHogMode

        do {
            try setStreamFormat(
                physicalTarget,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            appliedPhysical = try waitForFormat(
                physicalTarget,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            // USB Audio 的 DoP 实际链路是 Float32 virtual -> SInt32 physical，不能把两者设成同一格式。
            try setStreamFormat(
                virtualTarget,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            appliedVirtual = try waitForFormat(
                virtualTarget,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )

            let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) {
                _, _, _, outputData, _ in
                renderState.render(outputData)
            }
            guard createStatus == noErr else { throw CoreAudioHALFormatProbeError.ioProcCreate(createStatus) }
            let startStatus = AudioDeviceStart(deviceID, ioProcID)
            guard startStatus == noErr else { throw CoreAudioHALFormatProbeError.ioStart(startStatus) }
            ioStarted = true
            Thread.sleep(forTimeInterval: duration)
        } catch {
            primaryError = error
        }

        if ioStarted {
            let status = AudioDeviceStop(deviceID, ioProcID)
            if status != noErr, primaryError == nil { primaryError = CoreAudioHALFormatProbeError.ioStop(status) }
        }
        if let ioProcID {
            let status = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            if status != noErr, primaryError == nil {
                primaryError = CoreAudioHALFormatProbeError.ioProcDestroy(status)
            }
        }

        do {
            try setStreamFormat(
                originalVirtual,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            let restoredVirtual = try waitForFormat(
                originalVirtual,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            try setStreamFormat(
                originalPhysical,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            let restoredPhysical = try waitForFormat(
                originalPhysical,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            if let primaryError { throw primaryError }
            guard let appliedPhysical, let appliedVirtual else {
                throw CoreAudioHALFormatProbeError.formatChangeTimedOut
            }
            if hogModeHeld {
                try releaseHogMode(deviceID: deviceID)
                hogModeHeld = false
            }
            return HALDoPSilenceProbeResult(
                plan: plan,
                duration: duration,
                appliedPhysicalFormat: describe(appliedPhysical),
                appliedVirtualFormat: describe(appliedVirtual),
                restoredPhysicalFormat: describe(restoredPhysical),
                restoredVirtualFormat: describe(restoredVirtual),
                callbackDiagnostics: renderState.diagnostics(),
                usedHogMode: acquiredHogMode
            )
        } catch {
            try? setStreamFormat(
                originalVirtual,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyVirtualFormat
            )
            try? setStreamFormat(
                originalPhysical,
                streamID: plan.streamID,
                selector: kAudioStreamPropertyPhysicalFormat
            )
            if hogModeHeld { try? releaseHogMode(deviceID: deviceID) }
            throw error is CoreAudioHALFormatProbeError
                ? error
                : CoreAudioHALFormatProbeError.formatRestoreFailed
        }
    }

    private struct RawCandidate {
        let streamID: AudioStreamID
        let format: AudioStreamBasicDescription
    }

    private static func carrierSampleRate(for dsdSampleRate: Int) throws -> Double {
        guard [2_822_400, 5_644_800, 11_289_600].contains(dsdSampleRate) else {
            throw CoreAudioHALFormatProbeError.unsupportedDSDRate(dsdSampleRate)
        }
        return Double(dsdSampleRate) / 16
    }

    private static func preferredCandidate(_ lhs: RawCandidate, _ rhs: RawCandidate) -> Bool {
        let lhsScore = candidateScore(lhs.format)
        let rhsScore = candidateScore(rhs.format)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.streamID < rhs.streamID
    }

    /// macOS USB Audio 的已验证 DoP 路径优先使用 32-bit packed、mixable physical format。
    private static func candidateScore(_ format: AudioStreamBasicDescription) -> Int {
        let isPacked = format.mFormatFlags & kAudioFormatFlagIsPacked != 0
        let isNonMixable = format.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
        if format.mBitsPerChannel == 32, isPacked, !isNonMixable { return 400 }
        if format.mBitsPerChannel == 32, isPacked { return 350 }
        if format.mBitsPerChannel == 24, !isPacked, isNonMixable { return 300 }
        return Int(format.mBitsPerChannel)
    }

    static func acquireHogModeIfAvailable(deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let owner = try hogModeOwner(deviceID: deviceID, address: &address)
        if owner == getpid() { return false }
        guard owner == -1 else { throw CoreAudioHALFormatProbeError.deviceInUse(owner) }
        var request = getpid()
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<pid_t>.size),
            &request
        )
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyWrite(status) }
        for _ in 0..<50 {
            let actualOwner = try hogModeOwner(deviceID: deviceID, address: &address)
            if actualOwner == getpid() { return true }
            if actualOwner != -1 { throw CoreAudioHALFormatProbeError.deviceInUse(actualOwner) }
            usleep(20_000)
        }
        throw CoreAudioHALFormatProbeError.hogModeAcquireFailed
    }

    static func releaseHogMode(deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var request = getpid()
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<pid_t>.size),
            &request
        )
        guard status == noErr else { throw CoreAudioHALFormatProbeError.hogModeReleaseFailed }
        // 部分 USB 驱动不会同步改写 SetPropertyData 的输入缓冲，必须重新读取实际 owner。
        for _ in 0..<50 {
            if try hogModeOwner(deviceID: deviceID, address: &address) != getpid() { return }
            usleep(20_000)
        }
        throw CoreAudioHALFormatProbeError.hogModeReleaseFailed
    }

    private static func hogModeOwner(
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) throws -> pid_t {
        var owner = pid_t(-1)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &owner
        )
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        return owner
    }

    static func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = withUnsafeMutablePointer(to: &uidValue) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { devicePointer in
                var translation = AudioValueTranslation(
                    mInputData: uidPointer,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: devicePointer,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    &translation
                )
            }
        }
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioHALFormatProbeError.deviceNotFound(uid)
        }
        return deviceID
    }

    static func outputStreams(deviceID: AudioDeviceID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        guard dataSize > 0 else { return [] }
        var streams = [AudioStreamID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioStreamID>.size
        )
        status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        return streams
    }

    private static func availableFormats(streamID: AudioStreamID) throws -> [AudioStreamRangedDescription] {
        var address = physicalFormatAddress(selector: kAudioStreamPropertyAvailablePhysicalFormats)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize)
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        guard dataSize > 0 else { return [] }
        var formats = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: Int(dataSize) / MemoryLayout<AudioStreamRangedDescription>.size
        )
        status = formats.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, $0.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        return formats
    }

    private static func currentFormat(streamID: AudioStreamID) throws -> AudioStreamBasicDescription {
        try currentFormat(streamID: streamID, selector: kAudioStreamPropertyPhysicalFormat)
    }

    static func currentFormat(
        streamID: AudioStreamID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var address = physicalFormatAddress(selector: selector)
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &format)
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyRead(status) }
        return format
    }

    private static func setPhysicalFormat(
        _ format: AudioStreamBasicDescription,
        streamID: AudioStreamID
    ) throws {
        try setStreamFormat(format, streamID: streamID, selector: kAudioStreamPropertyPhysicalFormat)
    }

    static func setStreamFormat(
        _ format: AudioStreamBasicDescription,
        streamID: AudioStreamID,
        selector: AudioObjectPropertySelector
    ) throws {
        var address = physicalFormatAddress(selector: selector)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(streamID, &address, &settable) == noErr, settable.boolValue else {
            throw CoreAudioHALFormatProbeError.propertyNotSettable
        }
        var format = format
        let status = AudioObjectSetPropertyData(
            streamID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &format
        )
        guard status == noErr else { throw CoreAudioHALFormatProbeError.propertyWrite(status) }
    }

    static func waitForFormat(
        _ expected: AudioStreamBasicDescription,
        streamID: AudioStreamID
    ) throws -> AudioStreamBasicDescription {
        try waitForFormat(
            expected,
            streamID: streamID,
            selector: kAudioStreamPropertyPhysicalFormat
        )
    }

    static func waitForFormat(
        _ expected: AudioStreamBasicDescription,
        streamID: AudioStreamID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        for _ in 0..<50 {
            let actual = try currentFormat(streamID: streamID, selector: selector)
            if matches(actual, expected) { return actual }
            usleep(20_000)
        }
        throw CoreAudioHALFormatProbeError.formatChangeTimedOut
    }

    static func targetFormat(for plan: DoPTransportPlan) throws -> AudioStreamBasicDescription {
        guard let target = try availableFormats(streamID: plan.streamID).compactMap({ ranged -> AudioStreamBasicDescription? in
            var format = ranged.mFormat
            guard ranged.mSampleRateRange.mMinimum <= plan.pcmCarrierSampleRate,
                  plan.pcmCarrierSampleRate <= ranged.mSampleRateRange.mMaximum,
                  format.mFormatFlags == plan.physicalFormat.formatFlags,
                  format.mBitsPerChannel == plan.physicalFormat.bitsPerChannel,
                  format.mBytesPerFrame == plan.physicalFormat.bytesPerFrame else { return nil }
            format.mSampleRate = plan.pcmCarrierSampleRate
            return format
        }).first else {
            throw CoreAudioHALFormatProbeError.noDoPTransport(plan.dsdSampleRate)
        }
        return target
    }

    /// 与 macOS USB Audio 驱动及 PinPlayer 实测一致的客户端侧格式。
    static func float32VirtualFormat(
        for physicalFormat: AudioStreamBasicDescription
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: physicalFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: physicalFormat.mChannelsPerFrame * UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: physicalFormat.mChannelsPerFrame * UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: physicalFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func matches(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        abs(lhs.mSampleRate - rhs.mSampleRate) < 0.5
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
    }

    private static func physicalFormatAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func describe(_ format: AudioStreamBasicDescription) -> HiFiAudioPhysicalFormat {
        let bigEndian = format.mFormatID.bigEndian
        let formatID = withUnsafeBytes(of: bigEndian) {
            String(bytes: $0, encoding: .ascii) ?? String(format: "0x%08X", format.mFormatID)
        }
        return HiFiAudioPhysicalFormat(
            formatID: formatID,
            minimumSampleRate: format.mSampleRate,
            maximumSampleRate: format.mSampleRate,
            channelCount: format.mChannelsPerFrame,
            bitsPerChannel: format.mBitsPerChannel,
            bytesPerFrame: format.mBytesPerFrame,
            formatFlags: format.mFormatFlags,
            isLinearPCM: format.mFormatID == kAudioFormatLinearPCM,
            isFloat: format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            isSignedInteger: format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
            isBigEndian: format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
            isPacked: format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
            isAlignedHigh: format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0,
            isNonMixable: format.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
        )
    }
}

private final class DoPSilenceRenderState: @unchecked Sendable {
    private let packed05: UInt32
    private let packedFA: UInt32
    private let float05: Float32
    private let floatFA: Float32
    private var usesAlternateMarker = false
    private let callbackCount = Atomic<UInt64>(0)
    private let firstBufferCount = Atomic<UInt32>(0)
    private let firstActiveBufferCount = Atomic<UInt32>(0)
    private let firstChannelCount = Atomic<UInt32>(0)
    private let firstMaximumFrameCount = Atomic<UInt32>(0)
    private let totalRenderedFrames = Atomic<UInt64>(0)

    init(physicalFormat: HiFiAudioPhysicalFormat) {
        let payload: UInt32 = 0x6969
        packed05 = DoPFrameEncoder.pack(payload | 0x0005_0000, for: physicalFormat)
        packedFA = DoPFrameEncoder.pack(payload | 0x00FA_0000, for: physicalFormat)
        float05 = DoPFrameEncoder.float32Sample(forPackedPhysicalWord: packed05)
        floatFA = DoPFrameEncoder.float32Sample(forPackedPhysicalWord: packedFA)
    }

    /// 实时回调中只写既有 HAL buffer，不分配、不加锁、不执行 I/O。
    func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        var maximumFrameCount = 0
        var activeBufferCount = 0
        var channelCount = 0
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            activeBufferCount += 1
            channelCount += Int(buffer.mNumberChannels)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<UInt32>.size
            let channelCount = Int(buffer.mNumberChannels)
            let frameCount = sampleCount / channelCount
            maximumFrameCount = max(maximumFrameCount, frameCount)
            let samples = data.assumingMemoryBound(to: Float32.self)
            var alternate = usesAlternateMarker
            for frame in 0..<frameCount {
                let value = alternate ? floatFA : float05
                for channel in 0..<channelCount {
                    samples[frame * channelCount + channel] = value
                }
                alternate.toggle()
            }
        }
        if maximumFrameCount.isMultiple(of: 2) == false {
            usesAlternateMarker.toggle()
        }
        let count = callbackCount.wrappingAdd(1, ordering: .relaxed)
        totalRenderedFrames.wrappingAdd(UInt64(maximumFrameCount), ordering: .relaxed)
        if count.oldValue == 0 {
            firstBufferCount.store(UInt32(buffers.count), ordering: .relaxed)
            firstActiveBufferCount.store(UInt32(activeBufferCount), ordering: .relaxed)
            firstChannelCount.store(UInt32(channelCount), ordering: .relaxed)
            firstMaximumFrameCount.store(UInt32(maximumFrameCount), ordering: .relaxed)
        }
    }

    func diagnostics() -> HALIOCallbackDiagnostics {
        HALIOCallbackDiagnostics(
            callbackCount: callbackCount.load(ordering: .relaxed),
            firstBufferCount: firstBufferCount.load(ordering: .relaxed),
            firstActiveBufferCount: firstActiveBufferCount.load(ordering: .relaxed),
            firstChannelCount: firstChannelCount.load(ordering: .relaxed),
            firstMaximumFrameCount: firstMaximumFrameCount.load(ordering: .relaxed),
            totalRenderedFrames: totalRenderedFrames.load(ordering: .relaxed),
            packedMarker05Word: packed05,
            packedMarkerFAWord: packedFA
        )
    }
}
