//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Tricks iOS into maintaining 120fps (ProMotion) during scroll deceleration
/// by toggling an invisible 1×1 pixel view on each display link tick.
final class ScrollFPSBooster {

    private var boostView: UIView?
    private var token: DisplayLinkToken?
    private weak var hostView: UIView?

    init(hostView: UIView) {
        self.hostView = hostView
    }

    func start() {
        guard token == nil, let hostView else { return }

        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.0001
        hostView.addSubview(view)
        boostView = view

        token = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak view] _ in
            guard let view else { return }
            view.frame.origin.x = view.frame.origin.x == 0 ? 1 : 0
        }
    }

    func stop() {
        token?.invalidate()
        token = nil
        boostView?.removeFromSuperview()
        boostView = nil
    }
}
