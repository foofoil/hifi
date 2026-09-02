import Foundation

public enum DSDContainerKind: String, Codable, Sendable {
    case dsf
    case dff
}

public enum DSDCompression: String, Codable, Sendable {
    case rawDSD
    case dst
}

public enum DSDBitOrder: String, Codable, Sendable {
    case leastSignificantBitFirst
    case mostSignificantBitFirst
}

public struct DSDContainerDescriptor: Codable, Equatable, Sendable {
    public let kind: DSDContainerKind
    public let compression: DSDCompression
    public let sampleRate: Int
    public let channelCount: Int
    public let sampleCount: UInt64?
    public let blockSizePerChannel: Int?
    public let bitOrder: DSDBitOrder
    public let audioDataOffset: UInt64
    public let audioDataByteCount: UInt64
    public let metadataOffset: UInt64?

    public var duration: TimeInterval? {
        sampleCount.map { TimeInterval($0) / TimeInterval(sampleRate) }
    }
}

public enum DSDContainerError: Error, Equatable, Sendable {
    case unsupportedContainer
    case truncated
    case invalidChunk(String)
    case invalidFormat
    case missingFormat
    case missingAudioData
    case unsupportedCompression(String)
}

public enum DSDContainerParser {
    /// 使用映射读取避免把大型 DSD 文件整体复制进堆内存；实际音频流读取将在 Engine 中按块进行。
    public static func parse(fileAt url: URL) throws -> DSDContainerDescriptor {
        try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func parse(_ data: Data) throws -> DSDContainerDescriptor {
        switch try data.ascii(at: 0, count: 4) {
        case "DSD ": try parseDSF(data)
        case "FRM8": try parseDFF(data)
        default: throw DSDContainerError.unsupportedContainer
        }
    }

    private static func parseDSF(_ data: Data) throws -> DSDContainerDescriptor {
        guard data.count >= 28 else { throw DSDContainerError.truncated }
        let headerSize = try data.uint64LE(at: 4)
        let declaredFileSize = try data.uint64LE(at: 12)
        let metadataPointer = try data.uint64LE(at: 20)
        guard headerSize >= 28,
              declaredFileSize >= headerSize,
              declaredFileSize <= UInt64(data.count),
              metadataPointer == 0 || metadataPointer < declaredFileSize else {
            throw DSDContainerError.invalidFormat
        }

        var offset = try checkedInt(headerSize)
        // DSF 的 ID3 数据位于普通 chunk 之后，不带 DSF chunk header；扫描必须在 metadata pointer 停止。
        let chunkAreaEnd = try checkedInt(metadataPointer == 0 ? declaredFileSize : metadataPointer)
        var format: (
            sampleRate: Int,
            channels: Int,
            sampleCount: UInt64,
            blockSize: Int,
            bitOrder: DSDBitOrder
        )?
        var audio: (offset: UInt64, byteCount: UInt64)?

        while offset < chunkAreaEnd {
            guard offset <= data.count - 12 else { throw DSDContainerError.truncated }
            let identifier = try data.ascii(at: offset, count: 4)
            let chunkSize = try data.uint64LE(at: offset + 4)
            guard chunkSize >= 12 else { throw DSDContainerError.invalidChunk(identifier) }
            let chunkEnd = try checkedAdd(UInt64(offset), chunkSize)
            guard chunkEnd <= UInt64(chunkAreaEnd) else { throw DSDContainerError.truncated }

            switch identifier {
            case "fmt ":
                guard chunkSize >= 52 else { throw DSDContainerError.invalidChunk(identifier) }
                let formatVersion = try data.uint32LE(at: offset + 12)
                let formatID = try data.uint32LE(at: offset + 16)
                let channels = try data.uint32LE(at: offset + 24)
                let sampleRate = try data.uint32LE(at: offset + 28)
                let bitsPerSample = try data.uint32LE(at: offset + 32)
                let sampleCount = try data.uint64LE(at: offset + 36)
                let blockSize = try data.uint32LE(at: offset + 44)
                guard formatVersion == 1, formatID == 0,
                      (1...32).contains(channels), sampleRate > 0,
                      bitsPerSample == 1 || bitsPerSample == 8,
                      sampleCount > 0, blockSize > 0 else {
                    throw DSDContainerError.invalidFormat
                }
                format = (
                    Int(sampleRate),
                    Int(channels),
                    sampleCount,
                    Int(blockSize),
                    bitsPerSample == 1 ? .leastSignificantBitFirst : .mostSignificantBitFirst
                )
            case "data":
                audio = (UInt64(offset + 12), chunkSize - 12)
            default:
                break
            }
            offset = try checkedInt(chunkEnd)
        }

        guard let format else { throw DSDContainerError.missingFormat }
        guard let audio, audio.byteCount > 0 else { throw DSDContainerError.missingAudioData }
        return DSDContainerDescriptor(
            kind: .dsf,
            compression: .rawDSD,
            sampleRate: format.sampleRate,
            channelCount: format.channels,
            sampleCount: format.sampleCount,
            blockSizePerChannel: format.blockSize,
            bitOrder: format.bitOrder,
            audioDataOffset: audio.offset,
            audioDataByteCount: audio.byteCount,
            metadataOffset: metadataPointer == 0 ? nil : metadataPointer
        )
    }

    private static func parseDFF(_ data: Data) throws -> DSDContainerDescriptor {
        guard data.count >= 16 else { throw DSDContainerError.truncated }
        let formSize = try data.uint64BE(at: 4)
        guard try data.ascii(at: 12, count: 4) == "DSD ",
              formSize >= 4,
              try checkedAdd(12, formSize) <= UInt64(data.count) else {
            throw DSDContainerError.invalidFormat
        }

        let formEnd = try checkedInt(checkedAdd(12, formSize))
        var offset = 16
        var sampleRate: Int?
        var channelCount: Int?
        var compression: DSDCompression?
        var audio: (offset: UInt64, byteCount: UInt64)?

        while offset < formEnd {
            let chunk = try dffChunk(in: data, at: offset, limit: formEnd)
            switch chunk.identifier {
            case "PROP":
                guard chunk.size >= 4,
                      try data.ascii(at: chunk.payloadOffset, count: 4) == "SND " else {
                    throw DSDContainerError.invalidChunk(chunk.identifier)
                }
                var propertyOffset = chunk.payloadOffset + 4
                while propertyOffset < chunk.end {
                    let property = try dffChunk(in: data, at: propertyOffset, limit: chunk.end)
                    switch property.identifier {
                    case "FS  ":
                        guard property.size >= 4 else { throw DSDContainerError.invalidChunk(property.identifier) }
                        sampleRate = Int(try data.uint32BE(at: property.payloadOffset))
                    case "CHNL":
                        guard property.size >= 2 else { throw DSDContainerError.invalidChunk(property.identifier) }
                        channelCount = Int(try data.uint16BE(at: property.payloadOffset))
                    case "CMPR":
                        guard property.size >= 4 else { throw DSDContainerError.invalidChunk(property.identifier) }
                        let identifier = try data.ascii(at: property.payloadOffset, count: 4)
                        switch identifier {
                        case "DSD ": compression = .rawDSD
                        case "DST ": compression = .dst
                        default: throw DSDContainerError.unsupportedCompression(identifier)
                        }
                    default:
                        break
                    }
                    propertyOffset = property.paddedEnd
                }
            case "DSD ":
                compression = compression ?? .rawDSD
                audio = (UInt64(chunk.payloadOffset), chunk.size)
            case "DST ":
                compression = .dst
                audio = (UInt64(chunk.payloadOffset), chunk.size)
            default:
                break
            }
            offset = chunk.paddedEnd
        }

        guard let sampleRate, let channelCount, sampleRate > 0, channelCount > 0 else {
            throw DSDContainerError.missingFormat
        }
        guard let compression else { throw DSDContainerError.missingFormat }
        guard let audio, audio.byteCount > 0 else { throw DSDContainerError.missingAudioData }
        let rawBitCount = audio.byteCount.multipliedReportingOverflow(by: 8)
        guard compression != .rawDSD || !rawBitCount.overflow else {
            throw DSDContainerError.invalidFormat
        }
        let sampleCount = compression == .rawDSD ? rawBitCount.partialValue / UInt64(channelCount) : nil
        return DSDContainerDescriptor(
            kind: .dff,
            compression: compression,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sampleCount: sampleCount,
            blockSizePerChannel: nil,
            bitOrder: .mostSignificantBitFirst,
            audioDataOffset: audio.offset,
            audioDataByteCount: audio.byteCount,
            metadataOffset: nil
        )
    }

    private struct DFFChunk {
        let identifier: String
        let size: UInt64
        let payloadOffset: Int
        let end: Int
        let paddedEnd: Int
    }

    private static func dffChunk(in data: Data, at offset: Int, limit: Int) throws -> DFFChunk {
        guard offset <= limit - 12 else { throw DSDContainerError.truncated }
        let identifier = try data.ascii(at: offset, count: 4)
        let size = try data.uint64BE(at: offset + 4)
        let end = try checkedInt(checkedAdd(UInt64(offset + 12), size))
        guard end <= limit else { throw DSDContainerError.truncated }
        let paddedEnd = try checkedInt(checkedAdd(UInt64(end), size % 2))
        guard paddedEnd <= limit else { throw DSDContainerError.truncated }
        return DFFChunk(
            identifier: identifier,
            size: size,
            payloadOffset: offset + 12,
            end: end,
            paddedEnd: paddedEnd
        )
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw DSDContainerError.invalidFormat }
        return result.partialValue
    }

    private static func checkedInt(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw DSDContainerError.invalidFormat }
        return Int(value)
    }
}

private extension Data {
    func ascii(at offset: Int, count: Int) throws -> String {
        guard offset >= 0, count >= 0, offset <= self.count - count else {
            throw DSDContainerError.truncated
        }
        guard let value = String(data: self[offset..<(offset + count)], encoding: .ascii) else {
            throw DSDContainerError.invalidFormat
        }
        return value
    }

    func uint16BE(at offset: Int) throws -> UInt16 {
        let bytes = try checkedBytes(at: offset, count: 2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        let bytes = try checkedBytes(at: offset, count: 4)
        return bytes.enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    func uint32BE(at offset: Int) throws -> UInt32 {
        let bytes = try checkedBytes(at: offset, count: 4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func uint64LE(at offset: Int) throws -> UInt64 {
        let bytes = try checkedBytes(at: offset, count: 8)
        return bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
    }

    func uint64BE(at offset: Int) throws -> UInt64 {
        let bytes = try checkedBytes(at: offset, count: 8)
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    func checkedBytes(at offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset <= self.count - count else {
            throw DSDContainerError.truncated
        }
        return Array(self[offset..<(offset + count)])
    }
}
