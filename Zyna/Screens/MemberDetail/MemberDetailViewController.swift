//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class MemberDetailViewController: ASDKViewController<MemberDetailNode> {

    var onBack: (() -> Void)?
    var onSendMessage: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let viewModel: MemberDetailViewModel
    private var cancellables = Set<AnyCancellable>()
    private var activePopup: AnchoredPopupNode?
    private let glassTopBar = GlassTopBar()
    private var lastAppliedTopInset: CGFloat = -1

    init(room: Room, userId: String) {
        self.viewModel = MemberDetailViewModel(room: room, userId: userId)
        super.init(node: MemberDetailNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupGlassTopBar()

        node.onRoleTapped = { [weak self] in self?.showRolePicker() }
        node.onSendMessageTapped = { [weak self] in self?.sendMessageTapped() }
        node.onKickTapped = { [weak self] in self?.kickTapped() }
        node.onBanTapped = { [weak self] in self?.banTapped() }

        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.node.apply(state: state)
            }
            .store(in: &cancellables)

        viewModel.onError = { [weak self] error in
            self?.showError(error)
        }
        viewModel.onDismiss = { [weak self] in
            self?.onDismiss?()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
        let target = glassTopBar.coveredHeight + 8
        if abs(target - lastAppliedTopInset) > 0.5 {
            lastAppliedTopInset = target
            node.setTopInset(target)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    // MARK: - Top bar

    private func setupGlassTopBar() {
        // Must match ScreenNode's .appBG — glass memsets empty capture
        // regions with this color; mismatch shows through as wrong color.
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = node.contentNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: AppColor.accent)
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .flexibleSpace
        ]
    }

    // MARK: - Role picker

    private func showRolePicker() {
        guard let member = viewModel.state.member else { return }
        var options: [RolePickerContentNode.Option] = viewModel.state.availableRoles.map { role in
            RolePickerContentNode.Option(
                role: role,
                label: role.localizedLabel,
                enabled: true
            )
        }
        // Keep current role visible so the picker shows from → to.
        if !options.contains(where: { $0.role == member.role }) {
            options.insert(
                RolePickerContentNode.Option(
                    role: member.role,
                    label: member.role.localizedLabel,
                    enabled: false
                ),
                at: 0
            )
        }

        let content = RolePickerContentNode(options: options, currentRole: member.role)
        content.onPick = { [weak self] role in
            self?.activePopup?.dismiss {
                self?.restoreRoleRowVoiceOverFocus()
                guard role != member.role else { return }
                self?.confirmRoleChange(to: role)
            }
        }

        let popup = AnchoredPopupNode(
            content: content,
            preferredWidth: 240,
            preferredHeight: CGFloat(options.count) * RolePickerContentNode.rowHeight
        )
        popup.onDismiss = { [weak self] in
            self?.activePopup = nil
            self?.restoreRoleRowVoiceOverFocus()
        }
        activePopup = popup
        node.addSubnode(popup)
        popup.frame = node.bounds
        popup.setAnchor(node.roleRowFrame)
        popup.animateIn()
    }

    private func restoreRoleRowVoiceOverFocus() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .screenChanged, argument: node.roleRowAccessibilityView)
    }

    private func confirmRoleChange(to role: MemberCellNode.Role) {
        guard let name = viewModel.state.member?.displayName ?? viewModel.state.member?.userId else { return }
        let roleLabel = role.localizedLabel
        let alert = UIAlertController(
            title: String(localized: "Change role?"),
            message: String(localized: "Set \(name) as \(roleLabel)?"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Change"), style: .default) { [weak self] _ in
            self?.viewModel.changeRole(to: role)
        })
        present(alert, animated: true)
    }

    // MARK: - Kick / Ban / Send Message

    private func sendMessageTapped() {
        guard let userId = viewModel.state.member?.userId else { return }
        onSendMessage?(userId)
    }

    private func kickTapped() {
        let isInvite = viewModel.state.membership == .invite
        let title = isInvite ? String(localized: "Cancel invite?") : String(localized: "Kick from group?")
        let message = isInvite ? nil : String(localized: "They can be re-invited later.")
        let actionTitle = isInvite ? String(localized: "Cancel Invite") : String(localized: "Kick")
        promptReason(title: title, message: message, actionTitle: actionTitle, destructive: true) { [weak self] reason in
            self?.viewModel.kick(reason: reason)
        }
    }

    private func banTapped() {
        promptReason(
            title: String(localized: "Ban from group?"),
            message: String(localized: "Banned users can't re-join without being unbanned."),
            actionTitle: String(localized: "Ban"),
            destructive: true
        ) { [weak self] reason in
            self?.viewModel.ban(reason: reason)
        }
    }

    private func promptReason(
        title: String,
        message: String?,
        actionTitle: String,
        destructive: Bool,
        onConfirm: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = String(localized: "Reason (optional)")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: actionTitle, style: destructive ? .destructive : .default) { _ in
            let reason = alert.textFields?.first?.text ?? ""
            onConfirm(reason)
        })
        present(alert, animated: true)
    }

    // MARK: - Error

    private func showError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "Something went wrong"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Accessibility

extension MemberDetailViewController: AccessibilityFocusProviding {
    /// First element VO focuses on after push: the back button.
    var initialAccessibilityFocus: UIView? {
        glassTopBar.accessibilityElementsInOrder.first
    }
}

