//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Single source of truth for message status icon geometry and style.
/// All dimensions scale with `size` (passed to the icon view).
enum MessageStatusIconConfig {

    /// Default icon size (pt). Matches the timestamp font size so the
    /// icon sits on the baseline. Callers may override per-use.
    static let defaultSize: CGFloat = 11

    /// Line thickness for checkmark strokes and clock outline,
    /// expressed as a fraction of the icon size.
    static let strokeWidthRatio: CGFloat = 0.16

    /// Horizontal offset of the front checkmark when drawing the
    /// double-check "delivered" state, as a fraction of icon size.
    static let doubleCheckOffsetRatio: CGFloat = 0.35

    /// One full rotation of the clock hand, in seconds.
    static let clockRotationPeriod: CFTimeInterval = 1.2

    /// White border width around the failed (red) circle icon.
    static let failedRingWidth: CGFloat = 1.0

    /// Fill colour for the failed state circle.
    static let failedFillColor: UIColor = .systemRed

    /// Colour of the "!" glyph on the failed circle.
    static let failedGlyphColor: UIColor = .white

    /// Border colour around the failed circle (separates from any
    /// bubble colour).
    static let failedBorderColor: UIColor = .white
}
