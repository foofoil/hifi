import Foundation

public struct DSDPlaybackItem: Sendable {
    public let id: String
    public let url: URL
    public let descriptor: DSDContainerDescriptor
    public let sacdTrackNumber: Int?

    public init(id: String, url: URL, descriptor: DSDContainerDescriptor, sacdTrackNumber: Int? = nil) {
        self.id = id
        self.url = url
        self.descriptor = descriptor
        self.sacdTrackNumber = sacdTrackNumber
    }
}

/// 只在 reader 上切换文件；曲目边界按 ring 已消费的帧定位，不能按预读位置提前切换 UI。
final class DoPPlaybackSequence {
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
    private var source: DSFDoPSource
    private var successors: ArraySlice<DSDPlaybackItem>
    private let open: (DSDPlaybackItem) throws -> DSFDoPSource?
    private var ended = false
    private var producedFrames: UInt64 = 0

    init(source: DSFDoPSource, itemID: String?, startingSample: UInt64,
         successors: [DSDPlaybackItem], open: @escaping (DSDPlaybackItem) throws -> DSFDoPSource?) {
        self.source = source
        self.successors = successors[...]
        self.open = open
        boundaries = [Boundary(frame: 0, itemID: itemID, startingSample: startingSample, sampleCount: source.sampleCount)]
    }

    func read(maximumDoPFrames: Int) throws -> [Float32] {
        guard !ended else { return [] }
        while true {
            let samples = try source.read(maximumDoPFrames: maximumDoPFrames)
            if !samples.isEmpty {
                producedFrames += UInt64(samples.count / source.channelCount)
                return samples
            }
            // 非整 DoP 帧的尾部已补静音，不能把这种边界宣称为无缝。
            guard source.sampleCount.isMultiple(of: 16), let next = successors.popFirst(),
                  let nextSource = try? open(next) else {
                // 下一曲失效时先让当前 ring 排空，再由普通切曲路径报告错误。
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
                        samplePosition: min(boundary.startingSample + (consumedFrames - boundary.frame) * 16, boundary.sampleCount),
                        sampleCount: boundary.sampleCount)
    }
}
