//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// ASButtonNode that responds to VoiceOver double-tap by firing
/// the same actions as a real touchUpInside.
final class AccessibleButtonNode: ASButtonNode {

    override func accessibilityActivate() -> Bool {
        sendActions(forControlEvents: .touchUpInside, with: nil)
        return true
    }
}
