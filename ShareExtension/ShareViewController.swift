import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private struct InboxItem: Codable {
        let id: UUID
        let text: String
        let createdAt: Date
    }

    private static let suiteName = "group.com.neoruaa.xhsdn"
    private static let inboxKey = "shared_inbox_items"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectSharedContent()
    }

    private func collectSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var values: [String] = []

        for provider in providers {
            let typeIdentifier: String?
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                typeIdentifier = UTType.url.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                typeIdentifier = UTType.plainText.identifier
            } else {
                typeIdentifier = nil
            }

            guard let typeIdentifier else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { value, _ in
                defer { group.leave() }
                let text: String?
                if let url = value as? URL {
                    text = url.absoluteString
                } else if let data = value as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = value as? String
                }

                if let text, !text.isEmpty {
                    lock.lock()
                    values.append(text)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if !values.isEmpty {
                Self.appendToInbox(values.joined(separator: "\n"))
            }
            self?.finish()
        }
    }

    private static func appendToInbox(_ text: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var items: [InboxItem] = []

        if let data = defaults.data(forKey: inboxKey),
           let decoded = try? decoder.decode([InboxItem].self, from: data) {
            items = decoded
        }

        items.append(InboxItem(id: UUID(), text: text, createdAt: Date()))
        if let data = try? encoder.encode(items) {
            defaults.set(data, forKey: inboxKey)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
