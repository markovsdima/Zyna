//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class CallsCoordinator {

    let navigationController = ZynaNavigationController()
    private let audioPlayer: AudioPlayerService

    var onRoomSelected: ((String) -> Void)?

    init(audioPlayer: AudioPlayerService) {
        self.audioPlayer = audioPlayer
    }

    func start() {
        let vc = CallsViewController(audioPlayer: audioPlayer)
        vc.onCallTapped = { [weak self] roomId in
            self?.onRoomSelected?(roomId)
        }
        navigationController.setStack([vc], animated: false)
    }
}
