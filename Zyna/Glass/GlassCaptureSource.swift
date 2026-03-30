//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// A source that can trigger glass re-capture when its content changes.
///
/// Conform to this protocol in views/nodes that have animated content
/// (Lottie, GIF, typing indicators, etc.) and register with GlassService
/// when they become visible.
///
/// Usage in a Texture cell node:
///
///     override func didEnterVisibleState() {
///         super.didEnterVisibleState()
///         GlassService.shared.addCaptureSource(self)
///     }
///
///     override func didExitVisibleState() {
///         super.didExitVisibleState()
///         GlassService.shared.removeCaptureSource(self)
///     }
///
///     // GlassCaptureSource:
///     var needsGlassCapture: Bool { lottieView.isAnimationPlaying }
///     var captureSourceFrame: CGRect? {
///         guard let window = view.window else { return nil }
///         return view.convert(view.bounds, to: window)
///     }
///
protocol GlassCaptureSource: AnyObject {
    /// Whether this source currently needs the glass to re-capture.
    /// Return `true` while animating, `false` when static.
    var needsGlassCapture: Bool { get }

    /// Frame in source window coordinates for intersection check with glass rects.
    /// Return nil if the source is not currently in a window.
    var captureSourceFrame: CGRect? { get }
}
