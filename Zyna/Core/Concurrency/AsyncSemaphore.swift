//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Counting semaphore for Swift concurrency. Waiters resume in FIFO order.
///
/// Callers must pair every `acquire()` with exactly one `release()`; there is
/// no scoped helper because `release()` is an actor call and cannot run
/// from `defer`.
actor AsyncSemaphore {

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        availablePermits = max(0, permits)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
