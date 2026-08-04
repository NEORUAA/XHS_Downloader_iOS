import SwiftUI
import Photos
import PhotosUI
import WebKit
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var coordinator: DownloadCoordinator
    @ObservedObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var filter: TaskFilter = .all
    @State private var showsSettings = false
    @State private var showsManualInput = false
    @State private var showsWebCapture = false
    @State private var clipboardHasLink = false
    @State private var taskToDelete: DownloadTaskRecord?

    var body: some View {
        Group {
            if #available(iOS 16, *) {
                NavigationStack { taskCenter }
            } else {
                NavigationView { taskCenter }
                    .navigationViewStyle(.stack)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(settings: settings)
        }
        .sheet(isPresented: $showsManualInput) {
            ManualInputView(coordinator: coordinator)
        }
        .sheet(isPresented: $showsWebCapture) {
            WebCaptureView { text in coordinator.enqueue(text) }
        }
        .sheet(item: $coordinator.selectionState) { _ in
            SelectiveDownloadView(coordinator: coordinator)
                .interactiveDismissDisabled()
        }
        .alert(
            L10n.text("common.notice"),
            isPresented: Binding(
                get: { coordinator.alertMessage != nil },
                set: { if !$0 { coordinator.alertMessage = nil } }
            ),
            actions: { Button(L10n.text("common.ok"), role: .cancel) { coordinator.alertMessage = nil } },
            message: { Text(coordinator.alertMessage ?? "") }
        )
        .confirmationDialog(
            L10n.text("task.delete.title"),
            isPresented: Binding(
                get: { taskToDelete != nil },
                set: { if !$0 { taskToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let task = taskToDelete {
                Button(L10n.text("task.delete.history"), role: .destructive) {
                    Task { await coordinator.deleteTask(taskID: task.id, deletePhotos: false) }
                    taskToDelete = nil
                }
                if !task.mediaAssets.isEmpty {
                    Button(L10n.text("task.delete.photos"), role: .destructive) {
                        Task { await coordinator.deleteTask(taskID: task.id, deletePhotos: true) }
                        taskToDelete = nil
                    }
                }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { taskToDelete = nil }
        }
        .onAppear {
            coordinator.consumeSharedInbox()
            refreshClipboardSuggestionFromPasteboard()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                coordinator.consumeSharedInbox()
                refreshClipboardSuggestionFromPasteboard()
                UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
            }
        }
    }

    private var taskCenter: some View {
        List {
            Section {
                filterPicker
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            let visibleTasks = coordinator.filteredTasks(for: filter)
            if visibleTasks.isEmpty {
                Section {
                    ContentUnavailableCard(filter: filter)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(visibleTasks) { task in
                        NavigationLink {
                            TaskDetailView(taskID: task.id, coordinator: coordinator)
                        } label: {
                            TaskCardView(task: task, coordinator: coordinator)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { taskToDelete = task } label: {
                                Label(L10n.text("common.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .xhsCompactSectionSpacing()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            floatingBottomActions
        }
        .accessibilityIdentifier("task-center-list")
        .navigationTitle(L10n.text("app.title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L10n.text("settings.title"))
            }
        }
    }

    private var filterPicker: some View {
        Picker(L10n.text("filter.title"), selection: $filter) {
            Text(L10n.text("filter.all")).tag(TaskFilter.all)
            Text(L10n.format("filter.waiting.count", coordinator.waitingCount)).tag(TaskFilter.waiting)
            Text(L10n.format("filter.failed.count", coordinator.failedCount)).tag(TaskFilter.failed)
        }
        .pickerStyle(.segmented)
        .padding(.top, 4)
    }

    private var clipboardSuggestion: some View {
        Button {
            if let text = UIPasteboard.general.string {
                coordinator.enqueue(text)
                clipboardHasLink = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.title3)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("clipboard.suggestion.title"))
                        .font(.headline)
                    Text(L10n.text("clipboard.suggestion.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(width: 320, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var clipboardSuggestionPopoverContent: some View {
        if #available(iOS 16.4, *) {
            clipboardSuggestion
                .presentationCompactAdaptation(.popover)
        } else {
            clipboardSuggestion
        }
    }

    private var floatingBottomActions: some View {
        HStack(spacing: 12) {
            primaryAction
                .frame(maxWidth: .infinity, minHeight: 56)
                .popover(
                    isPresented: Binding(
                        get: { clipboardHasLink && settings.clipboardSuggestions },
                        set: { if !$0 { clipboardHasLink = false } }
                    ),
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    clipboardSuggestionPopoverContent
                }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            Menu {
                Button { showsManualInput = true } label: {
                    Label(L10n.text("action.manual_input"), systemImage: "keyboard")
                }
                Button { showsWebCapture = true } label: {
                    Label(L10n.text("action.web_capture"), systemImage: "safari")
                }
                if !coordinator.tasks.isEmpty {
                    Button(role: .destructive) { coordinator.clearHistory() } label: {
                        Label(L10n.text("action.clear_history"), systemImage: "trash.slash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 56, height: 56)
            .xhsCircularGlass()
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .accessibilityLabel(L10n.text("common.more"))
            .accessibilityIdentifier("more-actions-button")
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if #available(iOS 16, *) {
            FullWidthPasteControl { values in
                coordinator.enqueue(values.joined(separator: "\n"))
                clipboardHasLink = false
            }
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
            .xhsPrimaryGlass()
        } else {
            Button {
                if let text = UIPasteboard.general.string { coordinator.enqueue(text) }
            } label: {
                primaryActionLabel
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(height: 56)
            .xhsPrimaryGlass()
            .accessibilityIdentifier("primary-paste-button")
        }
    }

    private var primaryActionLabel: some View {
        Label(L10n.text("action.paste_download"), systemImage: "arrow.down.circle.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private func refreshClipboardSuggestionFromPasteboard() {
        guard settings.clipboardSuggestions,
              UIPasteboard.general.hasStrings,
              let text = UIPasteboard.general.string else {
            clipboardHasLink = false
            return
        }
        clipboardHasLink = XHSURLDetector.containsSupportedLink(text)
    }
}

@available(iOS 16.0, *)
private struct FullWidthPasteControl: UIViewRepresentable {
    let onPaste: ([String]) -> Void

    func makeUIView(context: Context) -> PasteControlContainerView {
        PasteControlContainerView(onPaste: onPaste)
    }

    func updateUIView(_ uiView: PasteControlContainerView, context: Context) {
        uiView.onPaste = onPaste
    }
}

@available(iOS 16.0, *)
private final class PasteControlContainerView: UIView {
    var onPaste: ([String]) -> Void

    private let pasteControl: UIPasteControl

    init(onPaste: @escaping ([String]) -> Void) {
        self.onPaste = onPaste

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .labelOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 18
        configuration.baseForegroundColor = .clear
        configuration.baseBackgroundColor = .clear
        pasteControl = UIPasteControl(configuration: configuration)

        super.init(frame: .zero)

        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.url.identifier]
        )
        pasteControl.target = self
        pasteControl.translatesAutoresizingMaskIntoConstraints = false
        pasteControl.backgroundColor = .clear
        // Keep the system paste control in the hit-test chain while letting the
        // app's accent-tinted glass surface provide the visible appearance.
        pasteControl.layer.opacity = 0.011
        pasteControl.accessibilityIdentifier = "primary-paste-button"
        pasteControl.accessibilityLabel = L10n.text("action.paste_download")
        addSubview(pasteControl)

        let iconView = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
        iconView.tintColor = .white
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = L10n.text("action.paste_download")
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.adjustsFontSizeToFitWidth = true

        let contentStack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentOverlay = UIView()
        if #available(iOS 26.0, *) {
            contentOverlay.backgroundColor = .clear
        } else {
            contentOverlay.backgroundColor = .tintColor
        }
        contentOverlay.layer.cornerRadius = 18
        contentOverlay.layer.cornerCurve = .continuous
        contentOverlay.clipsToBounds = true
        contentOverlay.isUserInteractionEnabled = false
        contentOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlay.addSubview(contentStack)
        addSubview(contentOverlay)

        NSLayoutConstraint.activate([
            pasteControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            pasteControl.trailingAnchor.constraint(equalTo: trailingAnchor),
            pasteControl.topAnchor.constraint(equalTo: topAnchor),
            pasteControl.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentOverlay.topAnchor.constraint(equalTo: topAnchor),
            contentOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.centerXAnchor.constraint(equalTo: contentOverlay.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: contentOverlay.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentOverlay.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentOverlay.trailingAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func paste(itemProviders: [NSItemProvider]) {
        let acceptableProviders = itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !acceptableProviders.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var values: [String] = []

        for provider in acceptableProviders {
            let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                ? UTType.url.identifier
                : UTType.plainText.identifier
            group.enter()
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let value: String?
                switch item {
                case let string as String:
                    value = string
                case let url as URL:
                    value = url.absoluteString
                case let data as Data:
                    value = String(data: data, encoding: .utf8)
                default:
                    value = nil
                }
                if let value, !value.isEmpty {
                    lock.lock()
                    values.append(value)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.onPaste(values)
        }
    }
}

private struct TaskCardView: View {
    let task: DownloadTaskRecord
    @ObservedObject var coordinator: DownloadCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text(task.status.localizationKey), systemImage: statusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                Spacer()
                Text(task.updatedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(task.title.isEmpty ? L10n.text("task.resolving") : task.title)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text(L10n.text(task.noteType.localizationKey))
                Spacer()
                Text(L10n.format("task.media_count", task.savedCount, task.mediaCount))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            ProgressView(value: task.progress)
                .tint(statusColor)

            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                if task.status == .downloading || task.status == .queued {
                    Button(L10n.text("action.stop")) { coordinator.stop(taskID: task.id) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
                if task.status == .failed {
                    Button(L10n.text("action.retry")) { coordinator.retry(taskID: task.id) }
                        .buttonStyle(.bordered)
                }
                if task.status == .waitingForUser {
                    Label(L10n.text("action.choose_media"), systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch task.status {
        case .queued: return .secondary
        case .downloading: return .blue
        case .completed: return .green
        case .failed: return .red
        case .waitingForUser: return .orange
        }
    }

    private var statusSymbol: String {
        switch task.status {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .waitingForUser: return "hand.tap.fill"
        }
    }
}

private struct ContentUnavailableCard: View {
    let filter: TaskFilter

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: filter == .all ? "arrow.down.doc" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(L10n.text(filter == .all ? "empty.title" : "empty.filtered.title"))
                .font(.headline)
            Text(L10n.text(filter == .all ? "empty.subtitle" : "empty.filtered.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }
}

private struct TaskDetailView: View {
    let taskID: UUID
    @ObservedObject var coordinator: DownloadCoordinator
    @State private var section = 0
    @State private var previewIdentifier: String?
    @State private var confirmsPhotoDeletion = false

    private var task: DownloadTaskRecord? {
        coordinator.tasks.first { $0.id == taskID }
    }

    var body: some View {
        Group {
            if let task {
                ScrollView {
                    VStack(spacing: 16) {
                        Picker(L10n.text("detail.section"), selection: $section) {
                            Text(L10n.text("detail.files")).tag(0)
                            Text(L10n.text("detail.caption")).tag(1)
                        }
                        .pickerStyle(.segmented)

                        if section == 0 {
                            mediaSection(task)
                        } else {
                            captionSection(task)
                        }
                    }
                    .padding()
                }
                .navigationTitle(task.title.isEmpty ? L10n.text("detail.title") : task.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ShareSheetButton(items: shareItems(task))
                    }
                }
                .sheet(item: Binding(
                    get: { previewIdentifier.map(PreviewIdentifier.init) },
                    set: { previewIdentifier = $0?.value }
                )) { item in
                    PhotoPreview(localIdentifier: item.value)
                }
            } else {
                Text(L10n.text("error.task_missing"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func mediaSection(_ task: DownloadTaskRecord) -> some View {
        if task.mediaAssets.isEmpty {
            ContentUnavailableCard(filter: .all)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(task.mediaAssets) { asset in
                    Button { previewIdentifier = asset.localIdentifier } label: {
                        VStack(spacing: 0) {
                            ZStack(alignment: .bottomTrailing) {
                                PhotoAssetThumbnail(localIdentifier: asset.localIdentifier)
                                    .frame(minHeight: 150)
                                if asset.isVideo {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 3)
                                        .padding(8)
                                }
                            }
                            MediaAssetMetadataFooter(asset: asset)
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(role: .destructive) { confirmsPhotoDeletion = true } label: {
                Label(L10n.text("task.delete.photos"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .confirmationDialog(
                L10n.text("task.delete.photos.confirm"),
                isPresented: $confirmsPhotoDeletion,
                titleVisibility: .visible
            ) {
                Button(L10n.text("task.delete.photos"), role: .destructive) {
                    Task { await coordinator.deleteTask(taskID: task.id, deletePhotos: true) }
                }
                Button(L10n.text("common.cancel"), role: .cancel) {}
            }
        }
    }

    private func captionSection(_ task: DownloadTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task.noteText.isEmpty ? L10n.text("detail.no_caption") : task.noteText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = task.noteText
            } label: {
                Label(L10n.text("action.copy_caption"), systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(task.noteText.isEmpty)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func shareItems(_ task: DownloadTaskRecord) -> [Any] {
        var items: [Any] = []
        if !task.noteText.isEmpty { items.append(task.noteText) }
        if let url = URL(string: task.normalizedURL) { items.append(url) }
        return items
    }
}

private struct PreviewIdentifier: Identifiable {
    let value: String
    var id: String { value }
}

private struct PhotoAssetThumbnail: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay { ProgressView() }
            }
        }
        .clipped()
        .task(id: localIdentifier) { load() }
    }

    private func load() {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 500, height: 500),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            if let image { self.image = image }
        }
    }
}


private struct MediaAssetMetadataFooter: View {
    let asset: MediaAssetRecord

    @State private var fallbackPixelWidth: Int?
    @State private var fallbackPixelHeight: Int?
    @State private var fallbackByteCount: Int64?
    @State private var resourceRequestID: PHAssetResourceDataRequestID?

    private var pixelWidth: Int? { asset.pixelWidth ?? fallbackPixelWidth }
    private var pixelHeight: Int? { asset.pixelHeight ?? fallbackPixelHeight }
    private var byteCount: Int64? { asset.byteCount ?? fallbackByteCount }

    var body: some View {
        HStack(spacing: 6) {
            Text(resolutionText)
            Spacer(minLength: 4)
            Text(fileSizeText)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .task(id: asset.localIdentifier) { loadFallbackMetadata() }
        .onDisappear { cancelResourceRequest() }
    }

    private var resolutionText: String {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return "—" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    private var fileSizeText: String {
        guard let byteCount, byteCount > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func loadFallbackMetadata() {
        guard let photoAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.localIdentifier],
            options: nil
        ).firstObject else { return }

        if asset.pixelWidth == nil || asset.pixelHeight == nil {
            fallbackPixelWidth = photoAsset.pixelWidth
            fallbackPixelHeight = photoAsset.pixelHeight
        }

        guard asset.byteCount == nil, resourceRequestID == nil else { return }
        let resources = PHAssetResource.assetResources(for: photoAsset)
        let preferredType: PHAssetResourceType = asset.isVideo ? .video : .photo
        guard let resource = resources.first(where: { $0.type == preferredType }) ?? resources.first else { return }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let lock = NSLock()
        var receivedByteCount: Int64 = 0
        resourceRequestID = PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in
                lock.lock()
                receivedByteCount += Int64(data.count)
                lock.unlock()
            },
            completionHandler: { error in
                lock.lock()
                let finalByteCount = receivedByteCount
                lock.unlock()
                DispatchQueue.main.async {
                    if error == nil, finalByteCount > 0 {
                        fallbackByteCount = finalByteCount
                    }
                    resourceRequestID = nil
                }
            }
        )
    }

    private func cancelResourceRequest() {
        guard let resourceRequestID else { return }
        PHAssetResourceManager.default().cancelDataRequest(resourceRequestID)
        self.resourceRequestID = nil
    }
}

private struct PhotoPreview: View {
    let localIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.text("common.done")) { dismiss() }
                }
            }
        }
        .task { load() }
    }

    private func load() {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            if let data { image = UIImage(data: data) }
        }
    }
}

private struct SelectiveDownloadView: View {
    @ObservedObject var coordinator: DownloadCoordinator

    private var state: SelectiveDownloadState? { coordinator.selectionState }

    private func masonryColumns(for items: [SelectiveMediaItem]) -> [[SelectiveMediaItem]] {
        var columns: [[SelectiveMediaItem]] = [[], []]
        var estimatedHeights: [CGFloat] = [0, 0]

        for item in items {
            let targetColumn = estimatedHeights[0] <= estimatedHeights[1] ? 0 : 1
            columns[targetColumn].append(item)
            estimatedHeights[targetColumn] += (1 / thumbnailAspectRatio(for: item)) + 0.08
        }
        return columns
    }

    private func thumbnailAspectRatio(for item: SelectiveMediaItem) -> CGFloat {
        guard !item.remote.isVideo, let image = UIImage(contentsOfFile: item.cachedURL.path), image.size.height > 0 else {
            return 9 / 16
        }
        return min(max(image.size.width / image.size.height, 0.5), 1.8)
    }

    private func selectiveMediaTile(_ item: SelectiveMediaItem) -> some View {
        Button {
            coordinator.updateSelection(id: item.id, selected: !item.isSelected)
        } label: {
            ZStack(alignment: .topTrailing) {
                CachedMediaThumbnail(item: item)
                    .aspectRatio(thumbnailAspectRatio(for: item), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, item.isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationView {
            Group {
                if let state {
                    ScrollView {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(masonryColumns(for: state.items).enumerated()), id: \.offset) { _, column in
                                LazyVStack(spacing: 12) {
                                    ForEach(column) { item in
                                        selectiveMediaTile(item)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                        .padding()
                    }
                    .overlay {
                        if state.phase == .caching || state.phase == .saving {
                            ZStack {
                                Color.black.opacity(0.12).ignoresSafeArea()
                                ProgressView(state.phase == .caching ? L10n.text("selection.caching") : L10n.text("selection.saving"))
                                    .padding(24)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L10n.text("selection.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { coordinator.cancelSelection() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("selection.save")) { coordinator.saveSelection() }
                        .disabled(state?.phase != .ready || state?.items.contains(where: \.isSelected) != true)
                }
                ToolbarItem(placement: .bottomBar) {
                    Text(L10n.format("selection.count", state?.items.filter(\.isSelected).count ?? 0, state?.items.count ?? 0))
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }
}

private struct CachedMediaThumbnail: View {
    let item: SelectiveMediaItem

    var body: some View {
        ZStack {
            if item.remote.isVideo {
                Rectangle().fill(Color.black)
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            } else if let image = UIImage(contentsOfFile: item.cachedURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}

private struct ManualInputView: View {
    @ObservedObject var coordinator: DownloadCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isExtracting = false
    @State private var extractedCaption = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L10n.text("manual.section.input"))) {
                    TextEditor(text: $input)
                        .frame(minHeight: 150)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !extractedCaption.isEmpty {
                    Section(header: Text(L10n.text("detail.caption"))) {
                        Text(extractedCaption).textSelection(.enabled)
                        Button(L10n.text("action.copy_caption")) { UIPasteboard.general.string = extractedCaption }
                    }
                }
            }
            .navigationTitle(L10n.text("action.manual_input"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        extractCaption()
                    } label: {
                        if isExtracting { ProgressView() } else { Image(systemName: "text.quote") }
                    }
                    .disabled(isExtracting || !XHSURLDetector.containsSupportedLink(input))
                    Button(L10n.text("action.download")) {
                        coordinator.enqueue(input)
                        dismiss()
                    }
                    .disabled(!XHSURLDetector.containsSupportedLink(input))
                }
            }
        }
    }

    private func extractCaption() {
        isExtracting = true
        Task {
            do {
                extractedCaption = try await XHSDownloader().extractDescription(from: input) { _ in }
            } catch {
                coordinator.alertMessage = error.localizedDescription
            }
            isExtracting = false
        }
    }
}

private struct WebCaptureView: View {
    let onCapture: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = "https://www.xiaohongshu.com/"
    @State private var capturedURL = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    TextField(L10n.text("web.address"), text: $address)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L10n.text("web.go")) {
                        NotificationCenter.default.post(name: .xhsWebNavigate, object: address)
                    }
                }
                .padding()
                ControlledWebView(initialAddress: address) { url in capturedURL = url }
            }
            .navigationTitle(L10n.text("action.web_capture"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("web.import")) {
                        onCapture(capturedURL.isEmpty ? address : capturedURL)
                        dismiss()
                    }
                    .disabled(!XHSURLDetector.containsSupportedLink(capturedURL.isEmpty ? address : capturedURL))
                }
            }
        }
    }
}

private extension Notification.Name {
    static let xhsWebNavigate = Notification.Name("xhs.web.navigate")
}

private struct ControlledWebView: UIViewRepresentable {
    let initialAddress: String
    let onURLChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onURLChange: onURLChange) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .xhsWebNavigate, object: nil, queue: .main) { [weak webView] note in
            guard let value = note.object as? String, let url = URL(string: value) else { return }
            webView?.load(URLRequest(url: url))
        }
        if let url = URL(string: initialAddress) { webView.load(URLRequest(url: url)) }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onURLChange: (String) -> Void
        weak var webView: WKWebView?
        var observer: NSObjectProtocol?

        init(onURLChange: @escaping (String) -> Void) { self.onURLChange = onURLChange }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = "document.querySelector('link[rel=canonical]')?.href || location.href"
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                if let value = value as? String { self?.onURLChange(value) }
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NamingPreferences.enableKey) private var customNaming = false
    @AppStorage(NamingPreferences.templateKey) private var namingTemplate = NamingFormatter.defaultTemplate

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L10n.text("settings.download"))) {
                    Toggle(L10n.text("settings.live_photo"), isOn: $settings.createLivePhotos)
                    Toggle(L10n.text("settings.selective"), isOn: $settings.selectiveDownload)
                    Toggle(L10n.text("settings.keep_awake"), isOn: $settings.keepScreenAwake)
                }
                Section(header: Text(L10n.text("settings.system"))) {
                    Toggle(L10n.text("settings.clipboard"), isOn: $settings.clipboardSuggestions)
                    Toggle(L10n.text("settings.notifications"), isOn: $settings.debugNotifications)
                }
                Section(header: Text(L10n.text("settings.naming"))) {
                    Toggle(L10n.text("settings.naming.enable"), isOn: $customNaming)
                    if customNaming {
                        TextField(L10n.text("settings.naming.template"), text: $namingTemplate)
                            .textInputAutocapitalization(.never)
                        Text(L10n.text("settings.naming.placeholders"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(header: Text(L10n.text("settings.about"))) {
                    HStack {
                        Text(L10n.text("settings.version"))
                        Spacer()
                        Text(version).foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://github.com/NEORUAA/XHS_Downloader_iOS")!) {
                        Label(L10n.text("settings.github"), systemImage: "link")
                    }
                }
            }
            .navigationTitle(L10n.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.done")) { dismiss() }
                }
            }
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}

private struct ShareSheetButton: View {
    let items: [Any]
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel(L10n.text("common.share"))
            .sheet(isPresented: $presented) { ActivityView(items: items) }
            .disabled(items.isEmpty)
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension View {
    @ViewBuilder
    func xhsCompactSectionSpacing() -> some View {
        if #available(iOS 17.0, *) {
            self.listSectionSpacing(12)
        } else {
            self
        }
    }

    @ViewBuilder
    func xhsPrimaryGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(
                .regular.tint(.accentColor).interactive(),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            self.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    func xhsCircularGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
        } else {
            self.background(Color.accentColor, in: Circle())
        }
    }
}

#Preview {
    let settings = AppSettings()
    ContentView(coordinator: DownloadCoordinator(settings: settings), settings: settings)
}
