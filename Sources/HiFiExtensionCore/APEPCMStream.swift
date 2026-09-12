//
//  APEPCMStream.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import Foundation

public struct PCMStreamFormat: Equatable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let bitsPerSample: Int
    public let isFloat: Bool

    public init(sampleRate: Int, channelCount: Int, bitsPerSample: Int, isFloat: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
    }
}

/// 解码 worker 用的 PCM 帧流；输出归一化交织 Float32，seek 以音频帧为单位。
public protocol PCMStream: AnyObject {
    var format: PCMStreamFormat { get }
    var sampleCount: UInt64 { get }
    var samplePosition: UInt64 { get }

    func read(maximumFrames: Int) throws -> [Float32]
    func seek(toSample sample: UInt64) throws
}

public enum APEStreamError: Error, Equatable, Sendable {
    case invalidReadSize
    case invalidSeekPosition
    case truncatedAudioData
    case unsupportedFormat(String)
}

/// 单 APE 文件或其中一段 CUE 曲目的 PCM 流；文件 I/O 与解码只在 worker 上执行。
public final class APERawStream: PCMStream {
    public let format: PCMStreamFormat
    public let sampleCount: UInt64

    public var samplePosition: UInt64 { position }

    private let decoder: APEFileDecoder
    private let startBlock: UInt64
    private let endBlock: UInt64
    private var position: UInt64 = 0
    private let isBigEndian: Bool

    public init(fileAt url: URL, startBlock: UInt64 = 0, endBlock: UInt64? = nil) throws {
        let decoder = try APEFileDecoder(fileAt: url)
        let descriptor = decoder.descriptor
        guard [8, 16, 24, 32].contains(descriptor.bitsPerSample) else {
            throw APEStreamError.unsupportedFormat("bits-\(descriptor.bitsPerSample)")
        }
        let totalBlocks = descriptor.totalBlocks
        let end = endBlock ?? totalBlocks
        guard startBlock <= end, end <= totalBlocks else {
            throw APEStreamError.invalidSeekPosition
        }
        self.decoder = decoder
        self.startBlock = startBlock
        self.endBlock = end
        self.sampleCount = end - startBlock
        self.isBigEndian = (descriptor.formatFlags & (1 << 9)) != 0
        if isBigEndian, descriptor.isFloat {
            throw APEStreamError.unsupportedFormat("big-endian-float")
        }
        self.format = PCMStreamFormat(
            sampleRate: descriptor.sampleRate,
            channelCount: descriptor.channelCount,
            bitsPerSample: descriptor.bitsPerSample,
            isFloat: descriptor.isFloat
        )
        if startBlock > 0 {
            try decoder.seek(toBlock: startBlock)
        }
    }

    public func read(maximumFrames: Int) throws -> [Float32] {
        guard maximumFrames > 0 else { throw APEStreamError.invalidReadSize }
        guard position < sampleCount else { return [] }
        let requested = min(UInt64(maximumFrames), sampleCount - position)
        let raw = try decodeRaw(blocks: Int(requested))
        guard !raw.isEmpty else { throw APEStreamError.truncatedAudioData }
        position += UInt64(raw.count / format.channelCount)
        return raw
    }

    public func seek(toSample sample: UInt64) throws {
        guard sample <= sampleCount else { throw APEStreamError.invalidSeekPosition }
        try decoder.seek(toBlock: startBlock + sample)
        position = sample
    }

    private func decodeRaw(blocks: Int) throws -> [Float32] {
        let data: Data
        do {
            data = try decoder.decode(maxBlocks: blocks)
        } catch APECodecError.decodeFailed {
            throw APEStreamError.truncatedAudioData
        }
        let descriptor = decoder.descriptor
        let channels = descriptor.channelCount
        let frames = data.count / descriptor.blockAlign
        guard frames > 0 else { return [] }
        var output = [Float32]()
        output.reserveCapacity(frames * channels)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch (descriptor.bitsPerSample, descriptor.isFloat) {
            case (8, false):
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let value = bytes[frame * channels + channel]
                        output.append((Float32(value) - 128) / 128)
                    }
                }
            case (16, false):
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let offset = (frame * channels + channel) * 2
                        let word = Self.load16(bytes, at: offset, bigEndian: isBigEndian)
                        output.append(Float32(word) / 32768)
                    }
                }
            case (24, false):
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let offset = (frame * channels + channel) * 3
                        let word = Self.load24(bytes, at: offset, bigEndian: isBigEndian)
                        output.append(Float32(word) / 8388608)
                    }
                }
            case (32, false):
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let offset = (frame * channels + channel) * 4
                        let word = Self.load32(bytes, at: offset, bigEndian: isBigEndian)
                        output.append(Float32(word) / 2147483648)
                    }
                }
            case (32, true):
                for frame in 0..<frames {
                    for channel in 0..<channels {
                        let offset = (frame * channels + channel) * 4
                        output.append(Self.loadFloat32(bytes, at: offset))
                    }
                }
            default:
                break
            }
        }
        return output
    }

    private static func load16(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, bigEndian: Bool) -> Int16 {
        let low = UInt16(bytes[offset])
        let high = UInt16(bytes[offset + 1])
        let word = bigEndian ? (low << 8) | high : low | (high << 8)
        return Int16(bitPattern: word)
    }

    private static func load24(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, bigEndian: Bool) -> Int32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let word = bigEndian ? (b0 << 16) | (b1 << 8) | b2 : b0 | (b1 << 8) | (b2 << 16)
        return (Int32(bitPattern: word << 8)) >> 8
    }

    private static func load32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, bigEndian: Bool) -> Int32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        let word = bigEndian
            ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            : b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        return Int32(bitPattern: word)
    }

    private static func loadFloat32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Float32 {
        let word = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Float32(bitPattern: word)
    }
}
