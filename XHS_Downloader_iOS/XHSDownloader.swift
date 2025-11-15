//
//  XHSDownloader.swift
//  XHS_Downloader_iOS
//
//  Created by Codex on behalf of user.
//

import Foundation
import JavaScriptCore

struct RemoteMedia: Identifiable, Hashable {
    enum MediaType {
        case image
        case video
    }

    let id = UUID()
    let url: URL
    let type: MediaType
    let fileBaseName: String
    let originalURLString: String

    var isVideo: Bool {
        type == .video
    }
}

enum XHSDownloaderError: LocalizedError {
    case invalidURL
    case requestFailed
    case permissionDenied
    case missingLinks
    case parsingFailed
    case emptyMedia

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "分享链接格式不正确"
        case .requestFailed:
            return "网络请求失败，请稍后重试"
        case .permissionDenied:
            return "缺少必要的权限"
        case .missingLinks:
            return "未检测到有效的小红书链接"
        case .parsingFailed:
            return "笔记内容解析失败"
        case .emptyMedia:
            return "未找到任何可下载的媒体资源"
        }
    }
}

final class XHSDownloader {
    typealias LogHandler = @Sendable (String) async -> Void

    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

    private let xhsLinkRegex = try! NSRegularExpression(pattern: "(?:https?://)?www\\.xiaohongshu\\.com/explore/\\S+", options: .caseInsensitive)
    private let xhsUserRegex = try! NSRegularExpression(pattern: "(?:https?://)?www\\.xiaohongshu\\.com/user/profile/[a-z0-9]+/\\S+", options: .caseInsensitive)
    private let xhsShareRegex = try! NSRegularExpression(pattern: "(?:https?://)?www\\.xiaohongshu\\.com/discovery/item/\\S+", options: .caseInsensitive)
    private let xhsShortRegex = try! NSRegularExpression(pattern: "(?:https?://)?xhslink\\.com/[^\\s\\\"<>\\\\^`{|}，。；！？、【】《》]+", options: .caseInsensitive)
    private let idRegex = try! NSRegularExpression(pattern: "(?:explore|item)/([a-zA-Z0-9_\\-]+)/?(?:\\?|$)", options: .caseInsensitive)
    private let idUserRegex = try! NSRegularExpression(pattern: "user/profile/[a-z0-9]+/([a-zA-Z0-9_\\-]+)/?(?:\\?|$)", options: .caseInsensitive)
    private let htmlImgRegex = try! NSRegularExpression(pattern: "<img[^>]+src\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"][^>]*>", options: .caseInsensitive)
    private let htmlUrlRegex = try! NSRegularExpression(pattern: "https?://[\\w\\-._~:/?#\\[\\]@!$&'()*+,;=%]+\\.(?:jpg|jpeg|png|gif|mp4|avi|mov|webm|wmv|flv|f4v|swf|mpg|mpeg|asf|3gp|3g2|mkv|webp|heic|heif)", options: .caseInsensitive)

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func collectMedia(from input: String, logger: @escaping LogHandler) async throws -> [RemoteMedia] {
        let linkStrings = extractLinkStrings(from: input)
        guard !linkStrings.isEmpty else {
            await logger("输入中没有检测到合法的小红书链接")
            return []
        }

        var contexts: [LinkContext] = []
        for raw in linkStrings {
            if let context = try await prepareContext(for: raw, logger: logger) {
                contexts.append(context)
            }
        }

        guard !contexts.isEmpty else {
            await logger("没有可以处理的链接")
            return []
        }

        var aggregated: [RemoteMedia] = []
        var seen = Set<String>()

        for context in contexts {
            try Task.checkCancellation()
            await logger("正在获取笔记：\(context.resolvedURL.absoluteString)")
            guard let html = try await fetchPostDetails(for: context.resolvedURL) else {
                await logger("笔记加载失败：\(context.resolvedURL.absoluteString)")
                continue
            }

            let mediaUrls = parsePostDetails(html: html)
            if mediaUrls.isEmpty {
                await logger("笔记 \(context.postId ?? context.resolvedURL.lastPathComponent) 未找到可下载媒体")
                continue
            }

            let mediaItems = buildRemoteMedia(from: mediaUrls, postId: context.postId)
            let newItems = mediaItems.filter { seen.insert($0.originalURLString).inserted }
            await logger("笔记 \(context.postId ?? context.resolvedURL.lastPathComponent) 解析到 \(newItems.count) 个媒体资源")
            aggregated.append(contentsOf: newItems)
        }

        return aggregated
    }

    func makeSessionTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        return formatter.string(from: Date())
    }

    func download(media: RemoteMedia, sessionTimestamp: String) async throws -> URL {
        try Task.checkCancellation()

        var request = URLRequest(url: media.url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/jpeg,image/png,image/*;q=0.8,video/mp4,video/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90

        let (tempURL, response) = try await session.download(for: request)
        let ext = determineFileExtension(from: response, fallbackURL: media.url, mediaType: media.type)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("xhs_\(sessionTimestamp)_\(media.fileBaseName).\(ext)")

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}

// MARK: - Private helpers

private extension XHSDownloader {
    struct LinkContext {
        let sourceURL: URL
        let resolvedURL: URL
        let postId: String?
    }

    func extractLinkStrings(from input: String) -> [String] {
        var results: [String] = []
        let parts = input.split(whereSeparator: { $0.isWhitespace })

        for rawPart in parts {
            let part = String(rawPart)
            if let short = match(in: part, regex: xhsShortRegex) {
                results.append(short)
                continue
            }
            if let share = match(in: part, regex: xhsShareRegex) {
                results.append(share)
                continue
            }
            if let link = match(in: part, regex: xhsLinkRegex) {
                results.append(link)
                continue
            }
            if let user = match(in: part, regex: xhsUserRegex) {
                results.append(user)
            }
        }

        return results
    }

    func match(in text: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        return (text as NSString).substring(with: result.range)
    }

    func prepareContext(for raw: String, logger: LogHandler) async throws -> LinkContext? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if !cleaned.lowercased().hasPrefix("http") {
            cleaned = "https://" + cleaned
        }
        guard let originalURL = URL(string: cleaned) else { return nil }

        var resolvedURL = originalURL
        if cleaned.contains("xhslink.com") {
            if let redirect = await resolveShortLink(originalURL) {
                resolvedURL = redirect
                await logger("短链接已解析为：\(redirect.absoluteString)")
            } else {
                await logger("短链接解析失败，尝试直接使用原链接")
            }
        }

        let postId = extractPostId(from: resolvedURL.absoluteString)
        return LinkContext(sourceURL: originalURL, resolvedURL: resolvedURL, postId: postId)
    }

    func resolveShortLink(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent + " xiaohongshu", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await session.data(for: request)
            return response.url
        } catch {
            return nil
        }
    }

    func fetchPostDetails(for url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=1.0,image/avif,image/webp,image/apng,*/*;q=1.0", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            return nil
        }

        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        if let html = String(data: data, encoding: .ascii) {
            return html
        }
        return nil
    }

    func parsePostDetails(html: String) -> [String] {
        if let script = extractInitialStateScript(from: html),
           let root = evaluateInitialStateScript(script) {
            let urls = parseMediaFromRoot(root)
            if !urls.isEmpty {
                var seen = Set<String>()
                return urls.filter { seen.insert($0).inserted }
            }
        }

        return extractUrlsFromHtml(html)
    }

    func parseMediaFromRoot(_ root: [String: Any]) -> [String] {
        var mediaUrls: [String] = []

        if let noteRoot = root["note"] as? [String: Any] {
            mediaUrls.append(contentsOf: parseNoteRoot(noteRoot))
        }

        if mediaUrls.isEmpty, let detailMap = root["noteDetailMap"] as? [String: Any] {
            for value in detailMap.values {
                if let dict = value as? [String: Any] {
                    mediaUrls.append(contentsOf: parseNoteRoot(dict))
                }
            }
        }

        if mediaUrls.isEmpty, let feed = root["feed"] as? [String: Any] {
            mediaUrls.append(contentsOf: parseFeed(feed))
        }

        if mediaUrls.isEmpty {
            mediaUrls.append(contentsOf: parseNoteRoot(root))
        }
        return mediaUrls
    }

    func extractInitialStateScript(from html: String) -> String? {
        guard let startRange = html.range(of: "window.__INITIAL_STATE__="),
              let endRange = html[startRange.lowerBound...].range(of: "</script>") else {
            return nil
        }

        let scriptContent = String(html[startRange.lowerBound..<endRange.lowerBound])
        guard let equalIndex = scriptContent.firstIndex(of: "=") else {
            return nil
        }

        let expression = scriptContent[scriptContent.index(after: equalIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return "var window = window || {}; window.__INITIAL_STATE__=\(expression);"
    }

    func evaluateInitialStateScript(_ script: String) -> [String: Any]? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            if let message = exception?.toString() {
                NSLog("JSContext exception: \(message)")
            }
        }

        context.evaluateScript("var window = {}; var document = {}; var navigator = {};")
        context.evaluateScript(script)

        guard let windowObject = context.objectForKeyedSubscript("window"),
              let state = windowObject.objectForKeyedSubscript("__INITIAL_STATE__"),
              let dictionary = state.toDictionary() as? [String: Any] else {
            return nil
        }

        return dictionary
    }

    func parseNoteRoot(_ noteRoot: [String: Any]) -> [String] {
        var urls: [String] = []

        if let detailMap = noteRoot["noteDetailMap"] as? [String: Any] {
            for value in detailMap.values {
                if let dict = value as? [String: Any] {
                    if let note = dict["note"] as? [String: Any] {
                        urls.append(contentsOf: collectMedia(from: note))
                    } else {
                        urls.append(contentsOf: collectMedia(from: dict))
                    }
                }
            }
        } else if let note = noteRoot["note"] as? [String: Any] {
            urls.append(contentsOf: collectMedia(from: note))
        } else {
            urls.append(contentsOf: collectMedia(from: noteRoot))
        }
        return urls
    }

    func parseFeed(_ feed: [String: Any]) -> [String] {
        var urls: [String] = []
        if let items = feed["items"] as? [[String: Any]] {
            for item in items {
                urls.append(contentsOf: collectMedia(from: item))
            }
        }
        return urls
    }

    func collectMedia(from note: [String: Any]) -> [String] {
        var urls: [String] = []

        if let video = note["video"] as? [String: Any] {
            urls.append(contentsOf: extractVideoUrls(from: video))
        }

        if let media = note["media"] as? [String: Any] {
            urls.append(contentsOf: extractVideoUrls(from: media))
        }

        var imageArrays: [[String: Any]] = []
        if let imageList = note["imageList"] as? [[String: Any]] {
            imageArrays.append(contentsOf: imageList)
        } else if let images = note["images"] as? [[String: Any]] {
            imageArrays.append(contentsOf: images)
        } else if let imageObject = note["image"] as? [String: Any] {
            imageArrays.append(imageObject)
        }

        for image in imageArrays {
            if let url = preferredImageURL(from: image) {
                urls.append(url)
            }
            if let stream = image["stream"] as? [String: Any] {
                urls.append(contentsOf: extractStreamUrls(from: stream))
            }
        }

        if let cover = note["cover"] as? [String: Any], let url = preferredImageURL(from: cover) {
            urls.append(url)
        }

        return urls
    }

    func extractVideoUrls(from videoDict: [String: Any]) -> [String] {
        var urls: [String] = []
        if let consumer = videoDict["consumer"] as? [String: Any],
           let origin = consumer["originVideoKey"] as? String {
            urls.append("https://sns-video-bd.xhscdn.com/\(origin)")
        }

        if let media = videoDict["media"] as? [String: Any],
           let stream = media["stream"] as? [String: Any] {
            urls.append(contentsOf: extractStreamUrls(from: stream))
        }

        if let videoUrl = videoDict["url"] as? String {
            urls.append(videoUrl)
        }

        return urls
    }

    func extractStreamUrls(from stream: [String: Any]) -> [String] {
        var urls: [String] = []
        if let h264 = stream["h264"] as? [Any] {
            for entry in h264 {
                if let string = entry as? String, string.starts(with: "http") {
                    urls.append(string)
                } else if let dict = entry as? [String: Any] {
                    if let url = dict["masterUrl"] as? String {
                        urls.append(url)
                    } else if let url = dict["url"] as? String {
                        urls.append(url)
                    }
                }
            }
        }
        return urls
    }

    func preferredImageURL(from dict: [String: Any]) -> String? {
        if let origin = dict["originUrl"] as? String {
            return transformXhsCdnUrl(origin)
        }
        if let defaultUrl = dict["urlDefault"] as? String {
            return transformXhsCdnUrl(defaultUrl)
        }
        if let url = dict["url"] as? String {
            return transformXhsCdnUrl(url)
        }
        if let traceId = dict["traceId"] as? String {
            return transformXhsCdnUrl("https://sns-img-qc.xhscdn.com/\(traceId)")
        }
        if let infoList = dict["infoList"] as? [[String: Any]] {
            for info in infoList {
                if let url = info["url"] as? String {
                    return transformXhsCdnUrl(url)
                }
            }
        }
        return nil
    }

    func extractUrlsFromHtml(_ html: String) -> [String] {
        var urls: [String] = []
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        htmlImgRegex.enumerateMatches(in: html, options: [], range: fullRange) { result, _, _ in
            guard let range = result?.range(at: 1) else { return }
            let url = nsHTML.substring(with: range)
            if isValidMediaUrl(url) {
                urls.append(url)
            }
        }

        htmlUrlRegex.enumerateMatches(in: html, options: [], range: fullRange) { result, _, _ in
            guard let range = result?.range else { return }
            let url = nsHTML.substring(with: range)
            if isValidMediaUrl(url) {
                urls.append(url)
            }
        }

        return urls
    }

    func buildRemoteMedia(from urls: [String], postId: String?) -> [RemoteMedia] {
        var results: [RemoteMedia] = []
        let base = postId ?? UUID().uuidString.prefix(8).description
        for (index, raw) in urls.enumerated() {
            guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                  let originalURL = URL(string: encoded) ?? URL(string: raw) else { continue }
            let type: RemoteMedia.MediaType = isVideoUrl(raw) ? .video : .image
            let normalizedURL: URL
            if type == .image {
                let transformedString = transformXhsCdnUrl(raw)
                normalizedURL = URL(string: transformedString) ?? originalURL
            } else {
                normalizedURL = originalURL
            }
            let baseName = "\(base)_\(index + 1)"
            results.append(RemoteMedia(url: normalizedURL, type: type, fileBaseName: baseName, originalURLString: raw))
        }
        return results
    }

    func extractPostId(from url: String) -> String? {
        if let match = idRegex.firstMatch(in: url, options: [], range: NSRange(location: 0, length: (url as NSString).length)) {
            return (url as NSString).substring(with: match.range(at: 1))
        }
        if let match = idUserRegex.firstMatch(in: url, options: [], range: NSRange(location: 0, length: (url as NSString).length)) {
            return (url as NSString).substring(with: match.range(at: 1))
        }
        if url.contains("xhslink.com/") {
            let components = url.split(separator: "/").map(String.init)
            if let last = components.last?.split(separator: "?").first, !last.isEmpty, last != "o" {
                return String(last)
            } else if components.count > 1 {
                let secondLast = components[components.count - 2]
                return secondLast.split(separator: "?").first.map(String.init)
            }
        }
        return nil
    }

    func isValidMediaUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("xhscdn.com") {
            return true
        }
        return lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png") ||
            lower.contains(".gif") || lower.contains(".webp") || lower.contains(".mp4") ||
            lower.contains(".mov")
    }

    func isVideoUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".avi") ||
            lower.contains(".webm") || lower.contains("video") || lower.contains("stream") ||
            lower.contains("sns-video")
    }

    func transformXhsCdnUrl(_ originalUrl: String) -> String {
        guard originalUrl.contains("xhscdn.com"),
              !originalUrl.contains("video"),
              !originalUrl.contains("sns-video"),
              let token = extractImageToken(from: originalUrl) else { return originalUrl }

        return "https://ci.xiaohongshu.com/\(token)?imageView2/format/png"
    }

    func extractImageToken(from url: String) -> String? {
        var sanitized = url
        sanitized = sanitized.replacingOccurrences(of: "\\/", with: "/")
        sanitized = sanitized.replacingOccurrences(of: "\\u002F", with: "/")
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        if let httpRange = sanitized.range(of: "http", options: .caseInsensitive) {
            sanitized = String(sanitized[httpRange.lowerBound...])
        }

        let parts = sanitized.components(separatedBy: "/")
        guard parts.count > 5 else { return nil }

        let tokenSection = parts[5...].joined(separator: "/")
        let strippedBang = tokenSection.split(separator: "!").first ?? Substring(tokenSection)
        let strippedQuery = strippedBang.split(separator: "?").first ?? strippedBang
        let token = String(strippedQuery)
        return token.isEmpty ? nil : token
    }

    func determineFileExtension(from response: URLResponse?, fallbackURL: URL, mediaType: RemoteMedia.MediaType) -> String {
        if let http = response as? HTTPURLResponse,
           let mimeType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mimeType.contains("png") { return "png" }
            if mimeType.contains("webp") { return "webp" }
            if mimeType.contains("gif") { return "gif" }
            if mimeType.contains("jpeg") || mimeType.contains("jpg") { return "jpg" }
            if mimeType.contains("mp4") { return "mp4" }
            if mimeType.contains("quicktime") { return "mov" }
        }

        let ext = fallbackURL.pathExtension.lowercased()
        if !ext.isEmpty {
            return ext
        }

        return mediaType == .video ? "mp4" : "jpg"
    }
}
