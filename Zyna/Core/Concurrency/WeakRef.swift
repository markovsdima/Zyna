//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Sendable wrapper around a weak reference to a class instance.
///
/// Use this when you need a weak capture of `self` (or any reference type)
/// inside a `@Sendable` closure — typically the body of a `Task { ... }` —
/// but the captured class is not itself `Sendable`. A direct `[weak self]`
/// in that situation triggers Swift's strict concurrency diagnostic
/// "capture of 'self' with non-sendable type ...".
///
/// The wrapper is `@unchecked Sendable` because it holds a single weak
/// field with no shared mutable state. The compiler can't prove that on
/// its own, but the contract is trivial to maintain.
///
/// Usage:
/// ```
/// let ref = WeakRef(self)
/// Task { [ref, otherSendableValue] in
///     let result = await someAsyncWork()
///     await MainActor.run {
///         ref.value?.consume(result)
///     }
/// }
/// ```
///
/// Prefer plain `[weak self]` when the captured class is already
/// `Sendable` or fully `@MainActor`-isolated — this wrapper exists
/// only to bridge the Sendable gap.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    private weak var object: T?

    var value: T? {
        object
    }

    init(_ value: T) {
        object = value
    }
}
