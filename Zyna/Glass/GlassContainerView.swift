//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// A glass effect container with interactive content on top.
///
/// Place in the main window like a normal UIView. The glass renderer and
/// `contentView` are positioned in the main window by GlassService.
///
/// Usage:
///     let glass = GlassContainerView()
///     glass.cornerRadius = 20
///     glass.contentView.addSubview(myLabel)
///     parentView.addSubview(glass)
///     glass.frame = CGRect(x: 16, y: 100, width: 400, height: 49)
///
final class GlassContainerView: UIView {

    // MARK: - Public

    /// Add your interactive content here (labels, buttons, text fields).
    /// Positioned above the glass renderer in the main window.
    let contentView = UIView()

    var cornerRadius: CGFloat = 24 {
        didSet { anchor.cornerRadius = cornerRadius }
    }

    // MARK: - Private

    private let anchor = GlassAnchor()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false // touches go through to content above

        anchor.cornerRadius = cornerRadius
        addSubview(anchor)

        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            GlassService.shared.attachContent(contentView, for: anchor)
        } else {
            contentView.removeFromSuperview()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        anchor.frame = bounds
    }
}
