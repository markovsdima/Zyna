//
//  ButtonNode.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 20.04.2025.
//

import AsyncDisplayKit

class ButtonNode: ASButtonNode {
    private let title: String?
    private let highlightLayer = CALayer()

    init(title: String?) {
        self.title = title
        super.init()
        setupStyle()
        setupHighlight()
        setupEventHandlers()
    }

    private func setupStyle() {
        self.shadowColor = UIColor.black.cgColor
        self.shadowOpacity = 0.3
        self.shadowOffset = CGSize(width: 0, height: 2)
        self.shadowRadius = 4
        self.contentEdgeInsets = UIEdgeInsets(top: 16, left: 66, bottom: 16, right: 66)
        
        if let title {
            let attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
            self.setAttributedTitle(attributedTitle, for: .normal)
        }
    }

    private func setupHighlight() {
        highlightLayer.backgroundColor = UIColor.white.withAlphaComponent(0.3).cgColor
        highlightLayer.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
        highlightLayer.isHidden = true
        self.layer.addSublayer(highlightLayer)
    }

    private func setupEventHandlers() {
        self.addTarget(self, action: #selector(handleTouchDown), forControlEvents: .touchDown)
        self.addTarget(self, action: #selector(handleTouchUp), forControlEvents: .touchUpInside)
        self.addTarget(self, action: #selector(handleTouchUp), forControlEvents: .touchCancel)
        self.addTarget(self, action: #selector(handleTouchUp), forControlEvents: .touchUpOutside)
    }

    @objc private func handleTouchDown() {
        highlightLayer.isHidden = false
    }

    @objc private func handleTouchUp() {
        highlightLayer.isHidden = true
    }

    override func layout() {
        super.layout()
        //gradientNode.frame = self.bounds
        highlightLayer.frame = self.bounds
    }

    func setTitle(_ title: String) {
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )
        self.setAttributedTitle(attributedTitle, for: .normal)
    }
}
