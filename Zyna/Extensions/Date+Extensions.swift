//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension Date {
    var presenceLastSeenString: String {
        let diff = Date().timeIntervalSince(self)
        switch diff {
        case ..<60:    return "last seen just now"
        case ..<3600:  return "last seen \(Int(diff / 60)) min ago"
        case ..<86400: return "last seen today"
        default:       return "last seen recently"
        }
    }
}
