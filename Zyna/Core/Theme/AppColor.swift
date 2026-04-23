//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Facade over `Brand.current.theme`. Resolved once at startup;
/// runtime brand switching is intentionally not supported.
///
/// Tokens are `static let`, not `static var`: each one is materialized
/// from the theme on first access and then cached for the process
/// lifetime. UIColor.dynamic instances stay valid across light/dark
/// switches because UIKit re-resolves them per traitCollection at use
/// time — caching the wrapper is fine.
enum AppColor {

    static let current: AppTheme = Brand.current.theme

    // Non-themed constant.
    static let iconWhite = UIColor(hex: 0xF8F9FB)

    static let accent: UIColor                    = current.accent
    static let onAccent: UIColor                  = current.onAccent
    static let destructive: UIColor               = current.destructive
    static let chatBackground: UIColor            = current.chatBackground
    static let bubbleBackgroundIncoming: UIColor  = current.bubbleBackgroundIncoming
    static let bubbleBackgroundOutgoing: UIColor  = current.bubbleBackgroundOutgoing
    static let bubbleForegroundIncoming: UIColor  = current.bubbleForegroundIncoming
    static let bubbleForegroundOutgoing: UIColor  = current.bubbleForegroundOutgoing
    static let bubbleTimestampIncoming: UIColor   = current.bubbleTimestampIncoming
    static let bubbleTimestampOutgoing: UIColor   = current.bubbleTimestampOutgoing

    static let replyBarIncoming: UIColor          = current.replyBarIncoming
    static let replyBarOutgoing: UIColor          = current.replyBarOutgoing
    static let replySenderIncoming: UIColor       = current.replySenderIncoming
    static let replySenderOutgoing: UIColor       = current.replySenderOutgoing
    static let replyBodyIncoming: UIColor         = current.replyBodyIncoming
    static let replyBodyOutgoing: UIColor         = current.replyBodyOutgoing

    static let reactionBackgroundOwn: UIColor     = current.reactionBackgroundOwn
    static let reactionBackgroundOther: UIColor   = current.reactionBackgroundOther
    static let reactionForegroundOwn: UIColor     = current.reactionForegroundOwn
    static let reactionForegroundOther: UIColor   = current.reactionForegroundOther
    static let reactionBorderOwn: UIColor         = current.reactionBorderOwn

    static let inviteBannerBackground: UIColor    = current.inviteBannerBackground
    static let searchBarBackground: UIColor       = current.searchBarBackground
    static let voiceRecordingBackground: UIColor  = current.voiceRecordingBackground
    static let inputReplyBackground: UIColor      = current.inputReplyBackground
    static let systemEventBackground: UIColor     = current.systemEventBackground
}

extension UIColor {
    convenience init(hex: UInt, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension UIColor {
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}
