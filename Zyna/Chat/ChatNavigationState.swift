// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

struct ChatNavigationAnchor: Equatable {
    let eventID: String?
    let timestamp: TimeInterval
    let listID: String
    /// Distance from the bottom of the visible inverted list to this row.
    let distance: CGFloat
}

/// Session-only state, independent of SDK listeners and the loaded history.
struct ChatNavigationState {
    struct Search {
        let query: String
        let eventID: String?
    }
    var anchor: ChatNavigationAnchor?
    var text = ComposerText(body: "")
    var selection = NSRange(location: 0, length: 0)
    var reply: ChatMessage?
    var editing: ChatMessage?
    var forward: ChatMessage?
    var composer = ChatComposerState()
    var search: Search?
}
