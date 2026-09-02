import Darwin
import Foundation
import HiFiExtensionCore

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
}

private enum RuntimeStatus {
    static let success: Int32 = 0
    static let invalidMessage: Int32 = 1
    static let unsupportedRequest: Int32 = 2
    static let processingFailed: Int32 = 3
}

private let createSessionCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    guard let request = jsonObject(input, length: inputLength),
          let resource = request["resource"] as? [String: Any],
          let urlString = resource["url"] as? String,
          let url = URL(string: urlString), url.isFileURL else {
        return RuntimeStatus.unsupportedRequest
    }
    do {
        let descriptor = try DSDContainerParser.parse(fileAt: url)
        let devices = try CoreAudioDeviceCatalog.outputDevices()
        let sessionID = UUID()
        try runtimeController.registerSession(
            id: sessionID,
            request: request,
            fallbackURL: url,
            sampleRate: descriptor.sampleRate,
            sampleCount: descriptor.sampleCount ?? 0,
            devices: devices
        )
        let session = makeSession(
            id: sessionID,
            request: request,
            url: url,
            descriptor: descriptor,
            devices: devices
        )
        return writeJSON(session, to: output, length: outputLength)
    } catch {
        return RuntimeStatus.processingFailed
    }
}

private let performCommandCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    guard let message = jsonObject(input, length: inputLength),
          let commandID = message["commandID"] as? String,
          var session = message["session"] as? [String: Any] else {
        return RuntimeStatus.invalidMessage
    }
    do {
        try runtimeController.perform(commandID: commandID, session: &session)
    } catch {
        return RuntimeStatus.processingFailed
    }
    return writeJSON(session, to: output, length: outputLength)
}

private let releaseCallback: ReleaseCall = { _, bytes, _ in bytes?.deallocate() }
private let destroyCallback: DestroyCall = { _ in runtimeController.shutdown() }

private let runtimeController = HiFiRuntimeController()

nonisolated(unsafe) private let interfacePointer: UnsafeMutablePointer<RuntimeInterfaceV1> = {
    let pointer = UnsafeMutablePointer<RuntimeInterfaceV1>.allocate(capacity: 1)
    pointer.initialize(to: RuntimeInterfaceV1(
        apiVersion: 1,
        structSize: MemoryLayout<RuntimeInterfaceV1>.size,
        context: nil,
        createSession: createSessionCallback,
        performCommand: performCommandCallback,
        releaseBytes: releaseCallback,
        destroy: destroyCallback
    ))
    return pointer
}()

@_cdecl("foofoil_extension_create")
public func foofoilExtensionCreate(_ negotiatedAPIVersion: UInt32) -> UnsafeRawPointer? {
    guard negotiatedAPIVersion == 1 else { return nil }
    return UnsafeRawPointer(interfacePointer)
}

private func jsonObject(_ input: UnsafePointer<UInt8>?, length: Int) -> [String: Any]? {
    guard let input, length > 0,
          let value = try? JSONSerialization.jsonObject(with: Data(bytes: input, count: length)) else { return nil }
    return value as? [String: Any]
}

private func writeJSON(
    _ object: [String: Any],
    to output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    length outputLength: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let output, let outputLength,
          let data = try? JSONSerialization.data(withJSONObject: object) else {
        return RuntimeStatus.processingFailed
    }
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    data.copyBytes(to: bytes, count: data.count)
    output.pointee = bytes
    outputLength.pointee = data.count
    return RuntimeStatus.success
}

private func makeSession(
    id: UUID,
    request: [String: Any],
    url: URL,
    descriptor: DSDContainerDescriptor,
    devices: [HiFiAudioOutputDevice]
) -> [String: Any] {
    let duration = descriptor.duration
    let compression = descriptor.compression == .dst ? "DST" : "DSD"
    let format = "\(descriptor.kind.rawValue.uppercased()) · \(compression)"
    let details = [
        url.lastPathComponent,
        format,
        "\(descriptor.channelCount) × \(descriptor.sampleRate) Hz",
        duration.map { String(format: "%.2f s", $0) }
    ].compactMap { $0 }.joined(separator: "\n")
    let selected = devices.first(where: \.isSystemDefault) ?? devices.first
    let deviceObjects: [[String: Any]] = devices.map {
        [
            "id": $0.id,
            "displayName": $0.displayName,
            "isSystemDefault": $0.isSystemDefault,
            "isConnected": $0.isConnected,
            "hasHardwareVolume": $0.hasHardwareVolume,
            "supportedDoPRates": $0.potentialDoPDSDRates
        ]
    }
    var commands: [[String: Any]] = [
        [
            "id": "hifi.play",
            "titleLocalizationKey": "Play",
            "symbolName": "play.fill",
            "modifierFlags": 0,
            "isEnabled": selected != nil,
            "isChecked": false
        ],
        [
            "id": "hifi.pause",
            "titleLocalizationKey": "Pause",
            "symbolName": "pause.fill",
            "modifierFlags": 0,
            "isEnabled": false,
            "isChecked": false
        ],
        [
        "id": "hifi.output-device",
        "titleLocalizationKey": "Hi-Fi Output Device",
        "symbolName": "hifispeaker.2",
        "modifierFlags": 0,
        "isEnabled": !devices.isEmpty,
        "isChecked": false
        ]
    ]
    commands.append(contentsOf: devices.map {
        [
            "id": "hifi.device.\($0.id)",
            "titleLocalizationKey": "",
            "displayTitle": $0.displayName,
            "parentID": "hifi.output-device",
            "modifierFlags": 0,
            "isEnabled": $0.isConnected,
            "isChecked": $0.id == selected?.id
        ]
    })
    let capability: (String, String) -> [String: Any] = { id, scope in
        ["declaration": ["id": id, "contractVersion": 1, "scope": scope, "dependencies": []], "state": "active"]
    }
    var playback: [String: Any] = ["state": "idle", "position": 0, "isSeekable": duration != nil]
    if let duration { playback["duration"] = duration }
    var selection: [String: Any] = [
        "contractVersion": 1,
        "devices": deviceObjects,
        "outputPolicy": "automatic",
        "revision": 0
    ]
    if let selected {
        selection["selectedDeviceID"] = selected.id
        selection["statusDescription"] = selected.displayName
    }
    return [
        "id": id.uuidString,
        "extensionID": "app.foofoil.extension.hifi",
        "providerID": "audio.hifi",
        "request": request,
        "presentation": ["kind": "text", "titleKey": "Hi-Fi Audio", "body": details],
        "capabilities": [
            capability("session.seekable", "session"),
            capability("audio.device-selection", "application"),
            capability("ui.commands", "presentation")
        ],
        "commands": commands,
        "navigatorContributions": [],
        "mediaPlayback": playback,
        "audioDeviceSelection": selection
    ]
}

private final class HiFiRuntimeController: @unchecked Sendable {
    private let lock = NSLock()
    private let player = HALDSFPlaybackEngine()
    private var sessions: [UUID: RuntimeSession] = [:]
    private var playingSessionID: UUID?

    func registerSession(
        id: UUID,
        request: [String: Any],
        fallbackURL: URL,
        sampleRate: Int,
        sampleCount: UInt64,
        devices: [HiFiAudioOutputDevice]
    ) throws {
        let resource = request["resource"] as? [String: Any]
        let access = RuntimeResourceAccess(resource: resource, fallbackURL: fallbackURL)
        let selectedDeviceID = (devices.first(where: \.isSystemDefault) ?? devices.first)?.id
        let record = RuntimeSession(
            id: id,
            url: access.url,
            access: access,
            sampleRate: sampleRate,
            sampleCount: sampleCount,
            selectedDeviceID: selectedDeviceID
        )
        lock.lock()
        sessions[id] = record
        lock.unlock()
    }

    func perform(commandID: String, session: inout [String: Any]) throws {
        guard let idString = session["id"] as? String,
              let id = UUID(uuidString: idString) else {
            throw RuntimeControllerError.invalidSession
        }
        lock.lock()
        guard let record = sessions[id] else {
            lock.unlock()
            throw RuntimeControllerError.invalidSession
        }
        lock.unlock()

        switch commandID {
        case "hifi.play":
            do {
                guard let deviceUID = record.selectedDeviceID else {
                    throw RuntimeControllerError.noOutputDevice
                }
                try stopTrackedPlayback(beforeStarting: record)
                if record.sampleCount > 0, record.samplePosition >= record.sampleCount {
                    record.samplePosition = 0
                }
                try player.play(
                    fileAt: record.url,
                    deviceUID: deviceUID,
                    startingSample: record.samplePosition
                )
                record.playbackState = "playing"
                record.failureDescription = nil
                lock.lock()
                playingSessionID = id
                lock.unlock()
            } catch {
                lock.lock()
                if playingSessionID == id { playingSessionID = nil }
                lock.unlock()
                record.playbackState = "failed"
                record.failureDescription = String(describing: error)
            }
        case "hifi.pause":
            let status = try player.stop()
            record.samplePosition = status.samplePosition
            record.playbackState = "paused"
            record.failureDescription = status.failureDescription
            lock.lock()
            if playingSessionID == id { playingSessionID = nil }
            lock.unlock()
        case "hifi.close":
            close(record)
        default:
            if commandID.hasPrefix("hifi.device.") {
                let selectedID = String(commandID.dropFirst("hifi.device.".count))
                try selectDevice(selectedID, for: record, session: &session)
            }
        }
        updatePlaybackState(for: record, session: &session)
    }

    func shutdown() {
        _ = try? player.stop()
        lock.lock()
        sessions.removeAll()
        playingSessionID = nil
        lock.unlock()
    }

    private func selectDevice(
        _ selectedID: String,
        for record: RuntimeSession,
        session: inout [String: Any]
    ) throws {
        guard var selection = session["audioDeviceSelection"] as? [String: Any],
              var commands = session["commands"] as? [[String: Any]] else {
            throw RuntimeControllerError.invalidSession
        }
        let devices = selection["devices"] as? [[String: Any]] ?? []
        guard let device = devices.first(where: { $0["id"] as? String == selectedID }) else {
            throw RuntimeControllerError.noOutputDevice
        }

        lock.lock()
        let wasPlaying = playingSessionID == record.id
        lock.unlock()
        if wasPlaying {
            let status = try player.stop()
            record.samplePosition = status.samplePosition
            record.playbackState = "paused"
            record.failureDescription = status.failureDescription
            lock.lock()
            playingSessionID = nil
            lock.unlock()
        }
        record.selectedDeviceID = selectedID
        selection["selectedDeviceID"] = selectedID
        selection["statusDescription"] = device["displayName"] as? String ?? selectedID
        selection["revision"] = ((selection["revision"] as? NSNumber)?.uint64Value ?? 0) + 1
        for index in commands.indices where (commands[index]["id"] as? String)?.hasPrefix("hifi.device.") == true {
            commands[index]["isChecked"] = commands[index]["id"] as? String == "hifi.device.\(selectedID)"
        }
        session["audioDeviceSelection"] = selection
        session["commands"] = commands
    }

    /// HAL 播放器为进程级独占资源；切换箔片前先保存上一会话的位置。
    private func stopTrackedPlayback(beforeStarting record: RuntimeSession) throws {
        lock.lock()
        let trackedID = playingSessionID
        let trackedRecord = trackedID.flatMap { sessions[$0] }
        playingSessionID = nil
        lock.unlock()

        guard let trackedRecord else { return }
        let status = try player.stop()
        trackedRecord.samplePosition = status.samplePosition
        trackedRecord.playbackState = "paused"
        trackedRecord.failureDescription = status.failureDescription
    }

    private func close(_ record: RuntimeSession) {
        lock.lock()
        let wasPlaying = playingSessionID == record.id
        if wasPlaying { playingSessionID = nil }
        lock.unlock()
        if wasPlaying { _ = try? player.stop() }
        lock.lock()
        sessions.removeValue(forKey: record.id)
        lock.unlock()
    }

    private func updatePlaybackState(for record: RuntimeSession, session: inout [String: Any]) {
        let status = player.status()
        lock.lock()
        let wasTracked = playingSessionID == record.id
        if wasTracked { record.samplePosition = status.samplePosition }
        if wasTracked, status.state != .playing {
            playingSessionID = nil
            record.playbackState = status.state == .failed ? "failed" : "stopped"
            record.failureDescription = status.failureDescription
        }
        let isPlaying = playingSessionID == record.id && status.state == .playing
        lock.unlock()
        let position = TimeInterval(record.samplePosition) / TimeInterval(record.sampleRate)
        if var playback = session["mediaPlayback"] as? [String: Any] {
            playback["state"] = record.playbackState
            playback["position"] = position
            playback["failureMessage"] = record.failureDescription
            session["mediaPlayback"] = playback
        }
        if var selection = session["audioDeviceSelection"] as? [String: Any] {
            selection["activeTransport"] = isPlaying ? "dop" : nil
            if isPlaying, let deviceID = record.selectedDeviceID,
               let devices = selection["devices"] as? [[String: Any]],
               let device = devices.first(where: { $0["id"] as? String == deviceID }) {
                selection["statusDescription"] = "DSD\(record.sampleRate / 44_100) · DoP · \(device["displayName"] as? String ?? deviceID)"
            }
            session["audioDeviceSelection"] = selection
        }
        if var commands = session["commands"] as? [[String: Any]] {
            for index in commands.indices {
                switch commands[index]["id"] as? String {
                case "hifi.play": commands[index]["isEnabled"] = !isPlaying
                case "hifi.pause": commands[index]["isEnabled"] = isPlaying
                default: break
                }
            }
            session["commands"] = commands
        }
    }
}

private final class RuntimeSession {
    let id: UUID
    let url: URL
    let access: RuntimeResourceAccess
    let sampleRate: Int
    let sampleCount: UInt64
    var selectedDeviceID: String?
    var samplePosition: UInt64 = 0
    var playbackState = "idle"
    var failureDescription: String?

    init(
        id: UUID,
        url: URL,
        access: RuntimeResourceAccess,
        sampleRate: Int,
        sampleCount: UInt64,
        selectedDeviceID: String?
    ) {
        self.id = id
        self.url = url
        self.access = access
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.selectedDeviceID = selectedDeviceID
    }
}

private final class RuntimeResourceAccess {
    let url: URL
    private let didStartAccess: Bool

    init(resource: [String: Any]?, fallbackURL: URL) {
        if let bookmarkString = resource?["securityScopedBookmark"] as? String,
           let bookmark = Data(base64Encoded: bookmarkString) {
            var stale = false
            url = (try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &stale
            )) ?? fallbackURL
        } else {
            url = fallbackURL
        }
        didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
    }
}

private enum RuntimeControllerError: Error {
    case invalidSession
    case noOutputDevice
}
