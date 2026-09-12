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
    var performApplicationCommand: RuntimeCall?
}

private enum RuntimeStatus {
    static let success: Int32 = 0
    static let invalidMessage: Int32 = 1
    static let unsupportedRequest: Int32 = 2
    static let processingFailed: Int32 = 3
}

private let createSessionCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
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
    return try resources.enumerated().flatMap { index, resource -> [RuntimeSource] in
        guard let urlString = resource["url"] as? String,
              let fallbackURL = URL(string: urlString), fallbackURL.isFileURL else {
            throw RuntimeControllerError.invalidSource
        }
        let access = RuntimeResourceAccess(resource: resource, fallbackURL: fallbackURL)
        if SACDISOParser.sniff(fileAt: access.url) {
            let disc = try SACDISOParser.parse(fileAt: access.url)
            guard let area = disc.stereoArea else { throw SACDISOError.missingStereoArea }
            guard area.frameFormat != .dst else { throw SACDISOError.unsupportedFrameFormat }
            return try area.tracks.map { track in
                let descriptor = try disc.containerDescriptor(trackNumber: track.number)
                guard descriptor.compression == .rawDSD,
                      descriptor.sampleCount != nil,
                      HALDSFPlaybackEngine.supportsStereoPlayback(descriptor) else {
                    throw RuntimeControllerError.invalidSource
                }
                return RuntimeSource(
                    id: "track:stereo:\(String(format: "%02d", track.number))",
                    access: access,
                    descriptor: descriptor,
                    title: track.title,
                    artist: track.artist,
                    album: disc.displayTitle,
                    sacdTrackNumber: track.number
                )
            }
        }
        switch access.url.pathExtension.lowercased() {
        case "ape":
            // 同集合里已有同名 CUE 时以 CUE 分轨为准，避免同一专辑展开两次。
            if resources.count > 1,
               collectionContainsCue(matching: access.url, resources: resources, skipping: index) {
                return []
            }
            return try apeSources(
                audioAccess: access,
                index: index
            )
        case "cue":
            return try cueSources(
                cueAccess: access,
                resources: resources,
                index: index
            )
        default:
            break
        }
        let descriptor = try DSDContainerParser.parse(fileAt: access.url)
        guard descriptor.compression == .rawDSD,
              descriptor.sampleCount != nil,
              HALDSFPlaybackEngine.supportsStereoPlayback(descriptor) else {
            throw RuntimeControllerError.invalidSource
        }
        return [RuntimeSource(id: "file:\(index)", access: access, descriptor: descriptor)]
    }
}

/// 单 APE 文件：同目录同名 CUE 可读且指向本文件时展开为分轨，否则按整轨建会话。
private func apeSources(
    audioAccess: RuntimeResourceAccess,
    index: Int
) throws -> [RuntimeSource] {
    let descriptor = try APEParser.parse(fileAt: audioAccess.url)
    guard HALPCMPlaybackEngine.supportsPlayback(descriptor) else {
        throw RuntimeControllerError.invalidSource
    }
    if let sheet = try apeCueSheet(stemmingFrom: audioAccess.url, descriptor: descriptor),
       sheet.tracks.count > 1 {
        return cueTrackSources(sheet: sheet, audioAccess: audioAccess, descriptor: descriptor)
    }
    return [RuntimeSource(id: "file:\(index)", access: audioAccess, apeDescriptor: descriptor)]
}

/// CUE 文件：只接管单 APE 文件的整轨 CUE，其他交还宿主或其他 provider。
private func cueSources(
    cueAccess: RuntimeResourceAccess,
    resources: [[String: Any]],
    index: Int
) throws -> [RuntimeSource] {
    let cueURL = cueAccess.url
    guard let fileName = try cueFirstAudioFileName(cueURL: cueURL),
          (fileName as NSString).pathExtension.lowercased() == "ape" else {
        throw RuntimeControllerError.invalidSource
    }
    let audioAccess = try apeAudioAccess(
        fileName: fileName,
        cueURL: cueURL,
        resources: resources
    )
    let descriptor = try APEParser.parse(fileAt: audioAccess.url)
    guard HALPCMPlaybackEngine.supportsPlayback(descriptor) else {
        throw RuntimeControllerError.invalidSource
    }
    guard let sheet = try APECueSheetParser.load(cueAt: cueURL, sampleRate: descriptor.sampleRate),
          sheet.tracks.count > 1 else {
        throw RuntimeControllerError.invalidSource
    }
    return cueTrackSources(sheet: sheet, audioAccess: audioAccess, descriptor: descriptor)
}

/// 轻量读 CUE 首个 FILE 名；读不到按非我方处理，让出给其他 provider。
private func cueFirstAudioFileName(cueURL: URL) throws -> String? {
    guard let data = try? Data(contentsOf: cueURL), !data.isEmpty else {
        throw APECueSheetError.unreadable
    }
    guard let text = APECueSheetParser.decodeText(data) else {
        throw APECueSheetError.unreadable
    }
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let parsed = APECueSheetParser.parseLine(line),
              parsed.command == "FILE",
              let name = parsed.arguments.first, !name.isEmpty else { continue }
        return name
    }
    return nil
}

/// 用已知的 APE 描述解析同名 CUE；只展开指向本文件的单 APE 整轨 CUE。
private func apeCueSheet(
    stemmingFrom url: URL,
    descriptor: APEAudioDescriptor
) throws -> APECueSheet? {
    let directory = url.deletingLastPathComponent()
    let stem = (url.deletingPathExtension().lastPathComponent as NSString).lowercased
    let cueURL = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).cue")
    guard FileManager.default.fileExists(atPath: cueURL.path) else { return nil }
    guard let sheet = try? APECueSheetParser.load(cueAt: cueURL, sampleRate: descriptor.sampleRate),
          sheet.tracks.count > 1 else { return nil }
    // CUE 必须指向当前 APE（按主名比对，容忍 FILE 里写 .wav 的老抓轨）。
    let cueStem = ((sheet.audioFileName as NSString).deletingPathExtension as NSString).lowercased
    guard cueStem == stem else { return nil }
    return sheet
}

/// CUE 引用的 APE 访问：优先用 fileCollection 里同名资源的书签（沙盒持久授权），否则用同目录兄弟文件。
private func apeAudioAccess(
    fileName: String,
    cueURL: URL,
    resources: [[String: Any]]
) throws -> RuntimeResourceAccess {
    let baseName = (fileName as NSString).lastPathComponent
    let wanted = baseName.lowercased()
    let wantedStem = ((baseName as NSString).deletingPathExtension as NSString).lowercased
    var stemFallback: RuntimeResourceAccess?
    for resource in resources {
        guard let urlString = resource["url"] as? String,
              let url = URL(string: urlString), url.isFileURL,
              url.pathExtension.lowercased() == "ape" else { continue }
        let candidate = url.lastPathComponent.lowercased()
        let candidateStem = ((url.deletingPathExtension().lastPathComponent as NSString).lowercased)
        if candidate == wanted || candidateStem == wantedStem {
            return RuntimeResourceAccess(resource: resource, fallbackURL: url)
        }
        if stemFallback == nil,
           ((cueURL.deletingPathExtension().lastPathComponent as NSString).lowercased) == candidateStem {
            stemFallback = RuntimeResourceAccess(resource: resource, fallbackURL: url)
        }
    }
    if let stemFallback { return stemFallback }
    guard let sibling = APECueSheetParser.resolveAudioURL(named: fileName, cueURL: cueURL) else {
        throw HiFiPlaybackError.resourceAuthorizationFailure
    }
    return RuntimeResourceAccess(resource: nil, fallbackURL: sibling)
}

private func cueTrackSources(
    sheet: APECueSheet,
    audioAccess: RuntimeResourceAccess,
    descriptor: APEAudioDescriptor
) -> [RuntimeSource] {
    sheet.tracks.map { track in
        let endBlock = track.endBlock.map { min($0, descriptor.totalBlocks) }
        return RuntimeSource(
            id: "track:cue:\(String(format: "%02d", track.number))",
            access: audioAccess,
            apeDescriptor: descriptor,
            apeStartBlock: min(track.startBlock, descriptor.totalBlocks),
            apeEndBlock: endBlock,
            title: track.title,
            artist: track.performer,
            album: sheet.displayTitle,
            cueTrackNumber: track.number
        )
    }
}

/// 同 fileCollection 里是否存在同主名的 CUE 资源；存在时 APE 让位给 CUE 分轨。
private func collectionContainsCue(matching apeURL: URL, resources: [[String: Any]], skipping index: Int) -> Bool {
    let apeStem = (apeURL.deletingPathExtension().lastPathComponent as NSString).lowercased
    for (otherIndex, resource) in resources.enumerated() where otherIndex != index {
        guard let urlString = resource["url"] as? String,
              let url = URL(string: urlString), url.isFileURL,
              url.pathExtension.lowercased() == "cue",
              (url.deletingPathExtension().lastPathComponent as NSString).lowercased == apeStem else {
            continue
        }
        return true
    }
    return false
}

private let performCommandCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
    guard let input, let message = jsonObject(input, length: inputLength),
          let commandID = message["commandID"] as? String,
          var session = message["session"] as? [String: Any] else {
        return RuntimeStatus.invalidMessage
    }
    let lifecycle: SessionLifecycleMessage?
    let media: MediaPlaybackMessage?
    let navigation: NavigatorActionMessage?
    if commandID == "media.transport" || commandID == "ui.navigator.action" {
        do {
            let data = Data(bytes: input, count: inputLength)
            media = commandID == "media.transport" ? try JSONDecoder().decode(MediaPlaybackMessage.self, from: data) : nil
            navigation = commandID == "ui.navigator.action" ? try JSONDecoder().decode(NavigatorActionMessage.self, from: data) : nil
            try media?.validate()
            try navigation?.validate()
        } catch {
            return RuntimeStatus.invalidMessage
        }
    } else {
        media = nil
        navigation = nil
    }
    if commandID == "session.lifecycle" {
        do {
            let data = Data(bytes: input, count: inputLength)
            let decoded = try JSONDecoder().decode(SessionLifecycleMessage.self, from: data)
            try decoded.validate()
            lifecycle = decoded
        } catch {
            return RuntimeStatus.invalidMessage
        }
    } else {
        lifecycle = nil
    }
    do {
        if let lifecycle {
            try runtimeController.perform(lifecycle: lifecycle, session: &session)
        } else if let media {
            try runtimeController.perform(media: media, session: &session)
        } else if let navigation {
            try runtimeController.perform(navigation: navigation, session: &session)
        } else {
            // 只接受当前公共命令；旧 `hifi.*` 外部入口明确拒绝。
            return RuntimeStatus.invalidMessage
        }
    } catch {
        return RuntimeStatus.processingFailed
    }
    return writeJSON(session, to: output, length: outputLength)
}

private let performApplicationCommandCallback: RuntimeCall = { _, input, inputLength, output, outputLength in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
    guard let message = jsonObject(input, length: inputLength) else {
        return RuntimeStatus.invalidMessage
    }
    do {
        if message["commandID"] as? String == "content.probe" {
            let response = try contentProbe(message)
            return writeJSON(response, to: output, length: outputLength)
        }
        let response = try audioDeviceServiceController.perform(
            message,
            stopDSDPlayback: { try runtimeController.stopForExternalPCM(deviceUID: $0) }
        )
        return writeJSON(response, to: output, length: outputLength)
    } catch RuntimeControllerError.invalidSession {
        return RuntimeStatus.invalidMessage
    } catch {
        return RuntimeStatus.processingFailed
    }
}

private let releaseCallback: ReleaseCall = { _, bytes, _ in bytes?.deallocate() }
private let destroyCallback: DestroyCall = { _ in
    runtimeControlLock.lock()
    defer { runtimeControlLock.unlock() }
    audioDeviceServiceController.shutdown()
    runtimeController.shutdown()
}

// 会话命令与应用级 PCM 命令可从不同线程进入；统一串行交接设备，HAL callback 不使用此锁。
private let runtimeControlLock = NSRecursiveLock()
private let runtimeController = HiFiRuntimeController()
private let audioDeviceServiceController = AudioDeviceServiceController()

nonisolated(unsafe) private let interfacePointer: UnsafeMutablePointer<RuntimeInterfaceV1> = {
    let pointer = UnsafeMutablePointer<RuntimeInterfaceV1>.allocate(capacity: 1)
    pointer.initialize(to: RuntimeInterfaceV1(
        apiVersion: 1,
        structSize: MemoryLayout<RuntimeInterfaceV1>.size,
        context: nil,
        createSession: createSessionCallback,
        performCommand: performCommandCallback,
        releaseBytes: releaseCallback,
        destroy: destroyCallback,
        performApplicationCommand: performApplicationCommandCallback
    ))
    return pointer
}()

@_cdecl("foofoil_extension_create")
public func foofoilExtensionCreate(_ negotiatedAPIVersion: UInt32) -> UnsafeRawPointer? {
    guard negotiatedAPIVersion == 1 else { return nil }
    return UnsafeRawPointer(interfacePointer)
}

/// 只在预算内读取 Scarlet Book 主 TOC 魔数；不建会话、不碰设备。
private func contentProbe(_ message: [String: Any]) throws -> [String: Any] {
    guard message["contractVersion"] as? Int == 1,
          let resource = message["resource"] as? [String: Any],
          let urlString = resource["url"] as? String,
          let fallbackURL = URL(string: urlString), fallbackURL.isFileURL else {
        throw RuntimeControllerError.invalidSession
    }
    let maxReadBytes = (message["maxReadBytes"] as? Int) ?? 2_097_152
    guard maxReadBytes > 0 else { throw RuntimeControllerError.invalidSession }
    var result: [String: Any] = ["contractVersion": 1, "disposition": "unmatched"]
    switch fallbackURL.pathExtension.lowercased() {
    case "iso":
        let sniffBytes = 510 * 2048 + 8
        guard maxReadBytes >= sniffBytes else { return result }
        let access = RuntimeResourceAccess(resource: resource, fallbackURL: fallbackURL)
        if SACDISOParser.sniff(fileAt: access.url) {
            result["disposition"] = "matched"
            result["reason"] = "sacd-master-toc"
        }
    case "cue":
        // 探针只确认“单 APE 整轨 CUE”，不建会话不碰设备；采样率未知时按 44.1k 解析取文件名。
        let access = RuntimeResourceAccess(resource: resource, fallbackURL: fallbackURL)
        if let data = try? Data(contentsOf: access.url),
           let text = APECueSheetParser.decodeText(data),
           let sheet = APECueSheetParser.parse(text: text, cueURL: access.url, sampleRate: 44100),
           sheet.tracks.count > 1 {
            result["disposition"] = "matched"
            result["reason"] = "ape-cue-sheet"
        }
    default:
        break
    }
    return result
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
    let duration = source.duration
    let details = [
        url.lastPathComponent,
        source.formatSummary,
        "\(source.channelCount) × \(source.sampleRate) Hz",
        duration.map { String(format: "%.2f s", $0) }
    ].compactMap { $0 }.joined(separator: "\n")
    let compatibleDevices = devices.filter { isDeviceCompatible($0, source: source) }
    let selected = compatibleDevices.first(where: \.isSystemDefault) ?? compatibleDevices.first
    let deviceObjects: [[String: Any]] = devices.map { device in
        [
            "id": device.id,
            "displayName": device.displayName,
            "isSystemDefault": device.isSystemDefault,
            "isConnected": device.isConnected,
            "isCompatible": compatibleDevices.contains { $0.id == device.id },
            "hasHardwareVolume": device.hasHardwareVolume,
            "supportedDoPRates": device.potentialDoPDSDRates,
            "supportedPCMSampleRates": device.supportedPCMSampleRates
        ]
    }
    // 标准媒体/设备操作由宿主 UI 与公共能力承接；这里只提供 availableActions，不再贡献旧菜单命令。
    var availableActions = ["refresh", "seek"]
    if devices.contains(where: { $0.isConnected }) { availableActions.append("selectDevice") }
    if selected != nil { availableActions.append("play") }
    if sources.count > 1 { availableActions.append(contentsOf: ["previous", "next"]) }
    let capability: (String, String) -> [String: Any] = { id, scope in
        ["declaration": ["id": id, "contractVersion": 1, "scope": scope, "dependencies": []], "state": "active"]
    }
    var playback: [String: Any] = [
        "state": "idle",
        "position": 0,
        "isSeekable": duration != nil,
        "underrunCount": 0,
        "availableActions": availableActions
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
        capability("media.transport", "session"),
        capability("session.lifecycle", "session"),
        capability("session.seekable", "session"),
        capability("audio.device-selection", "application")
    ]
    if sources.count > 1 {
        capabilities.append(capability("ui.navigator-actions", "presentation"))
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
        "commands": [],
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

private func queueObject(
    sources: [RuntimeSource],
    currentID: String,
    revision: UInt64 = 0
) -> [String: Any] {
    let items: [[String: Any]] = sources.map {
        var item: [String: Any] = [
            "id": $0.id,
            "title": $0.displayTitle,
            "symbolName": "waveform",
            "isPlayable": true
        ]
        if let artist = $0.artist { item["subtitle"] = artist }
        if let duration = $0.duration { item["duration"] = duration }
        return item
    }
    var object: [String: Any] = [
        "contractVersion": 1,
        "items": items,
        "currentItemID": currentID,
        "repeatMode": "off",
        "isShuffled": false,
        "revision": revision
    ]
    if let album = sources.first?.album { object["title"] = album }
    return object
}

private func navigatorObject(
    sources: [RuntimeSource],
    currentID: String,
    revision: UInt64 = 0
) -> [String: Any] {
    let isContainer = sources.contains { $0.sacdTrackNumber != nil || $0.cueTrackNumber != nil }
    return [
        "id": "hifi.playback-queue",
        "contractVersion": 1,
        "titleLocalizationKey": "Hi-Fi Audio",
        "style": "flat",
        "selectionMode": "single",
        "items": sources.map { source -> [String: Any] in
            var item: [String: Any] = [
                "id": source.id,
                "title": source.displayTitle,
                "symbolName": "waveform",
                "isEnabled": true,
                "isCurrent": source.id == currentID
            ]
            if let artist = source.artist { item["subtitle"] = artist }
            if let duration = source.duration {
                item["badge"] = formatDuration(duration)
            }
            return item
        },
        "selectedItemIDs": [currentID],
        "allowedActions": isContainer ? ["activate"] : ["activate", "move"],
        "revision": revision
    ]
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remainder = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
        : String(format: "%d:%02d", minutes, remainder)
}

private final class HiFiRuntimeController: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: RuntimeSession] = [:]

    func registerSession(id: UUID, sources: [RuntimeSource], devices: [HiFiAudioOutputDevice]) {
        let first = sources.first
        let compatible = devices.filter { device in
            guard let first else { return false }
            return isDeviceCompatible(device, source: first)
        }
        let selectedDeviceID = (compatible.first(where: \.isSystemDefault) ?? compatible.first)?.id
        let record = RuntimeSession(
            id: id,
            sources: sources,
            selectedDeviceID: selectedDeviceID
        )
        lock.lock()
        sessions[id] = record
        lock.unlock()
    }

    /// 恢复只作用于未播放的活会话，曲目选择与位置校验留在扩展内。
    func perform(lifecycle: SessionLifecycleMessage, session: inout [String: Any]) throws {
        guard let idString = session["id"] as? String, let id = UUID(uuidString: idString) else {
            throw RuntimeControllerError.invalidSession
        }
        lock.lock()
        let record = sessions[id]
        lock.unlock()
        if lifecycle.operation == .close {
            // 已关闭的会话重复关闭仍成功，不重新创建记录或接触硬件。
            if let record { try close(record) }
            var playback = session["mediaPlayback"] as? [String: Any] ?? [:]
            playback["state"] = "stopped"
            session["mediaPlayback"] = playback
            return
        }
        guard let record, let restoration = lifecycle.restoration else {
            throw RuntimeControllerError.invalidSession
        }
        guard !record.isActive else { throw LifecycleMessageError.activeSession }
        if let itemID = restoration.currentItemID,
           !record.sources.contains(where: { $0.id == itemID }) {
            // 文件被替换或曲目消失时，不把旧曲目的进度套到其他曲目。
            return
        }
        try perform(action: .pause, session: &session)
        if let itemID = restoration.currentItemID {
            switchItem(to: itemID, record: record, allowsAutomaticPlayback: false)
        }
        if let position = restoration.position {
            try perform(action: .seek(position: position), session: &session)
        }
        updatePlaybackState(for: record, session: &session)
        updateQueueState(for: record, session: &session)
    }

    func perform(navigation: NavigatorActionMessage, session: inout [String: Any]) throws {
        guard let idString = session["id"] as? String, let id = UUID(uuidString: idString) else {
            throw RuntimeControllerError.invalidSession
        }
        lock.lock()
        let record = sessions[id]
        lock.unlock()
        guard let record else { throw RuntimeControllerError.invalidSession }
        let orderedIDs = try navigation.orderedIDs(
            in: record.sources.map(\.id), canMove: !record.sources.contains { $0.sacdTrackNumber != nil }
        )
        var contribution = navigatorObject(sources: record.sources, currentID: record.sources[record.currentIndex].id)
        switch navigation.action.kind {
        case .activate:
            contribution["selectedItemIDs"] = navigation.action.itemIDs
            session["navigatorContributions"] = [contribution]
            try perform(action: .activate(itemID: navigation.action.itemIDs[0]), session: &session)
        case .move:
            guard let items = contribution["items"] as? [[String: Any]] else {
                throw RuntimeControllerError.invalidQueueOrder
            }
            contribution["items"] = orderedIDs.compactMap { id in items.first { $0["id"] as? String == id } }
            session["navigatorContributions"] = [contribution]
            try perform(action: .move(orderedIDs: orderedIDs), session: &session)
        case .remove:
            throw ActionMessageError.invalidAction
        }
    }

    /// 公共媒体消息直接映射为类型化动作，不再经过旧 `hifi.*` 字符串 dispatch。
    func perform(media: MediaPlaybackMessage, session: inout [String: Any]) throws {
        try perform(action: media.runtimeAction, session: &session)
    }

    func perform(action: RuntimeAction, session: inout [String: Any]) throws {
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

        synchronizeItem(for: record, status: record.engineStatus())

        if let queue = session["playbackQueue"] as? [String: Any],
           let items = queue["items"] as? [[String: Any]] {
            let ids = items.compactMap { $0["id"] as? String }
            let oldSuccessors = record.successors.map(\.id) + record.apeSuccessors.map(\.id)
            record.sequenceIDs = ids
            let newSuccessors = record.successors.map(\.id) + record.apeSuccessors.map(\.id)
            if case .refresh = action, record.isActive, oldSuccessors != newSuccessors {
                let status = try record.stopEngines()
                synchronizeItem(for: record, status: status)
                record.samplePosition = status.samplePosition
                record.isActive = false
                if let deviceUID = record.selectedDeviceID {
                    do {
                        try record.playCurrent(deviceUID: deviceUID, startingSample: record.samplePosition)
                        record.isActive = true
                    } catch {
                        record.playbackState = "failed"
                        record.failureDescription = failureKey(error)
                    }
                }
            }
        }

        // 每次命令前用系统最新设备列表刷新会话，避免独占设备离线后菜单与状态卡在已不存在的设备上。
        refreshDeviceSelection(for: record, session: &session)

        switch action {
        case .play:
            do {
                audioDeviceServiceController.releasePCMForExclusive(deviceUID: record.selectedDeviceID)
                guard let deviceUID = record.selectedDeviceID else {
                    throw RuntimeControllerError.noOutputDevice
                }
                try stopTrackedPlayback(beforeStarting: record)
                if record.sampleCount > 0, record.samplePosition >= record.sampleCount {
                    record.samplePosition = 0
                }
                try record.playCurrent(deviceUID: deviceUID, startingSample: record.samplePosition)
                record.playbackState = "playing"
                record.underrunCount = 0
                record.failureDescription = nil
                lock.lock()
                record.isActive = true
                lock.unlock()
            } catch {
                lock.lock()
                if record.isActive { record.isActive = false }
                lock.unlock()
                record.playbackState = "failed"
                record.failureDescription = failureKey(error)
            }
        case .pause:
            lock.lock()
            let ownsPlayer = record.isActive
            lock.unlock()
            // 恢复后尚未起播的会话保留 seek 位置，也不能停止另一窗口持有的输出。
            if ownsPlayer {
                let status = try record.stopEngines()
                synchronizeItem(for: record, status: status)
                record.samplePosition = status.samplePosition
                record.underrunCount = status.underrunCount
                record.failureDescription = status.failureDescription
                lock.lock()
                if record.isActive { record.isActive = false }
                lock.unlock()
            }
            record.playbackState = "paused"
        case .seek(let requestedPosition):
            guard requestedPosition.isFinite, requestedPosition >= 0 else {
                throw RuntimeControllerError.invalidPlaybackPosition
            }
            let requestedSample = min(
                UInt64(min(requestedPosition * Double(record.sampleRate), Double(record.sampleCount))),
                record.sampleCount
            )
            // DSD seek 按整 DoP 帧对齐；PCM 按帧精确。
            let targetSample = record.isAPE ? requestedSample : requestedSample - requestedSample % 16
            lock.lock()
            let wasPlaying = record.isActive
            if wasPlaying { record.isActive = false }
            lock.unlock()
            record.samplePosition = targetSample
            record.underrunCount = 0
            if wasPlaying {
                do {
                    _ = try record.stopEngines()
                    guard let deviceUID = record.selectedDeviceID else {
                        throw RuntimeControllerError.noOutputDevice
                    }
                    try record.playCurrent(deviceUID: deviceUID, startingSample: targetSample)
                    record.playbackState = "playing"
                    record.failureDescription = nil
                    lock.lock()
                    record.isActive = true
                    lock.unlock()
                } catch {
                    record.playbackState = "failed"
                    record.failureDescription = failureKey(error)
                }
            } else if record.playbackState == "idle" || record.playbackState == "stopped" {
                record.playbackState = "paused"
            }
        case .previous:
            let previous = record.currentIndex - 1
            if record.sources.indices.contains(previous) {
                switchItem(to: record.sources[previous].id, record: record)
            }
        case .next:
            let next = record.currentIndex + 1
            if record.sources.indices.contains(next) {
                switchItem(to: record.sources[next].id, record: record)
            }
        case .activate(let itemID):
            switchItem(to: itemID, record: record)
        case .move(let orderedIDs):
            try reorderSources(using: orderedIDs, record: record)
        case .refresh:
            break
        case .selectDevice(let selectedID):
            try selectDevice(selectedID, for: record, session: &session)
        }
        updatePlaybackState(for: record, session: &session)
        updateQueueState(for: record, session: &session)
    }

    func shutdown() {
        lock.lock()
        let records = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for record in records { record.stopEnginesQuietly() }
    }

    func stopForExternalPCM(deviceUID: String) throws {
        try stopPlayback(on: deviceUID)
    }

    private func stopPlayback(on deviceUID: String) throws {
        lock.lock()
        let records = sessions.values.filter { $0.isActive && $0.selectedDeviceID == deviceUID }
        lock.unlock()
        for record in records {
            let status = try record.stopEngines()
            synchronizeItem(for: record, status: status)
            record.isActive = false
            record.samplePosition = status.samplePosition
            record.underrunCount = status.underrunCount
            record.playbackState = "paused"
            record.failureDescription = status.failureDescription
        }
    }

    /// 设备插拔后立刻刷新会话内的设备列表；当前独占设备离线时暂停并回退到兼容的系统默认设备，
    /// 若没有任何可支持当前 DSD/PCM 速率的设备则置为失败，宿主据此给出警告且无法播放。
    private func refreshDeviceSelection(for record: RuntimeSession, session: inout [String: Any]) {
        guard let freshDevices = try? CoreAudioDeviceCatalog.outputDevices() else { return }
        guard var selection = session["audioDeviceSelection"] as? [String: Any] else { return }
        let sampleRate = record.sampleRate
        let isAPE = record.isAPE
        let compatible = freshDevices.filter {
            $0.isConnected && isDeviceCompatible($0, sampleRate: sampleRate, isAPE: isAPE)
        }
        let deviceObjects: [[String: Any]] = freshDevices.map { device in
            [
                "id": device.id,
                "displayName": device.displayName,
                "isSystemDefault": device.isSystemDefault,
                "isConnected": device.isConnected,
                "isCompatible": compatible.contains { $0.id == device.id },
                "hasHardwareVolume": device.hasHardwareVolume,
                "supportedDoPRates": device.potentialDoPDSDRates,
                "supportedPCMSampleRates": device.supportedPCMSampleRates
            ]
        }
        let currentID = record.selectedDeviceID
        let currentStillUsable = currentID.flatMap { id in
            freshDevices.first(where: { $0.id == id })
        }.map { $0.isConnected && isDeviceCompatible($0, sampleRate: sampleRate, isAPE: isAPE) } ?? false

        if !currentStillUsable {
            lock.lock()
            let wasPlaying = record.isActive
            lock.unlock()
            if wasPlaying {
                if let status = try? record.stopEngines() {
                    synchronizeItem(for: record, status: status)
                    record.samplePosition = status.samplePosition
                    record.underrunCount = status.underrunCount
                }
                lock.lock()
                record.isActive = false
                lock.unlock()
            }
            if let fallback = compatible.first(where: \.isSystemDefault) ?? compatible.first {
                record.selectedDeviceID = fallback.id
                // 离线后切换为跟随系统默认兼容设备时必须暂停，由用户决定是否继续播放。
                record.playbackState = "paused"
                record.failureDescription = nil
            } else {
                record.selectedDeviceID = nil
                // 没有任何可支持设备时给出明确失败，宿主显示警告且播放命令会被禁用。
                if wasPlaying || record.playbackState == "playing" || currentID != nil {
                    record.playbackState = "failed"
                    record.failureDescription = isAPE
                        ? HiFiPlaybackError.unsupportedPCMRate.localizationKey
                        : HiFiPlaybackError.unsupportedDoPRate.localizationKey
                }
            }
        }

        selection["devices"] = deviceObjects
        if let selectedID = record.selectedDeviceID,
           freshDevices.contains(where: { $0.id == selectedID }) {
            selection["selectedDeviceID"] = selectedID
            selection["statusDescription"] = freshDevices.first(where: { $0.id == selectedID })?.displayName ?? selectedID
        } else {
            selection.removeValue(forKey: "selectedDeviceID")
            // 无可用设备时不虚构状态描述，宿主靠 mediaPlayback.failed 显示本地化警告。
            selection.removeValue(forKey: "statusDescription")
        }
        selection["revision"] = ((selection["revision"] as? NSNumber)?.uint64Value ?? 0) + 1
        session["audioDeviceSelection"] = selection
    }

    private func selectDevice(
        _ selectedID: String,
        for record: RuntimeSession,
        session: inout [String: Any]
    ) throws {
        guard var selection = session["audioDeviceSelection"] as? [String: Any] else {
            throw RuntimeControllerError.invalidSession
        }
        let devices = selection["devices"] as? [[String: Any]] ?? []
        guard let device = devices.first(where: { $0["id"] as? String == selectedID }) else {
            throw RuntimeControllerError.noOutputDevice
        }
        if record.isAPE {
            let pcmRates = (device["supportedPCMSampleRates"] as? [NSNumber])?.map(\.doubleValue) ?? []
            guard pcmRates.contains(Double(record.sampleRate)) else {
                throw RuntimeControllerError.noOutputDevice
            }
        } else {
            let supportedRates = (device["supportedDoPRates"] as? [NSNumber])?.map(\.intValue) ?? []
            guard supportedRates.contains(record.sampleRate) else {
                throw RuntimeControllerError.noOutputDevice
            }
        }

        lock.lock()
        let wasPlaying = record.isActive
        lock.unlock()
        if wasPlaying {
            let status = try record.stopEngines()
            synchronizeItem(for: record, status: status)
            record.samplePosition = status.samplePosition
            record.underrunCount = status.underrunCount
            record.playbackState = "paused"
            record.failureDescription = status.failureDescription
            lock.lock()
            record.isActive = false
            lock.unlock()
        }
        record.selectedDeviceID = selectedID
        selection["selectedDeviceID"] = selectedID
        selection["statusDescription"] = device["displayName"] as? String ?? selectedID
        selection["revision"] = ((selection["revision"] as? NSNumber)?.uint64Value ?? 0) + 1
        if wasPlaying {
            do {
                audioDeviceServiceController.releasePCMForExclusive(deviceUID: selectedID)
                try stopTrackedPlayback(beforeStarting: record)
                try record.playCurrent(deviceUID: selectedID, startingSample: record.samplePosition)
                record.playbackState = "playing"
                record.failureDescription = nil
                lock.lock()
                record.isActive = true
                lock.unlock()
            } catch {
                record.playbackState = "failed"
                record.failureDescription = failureKey(error)
            }
        }
        session["audioDeviceSelection"] = selection
    }

    /// 只交接同一设备，其他 DAC 上的会话可继续播放。
    private func stopTrackedPlayback(beforeStarting record: RuntimeSession) throws {
        if let uid = record.selectedDeviceID { try stopPlayback(on: uid) }
    }

    private func close(_ record: RuntimeSession) throws {
        lock.lock()
        let wasPlaying = record.isActive
        lock.unlock()
        // 释放失败不能报告关闭成功，也不能先删除记录导致无法重试。
        if wasPlaying { _ = try record.stopEngines() }
        lock.lock()
        record.isActive = false
        sessions.removeValue(forKey: record.id)
        lock.unlock()
    }

    private func switchItem(to targetID: String, record: RuntimeSession, allowsAutomaticPlayback: Bool = true) {
        guard let index = record.sources.firstIndex(where: { $0.id == targetID }), index != record.currentIndex else { return }
        lock.lock()
        let wasPlaying = record.isActive
        if wasPlaying { record.isActive = false }
        lock.unlock()
        if wasPlaying { record.stopEnginesQuietly() }
        // 宿主列表切歌时，自然播完已经清除会话的 isActive 标记；若上一曲已到结尾，仍应接着播。
        let reachedEnd = record.sampleCount > 0 && record.samplePosition + 16 >= record.sampleCount
        let completedNaturally = record.playbackState == "stopped"
            || (record.playbackState == "paused" && reachedEnd)
        let shouldPlay = allowsAutomaticPlayback && (wasPlaying || completedNaturally)
        record.currentIndex = index
        record.queueRevision &+= 1
        record.samplePosition = 0
        record.underrunCount = 0
        record.failureDescription = nil
        record.playbackState = "paused"
        if shouldPlay, let deviceUID = record.selectedDeviceID {
            do {
                audioDeviceServiceController.releasePCMForExclusive(deviceUID: deviceUID)
                try stopTrackedPlayback(beforeStarting: record)
                try record.playCurrent(deviceUID: deviceUID, startingSample: 0)
                record.playbackState = "playing"
                lock.lock(); record.isActive = true; lock.unlock()
            } catch {
                record.playbackState = "failed"
                record.failureDescription = failureKey(error)
            }
        }
    }

    private func reorderSources(using orderedIDs: [String], record: RuntimeSession) throws {
        guard orderedIDs.count == record.sources.count,
              Set(orderedIDs).count == orderedIDs.count else {
            throw RuntimeControllerError.invalidQueueOrder
        }
        let sourcesByID = Dictionary(uniqueKeysWithValues: record.sources.map { ($0.id, $0) })
        guard orderedIDs.allSatisfy({ sourcesByID[$0] != nil }) else {
            throw RuntimeControllerError.invalidQueueOrder
        }
        let currentID = record.sources[record.currentIndex].id
        let reordered = orderedIDs.compactMap { sourcesByID[$0] }
        guard reordered.map(\.id) != record.sources.map(\.id),
              let currentIndex = reordered.firstIndex(where: { $0.id == currentID }) else { return }
        let wasPlaying = record.isActive
        if wasPlaying {
            let status = try record.stopEngines()
            synchronizeItem(for: record, status: status)
            record.samplePosition = status.samplePosition
            record.isActive = false
        }
        let audibleID = record.sources[record.currentIndex].id
        record.sources = reordered
        record.sequenceIDs = reordered.map(\.id)
        record.currentIndex = reordered.firstIndex(where: { $0.id == audibleID }) ?? currentIndex
        record.queueRevision &+= 1
        if wasPlaying, let deviceUID = record.selectedDeviceID {
            do {
                try record.playCurrent(deviceUID: deviceUID, startingSample: record.samplePosition)
                record.isActive = true
            } catch {
                record.playbackState = "failed"
                record.failureDescription = failureKey(error)
            }
        }
    }

    private func updateQueueState(for record: RuntimeSession, session: inout [String: Any]) {
        guard record.sources.count > 1 else { return }
        let currentID = record.sources[record.currentIndex].id
        session["playbackQueue"] = queueObject(
            sources: record.sources,
            currentID: currentID,
            revision: record.queueRevision
        )
        session["navigatorContributions"] = [navigatorObject(
            sources: record.sources,
            currentID: currentID,
            revision: record.queueRevision
        )]
        if var presentation = session["presentation"] as? [String: Any] {
            presentation["body"] = record.url.lastPathComponent
            session["presentation"] = presentation
        }
    }

    private func synchronizeItem(for record: RuntimeSession, status: EngineStatus) {
        guard record.isActive, let itemID = status.currentItemID,
              let index = record.sources.firstIndex(where: { $0.id == itemID }),
              index != record.currentIndex else { return }
        record.currentIndex = index
        record.queueRevision &+= 1
        record.samplePosition = status.samplePosition
    }

    private func updatePlaybackState(for record: RuntimeSession, session: inout [String: Any]) {
        var status = record.engineStatus()
        synchronizeItem(for: record, status: status)
        lock.lock()
        let isContainer = record.isSACDContainer || record.isCUEContainer
        let currentSuccessors = record.isAPE ? record.apeSuccessors.map(\.id) : record.successors.map(\.id)
        let shouldAdvance = record.isActive
            && status.state == .stopped
            && status.samplePosition >= record.sampleCount
            && !currentSuccessors.isEmpty
            && !isContainer
        lock.unlock()
        if shouldAdvance {
            synchronizeItem(for: record, status: status)
            record.samplePosition = status.samplePosition
            switchItem(to: currentSuccessors[0], record: record)
            status = record.engineStatus()
        }
        lock.lock()
        let wasTracked = record.isActive
        if wasTracked {
            synchronizeItem(for: record, status: status)
            record.samplePosition = status.samplePosition
            record.underrunCount = status.underrunCount
        }
        if wasTracked, status.state != .playing {
            record.isActive = false
            if status.state == .failed {
                record.playbackState = "failed"
                record.failureDescription = status.failureDescription
            } else if record.sampleCount > 0, status.samplePosition >= record.sampleCount {
                record.playbackState = "stopped"
                record.failureDescription = status.failureDescription
            } else {
                // 睡眠或设备恢复导致的中途停止保持暂停，避免被当成播完切歌。
                record.playbackState = "paused"
                record.failureDescription = nil
            }
        }
        let isPlaying = record.isActive && status.state == .playing
        lock.unlock()
        var reconnectedDevice: HiFiAudioOutputDevice?
        if record.playbackState == "failed",
           record.failureDescription == HiFiPlaybackError.deviceDisconnected.localizationKey,
           let selectedDeviceID = record.selectedDeviceID {
            reconnectedDevice = try? CoreAudioDeviceCatalog.outputDevices().first {
                $0.id == selectedDeviceID && $0.isConnected
            }
            if reconnectedDevice != nil {
                record.playbackState = "paused"
                record.failureDescription = nil
            }
        }
        let position = TimeInterval(record.samplePosition) / TimeInterval(record.sampleRate)
        // 权威可用性只由公共快照表达；宿主不再读取旧 command 的 isEnabled。
        let devices = (session["audioDeviceSelection"] as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        var availableActions = ["refresh", "seek"]
        if devices.contains(where: { ($0["isConnected"] as? Bool) != false }) {
            availableActions.append("selectDevice")
        }
        availableActions.append(isPlaying ? "pause" : "play")
        if record.sources.count > 1 { availableActions.append(contentsOf: ["previous", "next"]) }
        if var playback = session["mediaPlayback"] as? [String: Any] {
            playback["state"] = record.playbackState
            playback["position"] = position
            playback["duration"] = TimeInterval(record.sampleCount) / TimeInterval(record.sampleRate)
            playback["isSeekable"] = true
            playback["underrunCount"] = record.underrunCount
            playback["failureMessage"] = record.failureDescription
            playback["availableActions"] = availableActions
            session["mediaPlayback"] = playback
        }
        if var selection = session["audioDeviceSelection"] as? [String: Any] {
            selection["activeTransport"] = isPlaying ? (record.isAPE ? "pcm" : "dop") : nil
            if isPlaying, let deviceID = record.selectedDeviceID,
               let devices = selection["devices"] as? [[String: Any]],
               let device = devices.first(where: { $0["id"] as? String == deviceID }) {
                let deviceName = device["displayName"] as? String ?? deviceID
                if record.isAPE, let ape = record.sources[record.currentIndex].apeDescriptor {
                    selection["statusDescription"] = pcmStatusDescription(
                        sampleRate: ape.sampleRate,
                        bitsPerSample: ape.bitsPerSample,
                        channelCount: ape.channelCount,
                        deviceName: deviceName
                    )
                } else {
                    selection["statusDescription"] = dopStatusDescription(
                        sampleRate: record.sampleRate,
                        sourceChannels: record.sources[record.currentIndex].channelCount,
                        outputChannels: Int(status.outputChannelCount),
                        deviceName: deviceName
                    )
                }
            } else if let reconnectedDevice {
                selection["statusDescription"] = reconnectedDevice.displayName
            }
            session["audioDeviceSelection"] = selection
        }
    }
}

private final class RuntimeSession {
    let id: UUID
    var sources: [RuntimeSource]
    var currentIndex = 0
    var queueRevision: UInt64 = 0
    var url: URL { sources[currentIndex].url }
    var sampleRate: Int { sources[currentIndex].sampleRate }
    var sampleCount: UInt64 { sources[currentIndex].sampleCount }
    var isAPE: Bool { sources[currentIndex].isAPE }
    var sacdTrackNumber: Int? { sources[currentIndex].sacdTrackNumber }
    var apeStartBlock: UInt64 { sources[currentIndex].apeStartBlock }
    var apeEndBlock: UInt64? { sources[currentIndex].apeEndBlock }
    var sequenceIDs: [String]?
    var successors: [DSDPlaybackItem] {
        orderedSuccessors().compactMap { source in
            guard let descriptor = source.dsdDescriptor else { return nil }
            return DSDPlaybackItem(
                id: source.id,
                url: source.url,
                descriptor: descriptor,
                sacdTrackNumber: source.sacdTrackNumber
            )
        }
    }
    var apeSuccessors: [APEPlaybackItem] {
        orderedSuccessors().compactMap { source in
            guard let descriptor = source.apeDescriptor else { return nil }
            return APEPlaybackItem(
                id: source.id,
                url: source.url,
                descriptor: descriptor,
                startBlock: source.apeStartBlock,
                endBlock: source.apeEndBlock
            )
        }
    }
    var isSACDContainer: Bool { sources.contains { $0.sacdTrackNumber != nil } }
    var isCUEContainer: Bool { sources.contains { $0.cueTrackNumber != nil } }
    let player = HALDSFPlaybackEngine()
    let pcmPlayer = HALPCMPlaybackEngine()
    var isActive = false
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

    private func orderedSuccessors() -> [RuntimeSource] {
        let orderedIDs = sequenceIDs ?? sources.map(\.id)
        guard let index = orderedIDs.firstIndex(of: sources[currentIndex].id) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        return orderedIDs.dropFirst(index + 1).compactMap { byID[$0] }
    }

    /// 按当前曲目格式起播；DSD 走 DoP，APE 走 PCM 独占。
    func playCurrent(deviceUID: String, startingSample: UInt64) throws {
        if isAPE {
            try pcmPlayer.play(
                fileAt: url,
                deviceUID: deviceUID,
                startBlock: apeStartBlock,
                endBlock: apeEndBlock,
                startingSample: startingSample,
                itemID: sources[currentIndex].id,
                successors: apeSuccessors
            )
        } else {
            try player.play(
                fileAt: url,
                deviceUID: deviceUID,
                startingSample: startingSample,
                sacdTrackNumber: sacdTrackNumber,
                itemID: sources[currentIndex].id,
                successors: successors
            )
        }
    }

    func engineStatus() -> EngineStatus {
        isAPE ? EngineStatus(pcmPlayer.status()) : EngineStatus(player.status())
    }

    /// 停止双引擎；只传播当前格式引擎的错误（另一引擎 idle 时停止无副作用）。
    func stopEngines() throws -> EngineStatus {
        if isAPE {
            _ = try? player.stop()
            return EngineStatus(try pcmPlayer.stop())
        } else {
            _ = try? pcmPlayer.stop()
            return EngineStatus(try player.stop())
        }
    }

    func stopEnginesQuietly() {
        _ = try? player.stop()
        _ = try? pcmPlayer.stop()
    }
}

/// DSD/PCM 双引擎的统一状态快照；字段口径与两引擎一致。
private struct EngineStatus: Equatable {
    enum State: Equatable {
        case idle
        case playing
        case stopped
        case failed
    }

    let state: State
    let samplePosition: UInt64
    let sampleCount: UInt64
    let underrunCount: UInt64
    let outputChannelCount: Int
    let failureDescription: String?
    let currentItemID: String?

    init(_ status: HALDSFPlaybackStatus) {
        switch status.state {
        case .idle: state = .idle
        case .playing: state = .playing
        case .stopped: state = .stopped
        case .failed: state = .failed
        }
        samplePosition = status.samplePosition
        sampleCount = status.sampleCount
        underrunCount = status.underrunCount
        outputChannelCount = status.outputChannelCount
        failureDescription = status.failureDescription
        currentItemID = status.currentItemID
    }

    init(_ status: HALPCMPlaybackStatus) {
        switch status.state {
        case .idle: state = .idle
        case .playing: state = .playing
        case .stopped: state = .stopped
        case .failed: state = .failed
        }
        samplePosition = status.samplePosition
        sampleCount = status.sampleCount
        underrunCount = status.underrunCount
        outputChannelCount = status.outputChannelCount
        failureDescription = status.failureDescription
        currentItemID = status.currentItemID
    }
}

private final class RuntimeSource {
    let id: String
    let access: RuntimeResourceAccess
    let dsdDescriptor: DSDContainerDescriptor?
    let apeDescriptor: APEAudioDescriptor?
    let apeStartBlock: UInt64
    let apeEndBlock: UInt64?
    let title: String?
    let artist: String?
    let album: String?
    let sacdTrackNumber: Int?
    let cueTrackNumber: Int?
    var url: URL { access.url }
    var isAPE: Bool { apeDescriptor != nil }
    var sampleRate: Int {
        dsdDescriptor?.sampleRate ?? apeDescriptor?.sampleRate ?? 0
    }
    var sampleCount: UInt64 {
        if let sampleCount = dsdDescriptor?.sampleCount { return sampleCount }
        guard let ape = apeDescriptor else { return 0 }
        let end = min(apeEndBlock ?? ape.totalBlocks, ape.totalBlocks)
        let start = min(apeStartBlock, end)
        return end - start
    }
    var channelCount: Int {
        dsdDescriptor?.channelCount ?? apeDescriptor?.channelCount ?? 0
    }
    var duration: TimeInterval? {
        if let dsdDescriptor { return dsdDescriptor.duration }
        guard let ape = apeDescriptor, ape.sampleRate > 0 else { return nil }
        return TimeInterval(sampleCount) / TimeInterval(ape.sampleRate)
    }
    var formatSummary: String {
        if let dsdDescriptor {
            let compression = dsdDescriptor.compression == .dst ? "DST" : "DSD"
            return "\(dsdDescriptor.kind.rawValue.uppercased()) · \(compression)"
        }
        if let ape = apeDescriptor {
            return "APE · \(ape.compressionName)"
        }
        return "Audio"
    }
    var displayTitle: String {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty { return value }
        if let sacdTrackNumber { return "Track \(sacdTrackNumber)" }
        if let cueTrackNumber { return "Track \(cueTrackNumber)" }
        return url.deletingPathExtension().lastPathComponent
    }

    init(
        id: String,
        access: RuntimeResourceAccess,
        descriptor: DSDContainerDescriptor,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        sacdTrackNumber: Int? = nil
    ) {
        self.id = id
        self.access = access
        self.dsdDescriptor = descriptor
        self.apeDescriptor = nil
        self.apeStartBlock = 0
        self.apeEndBlock = nil
        self.title = title
        self.artist = artist
        self.album = album
        self.sacdTrackNumber = sacdTrackNumber
        self.cueTrackNumber = nil
    }

    init(
        id: String,
        access: RuntimeResourceAccess,
        apeDescriptor: APEAudioDescriptor,
        apeStartBlock: UInt64 = 0,
        apeEndBlock: UInt64? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        cueTrackNumber: Int? = nil
    ) {
        self.id = id
        self.access = access
        self.dsdDescriptor = nil
        self.apeDescriptor = apeDescriptor
        self.apeStartBlock = apeStartBlock
        self.apeEndBlock = apeEndBlock
        self.title = title
        self.artist = artist
        self.album = album
        self.sacdTrackNumber = nil
        self.cueTrackNumber = cueTrackNumber
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

private final class AudioDeviceServiceController: @unchecked Sendable {
    private let preferenceKey = "app.foofoil.extension.hifi.preferred-pcm-device-uid"
    private var leases: [String: (clientID: UUID, lease: PCMExclusiveDeviceLease)] = [:]
    private var revision: UInt64 = 0
    private var cachedDevices: [HiFiAudioOutputDevice]?

    func perform(_ message: [String: Any], stopDSDPlayback: (String) throws -> Void) throws -> [String: Any] {
        guard let command = message["command"] as? String,
              let clientText = message["clientID"] as? String,
              let clientID = UUID(uuidString: clientText) else { throw RuntimeControllerError.invalidSession }
        switch command {
        case "snapshot": break
        case "selectSystemDefault":
            releasePCM(clientID: clientID)
            UserDefaults.standard.removeObject(forKey: preferenceKey)
            revision &+= 1
        case "prepareExclusivePCM":
            guard let uid = message["selectedDeviceID"] as? String,
                  let rate = (message["sourceSampleRate"] as? NSNumber)?.doubleValue,
                  let channels = (message["channelCount"] as? NSNumber)?.intValue else {
                throw RuntimeControllerError.invalidSession
            }
            try stopDSDPlayback(uid)
            if let current = leases[uid],
               current.clientID == clientID,
               current.lease.sourceSampleRate == rate,
               current.lease.channelCount == channels {
                // 租约仍在手（自然播完连播）：直接复用，不碰 hog 与 DAC 格式。
                _ = try current.lease.refreshStatus()
            } else {
                releasePCM(clientID: clientID)
                releasePCM(deviceUID: uid)
                let lease = try PCMExclusiveDeviceLease(deviceUID: uid, sourceSampleRate: rate, channelCount: channels)
                leases[uid] = (clientID, lease)
                UserDefaults.standard.set(uid, forKey: preferenceKey)
                revision &+= 1
            }
        case "releasePCM": releasePCM(clientID: clientID)
        case "releaseAllPCM": shutdown()
        default: throw RuntimeControllerError.invalidSession
        }
        return try snapshot(clientID: clientID, refreshDevices: command == "snapshot")
    }

    /// DSD/APE 独占起播前释放宿主 PCM 租约；同一设备的宿主输出由 stopPlayback 交接。
    func releasePCMForExclusive(deviceUID: String?) {
        if let deviceUID { releasePCM(deviceUID: deviceUID) }
    }

    func shutdown() {
        for uid in Array(leases.keys) { releasePCM(deviceUID: uid) }
    }

    private func releasePCM(clientID: UUID) {
        for uid in leases.keys.filter({ leases[$0]?.clientID == clientID }) { releasePCM(deviceUID: uid) }
    }

    private func releasePCM(deviceUID: String) {
        guard let old = leases.removeValue(forKey: deviceUID) else { return }
        try? old.lease.restore()
        revision &+= 1
    }

    private func snapshot(clientID: UUID, refreshDevices: Bool) throws -> [String: Any] {
        let devices: [HiFiAudioOutputDevice]
        if refreshDevices || cachedDevices == nil {
            devices = try CoreAudioDeviceCatalog.outputDevices()
            cachedDevices = devices
        } else { devices = cachedDevices ?? [] }
        for uid in Array(leases.keys) where !devices.contains(where: { $0.id == uid && $0.isConnected }) {
            releasePCM(deviceUID: uid)
        }
        var preferredUID = UserDefaults.standard.string(forKey: preferenceKey)
        if let uid = preferredUID, !devices.contains(where: { $0.id == uid && $0.isConnected }) {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
            preferredUID = nil
            revision &+= 1
        }
        let owned = leases.values.first(where: { $0.clientID == clientID })
        let activeStatus = try? owned?.lease.refreshStatus()
        let deviceObjects: [[String: Any]] = devices.map {
            [
                "id": $0.id,
                "displayName": $0.displayName,
                "isSystemDefault": $0.isSystemDefault,
                "isConnected": $0.isConnected,
                "hasHardwareVolume": $0.hasHardwareVolume,
                "supportedDoPRates": $0.potentialDoPDSDRates,
                "supportsExclusiveMode": $0.supportsExclusiveMode,
                "supportedPCMSampleRates": $0.supportedPCMSampleRates
            ]
        }
        var result: [String: Any] = [
            "contractVersion": 1, "devices": deviceObjects,
            "pcmRouteMode": preferredUID == nil ? "systemDefault" : "exclusiveDevice",
            "revision": revision
        ]
        if let preferredUID { result["selectedPCMDeviceID"] = preferredUID }
        if let activeStatus {
            result["activeClientID"] = clientID.uuidString
            result["activeDeviceID"] = activeStatus.deviceUID
            result["activeSampleRate"] = activeStatus.activeSampleRate
            result["sourceSampleRate"] = activeStatus.sourceSampleRate
            result["sampleRateMatched"] = activeStatus.sampleRateMatched
            result["statusDescription"] = devices.first(where: { $0.id == activeStatus.deviceUID })?.displayName
        }
        return result
    }
}

private enum RuntimeControllerError: Error {
    case invalidSession
    case noOutputDevice
    case invalidPlaybackPosition
    case invalidQueueOrder
    case invalidSource
}

private func dopStatusDescription(
    sampleRate: Int,
    sourceChannels: Int,
    outputChannels: Int,
    deviceName: String
) -> String {
    let dsd = "DSD\(sampleRate / 44_100)"
    let route: String
    if sourceChannels > 2, outputChannels == 2 {
        route = "\(sourceChannels)ch→Stereo · DoP"
    } else if sourceChannels == 5, outputChannels == 6 {
        route = "5.0→5.1 · DoP"
    } else if sourceChannels == 5, outputChannels == 8 {
        route = "5.0→7.1 · DoP"
    } else if sourceChannels > 2 {
        route = "\(sourceChannels)ch · DoP"
    } else {
        route = "DoP"
    }
    return "\(dsd) · \(route) · \(deviceName)"
}

private func isDeviceCompatible(_ device: HiFiAudioOutputDevice, source: RuntimeSource) -> Bool {
    if source.isAPE {
        return device.supportedPCMSampleRates.contains(Double(source.sampleRate))
    }
    return device.potentialDoPDSDRates.contains(source.sampleRate)
}

private func isDeviceCompatible(_ device: HiFiAudioOutputDevice, sampleRate: Int, isAPE: Bool) -> Bool {
    if isAPE {
        return device.supportedPCMSampleRates.contains(Double(sampleRate))
    }
    return device.potentialDoPDSDRates.contains(sampleRate)
}

private func pcmStatusDescription(
    sampleRate: Int,
    bitsPerSample: Int,
    channelCount: Int,
    deviceName: String
) -> String {
    let rate: String
    if sampleRate % 1000 == 0 {
        rate = "\(sampleRate / 1000) kHz"
    } else {
        rate = String(format: "%.1f kHz", Double(sampleRate) / 1000)
    }
    return "\(rate) · \(bitsPerSample)-bit · \(channelCount)ch PCM · \(deviceName)"
}

private func failureKey(_ error: Error) -> String {
    if let error = error as? RuntimeControllerError {
        switch error {
        case .noOutputDevice, .invalidSession, .invalidPlaybackPosition, .invalidQueueOrder:
            return HiFiPlaybackError.outputInitializationFailure.localizationKey
        case .invalidSource:
            return HiFiPlaybackError.unsupportedSource.localizationKey
        }
    }
    return HiFiPlaybackError.from(error).localizationKey
}
