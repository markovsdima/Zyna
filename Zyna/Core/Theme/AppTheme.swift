//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Brand color contract. Defaults live in the extension below;
/// a brand only declares the tokens it actually overrides.
/// Most tokens derive from `accent` / `onAccent`, so overriding
/// those usually re-skins the chat in one shot.
protocol AppTheme {

    // Brand primitives
    var accent: UIColor { get }
    var onAccent: UIColor { get }
    var destructive: UIColor { get }

    // Chat surface — also fed to glass capture, see GlassAnchor.
    var chatBackground: UIColor { get }

    // Bubbles
    var bubbleBackgroundIncoming: UIColor { get }
    var bubbleBackgroundOutgoing: UIColor { get }
    var bubbleForegroundIncoming: UIColor { get }
    var bubbleForegroundOutgoing: UIColor { get }
    var bubbleTimestampIncoming: UIColor { get }
    var bubbleTimestampOutgoing: UIColor { get }

    // Reply header
    var replyBarIncoming: UIColor { get }
    var replyBarOutgoing: UIColor { get }
    var replySenderIncoming: UIColor { get }
    var replySenderOutgoing: UIColor { get }
    var replyBodyIncoming: UIColor { get }
    var replyBodyOutgoing: UIColor { get }

    // Reactions
    var reactionBackgroundOwn: UIColor { get }
    var reactionBackgroundOther: UIColor { get }
    var reactionForegroundOwn: UIColor { get }
    var reactionForegroundOther: UIColor { get }
    var reactionBorderOwn: UIColor { get }

    // Auxiliary surfaces
    var inviteBannerBackground: UIColor { get }
    var searchBarBackground: UIColor { get }
    var voiceRecordingBackground: UIColor { get }
    var inputReplyBackground: UIColor { get }
}

extension AppTheme {

    var accent: UIColor {
        UIColor.dynamic(light: UIColor(hex: 0x007AFF), dark: UIColor(hex: 0x0A84FF))
    }
    var onAccent: UIColor { .white }
    var destructive: UIColor {
        UIColor.dynamic(light: UIColor(hex: 0xEF4444), dark: UIColor(hex: 0xF87171))
    }

    var chatBackground: UIColor {
        UIColor.dynamic(light: UIColor(hex: 0xD5D5D5), dark: UIColor(hex: 0x141414))
    }

    var bubbleBackgroundIncoming: UIColor {
        UIColor.dynamic(light: UIColor(hex: 0xE8E8E8), dark: UIColor(hex: 0x2C2C2E))
    }
    var bubbleBackgroundOutgoing: UIColor { accent }
    var bubbleForegroundIncoming: UIColor {
        UIColor.dynamic(light: UIColor(hex: 0x1F2937), dark: UIColor(hex: 0xF3F4F6))
    }
    var bubbleForegroundOutgoing: UIColor { onAccent }
    var bubbleTimestampIncoming: UIColor { .secondaryLabel }
    var bubbleTimestampOutgoing: UIColor { onAccent.withAlphaComponent(0.7) }

    var replyBarIncoming: UIColor { accent }
    var replyBarOutgoing: UIColor { onAccent.withAlphaComponent(0.6) }
    var replySenderIncoming: UIColor { accent }
    var replySenderOutgoing: UIColor { onAccent.withAlphaComponent(0.9) }
    var replyBodyIncoming: UIColor { .secondaryLabel }
    var replyBodyOutgoing: UIColor { onAccent.withAlphaComponent(0.7) }

    var reactionBackgroundOwn: UIColor { accent.withAlphaComponent(0.12) }
    var reactionBackgroundOther: UIColor { bubbleBackgroundIncoming }
    var reactionForegroundOwn: UIColor { accent }
    var reactionForegroundOther: UIColor { .label }
    var reactionBorderOwn: UIColor { accent.withAlphaComponent(0.4) }

    var inviteBannerBackground: UIColor { .secondarySystemBackground }
    var searchBarBackground: UIColor { .systemBackground }
    var voiceRecordingBackground: UIColor { .systemBackground }
    var inputReplyBackground: UIColor { UIColor.black.withAlphaComponent(0.5) }
}
