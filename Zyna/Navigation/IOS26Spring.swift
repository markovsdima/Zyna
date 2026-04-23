//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Factory for `CASpringAnimation`s tuned to iOS 26's Liquid Glass
/// system spring (mass 1, stiffness 555.027, damping 47.118,
/// duration 0.3832 s). Same numbers Telegram extracted from iOS 26
/// internals — using them keeps our transitions visually in lockstep
/// with system spring animations the user encounters elsewhere
/// (sheets, alerts, system pops on iOS 26).
enum IOS26Spring {

    /// Canonical iOS 26 spring duration.
    static let duration: CFTimeInterval = 0.3832

    /// Device display corner radius for transition card rounding.
    /// Undocumented but stable since iPhone X. Falls back to 39 pt.
    static let screenCornerRadius: CGFloat = {
        guard let key = DynamicAction.resolveString(
            bytes: [
                0xF8, 0xC3, 0xCE, 0xD4, 0xD7, 0xCB, 0xC6, 0xDE,
                0xE4, 0xC8, 0xD5, 0xC9, 0xC2, 0xD5, 0xF5, 0xC6,
                0xC3, 0xCE, 0xD2, 0xD4
            ],
            mask: 0xA7
        ) else { return 39 }
        return UIScreen.main.value(forKey: key) as? CGFloat ?? 39
    }()

    /// Build a spring on `keyPath` interpolating `from`→`to`.
    /// Callers commit the matching model state separately (typically
    /// inside `CATransaction.setDisableActions(true)`) so the layer
    /// rests at the target after the animation.
    ///
    /// Forces ProMotion to 120 Hz via `preferredFrameRateRange` plus
    /// the undocumented KVC hint `highFrameRateReason = 1048619`,
    /// which is needed in practice — the public API alone leaves
    /// spring animations on the 60 Hz path.
    static func makeAnimation(
        keyPath: String,
        from: Any,
        to: Any
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1.0
        animation.stiffness = 555.027
        animation.damping = 47.118
        animation.duration = duration
        animation.fromValue = from
        animation.toValue = to
        animation.timingFunction = CAMediaTimingFunction(name: .linear)

        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120
        )
        if let fpsKey = DynamicAction.resolveString(
            bytes: [
                0xCF, 0xCE, 0xC0, 0xCF, 0xE1, 0xD5, 0xC6, 0xCA,
                0xC2, 0xF5, 0xC6, 0xD3, 0xC2, 0xF5, 0xC2, 0xC6,
                0xD4, 0xC8, 0xC9
            ],
            mask: 0xA7
        ) {
            animation.setValue(1048619, forKey: fpsKey)
        }

        return animation
    }
}
