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

    // MARK: - Registration

    private var registration: GlassRegistration?

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            registration = GlassService.shared.register(anchor: self)
        } else {
            registration = nil
        }
    }

    // MARK: - Frame Queries

    /// Frame from presentation layer (in-flight animation state).
    func presentationFrame() -> CGRect? {
        guard let window else { return nil }
        let currentLayer = layer.presentation() ?? layer
        return currentLayer.convert(currentLayer.bounds, to: window.layer)
    }

    /// Frame from model layer (final/resting state).
    func modelFrame() -> CGRect? {
        guard let window else { return nil }
        return layer.convert(layer.bounds, to: window.layer)
    }

    /// Whether the anchor is currently being animated (push/pop, keyboard, etc.)
    var isAnimating: Bool {
        guard let pf = presentationFrame(), let mf = modelFrame() else { return false }
        return abs(pf.origin.x - mf.origin.x) > 0.5 ||
               abs(pf.origin.y - mf.origin.y) > 0.5 ||
               abs(pf.width - mf.width) > 0.5 ||
               abs(pf.height - mf.height) > 0.5
    }
}
