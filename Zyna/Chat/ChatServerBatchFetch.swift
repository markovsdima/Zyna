//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import Foundation

/// Texture reuses one context per list. Identify each server wait by a
/// separate token so late callbacks cannot finish its successor.
final class ChatServerBatchFetch {
    typealias Token = UInt64

    private var sequence: Token = 0
    private(set) var currentToken: Token?
    private var context: ASBatchContext?
    private var subscription: AnyCancellable?

    var isActive: Bool { currentToken != nil }

    func begin(context: ASBatchContext) -> Token {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(!isActive)
        sequence &+= 1
        currentToken = sequence
        self.context = context
        return sequence
    }

    func isCurrent(_ token: Token) -> Bool {
        currentToken == token
    }

    func setSubscription(_ subscription: AnyCancellable, for token: Token) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(token) else { subscription.cancel(); return }
        self.subscription = subscription
    }

    func finish(_ token: Token) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(token) else { return }
        let context = self.context
        let subscription = self.subscription
        currentToken = nil
        self.context = nil
        self.subscription = nil
        context?.completeBatchFetching(true)
        subscription?.cancel()
    }
}
