import Foundation

public struct DSDStreamFormat: Equatable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let bitOrder: DSDBitOrder

    public init(sampleRate: Int, channelCount: Int, bitOrder: DSDBitOrder) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitOrder = bitOrder
    }
}

public struct DSDByteChunk: Equatable, Sendable {
    public let bytesByChannel: [[UInt8]]

    public init(bytesByChannel: [[UInt8]]) {
        self.bytesByChannel = bytesByChannel
    }

    public var byteFrameCount: Int { bytesByChannel.first?.count ?? 0 }
    public var isEmpty: Bool { byteFrameCount == 0 }
}

/// Reader/decoder worker 使用的统一 DSD 字节流；输出固定为逐声道、MSB-first。
public protocol DSDStream: AnyObject {
    var format: DSDStreamFormat { get }
    var sampleCount: UInt64 { get }
    var samplePosition: UInt64 { get }

    func read(maximumByteFrames: Int) throws -> DSDByteChunk
    func seek(toSample sample: UInt64) throws
}

public enum DSDStreamError: Error, Equatable, Sendable {
    case invalidReadSize
    case invalidSeekPosition
    case seekMustBeByteAligned
    case truncatedAudioData
    case unsupportedFormat
}
