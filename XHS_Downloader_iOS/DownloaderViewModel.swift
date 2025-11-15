//
//  DownloaderViewModel.swift
//  XHS_Downloader_iOS
//
//  Created by Codex on behalf of user.
//

import SwiftUI
import Photos
import UIKit
import Combine

struct MediaPreviewItem: Identifiable, Hashable {
    let id = UUID()
    let localURL: URL
    let isVideo: Bool
}

struct LogEntry: Identifiable, Hashable {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    let id = UUID()
    let timestamp = Date()
    let message: String

    var displayText: String {
        "[\(Self.formatter.string(from: timestamp))] \(message)"
    }
}

final class DownloaderViewModel: ObservableObject {
    @Published var shareText: String = ""
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var mediaItems: [MediaPreviewItem] = []
    @Published var isDownloading = false
    @Published var showProgress = false
    @Published var progressValue = 0.0
    @Published var progressText = ""
    @Published var showSettingsSheet = false

    private let downloader = XHSDownloader()

    func startDownload() {
        let trimmed = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("请输入分享文本后再开始下载")
            return
        }
        guard !isDownloading else { return }

        isDownloading = true
        showProgress = false
        progressValue = 0
        progressText = ""
        mediaItems.removeAll()
        appendLog("准备开始解析分享内容…")

        Task {
            do {
                try await ensurePhotoLibraryPermission()
                await MainActor.run { self.appendLog("已获得相册访问权限") }

                let remoteMedia = try await downloader.collectMedia(from: trimmed) { [weak self] message in
                    guard let self else { return }
                    await MainActor.run {
                        self.appendLog(message)
                    }
                }

                guard !remoteMedia.isEmpty else {
                    await MainActor.run {
                        self.appendLog("没有检测到可下载的媒体资源")
                        self.isDownloading = false
                    }
                    return
                }

                await MainActor.run {
                    self.showProgress = true
                    self.progressText = "0/\(remoteMedia.count)"
                    self.progressValue = 0
                }

                try await download(mediaItems: remoteMedia)

                await MainActor.run {
                    self.appendLog("全部媒体已保存到系统相册")
                    self.isDownloading = false
                    self.showProgress = false
                }
            } catch {
                await MainActor.run {
                    self.appendLog("下载失败：\(error.userFacingMessage)")
                    self.isDownloading = false
                    self.showProgress = false
                }
            }
        }
    }

    @MainActor
    func appendLog(_ message: String) {
        logEntries.append(LogEntry(message: message))
    }

    private func download(mediaItems: [RemoteMedia]) async throws {
        let timestamp = downloader.makeSessionTimestamp()
        let total = mediaItems.count

        for (index, media) in mediaItems.enumerated() {
            try Task.checkCancellation()
            let fileURL = try await downloader.download(media: media, sessionTimestamp: timestamp)
            try await saveToPhotoLibrary(fileURL: fileURL, isVideo: media.isVideo)

            await MainActor.run {
                let current = index + 1
                self.progressValue = Double(current) / Double(total)
                self.progressText = "\(current)/\(total)"
                self.mediaItems.append(MediaPreviewItem(localURL: fileURL, isVideo: media.isVideo))
            }
        }
    }

    private func ensurePhotoLibraryPermission() async throws {
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                return
            case .denied, .restricted:
                throw XHSDownloaderError.permissionDenied
            case .notDetermined:
                let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                if newStatus == .authorized || newStatus == .limited {
                    return
                }
                throw XHSDownloaderError.permissionDenied
            @unknown default:
                throw XHSDownloaderError.permissionDenied
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            switch status {
            case .authorized:
                return
            case .denied, .restricted:
                throw XHSDownloaderError.permissionDenied
            case .notDetermined:
                let granted = await requestLegacyPhotoPermission()
                if granted {
                    return
                }
                throw XHSDownloaderError.permissionDenied
            default:
                throw XHSDownloaderError.permissionDenied
            }
        }
    }

    private func requestLegacyPhotoPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func saveToPhotoLibrary(fileURL: URL, isVideo: Bool) async throws {
        do {
            try await saveWithPhotoLibrary(fileURL: fileURL, isVideo: isVideo)
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain && nsError.code == 3302 {
                if isVideo {
                    try await saveVideoWithUIKit(fileURL: fileURL)
                } else {
                    try await saveImageWithUIKit(fileURL: fileURL)
                }
            } else {
                throw error
            }
        }
    }

    private func saveWithPhotoLibrary(fileURL: URL, isVideo: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                if isVideo {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: XHSDownloaderError.requestFailed)
                }
            }
        }
    }

    private func saveImageWithUIKit(fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        guard let image = UIImage(data: data) else {
            throw XHSDownloaderError.parsingFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UIKitPhotoSaver.shared.storeContinuation(continuation)
            UIImageWriteToSavedPhotosAlbum(
                image,
                UIKitPhotoSaver.shared,
                #selector(UIKitPhotoSaver.imageSaveCompleted(_:didFinishSavingWithError:contextInfo:)),
                nil
            )
        }
    }

    private func saveVideoWithUIKit(fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UIKitPhotoSaver.shared.storeContinuation(continuation)
            UISaveVideoAtPathToSavedPhotosAlbum(
                fileURL.path,
                UIKitPhotoSaver.shared,
                #selector(UIKitPhotoSaver.videoSaveCompleted(_:didFinishSavingWithError:contextInfo:)),
                nil
            )
        }
    }
}

private extension Error {
    var userFacingMessage: String {
        if let localized = self as? LocalizedError, let desc = localized.errorDescription {
            return desc
        }
        return localizedDescription
    }
}

private final class UIKitPhotoSaver: NSObject {
    static let shared = UIKitPhotoSaver()
    private var continuation: CheckedContinuation<Void, Error>?

    func storeContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @objc func imageSaveCompleted(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {
        complete(with: error)
    }

    @objc func videoSaveCompleted(_ videoPath: NSString, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {
        complete(with: error)
    }

    private func complete(with error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: ())
        }
        continuation = nil
    }
}
