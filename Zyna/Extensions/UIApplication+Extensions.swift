//
//  UIApplication+Extensions.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 01.08.2025.
//

import UIKit

extension UIApplication {
    
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
