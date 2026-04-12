//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Invisible marker view placed in the main UI hierarchy.
/// Defines where a glass effect should appear and its optical parameters.
///
/// Automatically detects when it's being animated (navigation push/pop,
/// keyboard, custom transitions) and triggers glass re-capture.
///
/// Usage:
///     let glass = GlassAnchor()
///     glass.cornerRadius = 20
///     someView.addSubview(glass)
///     // Glass appears automatically. Remove from superview to dismiss.
final class GlassAnchor: UIView {

    // MARK: - Parameters

    var cornerRadius: CGFloat = 24

    /// When true, the capture rect extends from the glass top to the screen bottom,
    /// and a liquid-dissolve pass distorts content with increasing intensity downward.
    var extendsCaptureToScreenBottom = false

    /// Custom multi-shape provider. Return nil for default single rounded rect.
    var shapeProvider: ((_ glassFrame: CGRect, _ captureFrame: CGRect, _ scale: CGFloat) -> GlassRenderer.ShapeParams)?

    /// Chrome bar data provider. Return nil when bars are inactive.
    var barProvider: ((_ glassFrame: CGRect, _ captureFrame: CGRect, _ scale: CGFloat) -> GlassRenderer.BarData?)?

    /// Quick flag: true when bars are active (avoids calling barProvider just to check).
    /// Used by GlassService to expand capture frame upward.
    var hasBars: Bool = false

    /// True when scroll-to-live button is visible above the input bar.
    /// Used by GlassService to expand capture frame upward.
    var hasScrollButton: Bool = false

    /// The view whose layer tree to capture as glass background.
    /// Only this view's content is rendered — glass UI is excluded automatically.
    /// If nil, falls back to the anchor's window.
    weak var sourceView: UIView?

    /// Color used to fill the capture buffer before sublayers are
    /// rendered into it. GlassService renders only `sourceView`'s
    /// sublayers (an optimization that skips off-screen Texture cells),
    /// which means the source view's own backgroundColor is never
    /// drawn — empty regions would otherwise read as black. This color
    /// stands in for that missing background and should match what the
    /// user actually sees behind the cells.
    var backdropClearColor: UIColor = AppColor.chatBackground {
        didSet { recomputeClearPattern() }
    }

    /// Pre-resolved BGRA8 pattern for `backdropClearColor`, ready for
    /// `memset_pattern4` on the capture buffer. Cached so the per-frame
    /// path skips color resolution. Updated on color or trait changes.
    private(set) var clearPatternBGRA: UInt32 = 0xFF000000

    // MARK: - Registration

    private var registration: GlassRegistration?

    /// Metal renderer. Created once, owned by the bar that hosts us.
    /// GlassService drives its content; the bar places it in the
    /// view hierarchy.
    let renderer = GlassRenderer()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        recomputeClearPattern()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            registration = GlassService.shared.register(anchor: self, renderer: renderer)
            recomputeClearPattern()
        } else {
            registration = nil
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            recomputeClearPattern()
            GlassService.shared.setNeedsCapture()
        }
    }

    private func recomputeClearPattern() {
        let resolved = backdropClearColor.resolvedColor(with: traitCollection)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let rb = UInt32(max(0, min(1, r)) * 255)
        let gb = UInt32(max(0, min(1, g)) * 255)
        let bb = UInt32(max(0, min(1, b)) * 255)
        // BGRA8 premultiplied, opaque alpha → RGB unmodified.
        // Byte order in memory is B, G, R, A; on little-endian
        // ARM64 that packs into a UInt32 as 0xAARRGGBB.
        clearPatternBGRA = (UInt32(0xFF) << 24) | (rb << 16) | (gb << 8) | bb
    }

    // MARK: - Frame Queries

    /// Frame in window coordinates, including any in-flight ancestor
    /// animation. `CALayer.convert(_:to:)` started from a presentation
    /// layer already walks ancestor presentation layers, so a plain
    /// delegation is enough — no manual transform accumulation.
    func presentationFrame() -> CGRect? {
        guard let window else { return nil }
        let currentLayer = layer.presentation() ?? layer
        return currentLayer.convert(currentLayer.bounds, to: window.layer)
    }

    /// True if this layer or any ancestor has an active CAAnimation.
    /// Comparing presentation vs. model frames doesn't work here:
    /// `convert(_:to:)` walks ancestor presentation layers, so both
    /// reads return the same animated value and the diff is always
    /// zero. Walk the chain and check `animationKeys()` directly.
    var isAnimating: Bool {
        guard let windowLayer = window?.layer else { return false }
        var current: CALayer? = layer
        while let l = current, l !== windowLayer {
            if let keys = l.animationKeys(), !keys.isEmpty {
                return true
            }
            current = l.superlayer
        }
        return false
    }
}
