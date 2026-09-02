import CoreAudio
import Foundation

public struct HiFiAudioPhysicalFormat: Codable, Equatable, Hashable, Sendable {
    public let formatID: String
    public let minimumSampleRate: Double
    public let maximumSampleRate: Double
    public let channelCount: UInt32
    public let bitsPerChannel: UInt32
    public let bytesPerFrame: UInt32
    public let formatFlags: UInt32
    public let isLinearPCM: Bool
    public let isFloat: Bool
    public let isSignedInteger: Bool
    public let isBigEndian: Bool
    public let isPacked: Bool
    public let isAlignedHigh: Bool
    public let isNonMixable: Bool
}

public struct HiFiAudioOutputDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let isSystemDefault: Bool
    public let isConnected: Bool
    public let hasHardwareVolume: Bool
    public let currentPhysicalFormats: [HiFiAudioPhysicalFormat]
    public let currentVirtualFormats: [HiFiAudioPhysicalFormat]
    public let availablePhysicalFormats: [HiFiAudioPhysicalFormat]
    /// 仅表示物理 PCM 格式可承载 DoP，尚未经过 HAL 打开和 marker 验证。
    public let potentialDoPDSDRates: [Int]
}

public enum CoreAudioDeviceCatalogError: Error, Equatable, Sendable {
    case propertySize(OSStatus)
    case propertyRead(OSStatus)
}

public enum CoreAudioDeviceCatalog {
    public static func outputDevices() throws -> [HiFiAudioOutputDevice] {
        let defaultDeviceID = try readDefaultOutputDeviceID()
        return try readDeviceIDs().compactMap { deviceID in
            guard hasOutputChannels(deviceID),
                  let uid = try readStringProperty(kAudioDevicePropertyDeviceUID, from: deviceID),
                  let name = try readStringProperty(kAudioObjectPropertyName, from: deviceID) else {
                return nil
            }
            let streams = (try? readObjectIDs(
                kAudioDevicePropertyStreams,
                from: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            )) ?? []
            let currentFormats = streams.compactMap {
                try? readCurrentFormat(from: $0, selector: kAudioStreamPropertyPhysicalFormat)
            }
            let currentVirtualFormats = streams.compactMap {
                try? readCurrentFormat(from: $0, selector: kAudioStreamPropertyVirtualFormat)
            }
            let availableFormats = streams.flatMap { (try? readAvailablePhysicalFormats(from: $0)) ?? [] }
            return HiFiAudioOutputDevice(
                id: uid,
                displayName: name,
                isSystemDefault: deviceID == defaultDeviceID,
                isConnected: try readUInt32Property(kAudioDevicePropertyDeviceIsAlive, from: deviceID) != 0,
                hasHardwareVolume: hasHardwareVolume(deviceID),
                currentPhysicalFormats: normalized(currentFormats),
                currentVirtualFormats: normalized(currentVirtualFormats),
                availablePhysicalFormats: normalized(availableFormats),
                potentialDoPDSDRates: potentialDoPDSDRates(from: availableFormats)
            )
        }
        .sorted {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func potentialDoPDSDRates(from formats: [HiFiAudioPhysicalFormat]) -> [Int] {
        let carrierRates: [(pcm: Double, dsd: Int)] = [
            (176_400, 2_822_400),
            (352_800, 5_644_800),
            (705_600, 11_289_600)
        ]
        return carrierRates.compactMap { candidate in
            formats.contains {
                $0.isLinearPCM && !$0.isFloat
                    && $0.channelCount >= 2 && $0.bitsPerChannel >= 24
                    && $0.minimumSampleRate <= candidate.pcm
                    && candidate.pcm <= $0.maximumSampleRate
            } ? candidate.dsd : nil
        }
    }

    private static func normalized(_ formats: [HiFiAudioPhysicalFormat]) -> [HiFiAudioPhysicalFormat] {
        Array(Set(formats)).sorted {
            if $0.minimumSampleRate != $1.minimumSampleRate {
                return $0.minimumSampleRate < $1.minimumSampleRate
            }
            if $0.maximumSampleRate != $1.maximumSampleRate {
                return $0.maximumSampleRate < $1.maximumSampleRate
            }
            if $0.channelCount != $1.channelCount { return $0.channelCount < $1.channelCount }
            if $0.bitsPerChannel != $1.bitsPerChannel { return $0.bitsPerChannel < $1.bitsPerChannel }
            return $0.formatID < $1.formatID
        }
    }

    private static func readDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else { throw CoreAudioDeviceCatalogError.propertySize(sizeStatus) }
        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )
        let readStatus = devices.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard readStatus == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(readStatus) }
        return devices
    }

    private static func readObjectIDs(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else { throw CoreAudioDeviceCatalogError.propertySize(sizeStatus) }
        guard dataSize > 0 else { return [] }
        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        let readStatus = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard readStatus == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(readStatus) }
        return values
    }

    private static func readCurrentFormat(
        from streamID: AudioStreamID,
        selector: AudioObjectPropertySelector
    ) throws -> HiFiAudioPhysicalFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &format)
        guard status == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(status) }
        return physicalFormat(format, sampleRateRange: AudioValueRange(
            mMinimum: format.mSampleRate,
            mMaximum: format.mSampleRate
        ))
    }

    private static func readAvailablePhysicalFormats(
        from streamID: AudioStreamID
    ) throws -> [HiFiAudioPhysicalFormat] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else { throw CoreAudioDeviceCatalogError.propertySize(sizeStatus) }
        guard dataSize > 0 else { return [] }
        var descriptions = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: Int(dataSize) / MemoryLayout<AudioStreamRangedDescription>.size
        )
        let readStatus = descriptions.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard readStatus == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(readStatus) }
        return descriptions.map { physicalFormat($0.mFormat, sampleRateRange: $0.mSampleRateRange) }
    }

    private static func physicalFormat(
        _ format: AudioStreamBasicDescription,
        sampleRateRange: AudioValueRange
    ) -> HiFiAudioPhysicalFormat {
        HiFiAudioPhysicalFormat(
            formatID: fourCharacterCode(format.mFormatID),
            minimumSampleRate: sampleRateRange.mMinimum,
            maximumSampleRate: sampleRateRange.mMaximum,
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

    private static func fourCharacterCode(_ value: FourCharCode) -> String {
        let bigEndian = value.bigEndian
        return withUnsafeBytes(of: bigEndian) { bytes in
            String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
        }
    }

    private static func readDefaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(status) }
        return deviceID
    }

    private static func readStringProperty(
        _ selector: AudioObjectPropertySelector,
        from deviceID: AudioDeviceID
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(status) }
        return value?.takeUnretainedValue() as String?
    }

    private static func readUInt32Property(
        _ selector: AudioObjectPropertySelector,
        from deviceID: AudioDeviceID
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { throw CoreAudioDeviceCatalogError.propertyRead(status) }
        return value
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func hasHardwareVolume(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        return AudioObjectHasProperty(deviceID, &address)
            && AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr
            && isSettable.boolValue
    }
}
