//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum DeviceInsets {
    static var bottom: CGFloat = 0
    
    static func configure(from window: UIWindow) {
        bottom = window.safeAreaInsets.bottom
    }
}
