//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum Colors {
    
    // Background
    
    static let background = UIColor(hex: 0xF8F9FB)
    static let surfacePrimary = UIColor.white
    //static let surfaceSecondary = UIColor(hex: 0x262626)
    
    // Text
    
    static let textPrimary = UIColor(hex: 0x262626)
    static let textSecondary = UIColor(hex: 0x767676)
    static let textTertiary = UIColor(hex: 0x9CA3AF) // placeholders
    static let textOnAccent = UIColor.white
    
    // Actions
    
    static let accent = UIColor(hex: 0x0B26B0)
    
    // Separators
    
    // Categories
    
    enum Category {
        static let palette: [UIColor] = [
            UIColor(hex: 0x7B61FF),
            UIColor(hex: 0xFF9500),
            UIColor(hex: 0x007AFF),
            UIColor(hex: 0x34C759),
            UIColor(hex: 0xFF3B30),
        ]
        
        static func color(for index: Int) -> UIColor {
            palette[index % palette.count]
        }
    }
}
