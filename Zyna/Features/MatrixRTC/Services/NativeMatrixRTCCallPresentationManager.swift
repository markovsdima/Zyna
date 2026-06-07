//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRustSDK
import UIKit

private let log = ScopedLog(.call, prefix: "[matrixrtc-native-ui]")

final class NativeMatrixRTCCallPresentationManager {
    static let shared = NativeMatrixRTCCallPresentationManager()

    private var activeCallViewController: NativeMatrixRTCCallViewController?
    private weak var presentingController: UIViewController?

    private init() { }

    func present(
        room: Room,
        roomDisplayName: String,
        from presenter: UIViewController
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.present(
                    room: room,
                    roomDisplayName: roomDisplayName,
                    from: presenter
                )
            }
            return
        }

        let roomID = room.id()
        presentingController = presenter

        if let activeCallViewController {
            guard activeCallViewController.roomID == roomID else {
                log("Ignored native MatrixRTC presentation for \(roomID): another call is active")
                return
            }

            restore(activeCallViewController)
            return
        }

        let callViewController = NativeMatrixRTCCallViewController(
            room: room,
            roomDisplayName: roomDisplayName
        )
        activeCallViewController = callViewController

        callViewController.onDismiss = { [weak self, weak callViewController] in
            guard let self, let callViewController else { return }
            self.finish(callViewController)
        }

        topPresentationController(from: presenter).present(callViewController, animated: true)
    }

    private func restore(_ callViewController: NativeMatrixRTCCallViewController) {
        guard activeCallViewController === callViewController else { return }
        guard callViewController.presentingViewController == nil,
              callViewController.view.window == nil else {
            return
        }

        guard let presenter = currentPresentationController() else {
            log("Failed restoring native MatrixRTC call: no presenter")
            return
        }

        topPresentationController(from: presenter).present(callViewController, animated: false)
    }

    private func finish(_ callViewController: NativeMatrixRTCCallViewController) {
        guard activeCallViewController === callViewController else { return }
        activeCallViewController = nil

        if callViewController.presentingViewController != nil {
            callViewController.dismiss(animated: true)
        }
    }

    private func currentPresentationController() -> UIViewController? {
        if let presentingController {
            return presentingController
        }

        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        return keyWindow?.rootViewController
    }

    private func topPresentationController(from controller: UIViewController) -> UIViewController {
        var controller = controller
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}
