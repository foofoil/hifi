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
}

@_silgen_name("foofoil_extension_create")
private func createRuntime(_ version: UInt32) -> UnsafeRawPointer?

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: hifi-runtime-smoke <file.dsf|file.dff|--self-test>\n".utf8))
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
          let releaseBytes = interface.pointee.releaseBytes else {
        throw SmokeError.invalidInterface
    }
    func perform(_ commandID: String, session: [String: Any]) throws -> [String: Any] {
        guard let performCommand = interface.pointee.performCommand else {
            throw SmokeError.invalidInterface
        }
        let message = try JSONSerialization.data(withJSONObject: [
            "commandID": commandID,
            "session": session
        ])
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
    var finalSession = session
    if isSelfTest {
        var requested = session
        var contributions = requested["navigatorContributions"] as! [[String: Any]]
        contributions[0]["selectedItemIDs"] = ["file:1"]
        requested["navigatorContributions"] = contributions
        finalSession = try perform("hifi.navigator.activate", session: requested)
        guard (finalSession["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == "file:1" else {
            throw SmokeError.invalidSession
        }

        requested = finalSession
        contributions = requested["navigatorContributions"] as! [[String: Any]]
        var items = contributions[0]["items"] as! [[String: Any]]
        items.swapAt(0, 1)
        contributions[0]["items"] = items
        requested["navigatorContributions"] = contributions
        finalSession = try perform("hifi.navigator.move", session: requested)
        let reorderedIDs = ((finalSession["playbackQueue"] as? [String: Any])?["items"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String }
        guard reorderedIDs == ["file:1", "file:0"],
              (finalSession["playbackQueue"] as? [String: Any])?["currentItemID"] as? String == "file:1",
              ((finalSession["navigatorContributions"] as? [[String: Any]])?.first?["allowedActions"] as? [String])?
                .contains("move") == true else {
            throw SmokeError.invalidSession
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
