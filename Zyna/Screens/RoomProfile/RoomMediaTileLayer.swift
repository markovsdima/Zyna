// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

/// Reused only within the viewport pool. Async completion must match both
/// the event binding and request generation before touching its contents.
final class RoomMediaTileLayer: CALayer {
    private(set) var item: AttachmentItem?
    private(set) var image: UIImage?
    private(set) var isReady = false
    private(set) var failed = false
    private let badge = CATextLayer()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pixels = 0
    private var requestedPixels = 0
    private var plan: AttachmentThumbnailPlan?
    var onVisualChange: ((RoomMediaTileLayer) -> Void)?

    override init() {
        super.init()
        contentsGravity = .resizeAspectFill
        masksToBounds = true
        badge.alignmentMode = .center
        badge.foregroundColor = UIColor.white.cgColor
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
        badge.fontSize = 10
        badge.cornerRadius = 3
        badge.contentsScale = UIScreen.main.scale
        addSublayer(badge)
        reset()
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { task?.cancel() }

    @MainActor
    func bind(_ item: AttachmentItem?, pixels: Int, threshold: UInt64, force: Bool, load: Bool) {
        if self.item != item { reset(); self.item = item }
        guard let item else { return }
        let nextPlan = AttachmentThumbnailPlan.make(for: item, tilePixelSize: pixels,
            fullFileThreshold: threshold, forceLoad: force)
        if plan != nextPlan {
            task?.cancel(); task = nil; generation += 1
            plan = nextPlan
        }
        guard !isReady || self.pixels < pixels else { updateBadge(); return }
        if image == nil, let request = nextPlan.request {
            for size in [pixels, 128, 256, 512, 768] {
                if let cached = MediaCache.shared.cachedAttachmentThumbnail(mxc: request.mxc, tilePixelSize: size) {
                    setImage(cached); self.pixels = size; isReady = true
                    break
                }
            }
        }
        updateBadge()
        guard load, (!isReady || self.pixels < pixels), !failed,
              nextPlan.request != nil || (image == nil && item.blurhash != nil),
              task == nil || requestedPixels != pixels else { return }
        task?.cancel()
        generation += 1
        let generation = generation
        requestedPixels = pixels
        task = Task { @MainActor [weak self] in
            if self?.image == nil, let hash = item.blurhash {
                let placeholder = await Task.detached(priority: .utility) {
                    BlurhashDecoder.placeholder(for: hash, aspectRatio: item.aspectRatio)
                }.value
                guard !Task.isCancelled, self?.generation == generation else { return }
                if let placeholder { self?.setImage(placeholder) }
            }
            if let request = nextPlan.request {
                let result = await MediaCache.shared.loadAttachmentThumbnail(request, tilePixelSize: pixels, lane: nextPlan.lane)
                guard !Task.isCancelled, self?.generation == generation else { return }
                if let result { self?.setImage(result.image); self?.pixels = pixels; self?.isReady = true }
                self?.failed = result == nil
            }
            guard self?.generation == generation else { return }
            self?.task = nil
            self?.updateBadge()
        }
    }

    func reset() {
        onVisualChange = nil
        task?.cancel(); task = nil; generation += 1
        item = nil; image = nil; contents = nil
        pixels = 0; requestedPixels = 0; isReady = false; failed = false; plan = nil
        badge.isHidden = true
        backgroundColor = UIColor.secondarySystemBackground.cgColor
        opacity = 1
        removeAllAnimations()
    }

    @MainActor func retry() { failed = false; task?.cancel(); task = nil }

    /// A transition replica shares decoded pixels and owns no fetch task.
    /// Its native grid width determines the badge; the parent scales both.
    func copyPresentation(from source: RoomMediaTileLayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        item = source.item; plan = source.plan
        isReady = source.isReady; failed = source.failed
        if image !== source.image {
            image = source.image
            contents = source.contents
        }
        backgroundColor = source.backgroundColor
        updateBadge()
        CATransaction.commit()
    }

    private func setImage(_ image: UIImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.image = image
        contents = image.cgImage
        CATransaction.commit()
        onVisualChange?(self)
    }

    private func updateBadge() {
        let title: String
        if failed { title = "↻" }
        else if !isReady, plan?.isTapToLoad == true { title = "↓" }
        else if item?.kind == .video {
            let duration = Int(item?.durationSeconds ?? 0)
            title = bounds.width < 65 ? "▶" : String(format: "▶ %d:%02d", duration / 60, duration % 60)
        } else { title = "" }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let changed = badge.string as? String != title
        if changed { badge.string = title }
        badge.isHidden = title.isEmpty
        layoutBadge()
        CATransaction.commit()
        if changed { onVisualChange?(self) }
    }

    override func layoutSublayers() { super.layoutSublayers(); updateBadge() }

    private func layoutBadge() {
        let text = badge.string as? String ?? ""
        let width = min(max(14, CGFloat(text.count) * 6 + 6), max(0, bounds.width - 4))
        badge.frame = CGRect(x: bounds.width - width - 2, y: max(0, bounds.height - 17), width: width, height: 15)
    }
}
