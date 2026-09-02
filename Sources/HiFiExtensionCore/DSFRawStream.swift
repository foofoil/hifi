import Foundation

/// 按 DSF 的 channel-block 布局读取原始 DSD；所有文件 I/O 必须在非实时 worker 上执行。
public final class DSFRawStream: DSDStream {
    public let format: DSDStreamFormat
    public let sampleCount: UInt64

    public var samplePosition: UInt64 { min(bytePosition * 8, sampleCount) }

    private let fileHandle: FileHandle
    private let descriptor: DSDContainerDescriptor
    private let blockSize: UInt64
    private let validBytesPerChannel: UInt64
    private var bytePosition: UInt64 = 0
    private var cachedBlockIndex: UInt64?
    private var cachedBlock = Data()

    public init(fileAt url: URL) throws {
        let descriptor = try DSDContainerParser.parse(fileAt: url)
        guard descriptor.kind == .dsf,
              descriptor.compression == .rawDSD,
              let sampleCount = descriptor.sampleCount,
              let blockSize = descriptor.blockSizePerChannel,
              blockSize > 0 else {
            throw DSDStreamError.unsupportedFormat
        }
        self.descriptor = descriptor
        self.sampleCount = sampleCount
        self.blockSize = UInt64(blockSize)
        validBytesPerChannel = (sampleCount + 7) / 8
        format = DSDStreamFormat(
            sampleRate: descriptor.sampleRate,
            channelCount: descriptor.channelCount,
            bitOrder: .mostSignificantBitFirst
        )
        fileHandle = try FileHandle(forReadingFrom: url)

        let blockCount = (validBytesPerChannel + UInt64(blockSize) - 1) / UInt64(blockSize)
        let requiredBytes = blockCount
            .multipliedReportingOverflow(by: UInt64(blockSize) * UInt64(descriptor.channelCount))
        guard !requiredBytes.overflow, requiredBytes.partialValue <= descriptor.audioDataByteCount else {
            try? fileHandle.close()
            throw DSDStreamError.truncatedAudioData
        }
    }

    deinit {
        try? fileHandle.close()
    }

    public func read(maximumByteFrames: Int) throws -> DSDByteChunk {
        guard maximumByteFrames > 0 else { throw DSDStreamError.invalidReadSize }
        let remaining = validBytesPerChannel - bytePosition
        guard remaining > 0 else {
            return DSDByteChunk(bytesByChannel: Array(repeating: [], count: format.channelCount))
        }
        let requested = min(UInt64(maximumByteFrames), remaining)
        var output = Array(repeating: [UInt8](), count: format.channelCount)
        for channel in output.indices { output[channel].reserveCapacity(Int(requested)) }

        var copied: UInt64 = 0
        while copied < requested {
            let position = bytePosition + copied
            let blockIndex = position / blockSize
            let offsetInBlock = position % blockSize
            try loadBlock(at: blockIndex)
            let count = min(requested - copied, blockSize - offsetInBlock)

            for channel in 0..<format.channelCount {
                let channelOffset = UInt64(channel) * blockSize + offsetInBlock
                let start = Int(channelOffset)
                let end = start + Int(count)
                guard end <= cachedBlock.count else { throw DSDStreamError.truncatedAudioData }
                if descriptor.bitOrder == .leastSignificantBitFirst {
                    output[channel].append(contentsOf: cachedBlock[start..<end].map(Self.reverseBits))
                } else {
                    output[channel].append(contentsOf: cachedBlock[start..<end])
                }
            }
            copied += count
        }
        bytePosition += copied
        return DSDByteChunk(bytesByChannel: output)
    }

    public func seek(toSample sample: UInt64) throws {
        guard sample <= sampleCount else { throw DSDStreamError.invalidSeekPosition }
        guard sample.isMultiple(of: 8) else { throw DSDStreamError.seekMustBeByteAligned }
        bytePosition = sample / 8
        cachedBlockIndex = nil
        cachedBlock.removeAll(keepingCapacity: true)
    }

    private func loadBlock(at index: UInt64) throws {
        guard cachedBlockIndex != index else { return }
        let bytesPerGroup = blockSize * UInt64(format.channelCount)
        let groupOffset = bytesPerGroup.multipliedReportingOverflow(by: index)
        guard !groupOffset.overflow else { throw DSDStreamError.truncatedAudioData }
        let fileOffset = descriptor.audioDataOffset.addingReportingOverflow(groupOffset.partialValue)
        guard !fileOffset.overflow else { throw DSDStreamError.truncatedAudioData }

        try fileHandle.seek(toOffset: fileOffset.partialValue)
        guard let data = try fileHandle.read(upToCount: Int(bytesPerGroup)),
              data.count == Int(bytesPerGroup) else {
            throw DSDStreamError.truncatedAudioData
        }
        cachedBlock = data
        cachedBlockIndex = index
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var value = byte
        value = (value >> 4) | (value << 4)
        value = ((value & 0xCC) >> 2) | ((value & 0x33) << 2)
        return ((value & 0xAA) >> 1) | ((value & 0x55) << 1)
    }
}
