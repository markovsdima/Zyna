//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

struct ChatSearchResult {
    let eventId: String
    let body: String
}

struct ChatSearchState {
    var query: String = ""
    var results: [ChatSearchResult] = []
    var currentIndex: Int = 0

    var currentResult: ChatSearchResult? {
        guard !results.isEmpty, currentIndex >= 0, currentIndex < results.count else { return nil }
        return results[currentIndex]
    }

    var statusText: String {
        guard !results.isEmpty else {
            return query.isEmpty ? "" : "No results"
        }
        return "\(currentIndex + 1) of \(results.count)"
    }
}
