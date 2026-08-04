import Foundation
import Testing
@testable import XHS_Downloader_iOS

struct XHS_Downloader_iOSTests {
    @Test func extractsSupportedDomainsAndShareText() {
        let input = "看看这篇 https://www.xiaohongshu.com/explore/abc123?x=1 还有 https://xhslink.cn/AbCdE。重复 https://xhslink.cn/AbCdE"
        let links = XHSURLDetector.extract(from: input)
        #expect(links == [
            "https://www.xiaohongshu.com/explore/abc123?x=1",
            "https://xhslink.cn/AbCdE"
        ])
    }

    @Test func extractsExactXHSShareTextFromClipboard() {
        let input = "🐰夏天跟兔兔一起度过！ 萤火虫d3阿米娅@uuohz 📷富士... http://xhslink.cn/o/6k5VEtmd2WX \n复制这段，去【小红书】发现更多好内容~"
        #expect(XHSURLDetector.extract(from: input) == [
            "http://xhslink.cn/o/6k5VEtmd2WX"
        ])
    }

    @Test func persistsTasksAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let task = DownloadTaskRecord(
            sourceText: "share text",
            normalizedURL: "https://xhslink.com/example",
            title: "Example",
            status: .completed,
            progress: 1,
            mediaCount: 3,
            savedCount: 3
        )

        try store.save([task])
        let loaded = try #require(store.load().first)
        #expect(loaded.id == task.id)
        #expect(loaded.normalizedURL == task.normalizedURL)
        #expect(loaded.status == .completed)
        #expect(loaded.mediaCount == 3)
        #expect(abs(loaded.createdAt.timeIntervalSince(task.createdAt)) < 1)
    }

    @Test func namingTemplateSupportsAndroidPlaceholders() {
        let preferences = NamingPreferences(enabled: true, template: "{username}_{postId}_{index_padded}")
        let name = NamingFormatter.makeBaseName(
            metadata: NoteMetadata(userName: "A/B", userId: nil, title: nil, publishTime: nil),
            fallbackPostId: "post-1",
            index: 2,
            downloadEpochSeconds: 123,
            preferences: preferences
        )
        #expect(name == "A_B_post-1_02_02")
    }

    @Test func interruptedTasksBecomeRetryableFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadTaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let task = DownloadTaskRecord(
            sourceText: "share text",
            normalizedURL: "https://xhslink.com/example",
            status: .downloading,
            progress: 0.4
        )
        try store.save([task])

        let settings = await MainActor.run { AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
        let coordinator = await MainActor.run { DownloadCoordinator(settings: settings, store: store) }
        let recovered = await MainActor.run { coordinator.tasks.first }
        #expect(recovered?.status == .failed)
        #expect(recovered?.progress == 0.4)
    }
}
