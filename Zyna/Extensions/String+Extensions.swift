//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
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
