//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class CreateGroupViewController: ASDKViewController<CreateGroupNode> {

    private let viewModel: CreateGroupViewModel
    private var isUpdatingAliasProgrammatically = false

    init(
        viewModel: CreateGroupViewModel,
        presentation: CreateRoomPresentation = .groupRoom
    ) {
        self.viewModel = viewModel
        super.init(node: CreateGroupNode(presentation: presentation))
        title = presentation.screenTitle
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
        node.updateSelection(postingPermission: viewModel.postingPermission, access: viewModel.roomAccess)
        node.updateAliasServerName(viewModel.serverName)
        node.updateAliasLocalPart(viewModel.roomAliasLocalPart)
        node.nameInputNode.delegate = self
        node.topicInputNode.delegate = self
        node.aliasInputNode.delegate = self
        node.createButtonNode.addTarget(self, action: #selector(createTapped), forControlEvents: .touchUpInside)
        node.onPostingPermissionSelected = { [weak self] permission in
            guard let self else { return }
            self.viewModel.updatePostingPermission(permission)
        }
        node.onRoomAccessSelected = { [weak self] access in
            guard let self else { return }
            self.viewModel.updateRoomAccess(access)
            self.updateAliasInput(self.viewModel.roomAliasLocalPart)
        }
        viewModel.onError = { [weak self] message in
            self?.showError(message)
        }
        viewModel.onCreatingChanged = { [weak self] isCreating in
            self?.node.updateCreating(isCreating)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        node.view.addGestureRecognizer(tap)
    }

    @objc private func createTapped() {
        viewModel.updateRoomName(node.nameInputNode.textView.text ?? "")
        viewModel.updateRoomTopic(node.topicInputNode.textView.text ?? "")
        viewModel.createRoom()
    }

    @objc private func dismissKeyboard() {
        node.view.endEditing(true)
    }

    private func updateAliasInput(_ localPart: String) {
        isUpdatingAliasProgrammatically = true
        node.updateAliasLocalPart(localPart)
        isUpdatingAliasProgrammatically = false
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Could not create room"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - ASEditableTextNodeDelegate

extension CreateGroupViewController: ASEditableTextNodeDelegate {
    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        // Sync text to viewModel on every change
        if editableTextNode === node.nameInputNode {
            viewModel.updateRoomName(editableTextNode.textView.text ?? "")
            if viewModel.roomAccess.isPublic {
                updateAliasInput(viewModel.roomAliasLocalPart)
            }
        } else if editableTextNode === node.topicInputNode {
            viewModel.updateRoomTopic(editableTextNode.textView.text ?? "")
        } else if editableTextNode === node.aliasInputNode, !isUpdatingAliasProgrammatically {
            viewModel.updateRoomAliasLocalPart(editableTextNode.textView.text ?? "")
            updateAliasInput(viewModel.roomAliasLocalPart)
        }
    }
}
