//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Plain tappable container: fires `onTap` on either finger-tap or
/// VoiceOver activate. Use when you'd reach for an `ASDisplayNode` +
/// `UITapGestureRecognizer` but want the VO double-tap to fire too.
class TappableNode: ASDisplayNode {

    var onTap: (() -> Void)?

    override func didLoad() {
        super.didLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTap() { onTap?() }

    override func accessibilityActivate() -> Bool {
        guard let onTap else { return false }
        onTap()
        return true
    }
}
