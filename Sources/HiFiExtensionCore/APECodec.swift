//
//  APECodec.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import Foundation
import MACLib

public enum APECodecError: Error, Equatable, Sendable {
    case openFailed(Int32)
    case infoFailed
    case infoMismatch
    case decodeFailed(Int32)
    case seekFailed(Int32)
    case invalidPosition
    case unsupportedFormat(String)
}

/// 解码器句柄的薄封装；所有调用必须在同一非实时 worker 上串行执行。
public final class APEFileDecoder {
    public let url: URL
    public let descriptor: APEAudioDescriptor

    public var totalBlocks: UInt64 { descriptor.totalBlocks }

    private var handle: UnsafeMutableRawPointer?

    public init(fileAt url: URL) throws {
        let descriptor = try APEParser.parse(fileAt: url)
        guard !descriptor.isFloat || descriptor.bitsPerSample == 32 else {
            throw APECodecError.unsupportedFormat("float-\(descriptor.bitsPerSample)")
        }
        var errorCode: Int32 = 0
        guard let handle = url.path.withCString({ path in
            hifi_ape_open(path, &errorCode)
        }) else {
            throw APECodecError.openFailed(errorCode)
        }
        self.handle = handle
        self.url = url
        self.descriptor = descriptor
        do {
            try verifyInfoMatchesHeader(handle: handle, descriptor: descriptor)
        } catch {
            hifi_ape_close(handle)
            self.handle = nil
            throw error
        }
    }

    deinit {
        if let handle { hifi_ape_close(handle) }
    }

    /// 解码最多 maxBlocks 个块，返回原始交织字节；到文件尾返回空。
    public func decode(maxBlocks: Int) throws -> Data {
        guard let handle else { throw APECodecError.invalidPosition }
        guard maxBlocks > 0 else { throw APECodecError.invalidPosition }
        let byteCount = maxBlocks * descriptor.blockAlign
        var buffer = Data(count: byteCount)
        var retrieved: Int64 = 0
        let result: Int32 = buffer.withUnsafeMutableBytes { raw in
            hifi_ape_decode(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), Int64(maxBlocks), &retrieved)
        }
        guard result == 0 else { throw APECodecError.decodeFailed(result) }
        guard retrieved > 0 else { return Data() }
        return buffer.prefix(Int(retrieved) * descriptor.blockAlign)
    }

    public func seek(toBlock block: UInt64) throws {
        guard let handle else { throw APECodecError.invalidPosition }
        guard block <= descriptor.totalBlocks else { throw APECodecError.invalidPosition }
        let result = hifi_ape_seek(handle, Int64(block))
        guard result == 0 else { throw APECodecError.seekFailed(result) }
    }

    private func verifyInfoMatchesHeader(
        handle: UnsafeMutableRawPointer,
        descriptor: APEAudioDescriptor
    ) throws {
        var info = HiFiAPEInfo()
        guard hifi_ape_info(handle, &info) == 0 else { throw APECodecError.infoFailed }
        guard Int(info.sampleRate) == descriptor.sampleRate,
              Int(info.channelCount) == descriptor.channelCount,
              Int(info.bitsPerSample) == descriptor.bitsPerSample,
              UInt64(info.totalBlocks) == descriptor.totalBlocks else {
            throw APECodecError.infoMismatch
        }
    }
}
