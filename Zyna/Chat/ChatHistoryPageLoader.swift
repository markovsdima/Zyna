//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Scroll prefetch, Texture batch fetch and server-flush retries share one
/// local request. Stay busy until Texture has applied an inserted page.
final class ChatHistoryPageLoader {
    enum Result: Equatable {
        case applied
        case exhausted
        case superseded
        case failed
    }

    private(set) var isLoading = false
    private var completions: [(Result) -> Void] = []

    func load(
        fetch: (@escaping (Result) -> Void) -> Void,
        waitForUpdates: @escaping (@escaping () -> Void) -> Void,
        completion: @escaping (Result) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        completions.append(completion)
        guard !isLoading else { return }
        isLoading = true
        fetch { [weak self] result in
            guard let self else { return }
            // An empty page can still update a boundary after a deletion.
            // Release the request only after that list update has finished.
            if result == .applied || result == .exhausted {
                waitForUpdates { self.finish(result) }
            } else {
                self.finish(result)
            }
        }
    }

    private func finish(_ result: Result) {
        dispatchPrecondition(condition: .onQueue(.main))
        let callbacks = completions
        completions.removeAll()
        isLoading = false
        for callback in callbacks { callback(result) }
    }

    /// Local data remains eligible while SDK history sync is running.
    static func canFetch(hasLocal: Bool, serverBusy: Bool, serverExhausted: Bool) -> Bool {
        hasLocal || (!serverBusy && !serverExhausted)
    }

    /// Distance is measured in list coordinates, including its inset.
    /// A small overscroll must not prevent loading the missing local page.
    static func shouldPrefetch(remaining: CGFloat, viewportHeight: CGFloat) -> Bool {
        viewportHeight > 0 && remaining <= viewportHeight * 3
    }

    /// Both edges may be close after a jump into a sparse window. Fill the
    /// nearer eligible edge first; reconsider after Texture applies the page.
    static func prefetchDirection(
        olderRemaining: CGFloat, newerRemaining: CGFloat, viewportHeight: CGFloat,
        hasOlder: Bool, hasNewer: Bool
    ) -> MessageWindow.PageDirection? {
        let older = hasOlder && shouldPrefetch(remaining: olderRemaining, viewportHeight: viewportHeight)
        let newer = hasNewer && shouldPrefetch(remaining: newerRemaining, viewportHeight: viewportHeight)
        if newer && (!older || newerRemaining < olderRemaining) { return .newer }
        return older ? .older : nil
    }

    enum ServerWaitAction: Equatable { case retry, finish, exhausted }

    static func shouldLoadSparseHistory(displayCount: Int, hasLocal: Bool, serverExhausted: Bool) -> Bool {
        displayCount < 20 && !hasLocal && !serverExhausted
    }

    static func serverWaitAction(
        result: Result, attemptsRemaining: Int, displayCountIncreased: Bool
    ) -> ServerWaitAction {
        switch result {
        case .applied, .failed:
            return .finish
        case .superseded:
            return attemptsRemaining > 1 ? .retry : .finish
        case .exhausted:
            if attemptsRemaining > 1 { return .retry }
            return displayCountIncreased ? .finish : .exhausted
        }
    }
}
