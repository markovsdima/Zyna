//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ProfileCoordinator {

    let navigationController = ASDKNavigationController()
    var onLogout: (() -> Void)?

    func start() {
        let vc = ProfileViewController(mode: .own)
        vc.onLogout = { [weak self] in
            self?.onLogout?()
        }
        navigationController.setViewControllers([vc], animated: false)
    }
}
