//
//  APECueSheet.swift
//  HiFiExtensionCore
//
//  Created by 董超 on 2026/9/12.
//

import Foundation

/// CUE 分轨：`MM:SS:FF` 按 75 fps 换算为 APE 块；切分口径与宿主 CueSheet 保持一致。
public struct APECueTrack: Equatable, Sendable {
    public let number: Int
    public let title: String?
    public let performer: String?
    public let startBlock: UInt64
    /// nil 表示到文件末尾。
    public let endBlock: UInt64?

    public init(number: Int, title: String?, performer: String?, startBlock: UInt64, endBlock: UInt64?) {
        self.number = number
        self.title = title
        self.performer = performer
        self.startBlock = startBlock
        self.endBlock = endBlock
    }
}

public struct APECueSheet: Equatable, Sendable {
    public let url: URL
    public let title: String?
    public let performer: String?
    public let audioFileName: String
    public let audioURL: URL?
    public let tracks: [APECueTrack]

    public var displayTitle: String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return url.deletingPathExtension().lastPathComponent
    }
}

public enum APECueSheetError: Error, Equatable, Sendable {
    case unreadable
    case notAPECue
}

public enum APECueSheetParser {
    public static let frameRate: Int64 = 75

    /// 读取并解析；非单 APE 文件的 CUE 返回 nil，调用方让出给其他 provider。
    public static func load(cueAt url: URL, sampleRate: Int) throws -> APECueSheet? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw APECueSheetError.unreadable
        }
        guard let text = decodeText(data) else { throw APECueSheetError.unreadable }
        return parse(text: text, cueURL: url, sampleRate: sampleRate)
    }

    public static func parse(text: String, cueURL: URL, sampleRate: Int) -> APECueSheet? {
        guard sampleRate > 0 else { return nil }
        var albumTitle: String?
        var albumPerformer: String?
        var currentFileName = ""
        var rawTracks: [RawTrack] = []
        var current: RawTrack?

        func flush() {
            if let current { rawTracks.append(current) }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let parsed = parseLine(line) else { continue }
            switch parsed.command {
            case "TITLE":
                let value = parsed.arguments.joined(separator: " ")
                guard !value.isEmpty else { continue }
                if current != nil {
                    current?.title = value
                } else {
                    albumTitle = value
                }
            case "PERFORMER":
                let value = parsed.arguments.joined(separator: " ")
                guard !value.isEmpty else { continue }
                if current != nil {
                    current?.performer = value
                } else {
                    albumPerformer = value
                }
            case "FILE":
                if let name = parsed.arguments.first, !name.isEmpty {
                    currentFileName = name
                }
            case "TRACK":
                flush()
                let number = parsed.arguments.first.flatMap(Int.init) ?? (rawTracks.count + 1)
                let type = parsed.arguments.dropFirst().first?.uppercased() ?? "AUDIO"
                current = RawTrack(number: number, type: type, fileName: currentFileName)
                if current?.fileName.isEmpty == true {
                    current?.fileName = currentFileName
                }
            case "INDEX":
                guard var track = current,
                      let indexNumber = parsed.arguments.first.flatMap(Int.init),
                      let timeText = parsed.arguments.dropFirst().first,
                      let cueFrames = parseTime(timeText) else { continue }
                if indexNumber == 1 {
                    track.index01 = cueFrames
                } else if indexNumber == 0, track.index01 == nil {
                    track.index00 = cueFrames
                }
                current = track
            default:
                break
            }
        }
        flush()

        let audioTracks = rawTracks.filter { $0.type.isEmpty || $0.type == "AUDIO" }
        guard !audioTracks.isEmpty else { return nil }
        // 只接管单 APE 文件的整轨 CUE；多文件或非 APE 交给宿主/其他 provider。
        let fileNames = Set(audioTracks.map(\.fileName))
        guard fileNames.count == 1, let fileName = fileNames.first,
              (fileName as NSString).pathExtension.lowercased() == "ape" else {
            return nil
        }
        let audioURL = resolveAudioURL(named: fileName, cueURL: cueURL)
        var tracks: [APECueTrack] = []
        for (index, raw) in audioTracks.enumerated() {
            let start = raw.index01 ?? raw.index00 ?? 0
            var end: Int64?
            if index + 1 < audioTracks.count {
                let next = audioTracks[index + 1].index01 ?? audioTracks[index + 1].index00 ?? start
                end = next > start ? next : nil
            }
            tracks.append(APECueTrack(
                number: raw.number,
                title: raw.title,
                performer: raw.performer ?? albumPerformer,
                startBlock: cueFramesToBlocks(start, sampleRate: sampleRate),
                endBlock: end.map { cueFramesToBlocks($0, sampleRate: sampleRate) }
            ))
        }
        return APECueSheet(
            url: cueURL,
            title: albumTitle,
            performer: albumPerformer,
            audioFileName: fileName,
            audioURL: audioURL,
            tracks: tracks
        )
    }

    /// CUE 帧 → APE 块；44.1/48 kHz 等可整除采样率是整数精确换算。
    public static func cueFramesToBlocks(_ cueFrames: Int64, sampleRate: Int) -> UInt64 {
        let rate = Int64(sampleRate)
        guard rate > 0, cueFrames > 0 else { return 0 }
        if rate % frameRate == 0 {
            return UInt64(cueFrames * (rate / frameRate))
        }
        return UInt64((cueFrames * rate + frameRate / 2) / frameRate)
    }

    public static func parseTime(_ text: String) -> Int64? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0,
              let seconds = Int(parts[1]), seconds >= 0,
              let frames = Int(parts[2]), frames >= 0 else {
            return nil
        }
        return Int64((minutes * 60 + seconds) * 75 + frames)
    }

    public static func parseLine(_ line: String) -> (command: String, arguments: [String])? {
        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        func flush() {
            if !current.isEmpty {
                arguments.append(current)
                current = ""
            }
        }

        while index < line.endIndex {
            let character = line[index]
            let nextIndex = line.index(after: index)
            if character == "\"" {
                if inQuotes {
                    if nextIndex < line.endIndex, line[nextIndex] == "\"" {
                        current.append("\"")
                        index = line.index(after: nextIndex)
                        continue
                    }
                    inQuotes = false
                } else {
                    inQuotes = true
                }
                index = nextIndex
                continue
            }
            if character.isWhitespace, !inQuotes {
                flush()
                index = nextIndex
                continue
            }
            current.append(character)
            index = nextIndex
        }
        flush()
        guard let command = arguments.first, !command.isEmpty else { return nil }
        return (command.uppercased(), Array(arguments.dropFirst()))
    }

    /// 同目录解析 CUE 引用的 APE；找不到时返回 nil，由调用方按 fileCollection 配对或报错。
    public static func resolveAudioURL(named fileName: String, cueURL: URL) -> URL? {
        let directory = cueURL.deletingLastPathComponent()
        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        let asPath = URL(fileURLWithPath: normalized)
        var candidates: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { candidates.append(url) }
        }
        if normalized.hasPrefix("/") {
            append(asPath)
        } else if normalized.contains("/") {
            append(directory.appendingPathComponent(normalized))
        }
        append(directory.appendingPathComponent(asPath.lastPathComponent))
        let stem = (asPath.lastPathComponent as NSString).deletingPathExtension
        if !stem.isEmpty {
            append(directory.appendingPathComponent("\(stem).ape"))
        }
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static var fallbackEncodings: [String.Encoding] {
        [
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )),
            .shiftJIS,
            .windowsCP1252,
            .isoLatin1
        ]
    }

    struct RawTrack {
        var number: Int
        var type: String
        var title: String?
        var performer: String?
        var fileName: String
        var index00: Int64?
        var index01: Int64?
    }
}
