//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRustSDK
import UIKit

final class ElementCallPresentationManager {

    static let shared = ElementCallPresentationManager()

    private var activeCallViewController: ElementCallViewController?
    private weak var presentingController: UIViewController?
    private var isRestoringPictureInPicture = false

    private init() { }

    func present(
        room: Room,
        roomDisplayName: String,
        deviceID: String?,
        voiceOnly: Bool,
        from presenter: UIViewController
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.present(
                    room: room,
                    roomDisplayName: roomDisplayName,
                    deviceID: deviceID,
                    voiceOnly: voiceOnly,
                    from: presenter
                )
            }
            return
        }

        let roomID = room.id()
        presentingController = presenter

        if let activeCallViewController {
            guard activeCallViewController.roomID == roomID else {
                logElementCallPresentation("Ignored Element Call presentation for \(roomID): another call is active")
                return
            }

            restore(activeCallViewController)
            return
        }

        let callViewController = ElementCallViewController(
            room: room,
            roomName: roomDisplayName,
            deviceID: deviceID,
            voiceOnly: voiceOnly
        )
        activeCallViewController = callViewController

        callViewController.onDismiss = { [weak self, weak callViewController] in
            guard let self, let callViewController else { return }
            self.finish(callViewController)
        }
        callViewController.onPictureInPictureStarted = { [weak self, weak callViewController] in
            guard let self, let callViewController else { return }
            self.minimize(callViewController)
        }
        callViewController.onPictureInPictureStopped = { [weak self, weak callViewController] in
            guard let self, let callViewController else { return }
            self.restore(callViewController)
        }
        callViewController.onPictureInPictureRestoreRequested = { [weak self, weak callViewController] completion in
            guard let self, let callViewController else {
                completion(false)
                return
            }
            self.restoreForPictureInPictureStop(callViewController, completion: completion)
        }

        topPresentationController(from: presenter).present(callViewController, animated: true)
    }

    private func minimize(_ callViewController: ElementCallViewController) {
        guard activeCallViewController === callViewController else { return }
        guard callViewController.presentingViewController != nil else { return }
        logElementCallPresentation("Minimizing Element Call into Picture in Picture")
        callViewController.dismiss(animated: false)
    }

    private func restore(_ callViewController: ElementCallViewController) {
        guard activeCallViewController === callViewController else { return }
        guard !isRestoringPictureInPicture else { return }

        if callViewController.isPictureInPictureActive {
            callViewController.stopPictureInPicture()
            return
        }

        guard callViewController.presentingViewController == nil,
              callViewController.view.window == nil else {
            return
        }

        guard let presenter = currentPresentationController() else {
            logElementCallPresentation("Failed restoring Element Call: no presenter")
            return
        }

        logElementCallPresentation("Restoring Element Call from Picture in Picture")
        topPresentationController(from: presenter).present(callViewController, animated: false)
    }

    private func restoreForPictureInPictureStop(
        _ callViewController: ElementCallViewController,
        completion: @escaping (Bool) -> Void
    ) {
        guard activeCallViewController === callViewController else {
            completion(false)
            return
        }

        guard callViewController.view.window == nil || callViewController.isBeingDismissed else {
            completion(true)
            return
        }

        guard !isRestoringPictureInPicture else {
            completion(true)
            return
        }

        if callViewController.isBeingDismissed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak callViewController] in
                guard let self, let callViewController else {
                    completion(false)
                    return
                }
                self.restoreForPictureInPictureStop(callViewController, completion: completion)
            }
            return
        }

        guard let presenter = currentPresentationController() else {
            logElementCallPresentation("Failed restoring Element Call from Picture in Picture: no presenter")
            completion(false)
            return
        }

        isRestoringPictureInPicture = true
        logElementCallPresentation("Restoring Element Call UI for Picture in Picture stop")
        topPresentationController(from: presenter).present(callViewController, animated: false) { [weak self] in
            self?.isRestoringPictureInPicture = false
            completion(true)
        }
    }

    private func finish(_ callViewController: ElementCallViewController) {
        guard activeCallViewController === callViewController else { return }
        logElementCallPresentation("Finishing Element Call presentation")
        activeCallViewController = nil
        isRestoringPictureInPicture = false

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

private let logElementCallPresentation = ScopedLog(.call, prefix: "[ElementCallPresentation]")
