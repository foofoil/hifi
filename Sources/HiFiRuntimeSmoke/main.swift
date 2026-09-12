import Foundation

private typealias RuntimeCall = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?
) -> Int32
private typealias ReleaseCall = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int) -> Void
private typealias DestroyCall = @convention(c) (UnsafeMutableRawPointer?) -> Void

private struct RuntimeInterfaceV1 {
    let apiVersion: UInt32
    let structSize: Int
    let context: UnsafeMutableRawPointer?
    let createSession: RuntimeCall?
    let performCommand: RuntimeCall?
    let releaseBytes: ReleaseCall?
    let destroy: DestroyCall?
    let performApplicationCommand: RuntimeCall?
}

@_silgen_name("foofoil_extension_create")
private func createRuntime(_ version: UInt32) -> UnsafeRawPointer?

guard CommandLine.arguments.count == 2
    || ((3...4).contains(CommandLine.arguments.count) && CommandLine.arguments[1] == "--self-test") else {
    FileHandle.standardError.write(Data("Usage: hifi-runtime-smoke <file.dsf|file.dff|file.ape|file.cue|--self-test> [lifecycle-fixture.json] [media-navigation-fixture.json]\n".utf8))
    exit(64)
}

let selfTestURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("foofoil-hifi-runtime-smoke-\(UUID().uuidString).dsf")
let isSelfTest = CommandLine.arguments[1] == "--self-test"
if isSelfTest { try makeTestDSF().write(to: selfTestURL, options: .atomic) }
defer { if isSelfTest { try? FileManager.default.removeItem(at: selfTestURL) } }
let url = isSelfTest
    ? selfTestURL
    : URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let resource: [String: Any] = ["url": url.absoluteString]
let request: [String: Any] = isSelfTest
    ? ["kind": "fileCollection", "resources": [resource, resource]]
    : ["kind": "singleFile", "resource": resource]

do {
    guard let rawInterface = createRuntime(1) else { throw SmokeError.runtimeUnavailable }
    let interface = rawInterface.assumingMemoryBound(to: RuntimeInterfaceV1.self)
    guard interface.pointee.apiVersion == 1,
          interface.pointee.structSize >= MemoryLayout<RuntimeInterfaceV1>.size,
          let createSession = interface.pointee.createSession,
          let releaseBytes = interface.pointee.releaseBytes,
          let performApplicationCommand = interface.pointee.performApplicationCommand else {
        throw SmokeError.invalidInterface
    }
    func perform(_ commandID: String, session: [String: Any], fields: [String: Any] = [:]) throws -> [String: Any] {
        guard let performCommand = interface.pointee.performCommand else {
            throw SmokeError.invalidInterface
        }
        var object = fields
        object["commandID"] = commandID
        object["session"] = session
        let message = try JSONSerialization.data(withJSONObject: object)
        var commandResponse: UnsafeMutablePointer<UInt8>?
        var commandResponseLength = 0
        let commandStatus = message.withUnsafeBytes { bytes in
            performCommand(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &commandResponse,
                &commandResponseLength
            )
        }
        guard commandStatus == 0, let commandResponse else { throw SmokeError.callFailed(commandStatus) }
        defer { releaseBytes(interface.pointee.context, commandResponse, commandResponseLength) }
        return try JSONSerialization.jsonObject(
            with: Data(bytes: commandResponse, count: commandResponseLength)
        ) as! [String: Any]
    }
    let requestData = try JSONSerialization.data(withJSONObject: request)
    var response: UnsafeMutablePointer<UInt8>?
    var responseLength = 0
    let status = requestData.withUnsafeBytes { bytes in
        createSession(
            interface.pointee.context,
            bytes.bindMemory(to: UInt8.self).baseAddress,
            bytes.count,
            &response,
            &responseLength
        )
    }
    guard status == 0, let response, responseLength > 0 else { throw SmokeError.callFailed(status) }
    defer { releaseBytes(interface.pointee.context, response, responseLength) }
    let sessionData = Data(bytes: response, count: responseLength)
    guard let session = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
          session["providerID"] as? String == "audio.hifi",
          session["audioDeviceSelection"] is [String: Any],
          !isSelfTest || ((session["playbackQueue"] as? [String: Any])?["items"] as? [[String: Any]])?.count == 2 else {
        throw SmokeError.invalidSession
    }
    if isSelfTest {
        let deviceRequest = try JSONSerialization.data(withJSONObject: [
            "command": "snapshot",
            "clientID": "00000000-0000-0000-0000-0000000000AA"
        ])
        var deviceResponse: UnsafeMutablePointer<UInt8>?
        var deviceResponseLength = 0
        let deviceStatus = deviceRequest.withUnsafeBytes { bytes in
            performApplicationCommand(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &deviceResponse,
                &deviceResponseLength
            )
        }
        guard deviceStatus == 0, let deviceResponse else { throw SmokeError.callFailed(deviceStatus) }
        defer { releaseBytes(interface.pointee.context, deviceResponse, deviceResponseLength) }
        guard let snapshot = try JSONSerialization.jsonObject(
            with: Data(bytes: deviceResponse, count: deviceResponseLength)
        ) as? [String: Any],
              snapshot["contractVersion"] as? Int == 1,
              snapshot["devices"] is [[String: Any]],
              snapshot["pcmRouteMode"] is String else {
            throw SmokeError.invalidSession
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
                performApplicationCommand(
                    interface.pointee.context,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &response,
                    &length
                )
            }
            guard status == 0, let response else { throw SmokeError.callFailed(status) }
            defer { releaseBytes(interface.pointee.context, response, length) }
            return try JSONSerialization.jsonObject(with: Data(bytes: response, count: length)) as! [String: Any]
        }

        let probeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let ordinaryISO = probeDir.appendingPathComponent("disk.iso")
        try Data(repeating: 0, count: 32).write(to: ordinaryISO)
        var magicISO = Data(repeating: 0, count: 511 * 2048)
        magicISO.replaceSubrange((510 * 2048)..<(510 * 2048 + 8), with: Data("SACDMTOC".utf8))
        let sacdISO = probeDir.appendingPathComponent("album.iso")
        try magicISO.write(to: sacdISO)
        let unmatchedDSF = try probe(selfTestURL)
        let unmatchedISO = try probe(ordinaryISO)
        let matchedISO = try probe(sacdISO)
        guard unmatchedDSF["disposition"] as? String == "unmatched",
              unmatchedISO["disposition"] as? String == "unmatched",
              matchedISO["disposition"] as? String == "matched" else {
            throw SmokeError.invalidSession
        }
        let tinyBudget = try JSONSerialization.data(withJSONObject: [
            "commandID": "content.probe",
            "contractVersion": 1,
            "resource": ["url": sacdISO.absoluteString],
            "maxReadBytes": 8
        ])
        var tinyResponse: UnsafeMutablePointer<UInt8>?
        var tinyLength = 0
        let tinyStatus = tinyBudget.withUnsafeBytes { bytes in
            performApplicationCommand(
                interface.pointee.context,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &tinyResponse,
                &tinyLength
            )
        }
        guard tinyStatus == 0, let tinyResponse else { throw SmokeError.callFailed(tinyStatus) }
        defer { releaseBytes(interface.pointee.context, tinyResponse, tinyLength) }
        let tiny = try JSONSerialization.jsonObject(with: Data(bytes: tinyResponse, count: tinyLength)) as! [String: Any]
        guard tiny["disposition"] as? String == "unmatched" else { throw SmokeError.invalidSession }
    }
    var finalSession = session
    if isSelfTest {
        finalSession = try perform("ui.navigator.action", session: session, fields: [
            "contractVersion": 1,
            "action": ["contributionID": "hifi.playback-queue", "kind": "activate", "itemIDs": ["file:1"]]
        ])
        guard (finalSession["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == "file:1" else {
            throw SmokeError.invalidSession
        }

        finalSession = try perform("ui.navigator.action", session: finalSession, fields: [
            "contractVersion": 1,
            "action": ["contributionID": "hifi.playback-queue", "kind": "move",
                       "itemIDs": ["file:0"], "movePosition": "end"]
        ])
        let reorderedIDs = ((finalSession["playbackQueue"] as? [String: Any])?["items"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String }
        guard reorderedIDs == ["file:1", "file:0"],
              (finalSession["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == "file:1",
              ((finalSession["navigatorContributions"] as? [[String: Any]])?.first?["allowedActions"] as? [String])?
                .contains("move") == true else {
            throw SmokeError.invalidSession
        }
    }
    if isSelfTest {
        finalSession = try perform("media.transport", session: finalSession, fields: [
            "contractVersion": 1, "action": ["kind": "seek", "position": 1.0]
        ])
        finalSession = try perform("media.transport", session: finalSession, fields: [
            "contractVersion": 1, "action": ["kind": "pause"]
        ])
        finalSession = try perform("media.transport", session: finalSession, fields: [
            "contractVersion": 1, "action": ["kind": "pause"]
        ])
        guard let restored = finalSession["mediaPlayback"] as? [String: Any],
              restored["state"] as? String == "paused",
              let position = restored["position"] as? Double, abs(position - 1) < 0.00001 else {
            throw SmokeError.invalidSession
        }
    }
    if isSelfTest, CommandLine.arguments.count == 4 {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [[String: Any]]
        guard fixtures.count == 7 else { throw SmokeError.invalidSession }
        for (index, fixture) in fixtures.enumerated() {
            guard let commandID = fixture["commandID"] as? String else { throw SmokeError.invalidSession }
            finalSession = try perform(commandID, session: finalSession, fields: fixture)
            guard (finalSession["mediaPlayback"] as? [String: Any])?["state"] as? String == "paused" else {
                throw SmokeError.invalidSession
            }
            if index == 1 {
                guard let position = (finalSession["mediaPlayback"] as? [String: Any])?["position"] as? Double,
                      abs(position - 0.5) < 0.00001 else { throw SmokeError.invalidSession }
            }
            if index >= 3 {
                let expectedID = index == 5 ? "file:1" : "file:0"
                guard (finalSession["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == expectedID else {
                    throw SmokeError.invalidSession
                }
            }
            if index == 4 {
                let ids = ((finalSession["playbackQueue"] as? [String: Any])?["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
                guard ids == ["file:0", "file:1"] else { throw SmokeError.invalidSession }
            }
        }
        for action: [String: Any] in [
            ["kind": "unknown"], ["kind": "seek", "position": -1], ["kind": "seek", "position": true],
            ["kind": "seek"], ["kind": "selectDevice", "deviceID": ""]
        ] {
            do {
                _ = try perform("media.transport", session: finalSession, fields: ["contractVersion": 1, "action": action])
                throw SmokeError.invalidSession
            } catch SmokeError.callFailed(1) {}
        }
        for action: [String: Any] in [
            ["contributionID": "missing", "kind": "activate", "itemIDs": ["file:0"]],
            ["contributionID": "hifi.playback-queue", "kind": "remove", "itemIDs": ["file:0"]],
            ["contributionID": "hifi.playback-queue", "kind": "move", "itemIDs": ["file:0"], "movePosition": "before", "destinationItemID": "file:0"]
        ] {
            do {
                _ = try perform("ui.navigator.action", session: finalSession, fields: ["contractVersion": 1, "action": action])
                throw SmokeError.invalidSession
            } catch SmokeError.callFailed(3) {}
        }
        // 旧外部私有入口明确被拒绝，不再被 Runtime 接受。
        for legacyCommandID in ["hifi.play", "hifi.pause", "hifi.status", "hifi.next", "hifi.close", "hifi.device.test-dac-uid"] {
            do {
                _ = try perform(legacyCommandID, session: finalSession)
                throw SmokeError.invalidSession
            } catch SmokeError.callFailed(1) {}
        }
    }
    if isSelfTest, CommandLine.arguments.count >= 3 {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [[String: Any]]
        guard fixtures.count == 2,
              fixtures[0]["operation"] as? String == "restore",
              fixtures[1]["operation"] as? String == "close",
              ((session["capabilities"] as? [[String: Any]])?.contains {
                  ($0["declaration"] as? [String: Any])?["id"] as? String == "session.lifecycle"
              }) == true else { throw SmokeError.invalidSession }

        // 先用公共媒体命令切到另一曲，再用共享 fixture 经真实 ABI 恢复，验证公共入口。
        finalSession = try perform("media.transport", session: finalSession, fields: [
            "contractVersion": 1, "action": ["kind": "next"]
        ])
        finalSession = try perform("session.lifecycle", session: finalSession, fields: fixtures[0])
        guard (finalSession["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == "file:1",
              let restored = finalSession["mediaPlayback"] as? [String: Any],
              restored["state"] as? String == "paused",
              let position = restored["position"] as? Double, abs(position - 1) < 0.00001 else {
            throw SmokeError.invalidSession
        }

        var missingTrack = fixtures[0]
        missingTrack["restoration"] = ["currentItemID": "removed-track", "position": 0]
        let unchanged = try perform("session.lifecycle", session: finalSession, fields: missingTrack)
        guard (unchanged["mediaPlayback"] as? [String: Any])?["position"] as? Double == position else {
            throw SmokeError.invalidSession
        }
        var pastEnd = fixtures[0]
        pastEnd["restoration"] = ["currentItemID": "file:1", "position": 1000]
        let clamped = try perform("session.lifecycle", session: finalSession, fields: pastEnd)
        guard let clampedPlayback = clamped["mediaPlayback"] as? [String: Any],
              let clampedPosition = clampedPlayback["position"] as? Double,
              let duration = clampedPlayback["duration"] as? Double,
              abs(clampedPosition - duration) < 0.00001,
              clampedPlayback["state"] as? String == "paused" else {
            throw SmokeError.invalidSession
        }
        var otherTrack = fixtures[0]
        otherTrack["restoration"] = ["currentItemID": "file:0", "position": 0]
        let fromEnd = try perform("session.lifecycle", session: clamped, fields: otherTrack)
        guard (fromEnd["mediaPlayback"] as? [String: Any])?["state"] as? String == "paused",
              (fromEnd["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == "file:0" else {
            throw SmokeError.invalidSession
        }
        finalSession = try perform("session.lifecycle", session: fromEnd, fields: fixtures[0])
        let invalidMessages: [[String: Any]] = [
            ["contractVersion": 2, "operation": "close"],
            ["contractVersion": 1, "operation": "unknown"],
            ["contractVersion": 1, "operation": "restore"],
            ["contractVersion": 1, "operation": "restore", "restoration": ["position": -1]],
            ["contractVersion": 1, "operation": "restore", "restoration": ["position": true]],
            ["contractVersion": 1, "operation": "close", "restoration": [:]]
        ]
        for invalid in invalidMessages {
            do {
                _ = try perform("session.lifecycle", session: finalSession, fields: invalid)
                throw SmokeError.invalidSession
            } catch SmokeError.callFailed(1) {
                // 无效消息在访问播放器前被拒绝。
            }
        }
        finalSession = try perform("session.lifecycle", session: finalSession, fields: fixtures[1])
        finalSession = try perform("session.lifecycle", session: finalSession, fields: fixtures[1])
        guard (finalSession["mediaPlayback"] as? [String: Any])?["state"] as? String == "stopped" else {
            throw SmokeError.invalidSession
        }
        do {
            _ = try perform("media.transport", session: finalSession, fields: [
                "contractVersion": 1, "action": ["kind": "refresh"]
            ])
            throw SmokeError.invalidSession
        } catch SmokeError.callFailed(3) {
            // 关闭确实移除了运行时记录；重复 close 的成功不是重复使用旧会话。
        }
    }
    let pretty = try JSONSerialization.data(withJSONObject: finalSession, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(pretty)
    FileHandle.standardOutput.write(Data("\n".utf8))
    interface.pointee.destroy?(interface.pointee.context)
} catch {
    FileHandle.standardError.write(Data("Hi-Fi runtime smoke test failed: \(error)\n".utf8))
    exit(1)
}

private enum SmokeError: Error {
    case runtimeUnavailable
    case invalidInterface
    case callFailed(Int32)
    case invalidSession
}

private func makeTestDSF() -> Data {
    var formatPayload = Data()
    formatPayload.appendLE(UInt32(1))
    formatPayload.appendLE(UInt32(0))
    formatPayload.appendLE(UInt32(2))
    formatPayload.appendLE(UInt32(2))
    formatPayload.appendLE(UInt32(2_822_400))
    formatPayload.appendLE(UInt32(1))
    formatPayload.appendLE(UInt64(5_644_800))
    formatPayload.appendLE(UInt32(4_096))
    formatPayload.appendLE(UInt32(0))
    let format = littleEndianChunk("fmt ", payload: formatPayload)
    let audio = littleEndianChunk("data", payload: Data(repeating: 0x69, count: 16))
    var data = Data("DSD ".utf8)
    data.appendLE(UInt64(28))
    data.appendLE(UInt64(28 + format.count + audio.count))
    data.appendLE(UInt64(0))
    data.append(format)
    data.append(audio)
    return data
}

private func littleEndianChunk(_ identifier: String, payload: Data) -> Data {
    var data = Data(identifier.utf8)
    data.appendLE(UInt64(payload.count + 12))
    data.append(payload)
    return data
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
