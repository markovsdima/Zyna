//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Live mirror of another UIView's layer contents. The compositor
/// sets up a layer reference rather than a render pass, so mirroring
/// a view in a second on-screen location costs near-zero per frame.
///
/// Typical uses: peek previews, live miniatures, bubble-through-
/// gradient effects.
///
/// `matchesPosition` picks the mode: `false` fits the source into the
/// portal's own frame; `true` reveals the slice of source that lies
/// behind the portal in window coordinates ("window through source").
final class PortalView {

    /// The underlying mirror view. Add to your view hierarchy.
    let view: UIView

    /// Source whose layer contents are mirrored. Setting triggers a
    /// re-insert of `view` in its superview — without it, the
    /// compositor sometimes doesn't re-establish the mirror after the
    /// source changes.
    var sourceView: UIView? {
        didSet { applySource() }
    }

    /// Returns nil if the underlying class is unavailable on the current iOS.
    init?(matchesPosition: Bool = false) {
        guard let cls = Self.portalClass else { return nil }
        self.view = cls.init()

        let no = NSNumber(value: false)
        let matchFlag = NSNumber(value: matchesPosition)
        view.setValue(matchFlag, forKey: Keys.matchesPosition)
        view.setValue(matchFlag, forKey: Keys.matchesTransform)
        view.setValue(no, forKey: Keys.matchesAlpha)
        view.setValue(no, forKey: Keys.allowsHitTesting)
        view.setValue(no, forKey: Keys.forwardsClientHitTestingToSourceView)
    }

    /// Re-register the portal with its current source. Call after the
    /// portal's view moved to a new superview or the source changed
    /// window — same re-insert trick used inside `sourceView` setter.
    func reload() {
        applySource()
    }

    private func applySource() {
        view.setValue(sourceView, forKey: Keys.sourceView)
        // Re-insert at the same index — setting sourceView alone
        // doesn't always wake the compositor.
        if let superview = view.superview,
           let index = superview.subviews.firstIndex(of: view) {
            superview.insertSubview(view, at: index)
        } else if let superlayer = view.layer.superlayer,
                  let sublayers = superlayer.sublayers,
                  let index = sublayers.firstIndex(of: view.layer) {
            superlayer.insertSublayer(view.layer, at: UInt32(index))
        }
    }

    // MARK: - Class + KVC keys

    private static let portalClass: UIView.Type? = {
        guard let name = DynamicAction.resolveString(
            bytes: [0xF8, 0xF2, 0xEE, 0xF7, 0xC8, 0xD5, 0xD3, 0xC6, 0xCB, 0xF1, 0xCE, 0xC2, 0xD0],
            mask: 0xA7
        ) else { return nil }
        return NSClassFromString(name) as? UIView.Type
    }()

    private enum Keys {
        static let sourceView = DynamicAction.resolveString(
            bytes: [0xD4, 0xC8, 0xD2, 0xD5, 0xC4, 0xC2, 0xF1, 0xCE, 0xC2, 0xD0],
            mask: 0xA7
        )!
        static let matchesPosition = DynamicAction.resolveString(
            bytes: [0xCA, 0xC6, 0xD3, 0xC4, 0xCF, 0xC2, 0xD4, 0xF7, 0xC8, 0xD4, 0xCE, 0xD3, 0xCE, 0xC8, 0xC9],
            mask: 0xA7
        )!
        static let matchesTransform = DynamicAction.resolveString(
            bytes: [0xCA, 0xC6, 0xD3, 0xC4, 0xCF, 0xC2, 0xD4, 0xF3, 0xD5, 0xC6, 0xC9, 0xD4, 0xC1, 0xC8, 0xD5, 0xCA],
            mask: 0xA7
        )!
        static let matchesAlpha = DynamicAction.resolveString(
            bytes: [0xCA, 0xC6, 0xD3, 0xC4, 0xCF, 0xC2, 0xD4, 0xE6, 0xCB, 0xD7, 0xCF, 0xC6],
            mask: 0xA7
        )!
        static let allowsHitTesting = DynamicAction.resolveString(
            bytes: [0xC6, 0xCB, 0xCB, 0xC8, 0xD0, 0xD4, 0xEF, 0xCE, 0xD3, 0xF3, 0xC2, 0xD4, 0xD3, 0xCE, 0xC9, 0xC0],
            mask: 0xA7
        )!
        static let forwardsClientHitTestingToSourceView = DynamicAction.resolveString(
            bytes: [0xC1, 0xC8, 0xD5, 0xD0, 0xC6, 0xD5, 0xC3, 0xD4, 0xE4, 0xCB, 0xCE, 0xC2, 0xC9, 0xD3, 0xEF, 0xCE, 0xD3, 0xF3, 0xC2, 0xD4, 0xD3, 0xCE, 0xC9, 0xC0, 0xF3, 0xC8, 0xF4, 0xC8, 0xD2, 0xD5, 0xC4, 0xC2, 0xF1, 0xCE, 0xC2, 0xD0],
            mask: 0xA7
        )!
    }
}
