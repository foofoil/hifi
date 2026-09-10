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

struct ContentProbeMessageTests {
    @Test func sniffBudgetRejectsOrdinaryISOAndAcceptsMasterTOC() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ordinary = directory.appendingPathComponent("disk.iso")
        try Data(repeating: 0, count: 32).write(to: ordinary)
        #expect(!SACDISOParser.sniff(fileAt: ordinary))

        var marked = Data(repeating: 0, count: 511 * 2048)
        marked.replaceSubrange((510 * 2048)..<(510 * 2048 + 8), with: Data("SACDMTOC".utf8))
        let sacd = directory.appendingPathComponent("album.iso")
        try marked.write(to: sacd)
        #expect(SACDISOParser.sniff(fileAt: sacd))

        let needed = 510 * 2048 + 8
        #expect(needed <= 2_097_152)
        #expect(!SACDISOParser.sniff(Data(repeating: 0, count: needed - 1)))
    }

    @Test func sharedFixtureUsesApplicationCommandID() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("extension-kit/Sources/FoofoilExtensionKit/Fixtures/ContentProbeRequests.json")
        let requests = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request["commandID"] as? String == "content.probe")
            #expect(request["contractVersion"] as? Int == 1)
            #expect((request["resource"] as? [String: Any])?["url"] is String)
            #expect(request["maxReadBytes"] as? Int == 2_097_152)
            #expect(request["command"] == nil)
            #expect(request["session"] == nil)
        }
    }

    @Test func applicationCommandProbesOrdinaryAndMagicISO() throws {
        guard let raw = foofoilExtensionCreate(1) else {
            Issue.record("Runtime interface missing")
            return
        }
        let interface = raw.assumingMemoryBound(to: RuntimeInterfaceV1.self)
        guard interface.pointee.apiVersion == 1,
              let perform = interface.pointee.performApplicationCommand,
              let release = interface.pointee.releaseBytes else {
            Issue.record("Application command entry missing")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-hifi-probe-abi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ordinary = directory.appendingPathComponent("disk.iso")
        try Data(repeating: 0, count: 32).write(to: ordinary)
        var marked = Data(repeating: 0, count: 511 * 2048)
        marked.replaceSubrange((510 * 2048)..<(510 * 2048 + 8), with: Data("SACDMTOC".utf8))
        let sacd = directory.appendingPathComponent("album.iso")
        try marked.write(to: sacd)

        func probe(_ url: URL, maxReadBytes: Int = 2_097_152) throws -> [String: Any] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "commandID": "content.probe",
                "contractVersion": 1,
                "resource": ["url": url.absoluteString],
                "maxReadBytes": maxReadBytes
            ])
            var response: UnsafeMutablePointer<UInt8>?
            var length = 0
            let status = payload.withUnsafeBytes { bytes in
                perform(
                    interface.pointee.context,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &response,
                    &length
                )
            }
            #expect(status == 0)
            let bytes = try #require(response)
            defer { release(interface.pointee.context, bytes, length) }
            return try #require(JSONSerialization.jsonObject(with: Data(bytes: bytes, count: length)) as? [String: Any])
        }

        let unmatchedISO = try probe(ordinary)
        let matchedISO = try probe(sacd)
        let tinyBudget = try probe(sacd, maxReadBytes: 8)
        #expect(unmatchedISO["disposition"] as? String == "unmatched")
        #expect(matchedISO["disposition"] as? String == "matched")
        #expect(matchedISO["reason"] as? String == "sacd-master-toc")
        #expect(tinyBudget["disposition"] as? String == "unmatched")
        #expect(unmatchedISO["session"] == nil)
        #expect(matchedISO["session"] == nil)
    }
}
