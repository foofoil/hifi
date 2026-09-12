//
//  PCMPlaybackSequence.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import Foundation

public struct APEPlaybackItem: Sendable {
    public let id: String
    public let url: URL
    public let descriptor: APEAudioDescriptor
    public let startBlock: UInt64
    public let endBlock: UInt64?

    public init(id: String, url: URL, descriptor: APEAudioDescriptor, startBlock: UInt64 = 0, endBlock: UInt64? = nil) {
        self.id = id
        self.url = url
        self.descriptor = descriptor
        self.startBlock = startBlock
        self.endBlock = endBlock
    }
}

/// 只在 reader 上切换音轨；边界按 ring 已消费帧定位，不按预读位置提前切换 UI。
final class PCMPlaybackSequence {
    struct Position: Equatable {
        let itemID: String?
        let samplePosition: UInt64
        let sampleCount: UInt64
    }

    private struct Boundary {
        let frame: UInt64
        let itemID: String?
        let startingSample: UInt64
        let sampleCount: UInt64
    }

    private let lock = NSLock()
    private var boundaries: [Boundary]
    private var source: APERawStream
    private var successors: ArraySlice<APEPlaybackItem>
    private let open: (APEPlaybackItem) throws -> APERawStream?
    private var ended = false
    private var producedFrames: UInt64 = 0

    init(source: APERawStream, itemID: String?, startingSample: UInt64,
         successors: [APEPlaybackItem], open: @escaping (APEPlaybackItem) throws -> APERawStream?) {
        self.source = source
        self.successors = successors[...]
        self.open = open
        boundaries = [Boundary(frame: 0, itemID: itemID, startingSample: startingSample, sampleCount: source.sampleCount)]
    }

    func read(maximumFrames: Int) throws -> [Float32] {
        guard !ended else { return [] }
        while true {
            let samples = try source.read(maximumFrames: maximumFrames)
            if !samples.isEmpty {
                producedFrames += UInt64(samples.count / source.format.channelCount)
                return samples
            }
            guard let next = successors.popFirst(),
                  let nextSource = try? open(next) else {
                // 下一轨失效时先让当前 ring 排空，再由普通切轨路径报告错误。
                ended = true
                return []
            }
            lock.lock()
            boundaries.append(Boundary(frame: producedFrames, itemID: next.id, startingSample: 0, sampleCount: nextSource.sampleCount))
            lock.unlock()
            source = nextSource
        }
    }

    func position(consumedFrames: UInt64) -> Position {
        lock.lock()
        defer { lock.unlock() }
        let boundary = boundaries.last(where: { $0.frame <= consumedFrames }) ?? boundaries[0]
        return Position(itemID: boundary.itemID,
                        samplePosition: min(boundary.startingSample + (consumedFrames - boundary.frame), boundary.sampleCount),
                        sampleCount: boundary.sampleCount)
    }
}
