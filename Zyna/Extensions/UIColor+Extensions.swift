//
//  UIColor+Extensions.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 21.04.2025.
//

import UIKit

extension UIColor {
    
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var cleanedHex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        
        if cleanedHex.hasPrefix("#") {
            cleanedHex.removeFirst()
        }
        
        if cleanedHex.hasPrefix("0X") {
            cleanedHex.removeFirst(2)
        }
        
        guard cleanedHex.count == 6 else {
            self.init(white: 1.0, alpha: alpha) // fallback: white color
            return
        }
        
        var rgbValue: UInt64 = 0
        Scanner(string: cleanedHex).scanHexInt64(&rgbValue)
        
        let red   = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue  = CGFloat(rgbValue & 0x0000FF) / 255.0
        
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
