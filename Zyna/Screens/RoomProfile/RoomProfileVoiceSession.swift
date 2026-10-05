// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Lightweight bookmarks owned by one open profile, independent of pages.
@MainActor
final class RoomProfileVoiceSession {
    private var positions: [String: Float] = [:]

    func progress(for eventID: String) -> Float { positions[eventID] ?? 0 }

    func remember(eventID: String, progress: Float) {
        guard progress.isFinite else { return }
        positions[eventID] = progress < 1 ? max(0, progress) : 0
    }

    /// Failed/cancelled loads leave the bookmark intact. Once playback starts,
    /// the shared player owns its position until the user explicitly stops it.
    func didStart(eventID: String) { positions.removeValue(forKey: eventID) }
}
