import Foundation
import Testing
@testable import HiFiExtensionRuntime

struct MediaActionMessageTests {
    private func navigation(_ action: [String: Any]) throws -> NavigatorActionMessage {
        let data = try JSONSerialization.data(withJSONObject: [
            "commandID": "ui.navigator.action", "contractVersion": 1,
            "action": action.merging(["contributionID": "hifi.playback-queue"], uniquingKeysWith: { a, _ in a })
        ])
        let message = try JSONDecoder().decode(NavigatorActionMessage.self, from: data)
        try message.validate()
        return message
    }

    @Test func movePreservesSourceOrderAndRejectsContainerMutation() throws {
        let message = try navigation(["kind": "move", "itemIDs": ["c", "a"], "movePosition": "end"])
        #expect(try message.orderedIDs(in: ["a", "b", "c", "d"], canMove: true) == ["b", "d", "a", "c"])
        #expect(throws: ActionMessageError.self) { try message.orderedIDs(in: ["a", "b", "c", "d"], canMove: false) }
    }

    @Test func refusesUnknownDuplicateAndSelfDestinationIDs() throws {
        for action: [String: Any] in [
            ["kind": "activate", "itemIDs": ["missing"]],
            ["kind": "activate", "itemIDs": ["a", "b"]],
            ["kind": "move", "itemIDs": ["a", "a"], "movePosition": "end"],
            ["kind": "move", "itemIDs": ["a"], "movePosition": "before", "destinationItemID": "a"],
            ["kind": "remove", "itemIDs": ["a"]]
        ] {
            let message = try navigation(action)
            #expect(throws: ActionMessageError.self) { try message.orderedIDs(in: ["a", "b"], canMove: true) }
        }
    }

    @Test func mediaRejectsInvalidWireParametersBeforeExecution() throws {
        for action: [String: Any] in [
            ["kind": "seek", "position": -1], ["kind": "seek"], ["kind": "selectDevice", "deviceID": ""]
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["commandID": "media.transport", "contractVersion": 1, "action": action])
            let message = try JSONDecoder().decode(MediaPlaybackMessage.self, from: data)
            #expect(throws: ActionMessageError.self) { try message.validate() }
        }
    }

    /// 公共媒体消息直接映射为类型化动作，不再经过旧 `hifi.*` 字符串。
    @Test func mediaMapsToTypedRuntimeActions() throws {
        func runtimeAction(_ action: [String: Any]) throws -> RuntimeAction {
            let data = try JSONSerialization.data(withJSONObject: [
                "commandID": "media.transport", "contractVersion": 1, "action": action
            ])
            let message = try JSONDecoder().decode(MediaPlaybackMessage.self, from: data)
            try message.validate()
            return message.runtimeAction
        }
        #expect(try runtimeAction(["kind": "play"]) == .play)
        #expect(try runtimeAction(["kind": "pause"]) == .pause)
        #expect(try runtimeAction(["kind": "previous"]) == .previous)
        #expect(try runtimeAction(["kind": "next"]) == .next)
        #expect(try runtimeAction(["kind": "refresh"]) == .refresh)
        #expect(try runtimeAction(["kind": "seek", "position": 1.5]) == .seek(position: 1.5))
        #expect(try runtimeAction(["kind": "selectDevice", "deviceID": "opaque-uid"]) == .selectDevice("opaque-uid"))
    }
}
