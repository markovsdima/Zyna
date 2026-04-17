//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class CreateGroupViewController: ASDKViewController<CreateGroupNode> {

    private let viewModel: CreateGroupViewModel

    init(viewModel: CreateGroupViewModel) {
        self.viewModel = viewModel
        super.init(node: CreateGroupNode())
        title = String(localized: "New Group")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = []
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .appBG
        appearance.shadowColor = .clear
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        node.updateMembersCount(viewModel.members.count)
        node.nameInputNode.delegate = self
        node.topicInputNode.delegate = self
        node.createButtonNode.addTarget(self, action: #selector(createTapped), forControlEvents: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.cancelsTouchesInView = false
        node.view.addGestureRecognizer(tap)
    }

    @objc private func createTapped() {
        viewModel.roomName = node.nameInputNode.textView.text ?? ""
        viewModel.roomTopic = node.topicInputNode.textView.text ?? ""
        viewModel.createRoom()
    }

    @objc private func dismissKeyboard() {
        node.view.endEditing(true)
    }
}

// MARK: - ASEditableTextNodeDelegate

extension CreateGroupViewController: ASEditableTextNodeDelegate {
    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        // Sync text to viewModel on every change
        if editableTextNode === node.nameInputNode {
            viewModel.roomName = editableTextNode.textView.text ?? ""
        } else if editableTextNode === node.topicInputNode {
            viewModel.roomTopic = editableTextNode.textView.text ?? ""
        }
    }
}
