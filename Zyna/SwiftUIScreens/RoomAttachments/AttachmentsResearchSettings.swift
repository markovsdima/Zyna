//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Debug switches for the attachments R&D screen. Always off in Release.
enum AttachmentsResearchSettings {

    static let didChange = Notification.Name("com.zyna.attachments.research.didChange")

    /// `ZYNA_ATTACHMENTS_AUTODIAG=1` in the scheme's environment: tapping a chat
    /// runs `AttachmentsAutoDiagnostics` on that room instead of opening it.
    static var isAutoDiagnosticsEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ZYNA_ATTACHMENTS_AUTODIAG"] == "1"
        #else
        return false
        #endif
    }

    private static let pauseChatHistorySyncKey = "com.zyna.debug.attachments.pauseChatHistorySync"
    private static let useAllFilterKey = "com.zyna.debug.attachments.useAllFilter"

    /// Filter the attachments timeline is built with. `.sdkOnlyMessage` is the
    /// default now that the fork keeps `m.room.encrypted` in message-only
    /// timelines; `.allWithSwiftFilter` stays available for A/B measurements.
    /// Applies to the next screen open.
    static var filterMode: AttachmentSourceFilterMode {
        get {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: useAllFilterKey) ? .allWithSwiftFilter : .sdkOnlyMessage
            #else
            return .sdkOnlyMessage
            #endif
        }
        set {
            #if DEBUG
            UserDefaults.standard.set(newValue == .allWithSwiftFilter, forKey: useAllFilterKey)
            NotificationCenter.default.post(name: didChange, object: nil)
            #endif
        }
    }

    /// When on, `ChatViewModel` skips its background full-history sync so the
    /// attachments screen's own pagination can be measured in isolation.
    /// Off reproduces the real UX: the chat keeps paginating underneath.
    static var isChatHistorySyncPaused: Bool {
        get {
            #if DEBUG
            return UserDefaults.standard.bool(forKey: pauseChatHistorySyncKey)
            #else
            return false
            #endif
        }
        set {
            #if DEBUG
            UserDefaults.standard.set(newValue, forKey: pauseChatHistorySyncKey)
            NotificationCenter.default.post(name: didChange, object: nil)
            #endif
        }
    }
}
