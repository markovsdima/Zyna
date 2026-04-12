//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// A glass effect container with interactive content on top.
/// Renderer and content live inside this view's own hierarchy.
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

    /// Add interactive content here (labels, buttons, text fields).
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
        clipsToBounds = false

        anchor.cornerRadius = cornerRadius
        addSubview(anchor)
        addSubview(anchor.renderer)

        contentView.backgroundColor = .clear
        addSubview(contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        anchor.frame = bounds
        contentView.frame = bounds
    }
}
