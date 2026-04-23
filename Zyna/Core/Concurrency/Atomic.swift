//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import os.lock

/// Thread-safe container for a value of type `T`, backed by
/// `OSAllocatedUnfairLock`. Manual synchronization via the lock
/// justifies `@unchecked Sendable` / `nonisolated(unsafe)`.
final class Atomic<T>: @unchecked Sendable {

    private nonisolated(unsafe) var value: T
    private let lock = OSAllocatedUnfairLock()

    init(_ value: T) {
        self.value = value
    }

    var wrappedValue: T {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// Performs a compound mutation inside the critical section.
    func modify(_ transform: (inout T) -> Void) {
        lock.withLock { transform(&value) }
    }

    /// Like `modify` but returns a value out of the closure.
    func withValue<Result>(_ transform: (inout T) -> Result) -> Result {
        lock.withLock { transform(&value) }
    }

    /// Compare-and-swap. Returns true if the swap happened.
    func compareAndSwap(expected: T, desired: T) -> Bool where T: Equatable {
        lock.withLock {
            if value == expected {
                value = desired
                return true
            }
            return false
        }
    }
}

// MARK: - Boolean flag helpers

extension Atomic where T == Bool {

    /// If flag is false, sets it to true and returns true.
    /// Returns false if already set.
    func tryToSetFlag() -> Bool {
        var success = false
        modify { v in
            if !v { v = true; success = true }
        }
        return success
    }

    /// If flag is true, clears it and returns true.
    @discardableResult
    func tryToClearFlag() -> Bool {
        var success = false
        modify { v in
            if v { v = false; success = true }
        }
        return success
    }
}
