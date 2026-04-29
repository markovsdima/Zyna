//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ChatPeekPressureRimView: UIView {

    var cardFrame: CGRect = .zero {
        didSet {
            guard !cardFrame.equalTo(oldValue) else { return }
            updatePaths()
        }
    }

    var cornerRadius: CGFloat = 24 {
        didSet {
            guard cornerRadius != oldValue else { return }
            updatePaths()
        }
    }

    private let outerShadowLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let innerShadeLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        backgroundColor = .clear

        outerShadowLayer.fillColor = UIColor.clear.cgColor
        outerShadowLayer.lineJoin = .round
        outerShadowLayer.lineCap = .round
        outerShadowLayer.shadowColor = UIColor.black.cgColor
        outerShadowLayer.strokeColor = UIColor.black.withAlphaComponent(0.18).cgColor
        outerShadowLayer.lineWidth = 16
        outerShadowLayer.opacity = 0.48
        outerShadowLayer.shadowOpacity = 0.16
        outerShadowLayer.shadowRadius = 18
        outerShadowLayer.shadowOffset = CGSize(width: 0, height: 10)
        layer.addSublayer(outerShadowLayer)

        innerShadeLayer.fillColor = UIColor.clear.cgColor
        innerShadeLayer.strokeColor = UIColor.black.withAlphaComponent(0.18).cgColor
        innerShadeLayer.lineWidth = 3
        innerShadeLayer.opacity = 0.42
        layer.addSublayer(innerShadeLayer)

        highlightLayer.fillColor = UIColor.clear.cgColor
        highlightLayer.strokeColor = UIColor.white.withAlphaComponent(0.34).cgColor
        highlightLayer.lineWidth = 1.2
        highlightLayer.opacity = 0.72
        highlightLayer.shadowColor = UIColor.white.cgColor
        highlightLayer.shadowOpacity = 0.22
        highlightLayer.shadowRadius = 5
        highlightLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outerShadowLayer.frame = bounds
        highlightLayer.frame = bounds
        innerShadeLayer.frame = bounds
        updatePaths()
    }

    private func updatePaths() {
        guard bounds.width > 0,
              bounds.height > 0,
              !cardFrame.isEmpty
        else { return }

        let outerInset: CGFloat = -5
        let innerInset: CGFloat = 1.5
        let highlightInset: CGFloat = -1.5
        let outerRect = cardFrame.insetBy(dx: outerInset, dy: outerInset)
        let innerRect = cardFrame.insetBy(dx: innerInset, dy: innerInset)
        let highlightRect = cardFrame.insetBy(dx: highlightInset, dy: highlightInset)
        outerShadowLayer.path = UIBezierPath(
            roundedRect: outerRect,
            cornerRadius: cornerRadius - outerInset
        ).cgPath
        innerShadeLayer.path = UIBezierPath(
            roundedRect: innerRect,
            cornerRadius: max(0, cornerRadius - innerInset)
        ).cgPath
        highlightLayer.path = UIBezierPath(
            roundedRect: highlightRect,
            cornerRadius: cornerRadius - highlightInset
        ).cgPath
    }
}
