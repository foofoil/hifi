import Foundation
import Testing

struct DeviceServiceMessageTests {
    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension-kit/Sources/FoofoilExtensionKit/Fixtures/AudioDeviceServiceMessages.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func sharedFixtureMatchesRuntimeApplicationCommandKeys() throws {
        let requests = try #require(catalog()["requests"] as? [[String: Any]])
        let allowed = Set(["snapshot", "selectSystemDefault", "prepareExclusivePCM", "releasePCM", "releaseAllPCM"])
        for entry in requests {
            let body = try #require(entry["body"] as? [String: Any])
            let command = try #require(body["command"] as? String)
            #expect(allowed.contains(command))
            #expect(UUID(uuidString: try #require(body["clientID"] as? String)) != nil)
            if command == "prepareExclusivePCM" {
                #expect(!(body["selectedDeviceID"] as? String ?? "").isEmpty)
                #expect((body["sourceSampleRate"] as? NSNumber)?.doubleValue == 96_000)
                #expect((body["channelCount"] as? NSNumber)?.intValue == 2)
            }
        }

        let snapshots = try #require(catalog()["snapshots"] as? [[String: Any]])
        for entry in snapshots {
            let body = try #require(entry["body"] as? [String: Any])
            #expect(body["contractVersion"] as? Int == 1)
            #expect(["systemDefault", "exclusiveDevice"].contains(body["pcmRouteMode"] as? String))
            let devices = try #require(body["devices"] as? [[String: Any]])
            #expect(!devices.isEmpty)
            for device in devices {
                #expect(!(device["id"] as? String ?? "").isEmpty)
                #expect(!(device["displayName"] as? String ?? "").isEmpty)
            }
        }

        let incomplete = try #require((catalog()["invalidRequests"] as? [[String: Any]])?[1]["body"] as? [String: Any])
        #expect(incomplete["command"] as? String == "prepareExclusivePCM")
        #expect(incomplete["selectedDeviceID"] == nil)
    }
}
