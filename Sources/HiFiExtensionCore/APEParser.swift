//
//  APEParser.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import Foundation

/// Monkey's Audio 整轨描述；块是逐声道的 PCM 帧，与 MAC 的 block 口径一致。
public struct APEAudioDescriptor: Codable, Equatable, Sendable {
    public let fileVersion: Int
    public let compressionLevel: Int
    public let formatFlags: Int
    public let isFloat: Bool
    public let sampleRate: Int
    public let channelCount: Int
    public let bitsPerSample: Int
    public let totalBlocks: UInt64
    public let blocksPerFrame: Int
    public let totalFrames: Int

    public var bytesPerSample: Int { bitsPerSample / 8 }
    public var blockAlign: Int { bytesPerSample * channelCount }

    public var duration: TimeInterval? {
        guard sampleRate > 0 else { return nil }
        return TimeInterval(totalBlocks) / TimeInterval(sampleRate)
    }

    public var compressionName: String {
        switch compressionLevel {
        case 1000: "Fast"
        case 2000: "Normal"
        case 3000: "High"
        case 4000: "Extra High"
        case 5000: "Insane"
        default: "Level \(compressionLevel)"
        }
    }
}

public enum APEParserError: Error, Equatable, Sendable {
    case notAPE
    case truncated
    case invalidFormat
    case unsupportedFormat(String)
}

public enum APEParser {
    public static let compressionFast = 1000
    public static let compressionNormal = 2000
    public static let compressionHigh = 3000
    public static let compressionExtraHigh = 4000
    public static let compressionInsane = 5000

    static let formatFlag8Bit = 1 << 0
    static let formatFlag24Bit = 1 << 3
    static let formatFlagFloatingPoint = 1 << 12

    /// 只读文件头魔数，不打开解码器；供 manifest 匹配与 sniff 使用。
    public static func sniff(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return magic[magic.startIndex] == UInt8(ascii: "M")
            && magic[magic.startIndex + 1] == UInt8(ascii: "A")
            && magic[magic.startIndex + 2] == UInt8(ascii: "C")
            && magic[magic.startIndex + 3] == UInt8(ascii: " ")
    }

    public static func sniff(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[data.startIndex] == UInt8(ascii: "M")
            && data[data.startIndex + 1] == UInt8(ascii: "A")
            && data[data.startIndex + 2] == UInt8(ascii: "C")
            && data[data.startIndex + 3] == UInt8(ascii: " ")
    }

    /// 映射读取只解析文件头，不把整轨解码进内存。
    public static func parse(fileAt url: URL) throws -> APEAudioDescriptor {
        return try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func parse(_ data: Data) throws -> APEAudioDescriptor {
        guard sniff(data) else { throw APEParserError.notAPE }
        guard data.count >= 8 else { throw APEParserError.truncated }
        let version = Int(try data.uint16LE(at: 4))
        if version >= 3980 {
            return try parseNewFormat(data, version: version)
        }
        return try parseOldHeader(data, version: version)
    }

    // MARK: - New descriptor format (>= 3980)

    private static func parseNewFormat(_ data: Data, version: Int) throws -> APEAudioDescriptor {
        guard data.count >= 52 else { throw APEParserError.truncated }
        let descriptorBytes = Int(try data.uint32LE(at: 8))
        let headerBytes = Int(try data.uint32LE(at: 12))
        guard descriptorBytes >= 52, headerBytes >= 24 else { throw APEParserError.invalidFormat }
        guard descriptorBytes <= data.count,
              headerBytes <= data.count - descriptorBytes else {
            throw APEParserError.truncated
        }
        let headerOffset = descriptorBytes
        let compression = Int(try data.uint16LE(at: headerOffset))
        let flags = Int(try data.uint16LE(at: headerOffset + 2))
        let blocksPerFrame = Int(try data.uint32LE(at: headerOffset + 4))
        let finalFrameBlocks = UInt64(try data.uint32LE(at: headerOffset + 8))
        let totalFrames = UInt64(try data.uint32LE(at: headerOffset + 12))
        let bits = Int(try data.uint16LE(at: headerOffset + 16))
        let channels = Int(try data.uint16LE(at: headerOffset + 18))
        let sampleRate = Int(try data.uint32LE(at: headerOffset + 20))
        guard (1000...5000).contains(compression) else {
            throw APEParserError.unsupportedFormat("compression-level-\(compression)")
        }
        guard totalFrames > 0, blocksPerFrame > 0, blocksPerFrame <= 10_000_000,
              finalFrameBlocks <= UInt64(blocksPerFrame) else {
            throw APEParserError.invalidFormat
        }
        guard (1...8).contains(channels) else {
            throw APEParserError.unsupportedFormat("channels-\(channels)")
        }
        guard [8, 16, 24, 32].contains(bits), sampleRate > 0 else {
            throw APEParserError.invalidFormat
        }
        let isFloat = (flags & formatFlagFloatingPoint) != 0
        if isFloat, bits != 32 { throw APEParserError.invalidFormat }
        let totalBlocks = (totalFrames - 1) * UInt64(blocksPerFrame) + finalFrameBlocks
        guard totalBlocks > 0 else { throw APEParserError.invalidFormat }
        return APEAudioDescriptor(
            fileVersion: version,
            compressionLevel: compression,
            formatFlags: flags,
            isFloat: isFloat,
            sampleRate: sampleRate,
            channelCount: channels,
            bitsPerSample: bits,
            totalBlocks: totalBlocks,
            blocksPerFrame: blocksPerFrame,
            totalFrames: Int(totalFrames)
        )
    }

    // MARK: - Old header format (< 3980)

    private static func parseOldHeader(_ data: Data, version: Int) throws -> APEAudioDescriptor {
        guard version >= 3800 else {
            throw APEParserError.unsupportedFormat("version-\(version)")
        }
        guard data.count >= 32 else { throw APEParserError.truncated }
        let compression = Int(try data.uint16LE(at: 6))
        let flags = Int(try data.uint16LE(at: 8))
        let channels = Int(try data.uint16LE(at: 10))
        let sampleRate = Int(try data.uint32LE(at: 12))
        let totalFrames = UInt64(try data.uint32LE(at: 24))
        let finalFrameBlocks = UInt64(try data.uint32LE(at: 28))
        guard (1000...5000).contains(compression) else {
            throw APEParserError.unsupportedFormat("compression-level-\(compression)")
        }
        guard (1...2).contains(channels) else {
            throw APEParserError.unsupportedFormat("channels-\(channels)")
        }
        guard sampleRate > 0, totalFrames > 0 else { throw APEParserError.invalidFormat }
        // 口径与 MACLib AnalyzeOld 一致：3950 起每帧 73728*4，否则 3900 起 73728（3800 Extra High 除外 9216）。
        let blocksPerFrame: Int
        if version >= 3950 {
            blocksPerFrame = 73728 * 4
        } else if version >= 3900 || compression == compressionExtraHigh {
            blocksPerFrame = 73728
        } else {
            blocksPerFrame = 9216
        }
        guard finalFrameBlocks <= UInt64(blocksPerFrame) else { throw APEParserError.invalidFormat }
        let bits: Int
        if (flags & formatFlag8Bit) != 0 {
            bits = 8
        } else if (flags & formatFlag24Bit) != 0 {
            bits = 24
        } else {
            bits = 16
        }
        let isFloat = (flags & formatFlagFloatingPoint) != 0
        if isFloat, bits != 32 { throw APEParserError.invalidFormat }
        let totalBlocks = (totalFrames - 1) * UInt64(blocksPerFrame) + finalFrameBlocks
        guard totalBlocks > 0 else { throw APEParserError.invalidFormat }
        return APEAudioDescriptor(
            fileVersion: version,
            compressionLevel: compression,
            formatFlags: flags,
            isFloat: isFloat,
            sampleRate: sampleRate,
            channelCount: channels,
            bitsPerSample: bits,
            totalBlocks: totalBlocks,
            blocksPerFrame: blocksPerFrame,
            totalFrames: Int(totalFrames)
        )
    }
}

private extension Data {
    func uint16LE(at offset: Int) throws -> UInt16 {
        let base = startIndex + offset
        guard offset >= 0, base <= endIndex - 2 else { throw APEParserError.truncated }
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        let base = startIndex + offset
        guard offset >= 0, base <= endIndex - 4 else { throw APEParserError.truncated }
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
