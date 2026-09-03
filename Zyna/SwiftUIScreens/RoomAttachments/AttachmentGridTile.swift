//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Square grid cell: blurhash first, then the tile derivative from
/// `MediaCache`. All stored properties are `Equatable` so SwiftUI can skip
/// unchanged cells; the memory hit happens in `init` so scroll-back never
/// flashes a placeholder.
struct AttachmentGridTile: View {

    let item: AttachmentItem
    let tilePixelSize: Int
    let plan: AttachmentThumbnailPlan
    let onTap: (CGRect) -> Void
    let onRequestLoad: () -> Void
    let onLoaded: (AttachmentFetchStats?) -> Void

    @State private var image: UIImage?
    @State private var placeholder: UIImage?
    @State private var failed = false

    private struct TaskKey: Hashable {
        let id: String
        let plan: AttachmentThumbnailPlan
        let tilePixelSize: Int
    }

    init(
        item: AttachmentItem,
        tilePixelSize: Int,
        plan: AttachmentThumbnailPlan,
        onTap: @escaping (CGRect) -> Void,
        onRequestLoad: @escaping () -> Void,
        onLoaded: @escaping (AttachmentFetchStats?) -> Void
    ) {
        self.item = item
        self.tilePixelSize = tilePixelSize
        self.plan = plan
        self.onTap = onTap
        self.onRequestLoad = onRequestLoad
        self.onLoaded = onLoaded
        if let request = plan.request {
            _image = State(initialValue: MediaCache.shared.cachedAttachmentThumbnail(
                mxc: request.mxc, tilePixelSize: tilePixelSize
            ))
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let placeholder {
                    Image(uiImage: placeholder)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                }
                overlay
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(frame: proxy.frame(in: .global))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: TaskKey(id: item.id, plan: plan, tilePixelSize: tilePixelSize)) {
            await load()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        if item.kind == .video {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(Self.durationText(item.durationSeconds))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
                }
            }
        }
        if image == nil {
            if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 2)
            } else if plan.isTapToLoad {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 2)
            }
        }
    }

    private var accessibilityLabel: String {
        switch item.kind {
        case .video: return String(localized: "Video, \(Self.durationText(item.durationSeconds))")
        default: return String(localized: "Photo")
        }
    }

    static func durationText(_ seconds: TimeInterval?) -> String {
        let total = Int((seconds ?? 0).rounded())
        let minutes = total / 60
        let remainder = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    // MARK: - Interaction

    private func handleTap(frame: CGRect) {
        if image == nil, plan.isTapToLoad {
            onRequestLoad()
            return
        }
        if failed, plan.request != nil {
            failed = false
            Task { await load() }
            return
        }
        onTap(frame)
    }

    // MARK: - Loading

    private func load() async {
        if image == nil, placeholder == nil, let hash = item.blurhash {
            let aspectRatio = item.aspectRatio
            let decoded = await Task.detached(priority: .userInitiated) {
                BlurhashDecoder.placeholder(for: hash, aspectRatio: aspectRatio)
            }.value
            guard !Task.isCancelled else { return }
            placeholder = decoded
        }

        guard image == nil, let request = plan.request else {
            if case .deferred = plan {
                onLoaded(nil)
            }
            return
        }

        let result = await MediaCache.shared.loadAttachmentThumbnail(
            request, tilePixelSize: tilePixelSize, lane: plan.lane
        )
        guard !Task.isCancelled else { return }
        if let result {
            image = result.image
            failed = false
        } else {
            failed = true
        }
        onLoaded(result?.stats)
    }
}
