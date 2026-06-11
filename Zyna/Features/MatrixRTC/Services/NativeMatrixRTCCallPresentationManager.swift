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
    private var pendingRoomID: String?

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
        if let activeCallViewController {
            guard activeCallViewController.roomID == roomID else {
                log("Ignored native MatrixRTC presentation for \(roomID): another call is active")
                return
            }

            restore(activeCallViewController)
            return
        }

        if let pendingRoomID {
            guard pendingRoomID == roomID else {
                log("Ignored native MatrixRTC presentation for \(roomID): another call presentation is pending")
                return
            }
            return
        }

        pendingRoomID = roomID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = await makeLaunchContext(
                room: room,
                roomDisplayName: roomDisplayName
            )
            guard pendingRoomID == context.roomID else { return }
            pendingRoomID = nil
            present(context: context, from: presenter)
        }
    }

    private func present(
        context: NativeMatrixRTCCallLaunchContext,
        from presenter: UIViewController
    ) {
        let roomID = context.roomID
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
            context: context
        )
        activeCallViewController = callViewController

        callViewController.onDismiss = { [weak self, weak callViewController] in
            guard let self, let callViewController else { return }
            self.finish(callViewController)
        }

        topPresentationController(from: presenter).present(callViewController, animated: true)
    }

    private func makeLaunchContext(
        room: Room,
        roomDisplayName: String
    ) async -> NativeMatrixRTCCallLaunchContext {
        let avatar = AvatarViewModel(
            userId: room.id(),
            displayName: roomDisplayName,
            mxcAvatarURL: room.avatarUrl()
        )
        let kind: NativeMatrixRTCCallKind
        if await room.isDirect() {
            kind = .direct(peer: NativeMatrixRTCCallPeer(
                id: room.id(),
                displayName: roomDisplayName,
                avatar: avatar
            ))
        } else {
            kind = .group(room: NativeMatrixRTCCallRoomInfo(
                id: room.id(),
                displayName: roomDisplayName,
                avatar: avatar
            ))
        }

        return NativeMatrixRTCCallLaunchContext(
            room: room,
            roomDisplayName: roomDisplayName,
            kind: kind,
            direction: .outgoing,
            initialMedia: .audio
        )
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
        pendingRoomID = nil

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
