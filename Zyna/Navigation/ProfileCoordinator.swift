//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ProfileCoordinator {

    let navigationController = ZynaNavigationController()
    var onLogout: (() -> Void)?

    func start() {
        let vc = ProfileViewController(mode: .own)
        vc.onLogout = { [weak self] in
            self?.onLogout?()
        }
        vc.onSettingsTapped = { [weak self] in
            self?.showSettings()
        }
        navigationController.setStack([vc], animated: false)
    }

    private func showSettings() {
        let vc = SettingsViewController()
        vc.onBack = { [weak self] in
            _ = self?.navigationController.pop()
        }
        vc.onThemeTapped = { [weak self] in
            self?.showChatThemeSettings()
        }
        vc.onNameColorTapped = { [weak self] in
            self?.showNameColorSettings()
        }
        navigationController.push(vc)
    }

    private func showChatThemeSettings() {
        let vc = ChatThemeSettingsViewController()
        vc.onBack = { [weak self] in
            _ = self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func showNameColorSettings() {
        let vc = ProfileNameColorSettingsViewController()
        vc.onBack = { [weak self] in
            _ = self?.navigationController.pop()
        }
        navigationController.push(vc)
    }
}
