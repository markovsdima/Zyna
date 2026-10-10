// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

/// The page's native pan also observes the sibling header. UIKit normally
/// keeps a UIButton's tracking touch; explicitly let a drag cancel it so the
/// shared pan can scroll. Taps still reach the button and its menu normally.
final class RoomProfileMediaScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIButton || super.touchesShouldCancel(in: view)
    }
}

final class RoomProfileCollectionView: ASCollectionView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIButton || super.touchesShouldCancel(in: view)
    }
}
