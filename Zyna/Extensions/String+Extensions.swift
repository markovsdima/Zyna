//
//  String+Extensions.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 03.08.2025.
//

import Foundation
//import UniformTypeIdentifiers

extension String {
    var isASCII: Bool {
        allSatisfy(\.isASCII)
    }
    
    func asciifyIfNeeded() -> String? {
        if isASCII { return self }
        let mutableString = NSMutableString(string: self)
        guard CFStringTransform(mutableString, nil, "Any-Latin; Latin-ASCII; [:^ASCII:] Remove" as CFString, false) else {
            return nil
        }
        return mutableString.trimmingCharacters(in: .whitespaces)
    }
}
