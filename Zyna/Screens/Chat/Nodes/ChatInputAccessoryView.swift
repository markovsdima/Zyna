//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit

final class ChatInputAccessoryView: UIView {

    let inputNode = ChatInputNode()

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = .flexibleHeight
        backgroundColor = .systemBackground
        addSubview(inputNode.view)

        inputNode.onSizeChanged = { [weak self] in
            self?.invalidateIntrinsicContentSize()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = inputNode.layoutThatFits(ASSizeRange(
            min: CGSize(width: width, height: 0),
            max: CGSize(width: width, height: .greatestFiniteMagnitude)
        )).size
        return CGSize(width: width, height: size.height + safeAreaInsets.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        inputNode.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }
}
