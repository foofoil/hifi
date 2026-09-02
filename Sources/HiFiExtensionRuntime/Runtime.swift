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
    guard let request = jsonObject(input, length: inputLength) else {
        return RuntimeStatus.unsupportedRequest
    }
    do {
        let sources = try prepareSources(request: request)
        guard !sources.isEmpty else { return RuntimeStatus.unsupportedRequest }
        let devices = try CoreAudioDeviceCatalog.outputDevices()
        let sessionID = UUID()
        runtimeController.registerSession(id: sessionID, sources: sources, devices: devices)
        let session = makeSession(
            id: sessionID,
            request: request,
            sources: sources,
            devices: devices
        )
        return writeJSON(session, to: output, length: outputLength)
    } catch {
        return RuntimeStatus.processingFailed
    }
}

private func prepareSources(request: [String: Any]) throws -> [RuntimeSource] {
    let resources: [[String: Any]]
    switch request["kind"] as? String {
    case "singleFile": resources = (request["resource"] as? [String: Any]).map { [$0] } ?? []
    case "fileCollection": resources = request["resources"] as? [[String: Any]] ?? []
    default: resources = []
    }
    return try resources.enumerated().map { index, resource in
        guard let urlString = resource["url"] as? String,
              let fallbackURL = URL(string: urlString), fallbackURL.isFileURL else {
            throw RuntimeControllerError.invalidSource
        }
        let access = RuntimeResourceAccess(resource: resource, fallbackURL: fallbackURL)
        let descriptor = try DSDContainerParser.parse(fileAt: access.url)
        guard descriptor.kind == .dsf, descriptor.compression == .rawDSD,
              descriptor.channelCount == 2, descriptor.sampleCount != nil else {
            throw RuntimeControllerError.invalidSource
        }
        return RuntimeSource(id: "file:\(index)", access: access, descriptor: descriptor)
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
    sources: [RuntimeSource],
    devices: [HiFiAudioOutputDevice]
) -> [String: Any] {
    let source = sources[0]
    let url = source.url
    let descriptor = source.descriptor
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
            "id": "hifi.previous",
            "titleLocalizationKey": "Previous",
            "symbolName": "backward.fill",
            "modifierFlags": 0,
            "isEnabled": sources.count > 1,
            "isChecked": false
        ],
        [
            "id": "hifi.next",
            "titleLocalizationKey": "Next",
            "symbolName": "forward.fill",
            "modifierFlags": 0,
            "isEnabled": sources.count > 1,
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
    var playback: [String: Any] = [
        "state": "idle",
        "position": 0,
        "isSeekable": duration != nil,
        "underrunCount": 0
    ]
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
    var capabilities = [
        capability("session.seekable", "session"),
        capability("audio.device-selection", "application"),
        capability("ui.commands", "presentation")
    ]
    if sources.count > 1 {
        capabilities.append(capability("media.playback-queue", "session"))
        capabilities.append(capability("ui.navigator", "presentation"))
    }
    var result: [String: Any] = [
        "id": id.uuidString,
        "extensionID": "app.foofoil.extension.hifi",
        "providerID": "audio.hifi",
        "request": request,
        "presentation": ["kind": "text", "titleKey": "Hi-Fi Audio", "body": details],
        "capabilities": capabilities,
        "commands": commands,
        "navigatorContributions": [],
        "mediaPlayback": playback,
        "audioDeviceSelection": selection
    ]
    if sources.count > 1 {
        result["playbackQueue"] = queueObject(sources: sources, currentID: source.id)
        result["navigatorContributions"] = [navigatorObject(sources: sources, currentID: source.id)]
    }
    return result
}

private func queueObject(sources: [RuntimeSource], currentID: String) -> [String: Any] {
    let items: [[String: Any]] = sources.map {
        var item: [String: Any] = ["id": $0.id, "title": $0.url.lastPathComponent,
            "symbolName": "waveform", "isPlayable": true]
        if let duration = $0.descriptor.duration { item["duration"] = duration }
        return item
    }
    return ["contractVersion": 1, "items": items,
     "currentItemID": currentID, "repeatMode": "off", "isShuffled": false, "revision": 0]
}

private func navigatorObject(sources: [RuntimeSource], currentID: String) -> [String: Any] {
    ["id": "hifi.playback-queue", "contractVersion": 1, "titleLocalizationKey": "Hi-Fi Audio",
     "style": "flat", "selectionMode": "single", "items": sources.map {
        ["id": $0.id, "title": $0.url.lastPathComponent, "symbolName": "waveform",
         "isEnabled": true, "isCurrent": $0.id == currentID]
     }, "selectedItemIDs": [currentID], "allowedActions": ["activate"], "revision": 0]
}

private final class HiFiRuntimeController: @unchecked Sendable {
    private let lock = NSLock()
    private let player = HALDSFPlaybackEngine()
    private var sessions: [UUID: RuntimeSession] = [:]
    private var playingSessionID: UUID?

    func registerSession(id: UUID, sources: [RuntimeSource], devices: [HiFiAudioOutputDevice]) {
        let selectedDeviceID = (devices.first(where: \.isSystemDefault) ?? devices.first)?.id
        let record = RuntimeSession(
            id: id,
            sources: sources,
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
                record.underrunCount = 0
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
            record.underrunCount = status.underrunCount
            record.playbackState = "paused"
            record.failureDescription = status.failureDescription
            lock.lock()
            if playingSessionID == id { playingSessionID = nil }
            lock.unlock()
        case "hifi.seek":
            guard let playback = session["mediaPlayback"] as? [String: Any],
                  let requestedPosition = (playback["position"] as? NSNumber)?.doubleValue,
                  requestedPosition.isFinite, requestedPosition >= 0 else {
                throw RuntimeControllerError.invalidPlaybackPosition
            }
            let requestedSample = min(
                UInt64(min(requestedPosition * Double(record.sampleRate), Double(record.sampleCount))),
                record.sampleCount
            )
            let targetSample = requestedSample - requestedSample % 16
            lock.lock()
            let wasPlaying = playingSessionID == id
            if wasPlaying { playingSessionID = nil }
            lock.unlock()
            record.samplePosition = targetSample
            record.underrunCount = 0
            if wasPlaying {
                do {
                    _ = try player.stop()
                    guard let deviceUID = record.selectedDeviceID else {
                        throw RuntimeControllerError.noOutputDevice
                    }
                    try player.play(fileAt: record.url, deviceUID: deviceUID, startingSample: targetSample)
                    record.playbackState = "playing"
                    record.failureDescription = nil
                    lock.lock()
                    playingSessionID = id
                    lock.unlock()
                } catch {
                    record.playbackState = "failed"
                    record.failureDescription = String(describing: error)
                }
            } else if record.playbackState == "idle" || record.playbackState == "stopped" {
                record.playbackState = "paused"
            }
        case "hifi.previous", "hifi.next", "hifi.navigator.activate":
            let targetID: String?
            if commandID == "hifi.navigator.activate" {
                let contribution = (session["navigatorContributions"] as? [[String: Any]])?.first
                targetID = (contribution?["selectedItemIDs"] as? [String])?.first
            } else {
                let delta = commandID == "hifi.next" ? 1 : -1
                let next = record.currentIndex + delta
                targetID = record.sources.indices.contains(next) ? record.sources[next].id : nil
            }
            if let targetID { switchItem(to: targetID, record: record) }
        case "hifi.close":
            close(record)
        default:
            if commandID.hasPrefix("hifi.device.") {
                let selectedID = String(commandID.dropFirst("hifi.device.".count))
                try selectDevice(selectedID, for: record, session: &session)
            }
        }
        updatePlaybackState(for: record, session: &session)
        updateQueueState(for: record, session: &session)
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
            record.underrunCount = status.underrunCount
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
        trackedRecord.underrunCount = status.underrunCount
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

    private func switchItem(to targetID: String, record: RuntimeSession) {
        guard let index = record.sources.firstIndex(where: { $0.id == targetID }), index != record.currentIndex else { return }
        lock.lock()
        let wasPlaying = playingSessionID == record.id
        if wasPlaying { playingSessionID = nil }
        lock.unlock()
        if wasPlaying { _ = try? player.stop() }
        record.currentIndex = index
        record.samplePosition = 0
        record.underrunCount = 0
        record.failureDescription = nil
        record.playbackState = "paused"
        if wasPlaying, let deviceUID = record.selectedDeviceID {
            do {
                try player.play(fileAt: record.url, deviceUID: deviceUID)
                record.playbackState = "playing"
                lock.lock(); playingSessionID = record.id; lock.unlock()
            } catch {
                record.playbackState = "failed"
                record.failureDescription = String(describing: error)
            }
        }
    }

    private func updateQueueState(for record: RuntimeSession, session: inout [String: Any]) {
        guard record.sources.count > 1 else { return }
        let currentID = record.sources[record.currentIndex].id
        session["playbackQueue"] = queueObject(sources: record.sources, currentID: currentID)
        session["navigatorContributions"] = [navigatorObject(sources: record.sources, currentID: currentID)]
        if var presentation = session["presentation"] as? [String: Any] {
            presentation["body"] = record.url.lastPathComponent
            session["presentation"] = presentation
        }
    }

    private func updatePlaybackState(for record: RuntimeSession, session: inout [String: Any]) {
        var status = player.status()
        lock.lock()
        let shouldAdvance = playingSessionID == record.id
            && status.state == .stopped
            && status.samplePosition >= record.sampleCount
            && record.currentIndex + 1 < record.sources.count
        lock.unlock()
        if shouldAdvance {
            record.samplePosition = status.samplePosition
            switchItem(to: record.sources[record.currentIndex + 1].id, record: record)
            status = player.status()
        }
        lock.lock()
        let wasTracked = playingSessionID == record.id
        if wasTracked {
            record.samplePosition = status.samplePosition
            record.underrunCount = status.underrunCount
        }
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
            playback["duration"] = TimeInterval(record.sampleCount) / TimeInterval(record.sampleRate)
            playback["isSeekable"] = true
            playback["underrunCount"] = record.underrunCount
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
    let sources: [RuntimeSource]
    var currentIndex = 0
    var url: URL { sources[currentIndex].url }
    var sampleRate: Int { sources[currentIndex].descriptor.sampleRate }
    var sampleCount: UInt64 { sources[currentIndex].descriptor.sampleCount ?? 0 }
    var selectedDeviceID: String?
    var samplePosition: UInt64 = 0
    var underrunCount: UInt64 = 0
    var playbackState = "idle"
    var failureDescription: String?

    init(
        id: UUID,
        sources: [RuntimeSource],
        selectedDeviceID: String?
    ) {
        self.id = id
        self.sources = sources
        self.selectedDeviceID = selectedDeviceID
    }
}

private final class RuntimeSource {
    let id: String
    let access: RuntimeResourceAccess
    let descriptor: DSDContainerDescriptor
    var url: URL { access.url }

    init(id: String, access: RuntimeResourceAccess, descriptor: DSDContainerDescriptor) {
        self.id = id
        self.access = access
        self.descriptor = descriptor
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
    case invalidPlaybackPosition
    case invalidSource
}
