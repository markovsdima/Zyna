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
