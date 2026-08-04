import Foundation
import Combine
import UIKit

enum TaskStatus: String, Codable, CaseIterable {
    case queued = "QUEUED"
    case downloading = "DOWNLOADING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case waitingForUser = "WAITING_FOR_USER"

    var localizationKey: String {
        switch self {
        case .queued: return "status.queued"
        case .downloading: return "status.downloading"
        case .completed: return "status.completed"
        case .failed: return "status.failed"
        case .waitingForUser: return "status.waiting"
        }
    }
}

enum NoteType: String, Codable {
    case image
    case video
    case livePhoto
    case mixed
    case unknown

    var localizationKey: String {
        switch self {
        case .image: return "note.type.image"
        case .video: return "note.type.video"
        case .livePhoto: return "note.type.live_photo"
        case .mixed: return "note.type.mixed"
        case .unknown: return "note.type.unknown"
        }
    }
}

struct MediaAssetRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var localIdentifier: String
    var fileName: String
    var isVideo: Bool
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int64?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        localIdentifier: String,
        fileName: String,
        isVideo: Bool,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        byteCount: Int64? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.fileName = fileName
        self.isVideo = isVideo
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

struct DownloadTaskRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var sourceText: String
    var normalizedURL: String
    var title: String
    var noteText: String
    var noteType: NoteType
    var status: TaskStatus
    var progress: Double
    var mediaCount: Int
    var savedCount: Int
    var failedCount: Int
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var mediaAssets: [MediaAssetRecord]

    init(
        id: UUID = UUID(),
        sourceText: String,
        normalizedURL: String,
        title: String = "",
        noteText: String = "",
        noteType: NoteType = .unknown,
        status: TaskStatus = .queued,
        progress: Double = 0,
        mediaCount: Int = 0,
        savedCount: Int = 0,
        failedCount: Int = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        mediaAssets: [MediaAssetRecord] = []
    ) {
        self.id = id
        self.sourceText = sourceText
        self.normalizedURL = normalizedURL
        self.title = title
        self.noteText = noteText
        self.noteType = noteType
        self.status = status
        self.progress = progress
        self.mediaCount = mediaCount
        self.savedCount = savedCount
        self.failedCount = failedCount
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mediaAssets = mediaAssets
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case waiting
    case failed

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .all: return "filter.all"
        case .waiting: return "filter.waiting"
        case .failed: return "filter.failed"
        }
    }
}

enum SelectiveDownloadPhase: Equatable {
    case caching
    case ready
    case saving
    case error(String)
}

struct SelectiveMediaItem: Identifiable {
    let id: UUID
    let remote: RemoteMedia
    let cachedURL: URL
    var isSelected: Bool
}

struct SelectiveDownloadState: Identifiable {
    let id: UUID
    let taskID: UUID
    var phase: SelectiveDownloadPhase
    var items: [SelectiveMediaItem]

    init(taskID: UUID, phase: SelectiveDownloadPhase, items: [SelectiveMediaItem]) {
        self.id = taskID
        self.taskID = taskID
        self.phase = phase
        self.items = items
    }
}

enum XHSURLDetector {
    private static let expression = try! NSRegularExpression(
        pattern: #"https?://(?:www\.)?(?:xiaohongshu\.com|xhslink\.(?:com|cn))/[^\s<>\"']+"#,
        options: [.caseInsensitive]
    )

    static func extract(from input: String) -> [String] {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var seen = Set<String>()
        return expression.matches(in: input, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: input) else { return nil }
            var value = String(input[swiftRange])
            if let delimiter = value.firstIndex(where: { "，。；：！？）】》".contains($0) }) {
                value = String(value[..<delimiter])
            }
            while let last = value.last, ".,;:!?)]}".contains(last) {
                value.removeLast()
            }
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    static func first(from input: String) -> String? {
        extract(from: input).first
    }

    static func containsSupportedLink(_ input: String) -> Bool {
        first(from: input) != nil
    }
}

final class AppSettings: ObservableObject {
    enum Key {
        static let createLivePhotos = "create_live_photos"
        static let selectiveDownload = "selective_download"
        static let debugNotifications = "debug_notifications"
        static let keepScreenAwake = "keep_screen_awake"
        static let clipboardSuggestions = "clipboard_suggestions"
    }

    private let defaults: UserDefaults

    @Published var createLivePhotos: Bool { didSet { defaults.set(createLivePhotos, forKey: Key.createLivePhotos) } }
    @Published var selectiveDownload: Bool { didSet { defaults.set(selectiveDownload, forKey: Key.selectiveDownload) } }
    @Published var debugNotifications: Bool { didSet { defaults.set(debugNotifications, forKey: Key.debugNotifications) } }
    @Published var keepScreenAwake: Bool {
        didSet {
            defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake)
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }
    @Published var clipboardSuggestions: Bool { didSet { defaults.set(clipboardSuggestions, forKey: Key.clipboardSuggestions) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        createLivePhotos = defaults.object(forKey: Key.createLivePhotos) as? Bool ?? true
        selectiveDownload = defaults.object(forKey: Key.selectiveDownload) as? Bool ?? false
        debugNotifications = defaults.object(forKey: Key.debugNotifications) as? Bool ?? false
        keepScreenAwake = defaults.object(forKey: Key.keepScreenAwake) as? Bool ?? false
        clipboardSuggestions = defaults.object(forKey: Key.clipboardSuggestions) as? Bool ?? true
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }
}

final class DownloadTaskStore {
    let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("XHSDownloader", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("download-tasks.json")
        }
    }

    func load() -> [DownloadTaskRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([DownloadTaskRecord].self, from: data)) ?? []
    }

    func save(_ tasks: [DownloadTaskRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(tasks)
        try data.write(to: fileURL, options: [.atomic])
    }
}

struct SharedInboxItem: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

enum SharedInbox {
    static let suiteName = "group.com.neoruaa.xhsdn"
    private static let key = "shared_inbox_items"

    static func append(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let defaults = UserDefaults(suiteName: suiteName) else { return }
        var items = read(defaults: defaults)
        items.append(SharedInboxItem(text: text))
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }

    static func consume() -> [SharedInboxItem] {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return [] }
        let items = read(defaults: defaults)
        defaults.removeObject(forKey: key)
        return items
    }

    private static func read(defaults: UserDefaults) -> [SharedInboxItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SharedInboxItem].self, from: data)) ?? []
    }
}
