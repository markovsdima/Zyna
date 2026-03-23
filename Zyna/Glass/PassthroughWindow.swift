//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Transparent overlay window that passes all touches to the window below.
/// Used by GlassService to render glass effects above the main UI
/// without intercepting input or stealing key status.
final class PassthroughWindow: UIWindow {

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        rootViewController = vc
    }

    required init?(coder: NSCoder) { fatalError() }
}
