//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Transparent overlay window for glass effects.
/// Passes touches through EXCEPT on interactive content views
/// (labels, buttons, text fields placed via GlassContainerView).
final class PassthroughWindow: UIWindow {

    override var canBecomeKey: Bool { true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Let the normal hit test find a view
        guard let hit = super.hitTest(point, with: event) else { return nil }

        // If it hit the root view or a GlassRenderer — pass through
        if hit === rootViewController?.view || hit is GlassRenderer {
            return nil
        }

        // Otherwise it's interactive content — handle the touch
        return hit
    }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        rootViewController = vc
    }

    required init?(coder: NSCoder) { fatalError() }
}
