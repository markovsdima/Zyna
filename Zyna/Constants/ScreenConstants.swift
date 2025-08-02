//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum ScreenConstants {
    static let width = UIScreen.main.bounds.width
    static let height = UIScreen.main.bounds.height
    static let size = UIScreen.main.bounds.size
    static let scale = UIScreen.main.scale
    
    static let safeAreaTop: CGFloat = {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return 0
        }
        return window.safeAreaInsets.top
    }()
    
    static let safeAreaBottom: CGFloat = {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return 0
        }
        return window.safeAreaInsets.bottom
    }()
}
