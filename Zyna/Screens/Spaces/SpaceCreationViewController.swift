//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceCreationViewController: ASDKViewController<SpaceCreationNode> {

    var onBack: (() -> Void)?

    private let viewModel: SpaceCreationViewModel
    private var isUpdatingAliasProgrammatically = false

    init(viewModel: SpaceCreationViewModel) {
        self.viewModel = viewModel
        super.init(node: SpaceCreationNode(mode: viewModel.mode))
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupInputs()
        bindViewModel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let topInset = view.safeAreaInsets.top + 20
        if abs(node.topInset - topInset) > 0.5 {
            node.topInset = topInset
        }
    }

    private func setupInputs() {
        node.backButtonNode.addTarget(
            self,
            action: #selector(backTapped),
            forControlEvents: .touchUpInside
        )
        node.nameInputNode.delegate = self
        node.topicInputNode.delegate = self
        node.aliasInputNode.delegate = self
        node.onAccessSelected = { [weak self] access in
            guard let self else { return }
            self.viewModel.updateAccess(access)
            self.node.updateSelection(access: access)
            self.updateAliasInput(self.viewModel.aliasLocalPart)
        }
        node.updateSelection(access: viewModel.access)
        node.updateAliasServerName(viewModel.serverName)
        updateAliasInput(viewModel.aliasLocalPart)
        node.createButtonNode.addTarget(
            self,
            action: #selector(createTapped),
            forControlEvents: .touchUpInside
        )

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        node.view.addGestureRecognizer(tap)
    }

    @objc private func backTapped() {
        onBack?()
    }

    private func bindViewModel() {
        viewModel.onCreatingChanged = { [weak self] isCreating in
            self?.node.updateCreating(isCreating)
        }
        viewModel.onError = { [weak self] message in
            self?.showError(message)
        }
    }

    @objc private func createTapped() {
        viewModel.updateName(node.nameInputNode.textView.text ?? "")
        viewModel.updateTopic(node.topicInputNode.textView.text ?? "")
        if viewModel.access.isPublic {
            viewModel.updateAliasLocalPart(node.aliasInputNode.textView.text ?? "")
        }
        viewModel.createSpace()
    }

    @objc private func dismissKeyboard() {
        node.view.endEditing(true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: viewModel.mode.errorTitle,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func updateAliasInput(_ localPart: String) {
        isUpdatingAliasProgrammatically = true
        node.updateAliasLocalPart(localPart)
        isUpdatingAliasProgrammatically = false
    }
}

extension SpaceCreationViewController: ASEditableTextNodeDelegate {
    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        if editableTextNode === node.nameInputNode {
            viewModel.updateName(editableTextNode.textView.text ?? "")
            if viewModel.access.isPublic {
                updateAliasInput(viewModel.aliasLocalPart)
            }
        } else if editableTextNode === node.topicInputNode {
            viewModel.updateTopic(editableTextNode.textView.text ?? "")
        } else if editableTextNode === node.aliasInputNode, !isUpdatingAliasProgrammatically {
            viewModel.updateAliasLocalPart(editableTextNode.textView.text ?? "")
            updateAliasInput(viewModel.aliasLocalPart)
        }
    }
}
