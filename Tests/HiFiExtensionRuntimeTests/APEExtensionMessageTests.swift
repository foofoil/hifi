import Foundation
import Testing
@testable import HiFiExtensionCore
@testable import HiFiExtensionRuntime

private typealias RuntimeCall = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    UnsafeMutablePointer<Int>?
) -> Int32
private typealias ReleaseCall = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int) -> Void

private typealias DestroyCall = @convention(c) (UnsafeMutableRawPointer?) -> Void

private struct RuntimeInterfaceV1 {
    var apiVersion: UInt32
    var structSize: Int
    var context: UnsafeMutableRawPointer?
    var createSession: RuntimeCall?
    var performCommand: RuntimeCall?
    var releaseBytes: ReleaseCall?
    var destroy: DestroyCall?
    var performApplicationCommand: RuntimeCall?
}

struct APEExtensionMessageTests {
    @Test func probeMatchesSingleAPECueOnly() throws {
        let harness = try Harness()
        let directory = try harness.makeDirectory()

        let apeCue = directory.appendingPathComponent("CDImage.cue")
        try apeCueText(audioFile: "CDImage.ape").write(to: apeCue, atomically: true, encoding: .utf8)
        let wavCue = directory.appendingPathComponent("other.cue")
        try apeCueText(audioFile: "CDImage.wav").write(to: wavCue, atomically: true, encoding: .utf8)

        let matched = try harness.probe(apeCue)
        #expect(matched["disposition"] as? String == "matched")
        #expect(matched["reason"] as? String == "ape-cue-sheet")
        let unmatched = try harness.probe(wavCue)
        #expect(unmatched["disposition"] as? String == "unmatched")
    }

    @Test func createSessionForSingleAPEFile() throws {
        let harness = try Harness()
        let directory = try harness.makeDirectory()
        let apeURL = directory.appendingPathComponent("solo.ape")
        try Data(contentsOf: Harness.coreFixture(named: "sine05-high", extension: "ape"))
            .write(to: apeURL)

        let session = try harness.createSession(kind: "singleFile", resources: [["url": apeURL.absoluteString]])
        #expect(session["providerID"] as? String == "audio.hifi")
        let playback = try #require(session["mediaPlayback"] as? [String: Any])
        #expect((playback["duration"] as? Double) == 0.5)
        #expect(session["playbackQueue"] == nil)
        let selection = try #require(session["audioDeviceSelection"] as? [String: Any])
        let devices = try #require(selection["devices"] as? [[String: Any]])
        #expect(!devices.isEmpty)
        #expect(devices.allSatisfy { ($0["supportedPCMSampleRates"] as? [NSNumber]) != nil })
        let body = ((session["presentation"] as? [String: Any])?["body"] as? String) ?? ""
        #expect(body.contains("APE"))
    }

    @Test func createSessionForCuePlusAPEProjectsTracks() throws {
        let harness = try Harness()
        let directory = try harness.makeDirectory()
        let apeURL = directory.appendingPathComponent("CDImage.ape")
        try Data(contentsOf: Harness.coreFixture(named: "sine05-high", extension: "ape"))
            .write(to: apeURL)
        let cueURL = directory.appendingPathComponent("CDImage.cue")
        // 夹具只有 0.5s：两轨按 0.1s / 余量切分，验证分轨边界与时长。
        try """
        FILE "CDImage.ape" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:00:07
        """.write(to: cueURL, atomically: true, encoding: .utf8)

        var session = try harness.createSession(
            kind: "singleFile",
            resources: [["url": cueURL.absoluteString]]
        )
        let queue = try #require(session["playbackQueue"] as? [String: Any])
        let items = try #require(queue["items"] as? [[String: Any]])
        #expect(items.map { $0["id"] as? String } == ["track:cue:01", "track:cue:02"])
        #expect(items[0]["title"] as? String == "First")
        let durations = try #require(items.map { $0["duration"] as? Double } as? [Double])
        #expect(abs(durations[0] - 4116.0 / 44100.0) < 0.0001)
        #expect(abs(durations[0] + durations[1] - 0.5) < 0.0001)

        // 未起播的 seek 只记位置不碰设备；pause 保持暂停。
        session = try harness.perform(
            commandID: "media.transport",
            session: session,
            fields: ["contractVersion": 1, "action": ["kind": "seek", "position": 0.05]]
        )
        let playback = try #require(session["mediaPlayback"] as? [String: Any])
        #expect(playback["state"] as? String == "paused")
        #expect(abs((playback["position"] as? Double ?? -1) - 0.05) < 0.0001)

        session = try harness.perform(
            commandID: "ui.navigator.action",
            session: session,
            fields: ["contractVersion": 1, "action": [
                "contributionID": "hifi.playback-queue", "kind": "activate", "itemIDs": ["track:cue:02"]
            ]]
        )
        let moved = try #require(session["playbackQueue"] as? [String: Any])
        #expect(moved["currentItemID"] as? String == "track:cue:02")
    }

    @Test func fileCollectionWithCueAndAPEDoesNotDuplicateTracks() throws {
        let harness = try Harness()
        let directory = try harness.makeDirectory()
        let apeURL = directory.appendingPathComponent("CDImage.ape")
        try Data(contentsOf: Harness.coreFixture(named: "sine05-high", extension: "ape"))
            .write(to: apeURL)
        let cueURL = directory.appendingPathComponent("CDImage.cue")
        try """
        FILE "CDImage.ape" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:00:07
        """.write(to: cueURL, atomically: true, encoding: .utf8)

        let session = try harness.createSession(kind: "fileCollection", resources: [
            ["url": cueURL.absoluteString],
            ["url": apeURL.absoluteString]
        ])
        let queue = try #require(session["playbackQueue"] as? [String: Any])
        let items = try #require(queue["items"] as? [[String: Any]])
        #expect(items.map { $0["id"] as? String } == ["track:cue:01", "track:cue:02"])
    }

    @Test func nonAPECueFallsThroughToNextProvider() throws {        let harness = try Harness()
        let directory = try harness.makeDirectory()
        let cueURL = directory.appendingPathComponent("other.cue")
        try apeCueText(audioFile: "CDImage.wav").write(to: cueURL, atomically: true, encoding: .utf8)
        do {
            _ = try harness.createSession(kind: "singleFile", resources: [["url": cueURL.absoluteString]])
            Issue.record("Non-APE cue should not build a Hi-Fi session")
        } catch HarnessError.callFailed(let status) {
            #expect(status == 3)
        }
    }

    private func apeCueText(audioFile: String) -> String {
        """
        FILE "\(audioFile)" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 10:00:00
        """
    }
}

private enum HarnessError: Error {
    case runtimeUnavailable
    case callFailed(Int32)
}

private final class Harness {
    let raw: UnsafeRawPointer
    let interface: UnsafePointer<RuntimeInterfaceV1>

    init() throws {
        guard let raw = foofoilExtensionCreate(1) else { throw HarnessError.runtimeUnavailable }
        self.raw = raw
        self.interface = raw.assumingMemoryBound(to: RuntimeInterfaceV1.self)
        guard interface.pointee.apiVersion == 1,
              interface.pointee.createSession != nil,
              interface.pointee.performCommand != nil,
              interface.pointee.performApplicationCommand != nil,
              interface.pointee.releaseBytes != nil else {
            throw HarnessError.runtimeUnavailable
        }
    }

    static func coreFixture(named name: String, extension ext: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HiFiExtensionCoreTests/Fixtures/\(name).\(ext)")
    }

    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-ape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func createSession(kind: String, resources: [[String: Any]]) throws -> [String: Any] {
        let request: [String: Any] = kind == "singleFile"
            ? ["kind": "singleFile", "resource": resources[0]]
            : ["kind": "fileCollection", "resources": resources]
        let payload = try JSONSerialization.data(withJSONObject: request)
        var response: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = payload.withUnsafeBytes { bytes in
            interface.pointee.createSession!(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &response,
                &length
            )
        }
        guard status == 0, let response else { throw HarnessError.callFailed(status) }
        defer { interface.pointee.releaseBytes!(interface.pointee.context, response, length) }
        return try JSONSerialization.jsonObject(with: Data(bytes: response, count: length)) as! [String: Any]
    }

    func perform(commandID: String, session: [String: Any], fields: [String: Any]) throws -> [String: Any] {
        var object = fields
        object["commandID"] = commandID
        object["session"] = session
        let message = try JSONSerialization.data(withJSONObject: object)
        var response: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = message.withUnsafeBytes { bytes in
            interface.pointee.performCommand!(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &response,
                &length
            )
        }
        guard status == 0, let response else { throw HarnessError.callFailed(status) }
        defer { interface.pointee.releaseBytes!(interface.pointee.context, response, length) }
        return try JSONSerialization.jsonObject(with: Data(bytes: response, count: length)) as! [String: Any]
    }

    func probe(_ url: URL) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: [
            "commandID": "content.probe",
            "contractVersion": 1,
            "resource": ["url": url.absoluteString],
            "maxReadBytes": 2_097_152
        ])
        var response: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = payload.withUnsafeBytes { bytes in
            interface.pointee.performApplicationCommand!(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &response,
                &length
            )
        }
        guard status == 0, let response else { throw HarnessError.callFailed(status) }
        defer { interface.pointee.releaseBytes!(interface.pointee.context, response, length) }
        return try JSONSerialization.jsonObject(with: Data(bytes: response, count: length)) as! [String: Any]
    }
}
