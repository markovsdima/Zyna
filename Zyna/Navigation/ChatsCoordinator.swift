//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class ChatsCoordinator {

    let navigationController = ASDKNavigationController()
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let vc = RoomsViewController()
        vc.onChatSelected = { [weak self] room in
            self?.showChat(room)
        }
        navigationController.setViewControllers([vc], animated: false)
        observeIncomingCalls()
    }

    private func observeIncomingCalls() {
        CallService.shared.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard case .incomingRinging(_, _, let callerName) = state else { return }
                // Don't present if already showing a call screen
                guard self?.navigationController.presentedViewController == nil else { return }
                self?.presentCallScreen(roomName: callerName ?? "Incoming Call")
            }
            .store(in: &cancellables)
    }

    private func showChat(_ room: Room) {
        let viewModel = ChatViewModel(room: room)
        let vc = ChatViewController(viewModel: viewModel)
        vc.onBack = { [weak self] in
            self?.navigationController.popViewController(animated: true)
        }
        vc.onCallTapped = { [weak self] in
            self?.startCall(in: room, timelineService: viewModel.timelineService)
        }
        navigationController.pushViewController(vc, animated: true)
        navigationController.enableFullScreenPopGesture()
    }

    // MARK: - Calls

    private func startCall(in room: Room, timelineService: TimelineService) {
        CallService.shared.startCall(room: room, timelineService: timelineService)
        presentCallScreen(roomName: room.displayName() ?? "Call")
    }

    func presentCallScreen(roomName: String) {
        let callVC = CallViewController(roomName: roomName)
        callVC.onDismiss = { [weak self] in
            self?.navigationController.dismiss(animated: true)
        }
        navigationController.present(callVC, animated: true)
    }
}
