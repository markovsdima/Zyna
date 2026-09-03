//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

enum RoomAttachmentsMetrics {
    static let columns = 3
    static let spacing: CGFloat = 2

    /// Tile derivative size in pixels, bucketed to 32 so cache keys stay
    /// stable across small layout differences.
    static func tilePixelSize(
        screenWidth: CGFloat = ScreenConstants.width,
        scale: CGFloat = ScreenConstants.scale
    ) -> Int {
        let column = (screenWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let pixels = column * scale
        return max(32, Int((pixels / 32).rounded(.up)) * 32)
    }
}

/// R&D screen: room attachments from a second SDK timeline.
struct RoomAttachmentsView: View {

    @ObservedObject var viewModel: RoomAttachmentsViewModel
    let actions: RoomAttachmentsActions

    #if DEBUG
    @State private var showDiagnostics = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.pendingDecryptionCount > 0 {
                pendingBanner
            }
            content
        }
        .background(Color.appBackground)
        .task {
            await viewModel.start()
        }
        .alert(
            "Download failed",
            isPresented: Binding(
                get: { viewModel.downloadError != nil },
                set: { if !$0 { viewModel.downloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.downloadError = nil }
        } message: {
            Text(viewModel.downloadError ?? "")
        }
        #if DEBUG
        .overlay(alignment: .bottom) {
            if showDiagnostics {
                RoomAttachmentsDiagnosticsPanel(viewModel: viewModel)
            }
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $viewModel.tab) {
                ForEach(RoomAttachmentsViewModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            #if DEBUG
            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityLabel("Diagnostics")
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var pendingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(Color.appAccent)
            Text("\(viewModel.pendingDecryptionCount) messages are waiting for keys")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Retry")) {
                viewModel.retryDecryption(reason: "banner")
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let startError = viewModel.startError {
            VStack(spacing: 12) {
                Text("Couldn't load attachments.")
                Text(startError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isInitialLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewModel.tab {
            case .media:
                mediaGrid
            case .files:
                filesList
            }
        }
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: RoomAttachmentsMetrics.spacing),
            count: RoomAttachmentsMetrics.columns
        )
    }

    @ViewBuilder
    private var mediaGrid: some View {
        if viewModel.media.isEmpty, viewModel.fillState == .exhausted {
            emptyState(icon: "photo.on.rectangle", text: String(localized: "No photos or videos yet."))
        } else {
            ScrollView {
                LazyVGrid(
                    columns: gridColumns,
                    spacing: RoomAttachmentsMetrics.spacing,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(viewModel.media) { group in
                        Section {
                            ForEach(group.items) { item in
                                tile(for: item)
                            }
                        } header: {
                            monthHeader(group.title)
                        }
                    }
                }
                footer
            }
        }
    }

    @ViewBuilder
    private var filesList: some View {
        if viewModel.files.isEmpty, viewModel.fillState == .exhausted {
            emptyState(icon: "doc", text: String(localized: "No files yet."))
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.files) { group in
                        Section {
                            ForEach(group.items) { item in
                                AttachmentFileRow(item: item, progress: viewModel.downloadProgress[item.id])
                                    .onTapGesture {
                                        openFile(item)
                                    }
                                Divider()
                                    .padding(.leading, 72)
                            }
                        } header: {
                            monthHeader(group.title)
                        }
                    }
                }
                footer
            }
        }
    }

    private func tile(for item: AttachmentItem) -> some View {
        let plan = viewModel.plan(for: item)
        return AttachmentGridTile(
            item: item,
            tilePixelSize: viewModel.tilePixelSize,
            plan: plan,
            onTap: { frame in
                openMedia(item, sourceFrame: frame)
            },
            onRequestLoad: {
                viewModel.requestLoad(item)
            },
            onLoaded: { stats in
                viewModel.recordTile(item, plan: plan, stats: stats)
            }
        )
    }

    private func monthHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.appBackground)
    }

    /// Wrapped in a lazy container so `onAppear` fires reliably.
    private var footer: some View {
        LazyVStack(spacing: 10) {
            if isBusy {
                ProgressView()
            }
            switch viewModel.fillState {
            case .capped:
                Button(String(localized: "Load More")) {
                    viewModel.loadMoreTapped()
                }
                .font(.footnote.weight(.semibold))
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "Try Again")) {
                    viewModel.loadMoreTapped()
                }
                .font(.footnote.weight(.semibold))
            default:
                EmptyView()
            }
            Color.clear
                .frame(height: 1)
                .onAppear { viewModel.sentinelAppeared() }
                .onDisappear { viewModel.sentinelDisappeared() }
        }
        .padding(.vertical, 12)
    }

    private var isBusy: Bool {
        if case .filling = viewModel.fillState { return true }
        if case .settling = viewModel.fillState { return true }
        if case .paginating = viewModel.sdkPaginationStatus { return true }
        return false
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Opening

    private func openMedia(_ item: AttachmentItem, sourceFrame: CGRect) {
        switch item.kind {
        case .image:
            let images = viewModel.allImages
            guard let index = images.firstIndex(where: { $0.id == item.id }) else { return }
            let items = images.map { image in
                ImageViewerController.Item(
                    previewImage: viewModel.previewImage(for: image),
                    mediaSource: image.source,
                    sourceFrame: image.id == item.id ? sourceFrame : .zero
                )
            }
            actions.openImages(items, index)
        case .video:
            guard viewModel.beginDownload(item.id) else { return }
            let preview = viewModel.previewImage(for: item)
            let itemId = item.id
            let model = viewModel
            // Weak: a download in flight must not keep a popped screen's model alive.
            actions.openVideo(item, preview, sourceFrame) { [weak model] event in
                Task { @MainActor in
                    model?.handleDownloadEvent(event, for: itemId)
                }
            }
        default:
            openFile(item)
        }
    }

    private func openFile(_ item: AttachmentItem) {
        guard viewModel.beginDownload(item.id) else { return }
        let itemId = item.id
        let model = viewModel
        actions.openFile(item) { [weak model] event in
            Task { @MainActor in
                model?.handleDownloadEvent(event, for: itemId)
            }
        }
    }
}
