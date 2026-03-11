//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum AppColor {
    
    private static let blue500 = UIColor(hex: "#3B82F6")
    private static let blue400 = UIColor(hex: "#60A5FA")
    private static let gray100 = UIColor(hex: "#F3F4F6")
    private static let gray800 = UIColor(hex: "#1F2937")
    private static let gray900 = UIColor(hex: "#111827")
    
    static let iconWhite = UIColor(hex: 0xF8F9FB)
    
    static let bubbleForegroundOutgoing = UIColor.dynamic(
        light: .white, dark: gray900
    )
    
    static let bubbleForegroundIncoming = UIColor.dynamic(
        light: gray800, dark: gray100
    )
}

extension UIColor {
    convenience init(hex: UInt, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension UIColor {
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}
