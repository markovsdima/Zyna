//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class ChatsCoordinator {

    let navigationController = ASDKNavigationController()
    private let roomListService = ZynaRoomListService()
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let vc = RoomsViewController()
        vc.onChatSelected = { [weak self] room in
            self?.showChat(room)
        }
        vc.onComposeTapped = { [weak self] in
            self?.showStartChat()
        }
        navigationController.setViewControllers([vc], animated: false)
        observeIncomingCalls()
    }

    // MARK: - Start Chat Flow

    private func showStartChat() {
        let vm = StartChatViewModel(roomListService: roomListService)
        let vc = StartChatViewController(viewModel: vm)

        let nav = ASDKNavigationController(rootViewController: vc)

        vm.onDMReady = { [weak self] room in
            self?.dismissAndShowChat(room: room)
        }
        vm.onNewGroup = { [weak self] in
            self?.showSelectMembers(in: nav)
        }

        navigationController.present(nav, animated: true)
    }

    private func showSelectMembers(in nav: ASDKNavigationController) {
        let vm = SelectMembersViewModel()
        let vc = SelectMembersViewController(viewModel: vm)

        vm.onNext = { [weak self] users in
            self?.showCreateGroup(members: users, in: nav)
        }

        nav.pushViewController(vc, animated: true)
    }

    private func showCreateGroup(members: [UserProfile], in nav: ASDKNavigationController) {
        let vm = CreateGroupViewModel(members: members, roomListService: roomListService)
        let vc = CreateGroupViewController(viewModel: vm)

        vm.onRoomCreated = { [weak self] room in
            self?.dismissAndShowChat(room: room)
        }

        nav.pushViewController(vc, animated: true)
    }

    private func dismissAndShowChat(room: Room) {
        navigationController.dismiss(animated: true) { [weak self] in
            self?.showChat(room)
        }
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
