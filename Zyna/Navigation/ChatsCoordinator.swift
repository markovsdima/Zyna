//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class ChatsCoordinator {

    let navigationController = ZynaNavigationController()
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
        navigationController.setStack([vc], animated: false)
        observeIncomingCalls()
    }

    // MARK: - Start Chat Flow

    private func showStartChat() {
        let vm = StartChatViewModel(roomListService: roomListService)
        let vc = StartChatViewController(viewModel: vm)

        let nav = ZynaNavigationController(rootViewController: vc)

        vm.onDMReady = { [weak self] room in
            self?.dismissAndShowChat(room: room)
        }
        vm.onNewGroup = { [weak self] in
            self?.showSelectMembers(in: nav)
        }

        navigationController.present(nav, animated: true)
    }

    private func showSelectMembers(in nav: ZynaNavigationController) {
        let vm = SelectMembersViewModel()
        let vc = SelectMembersViewController(viewModel: vm)

        vm.onNext = { [weak self] users in
            self?.showCreateGroup(members: users, in: nav)
        }

        nav.push(vc)
    }

    private func showCreateGroup(members: [UserProfile], in nav: ZynaNavigationController) {
        let vm = CreateGroupViewModel(members: members, roomListService: roomListService)
        let vc = CreateGroupViewController(viewModel: vm)

        vm.onRoomCreated = { [weak self] room in
            self?.dismissAndShowChat(room: room)
        }

        nav.push(vc)
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

    func showChat(_ room: Room) {
        let viewModel = ChatViewModel(room: room)
        let vc = ChatViewController(viewModel: viewModel)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onCallTapped = { [weak self] in
            self?.startCall(in: room, timelineService: viewModel.timelineService)
        }
        vc.onTitleTapped = { [weak self] userId in
            self?.showProfile(userId: userId)
        }
        vc.onRoomDetailsTapped = { [weak self] in
            self?.showRoomDetails(room: room, memberCount: viewModel.memberCount)
        }
        vc.onForwardMessage = { [weak self] message in
            self?.showForwardPicker(message: message, timelineService: viewModel.timelineService)
        }
        navigationController.push(vc)
    }

    private func showForwardPicker(message: ChatMessage, timelineService: TimelineService) {
        guard let eventId = message.eventId else { return }

        Task { @MainActor in
            guard let content = await timelineService.extractForwardContent(eventId: eventId) else { return }
            self.presentForwardPicker(message: message, content: content)
        }
    }

    private func presentForwardPicker(
        message: ChatMessage,
        content: RoomMessageEventContentWithoutRelation
    ) {
        let picker = ForwardPickerViewController()
        let nav = ZynaNavigationController(rootViewController: picker)

        picker.onCancel = { [weak self] in
            self?.navigationController.dismiss(animated: true)
        }
        picker.onRoomSelected = { [weak self] selectedRoom in
            self?.navigationController.dismiss(animated: true)
            self?.openChatWithForward(
                roomId: selectedRoom.id,
                forwardPreview: message,
                forwardContent: content
            )
        }

        navigationController.present(nav, animated: true)
    }

    private func openChatWithForward(
        roomId: String,
        forwardPreview: ChatMessage,
        forwardContent: RoomMessageEventContentWithoutRelation
    ) {
        // Pop back to root, then open the target chat
        navigationController.popToRoot(animated: false)

        guard let room = roomListService.room(for: roomId)
                ?? (try? MatrixClientService.shared.client?.getRoom(roomId: roomId))
        else { return }

        let viewModel = ChatViewModel(room: room)
        let vc = ChatViewController(viewModel: viewModel)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onCallTapped = { [weak self] in
            self?.startCall(in: room, timelineService: viewModel.timelineService)
        }
        vc.onTitleTapped = { [weak self] userId in
            self?.showProfile(userId: userId)
        }
        vc.onRoomDetailsTapped = { [weak self] in
            self?.showRoomDetails(room: room, memberCount: viewModel.memberCount)
        }
        vc.onForwardMessage = { [weak self] message in
            self?.showForwardPicker(message: message, timelineService: viewModel.timelineService)
        }
        navigationController.push(vc)

        // Set pending forward after push so the input bar shows it
        viewModel.setPendingForward(preview: forwardPreview, content: forwardContent)
    }

    private func showProfile(userId: String) {
        let vc = ProfileViewController(mode: .other(userId: userId))
        vc.onSearchTapped = { [weak self] in
            self?.popAndActivateSearch()
        }
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func showRoomDetails(room: Room, memberCount: Int?) {
        let vc = RoomDetailsViewController(room: room, memberCount: memberCount)
        vc.onSearchTapped = { [weak self] in
            self?.popAndActivateSearch()
        }
        vc.onInviteMembersTapped = { [weak self] in
            self?.showInviteMembers(room: room)
        }
        navigationController.push(vc)
    }

    private func showInviteMembers(room: Room) {
        let vm = SelectMembersViewModel()
        let vc = SelectMembersViewController(viewModel: vm)

        vm.onNext = { [weak self] users in
            self?.inviteUsers(users, to: room)
        }

        navigationController.push(vc)
    }

    private func inviteUsers(_ users: [UserProfile], to room: Room) {
        navigationController.pop()
        for user in users {
            let userId = user.userId
            Task {
                do {
                    try await room.inviteUserById(userId: userId)
                } catch {
                    ScopedLog(.rooms)("Invite failed for \(userId): \(error)")
                }
            }
        }
    }

    private func popAndActivateSearch() {
        navigationController.pop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let chatVC = self?.navigationController.topViewController as? ChatViewController else { return }
            chatVC.activateSearch()
        }
    }

    /// Opens a chat and immediately starts a call. Used by the Calls tab.
    func showChatAndCall(room: Room) {
        navigationController.popToRoot(animated: false)
        let viewModel = ChatViewModel(room: room)
        let vc = ChatViewController(viewModel: viewModel)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onCallTapped = { [weak self] in
            self?.startCall(in: room, timelineService: viewModel.timelineService)
        }
        vc.onTitleTapped = { [weak self] userId in
            self?.showProfile(userId: userId)
        }
        vc.onRoomDetailsTapped = { [weak self] in
            self?.showRoomDetails(room: room, memberCount: viewModel.memberCount)
        }
        navigationController.push(vc, animated: false)
        startCall(in: room, timelineService: viewModel.timelineService)
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
