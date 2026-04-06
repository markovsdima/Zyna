//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Single source of truth for the Send-button colour palette. Tune
/// colours, geometry and animation here without touching the view code.
enum SendColorPaletteConfig {

    // MARK: - Colours

    /// 6 preset colours shown when long-pressing Send.
    /// Order matters: index 0 is the first item along the arc (top of
    /// fan), last is closest to the Send button (inner end).
    static let colors: [UIColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemIndigo,
        .systemPurple
    ]

    // MARK: - Geometry

    /// Radius (pt) from the Send button centre to each colour circle.
    /// With 6 circles across a 90° arc and 44pt diameter, this yields
    /// ~9pt gap between adjacent circles (arc-distance ≈ 53pt).
    static let arcRadius: CGFloat = 170

    /// Diameter (pt) of each colour circle.
    static let circleDiameter: CGFloat = 44

    /// Scale factor applied to the currently-highlighted circle.
    static let highlightScale: CGFloat = 1.3

    /// Angle (radians) where the arc begins — 0 is "due east" in math
    /// convention; we build a fan that sweeps from "up" to "left".
    static let arcStartAngle: CGFloat = .pi / 2            // straight up
    static let arcEndAngle: CGFloat = .pi                  // straight left

    // MARK: - Animation

    /// Show/hide animation duration.
    static let animationDuration: TimeInterval = 0.22

    /// Stagger between circle appearances (for fan open-out).
    static let stagger: TimeInterval = 0.02

    /// After send, how long the Send button stays tinted before fading back.
    static let sendFlashHold: TimeInterval = 0.8

    /// Fade duration for Send button returning to its default tint.
    static let sendFlashFadeOut: TimeInterval = 0.4
}
