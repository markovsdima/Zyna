//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SettingsCoordinator {

    let navigationController = ASDKNavigationController()

    func start() {
        let vc = SettingsViewController()
        navigationController.setViewControllers([vc], animated: false)
    }
}
