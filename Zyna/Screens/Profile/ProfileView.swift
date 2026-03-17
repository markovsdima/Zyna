//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ProfileViewController: ASDKViewController<ProfileNode> {

    var onLogout: (() -> Void)?

    override init() {
        super.init(node: ProfileNode())

        node.onLogoutTapped = { [weak self] in
            self?.confirmLogout()
        }

        loadProfileData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.topInset = view.safeAreaInsets.top + 24
        node.bottomInset = max(view.safeAreaInsets.bottom + 16, 16)
        node.setNeedsLayout()
    }

    // MARK: - Data

    private func loadProfileData() {
        guard let client = MatrixClientService.shared.client else { return }

        Task { @MainActor in
            let userId = try? client.userId()
            let displayName = try? await client.displayName()
            let avatarUrlString = try? await client.avatarUrl()
            let avatarUrl = avatarUrlString.flatMap { URL(string: $0) }

            self.node.update(displayName: displayName, userId: userId, avatarUrl: avatarUrl)
        }
    }

    // MARK: - Actions

    private func confirmLogout() {
        let alert = UIAlertController(
            title: "Выход",
            message: "Вы уверены, что хотите выйти?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Выйти", style: .destructive) { [weak self] _ in
            self?.onLogout?()
        })
        present(alert, animated: true)
    }
}
