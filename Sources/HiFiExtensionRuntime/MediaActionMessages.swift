import Foundation

/// Runtime 内部的类型化媒体动作；公共消息解码后直接映射到这里，不再绕回旧 `hifi.*` 字符串。
enum RuntimeAction: Equatable {
    case play
    case pause
    case seek(position: Double)
    case previous
    case next
    case refresh
    case selectDevice(String)
    case activate(itemID: String)
    case move(orderedIDs: [String])
}

struct MediaPlaybackMessage: Decodable {
    struct Action: Decodable {
        enum Kind: String, Decodable { case play, pause, previous, next, refresh, seek, selectDevice }
        let kind: Kind
        let position: Double?
        let deviceID: String?
    }
    let commandID: String
    let contractVersion: UInt32
    let action: Action

    func validate() throws {
        guard commandID == "media.transport", contractVersion == 1 else { throw ActionMessageError.invalidMessage }
        if action.kind == .seek {
            guard let position = action.position, position.isFinite, position >= 0 else { throw ActionMessageError.invalidMessage }
        }
        if action.kind == .selectDevice {
            guard let id = action.deviceID, !id.isEmpty else { throw ActionMessageError.invalidMessage }
        }
    }

    var runtimeAction: RuntimeAction {
        switch action.kind {
        case .play: .play
        case .pause: .pause
        case .previous: .previous
        case .next: .next
        case .refresh: .refresh
        case .seek: .seek(position: action.position ?? 0)
        case .selectDevice: .selectDevice(action.deviceID ?? "")
        }
    }
}

struct NavigatorActionMessage: Decodable {
    struct Action: Decodable {
        enum Kind: String, Decodable { case activate, move, remove }
        enum Position: String, Decodable { case before, after, end }
        let contributionID: String
        let kind: Kind
        let itemIDs: [String]
        let destinationItemID: String?
        let movePosition: Position?
    }
    let commandID: String
    let contractVersion: UInt32
    let action: Action

    func validate() throws {
        guard commandID == "ui.navigator.action", contractVersion == 1 else { throw ActionMessageError.invalidMessage }
    }

    /// 按 Runtime 的真实源列表验证，不能信任宿主快照里的 allowedActions 或项目集合。
    func orderedIDs(in sourceIDs: [String], canMove: Bool) throws -> [String] {
        let moving = Set(action.itemIDs)
        guard action.contributionID == "hifi.playback-queue", sourceIDs.count > 1,
              !moving.isEmpty, moving.count == action.itemIDs.count,
              moving.isSubset(of: Set(sourceIDs)) else { throw ActionMessageError.invalidAction }
        switch action.kind {
        case .activate:
            guard action.itemIDs.count == 1, action.movePosition == nil, action.destinationItemID == nil else {
                throw ActionMessageError.invalidAction
            }
            return sourceIDs
        case .remove:
            throw ActionMessageError.invalidAction
        case .move:
            guard canMove, let position = action.movePosition else { throw ActionMessageError.invalidAction }
            var remaining = sourceIDs.filter { !moving.contains($0) }
            let index: Int
            if position == .end {
                guard action.destinationItemID == nil else { throw ActionMessageError.invalidAction }
                index = remaining.endIndex
            } else {
                guard let destination = action.destinationItemID,
                      let target = remaining.firstIndex(of: destination) else { throw ActionMessageError.invalidAction }
                index = position == .before ? target : remaining.index(after: target)
            }
            remaining.insert(contentsOf: sourceIDs.filter(moving.contains), at: index)
            return remaining
        }
    }
}

enum ActionMessageError: Error { case invalidMessage, invalidAction }
