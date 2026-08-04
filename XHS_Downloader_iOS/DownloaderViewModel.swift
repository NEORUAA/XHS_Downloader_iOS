import Foundation
import Combine
import Photos
import UIKit
import UserNotifications
import AVFoundation
import ImageIO

private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return L10n.text("error.photo_permission")
        case .saveFailed: return L10n.text("error.photo_save")
        }
    }
}

final class PhotoLibraryService {
    func requestWriteAuthorization() async -> Bool {
        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        return status == .authorized || status == .limited
    }

    func saveMedia(at fileURL: URL, isVideo: Bool) async throws -> String {
        guard await requestWriteAuthorization() else {
            throw PhotoLibraryError.permissionDenied
        }

        let identifier = IdentifierBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let resourceType: PHAssetResourceType = isVideo ? .video : .photo
                request.addResource(with: resourceType, fileURL: fileURL, options: nil)
                identifier.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed)
                }
            }
        }

        guard let value = identifier.value else {
            throw PhotoLibraryError.saveFailed
        }
        return value
    }

    func saveLivePhoto(photoURL: URL, pairedVideoURL: URL) async throws -> String {
        guard await requestWriteAuthorization() else {
            throw PhotoLibraryError.permissionDenied
        }

        let identifier = IdentifierBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photoURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: nil)
                identifier.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed)
                }
            }
        }

        guard let value = identifier.value else {
            throw PhotoLibraryError.saveFailed
        }
        return value
    }

    func deleteAssets(localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed)
                }
            }
        }
    }
}

@MainActor
final class DownloadCoordinator: ObservableObject {
    @Published private(set) var tasks: [DownloadTaskRecord]
    @Published var selectionState: SelectiveDownloadState?
    @Published var alertMessage: String?
    @Published private(set) var lastLogMessage: String = ""

    let settings: AppSettings

    private let store: DownloadTaskStore
    private let downloader: XHSDownloader
    private let photoLibrary: PhotoLibraryService
    private var jobs: [UUID: Task<Void, Never>] = [:]

    init(
        settings: AppSettings,
        store: DownloadTaskStore? = nil,
        downloader: XHSDownloader? = nil,
        photoLibrary: PhotoLibraryService? = nil
    ) {
        self.settings = settings
        self.store = store ?? DownloadTaskStore()
        self.downloader = downloader ?? XHSDownloader()
        self.photoLibrary = photoLibrary ?? PhotoLibraryService()
        self.tasks = self.store.load().sorted { $0.createdAt > $1.createdAt }
        recoverInterruptedTasks()
    }

    deinit {
        jobs.values.forEach { $0.cancel() }
    }

    var waitingCount: Int { tasks.filter { $0.status == .waitingForUser }.count }
    var failedCount: Int { tasks.filter { $0.status == .failed }.count }

    func filteredTasks(for filter: TaskFilter) -> [DownloadTaskRecord] {
        switch filter {
        case .all: return tasks
        case .waiting: return tasks.filter { $0.status == .waitingForUser }
        case .failed: return tasks.filter { $0.status == .failed }
        }
    }

    func enqueue(_ input: String) {
        let links = XHSURLDetector.extract(from: input)
        guard !links.isEmpty else {
            alertMessage = L10n.text("error.no_link")
            return
        }

        var accepted = 0
        for link in links {
            if isDuplicate(link) {
                continue
            }
            let task = DownloadTaskRecord(sourceText: input, normalizedURL: link)
            tasks.insert(task, at: 0)
            persist()
            start(taskID: task.id)
            accepted += 1
        }

        if accepted == 0 {
            alertMessage = L10n.text("error.duplicate")
        }
    }

    func consumeSharedInbox() {
        for item in SharedInbox.consume() {
            enqueue(item.text)
        }
    }

    func stop(taskID: UUID) {
        jobs[taskID]?.cancel()
        jobs[taskID] = nil
        update(taskID) { task in
            task.status = .failed
            task.errorMessage = L10n.text("error.cancelled")
        }
        if selectionState?.taskID == taskID {
            cleanupSelectionFiles(selectionState)
            selectionState = nil
        }
    }

    func retry(taskID: UUID) {
        guard jobs[taskID] == nil else { return }
        update(taskID) { task in
            task.status = .queued
            task.progress = 0
            task.failedCount = 0
            task.errorMessage = nil
        }
        start(taskID: taskID)
    }

    func deleteTask(taskID: UUID, deletePhotos: Bool) async {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        stopSilently(taskID: taskID)
        if deletePhotos {
            do {
                try await photoLibrary.deleteAssets(localIdentifiers: task.mediaAssets.map(\.localIdentifier))
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
        tasks.removeAll { $0.id == taskID }
        persist()
    }

    func clearHistory() {
        for id in jobs.keys { jobs[id]?.cancel() }
        jobs.removeAll()
        cleanupSelectionFiles(selectionState)
        selectionState = nil
        tasks.removeAll()
        persist()
    }

    func updateSelection(id: UUID, selected: Bool) {
        guard var state = selectionState,
              let index = state.items.firstIndex(where: { $0.id == id }) else { return }
        state.items[index].isSelected = selected
        selectionState = state
    }

    func cancelSelection() {
        guard let state = selectionState else { return }
        cleanupSelectionFiles(state)
        selectionState = nil
        update(state.taskID) { task in
            task.status = .failed
            task.errorMessage = L10n.text("error.selection_cancelled")
        }
    }

    func saveSelection() {
        guard var state = selectionState, state.phase == .ready else { return }
        let selectedItems = state.items.filter(\.isSelected)
        guard !selectedItems.isEmpty else {
            alertMessage = L10n.text("error.selection_empty")
            return
        }
        state.phase = .saving
        selectionState = state
        let taskID = state.taskID
        jobs[taskID] = Task { [weak self] in
            guard let self else { return }
            await self.saveCachedItems(selectedItems, taskID: taskID, allItems: state.items)
        }
    }

    private func start(taskID: UUID) {
        jobs[taskID] = Task { [weak self] in
            guard let self else { return }
            await self.run(taskID: taskID)
        }
    }

    private func run(taskID: UUID) async {
        guard let task = task(for: taskID) else { return }
        update(taskID) { record in
            record.status = .downloading
            record.errorMessage = nil
        }

        do {
            let media = try await downloader.collectMedia(from: task.normalizedURL) { _ in }
            try Task.checkCancellation()
            guard !media.isEmpty else { throw XHSDownloaderError.emptyMedia }

            let noteText = (try? await downloader.extractDescription(from: task.normalizedURL) { _ in }) ?? ""
            let noteType = inferNoteType(media)
            update(taskID) { record in
                record.mediaCount = media.count
                record.noteType = noteType
                record.noteText = noteText
                if record.title.isEmpty {
                    record.title = noteText.firstNonemptyLine ?? media.first?.fileBaseName ?? L10n.text("task.untitled")
                }
            }

            if settings.selectiveDownload {
                try await cacheForSelection(media, taskID: taskID)
            } else {
                try await downloadAndSave(media, taskID: taskID)
            }
        } catch is CancellationError {
            update(taskID) { record in
                record.status = .failed
                record.errorMessage = L10n.text("error.cancelled")
            }
        } catch {
            update(taskID) { record in
                record.status = .failed
                record.errorMessage = error.localizedDescription
                record.failedCount = max(1, record.mediaCount - record.savedCount)
            }
            await postNotification(taskID: taskID, success: false)
        }
        jobs[taskID] = nil
    }

    private func downloadAndSave(_ media: [RemoteMedia], taskID: UUID) async throws {
        var saved = 0
        var failed = 0
        let sessionTimestamp = downloader.makeSessionTimestamp()

        for (index, item) in media.enumerated() {
            try Task.checkCancellation()
            do {
                let fileURL = try await downloader.download(media: item, sessionTimestamp: sessionTimestamp)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try Task.checkCancellation()
                let metadata = MediaFileMetadata(url: fileURL, isVideo: item.isVideo)
                let localIdentifier = try await photoLibrary.saveMedia(at: fileURL, isVideo: item.isVideo)
                saved += 1
                update(taskID) { task in
                    task.savedCount = saved
                    task.mediaAssets.append(MediaAssetRecord(
                        localIdentifier: localIdentifier,
                        fileName: fileURL.lastPathComponent,
                        isVideo: item.isVideo,
                        pixelWidth: metadata.pixelWidth,
                        pixelHeight: metadata.pixelHeight,
                        byteCount: metadata.byteCount
                    ))
                    task.progress = Double(index + 1) / Double(media.count)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                update(taskID) { task in
                    task.failedCount = failed
                    task.progress = Double(index + 1) / Double(media.count)
                    task.errorMessage = error.localizedDescription
                }
            }
        }

        finish(taskID: taskID, expected: media.count, saved: saved, failed: failed)
    }

    private func cacheForSelection(_ media: [RemoteMedia], taskID: UUID) async throws {
        let sessionTimestamp = downloader.makeSessionTimestamp()
        var items: [SelectiveMediaItem] = []
        selectionState = SelectiveDownloadState(taskID: taskID, phase: .caching, items: [])

        for (index, item) in media.enumerated() {
            try Task.checkCancellation()
            let fileURL = try await downloader.download(media: item, sessionTimestamp: sessionTimestamp)
            items.append(SelectiveMediaItem(id: item.id, remote: item, cachedURL: fileURL, isSelected: true))
            update(taskID) { task in
                task.progress = Double(index + 1) / Double(media.count) * 0.5
            }
            selectionState = SelectiveDownloadState(taskID: taskID, phase: .caching, items: items)
        }

        update(taskID) { task in
            task.status = .waitingForUser
            task.progress = 0.5
        }
        selectionState = SelectiveDownloadState(taskID: taskID, phase: .ready, items: items)
    }

    private func saveCachedItems(
        _ selectedItems: [SelectiveMediaItem],
        taskID: UUID,
        allItems: [SelectiveMediaItem]
    ) async {
        var saved = 0
        var failed = 0
        for (index, item) in selectedItems.enumerated() {
            do {
                try Task.checkCancellation()
                let metadata = MediaFileMetadata(url: item.cachedURL, isVideo: item.remote.isVideo)
                let identifier = try await photoLibrary.saveMedia(at: item.cachedURL, isVideo: item.remote.isVideo)
                saved += 1
                update(taskID) { task in
                    task.savedCount = saved
                    task.mediaAssets.append(MediaAssetRecord(
                        localIdentifier: identifier,
                        fileName: item.cachedURL.lastPathComponent,
                        isVideo: item.remote.isVideo,
                        pixelWidth: metadata.pixelWidth,
                        pixelHeight: metadata.pixelHeight,
                        byteCount: metadata.byteCount
                    ))
                    task.progress = 0.5 + (Double(index + 1) / Double(selectedItems.count) * 0.5)
                }
            } catch is CancellationError {
                update(taskID) { task in
                    task.status = .failed
                    task.errorMessage = L10n.text("error.cancelled")
                }
                cleanupSelectionFiles(SelectiveDownloadState(taskID: taskID, phase: .saving, items: allItems))
                selectionState = nil
                jobs[taskID] = nil
                return
            } catch {
                failed += 1
                update(taskID) { task in
                    task.failedCount = failed
                    task.errorMessage = error.localizedDescription
                }
            }
        }

        cleanupSelectionFiles(SelectiveDownloadState(taskID: taskID, phase: .saving, items: allItems))
        selectionState = nil
        finish(taskID: taskID, expected: selectedItems.count, saved: saved, failed: failed)
        jobs[taskID] = nil
    }

    private func finish(taskID: UUID, expected: Int, saved: Int, failed: Int) {
        update(taskID) { task in
            task.savedCount = saved
            task.failedCount = failed
            task.progress = 1
            if saved == expected && failed == 0 {
                task.status = .completed
                task.errorMessage = nil
            } else {
                task.status = .failed
                task.errorMessage = L10n.format("error.partial_failure", saved, expected)
            }
        }
        Task { await postNotification(taskID: taskID, success: failed == 0 && saved == expected) }
    }

    private func postNotification(taskID: UUID, success: Bool) async {
        guard settings.debugNotifications,
              let task = task(for: taskID) else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = success ? L10n.text("notification.completed") : L10n.text("notification.failed")
        content.body = task.title.isEmpty ? task.normalizedURL : task.title
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil))
    }

    private func inferNoteType(_ media: [RemoteMedia]) -> NoteType {
        let videos = media.filter(\.isVideo).count
        if videos == 0 { return .image }
        if videos == media.count { return .video }
        return settings.createLivePhotos && videos == 1 && media.count == 2 ? .livePhoto : .mixed
    }

    private func isDuplicate(_ normalizedURL: String) -> Bool {
        let threshold = Date().addingTimeInterval(-3600)
        return tasks.contains { $0.normalizedURL == normalizedURL && $0.createdAt >= threshold }
    }

    private func task(for id: UUID) -> DownloadTaskRecord? {
        tasks.first { $0.id == id }
    }

    private func update(_ id: UUID, mutation: (inout DownloadTaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&tasks[index])
        tasks[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try store.save(tasks)
        } catch {
            alertMessage = L10n.format("error.persistence", error.localizedDescription)
        }
    }

    private func recoverInterruptedTasks() {
        var changed = false
        for index in tasks.indices where tasks[index].status == .queued || tasks[index].status == .downloading || tasks[index].status == .waitingForUser {
            tasks[index].status = .failed
            tasks[index].errorMessage = L10n.text("error.interrupted")
            tasks[index].updatedAt = Date()
            changed = true
        }
        if changed { persist() }
    }

    private func cleanupSelectionFiles(_ state: SelectiveDownloadState?) {
        state?.items.forEach { try? FileManager.default.removeItem(at: $0.cachedURL) }
    }

    private func stopSilently(taskID: UUID) {
        jobs[taskID]?.cancel()
        jobs[taskID] = nil
        if selectionState?.taskID == taskID {
            cleanupSelectionFiles(selectionState)
            selectionState = nil
        }
    }
}

private extension String {
    var firstNonemptyLine: String? {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}


private struct MediaFileMetadata {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let byteCount: Int64?

    init(url: URL, isVideo: Bool) {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues?.fileSize, fileSize > 0 {
            byteCount = Int64(fileSize)
        } else {
            byteCount = nil
        }

        if isVideo {
            let asset = AVURLAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let transformedSize = track.naturalSize.applying(track.preferredTransform)
                pixelWidth = Int(abs(transformedSize.width).rounded())
                pixelHeight = Int(abs(transformedSize.height).rounded())
            } else {
                pixelWidth = nil
                pixelHeight = nil
            }
        } else if
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        {
            pixelWidth = width.intValue
            pixelHeight = height.intValue
        } else {
            pixelWidth = nil
            pixelHeight = nil
        }
    }
}
