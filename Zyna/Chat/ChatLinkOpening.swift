// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Owned by the source chat until routing finishes or a preview takes over.
/// A new tap or a disappearing chat cancels the operation and its animation.
@MainActor
final class ChatLinkOpening {
    let url: URL
    private(set) var isActive = true
    var onCancel: (() -> Void)?
    private var onLoading: (Bool) -> Void
    private var isLoading = true
    private let onFinish: () -> Void

    init(url: URL, onLoading: @escaping (Bool) -> Void, onFinish: @escaping () -> Void) {
        self.url = url
        self.onLoading = onLoading
        self.onFinish = onFinish
        onLoading(true)
    }

    func setLoading(_ value: Bool) {
        guard isActive else { return }
        isLoading = value
        onLoading(value)
    }

    func moveLoadingIndicator(to update: @escaping (Bool) -> Void) {
        guard isActive else { return }
        onLoading(false)
        onLoading = update
        onLoading(isLoading)
    }

    func finish() {
        guard isActive else { return }
        isActive = false
        onCancel = nil
        onLoading(false)
        onFinish()
    }

    func cancel() {
        guard isActive else { return }
        let cancel = onCancel
        finish()
        cancel?()
    }
}
