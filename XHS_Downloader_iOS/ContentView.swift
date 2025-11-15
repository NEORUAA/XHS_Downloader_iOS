//
//  ContentView.swift
//  XHS_Downloader_iOS
//
//  Created by NEORUAA Q on 2025/11/15.
//

import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = DownloaderViewModel()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                topBar
                upperSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomPanel
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $viewModel.showSettingsSheet) {
            SettingsSheet()
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.visible)
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("小红书下载器v\(appVersion)")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("无损分辨率 & 无水印")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .glassEffect()
        }
    }

    private var upperSection: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(spacing: 16) {
                LogListView(logs: viewModel.logEntries)
                    .frame(height: height * 0.3)
                MediaGridView(items: viewModel.mediaItems)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("输入分享文本")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ShareInputField(text: $viewModel.shareText)
            }

            Button {
                viewModel.startDownload()
            } label: {
                HStack {
                    Spacer()
                    Text(viewModel.isDownloading ? "正在下载…" : "下载媒体")
                        .fontWeight(.semibold)
                        .padding(10)
                    Spacer()
                }
            }
            .glassEffect()
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isDownloading)

            if viewModel.showProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("下载进度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.progressText)
                            .font(.footnote)
                            .monospacedDigit()
                    }
                    ProgressView(value: viewModel.progressValue)
                        .progressViewStyle(.linear)
                }
            }
        }
//        .padding(18)
//        .background(
//            RoundedRectangle(cornerRadius: 24, style: .continuous)
//                .fill(.thinMaterial)
//        )
    }
}

struct ShareInputField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool
    private let placeholder = "苹果iPhone原生4K壁... http://xhslink.com/o/8xU2muQboVH 复制后打开【小红书】查看笔记！"

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                ZStack(alignment: .topTrailing) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .focused($isFocused)

                    if !text.isEmpty {
                        ClearButton(text: $text)
                            .padding(.trailing, 8)
                            .padding(.top, 8)
                    }
                }
            } else {
                legacyTextEditor
            }
        }
    }

    private var legacyTextEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .focused($isFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(minHeight: 90, maxHeight: 130)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if !text.isEmpty {
                        ClearButton(text: $text)
                            .padding(12)
                    }
                }
        }
    }

    private struct ClearButton: View {
        @Binding var text: String

        var body: some View {
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }
}

struct LogListView: View {
    let logs: [LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if logs.isEmpty {
                        Text("实时日志会显示在此处")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(logs) { log in
                            Text(log.displayText)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.primary)
                                .padding(.vertical, 2)
                                .id(log.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)
            )
            .onChange(of: logs.last?.id) { id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct MediaGridView: View {
    let items: [MediaPreviewItem]
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("下载的图片和视频会显示在这里")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { item in
                            MediaTile(item: item)
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)
            )
            .padding(.bottom, 2)
            .onChange(of: items.last?.id) { id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct MediaTile: View {
    let item: MediaPreviewItem
    @State private var thumbnail: UIImage?
    @State private var aspectRatio: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
            }

            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(8)
            }
        }
        .task(id: item.id) {
            if let image = await ThumbnailGenerator.shared.thumbnail(for: item) {
                await MainActor.run {
                    thumbnail = image
                    let ratio = image.size.width / max(image.size.height, 1)
                    aspectRatio = ratio.isFinite && ratio > 0 ? ratio : 1
                }
            }
        }
    }
}

struct SettingsSheet: View {
    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.secondary.opacity(0))
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            Text("设置")
                .font(.title3)
                .fontWeight(.semibold)

            Spacer()

            Text("设置内容即将上线，敬请期待")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .padding(.bottom, 24)
    }
}

private actor ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    func thumbnail(for item: MediaPreviewItem) async -> UIImage? {
        if item.isVideo {
            let asset = AVAsset(url: item.localURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
            return nil
        } else {
            return UIImage(contentsOfFile: item.localURL.path)
        }
    }
}

private extension View {
    @ViewBuilder
    func ifAvailableiOS16<Content: View>(_ transform: (Self) -> Content) -> some View {
        if #available(iOS 16.0, *) {
            transform(self)
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
}
