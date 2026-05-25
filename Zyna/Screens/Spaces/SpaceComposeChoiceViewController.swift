//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceComposeChoiceViewController: ASDKViewController<SpaceComposeChoiceNode> {

    var onCancel: (() -> Void)?
    var onExistingChat: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onNewTrack: (() -> Void)?

    init(parent: RoomModel, presentation: SpacePresentationKind) {
        super.init(node: SpaceComposeChoiceNode(parent: parent, presentation: presentation))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        node.cancelButtonNode.addTarget(
            self,
            action: #selector(cancelTapped),
            forControlEvents: .touchUpInside
        )
        node.existingChatOptionNode.onTap = { [weak self] in
            self?.onExistingChat?()
        }
        node.chatOptionNode.onTap = { [weak self] in
            self?.onNewChat?()
        }
        node.trackOptionNode.onTap = { [weak self] in
            self?.onNewTrack?()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topInset = view.safeAreaInsets.top + 20
        if abs(node.topInset - topInset) > 0.5 {
            node.topInset = topInset
        }
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
