//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class CallsCoordinator {

    let navigationController = ZynaNavigationController()

    var onRoomSelected: ((String) -> Void)?

    func start() {
        let vc = CallsViewController()
        vc.onCallTapped = { [weak self] roomId in
            self?.onRoomSelected?(roomId)
        }
        navigationController.setStack([vc], animated: false)
    }
}
