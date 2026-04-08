//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class CallsCoordinator {

    let navigationController = ASDKNavigationController()

    var onRoomSelected: ((String) -> Void)?

    func start() {
        let vc = CallsViewController()
        vc.onCallTapped = { [weak self] roomId in
            self?.onRoomSelected?(roomId)
        }
        navigationController.setViewControllers([vc], animated: false)
    }
}
