//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

private enum ChatScreenTarget {
    case live(Room)
    case cached(RoomModel)
}

final class ChatsCoordinator {

    let navigationController = ZynaNavigationController()
    private let roomListService = ZynaRoomListService()
    private let audioPlayer: AudioPlayerService
    private var cancellables = Set<AnyCancellable>()

    init(audioPlayer: AudioPlayerService) {
        self.audioPlayer = audioPlayer
    }

    func start() {
        let vc = RoomsViewController(
            audioPlayer: audioPlayer,
            roomListService: roomListService
        )
        vc.onChatSelected = { [weak self] target in
            self?.showChat(target)
        }
        vc.onChatPreviewRequested = { [weak self] target, sourceFrame, backgroundSourceView in
            self?.showChatPreview(
                target,
                sourceFrame: sourceFrame,
                backgroundSourceView: backgroundSourceView
            )
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
            self?.showCreateGroup(in: nav)
        }

        configureComposeSheet(nav)
        navigationController.present(nav, animated: true)
    }

    private func configureComposeSheet(_ controller: UIViewController) {
        controller.modalPresentationStyle = .pageSheet
        guard let sheet = controller.sheetPresentationController else { return }
        sheet.detents = [.large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }

    private func showSelectMembers(in nav: ZynaNavigationController) {
        let vm = SelectMembersViewModel()
        let vc = SelectMembersViewController(viewModel: vm)

        vm.onNext = { [weak self] users in
            self?.showCreateGroup(members: users, in: nav, showsInviteStepAfterCreation: false)
        }

        nav.push(vc)
    }

    private func showCreateGroup(
        members: [UserProfile] = [],
        in nav: ZynaNavigationController,
        showsInviteStepAfterCreation: Bool = true
    ) {
        let vm = CreateGroupViewModel(members: members, roomListService: roomListService)
        let vc = CreateGroupViewController(viewModel: vm)

        vm.onRoomCreated = { [weak self, weak nav] room in
            if showsInviteStepAfterCreation, let nav {
                self?.showPostCreateInviteMembers(room: room, in: nav)
            } else {
                self?.dismissAndShowChat(room: room)
            }
        }

        nav.push(vc)
    }

    private func showPostCreateInviteMembers(room: Room, in nav: ZynaNavigationController) {
        let vm = SelectMembersViewModel(allowsSkip: true)
        let vc = SelectMembersViewController(viewModel: vm)
        vc.title = String(localized: "Invite Members")

        vm.onNext = { [weak self] users in
            self?.inviteUsersInBackground(users, to: room)
            self?.dismissAndShowChat(room: room)
        }
        vm.onSkip = { [weak self] in
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
        showChat(room, animated: true)
    }

    func showChat(_ room: Room, animated: Bool) {
        showChatScreen(.live(room), animated: animated)
    }

    private func showChat(_ target: ChatOpenTarget) {
        showChat(target, animated: true)
    }

    private func showChat(_ target: ChatOpenTarget, animated: Bool) {
        switch target {
        case .live(let room):
            showChatScreen(.live(room), animated: animated)
        case .cached(let room):
            showChatScreen(.cached(room), animated: animated)
        case .space(let space):
            showSpace(space, animated: animated)
        }
    }

    private func showChatScreen(_ target: ChatScreenTarget, animated: Bool) {
        let (vc, _) = makeChatScreen(target: target)
        navigationController.push(vc, animated: animated)
    }

    private func showSpace(_ space: RoomModel, animated: Bool) {
        let vc = SpaceViewController(space: space, roomListService: roomListService)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onSettings = {
            ScopedLog(.rooms)("Storyline title tapped: \(space.id)")
        }
        vc.onChatSelected = { [weak self] chat in
            if let room = self?.roomListService.room(for: chat.id) {
                self?.showChat(room)
            } else {
                self?.showChat(.cached(chat))
            }
        }
        navigationController.push(vc, animated: animated)
    }

    private func showChatPreview(
        _ target: ChatOpenTarget,
        sourceFrame: CGRect?,
        backgroundSourceView: UIView?
    ) {
        guard navigationController.presentedViewController == nil else { return }

        let viewModel: ChatViewModel
        switch target {
        case .live(let room):
            viewModel = ChatViewModel(room: room, mode: .preview)
        case .cached(let room):
            viewModel = ChatViewModel(cachedRoom: room, mode: .preview)
        case .space:
            return
        }
        let chatController = ChatViewController(viewModel: viewModel, audioPlayer: audioPlayer)
        let resolvedBackgroundSourceView = navigationController.parent?.view
            ?? backgroundSourceView
            ?? navigationController.view
        let overlay = ChatPeekOverlayController(
            chatController: chatController,
            sourceFrameInScreen: sourceFrame,
            backgroundSourceView: resolvedBackgroundSourceView
        )
        navigationController.present(overlay, animated: false)
    }

    private func showForwardPicker(message: ChatMessage) {
        guard message.eventId != nil,
              message.content.textBody != nil
                || message.content.mediaForwardInfo != nil else { return }
        presentForwardPicker(message: message)
    }

    private func presentForwardPicker(message: ChatMessage) {
        let picker = ForwardPickerViewController()
        let nav = ZynaNavigationController(rootViewController: picker)

        picker.onCancel = { [weak self] in
            self?.navigationController.dismiss(animated: true)
        }
        picker.onRoomSelected = { [weak self] selectedRoom in
            self?.navigationController.dismiss(animated: true)
            self?.openChatWithForward(
                roomModel: selectedRoom,
                forwardPreview: message
            )
        }

        navigationController.present(nav, animated: true)
    }

    private func makeChatScreen(
        target: ChatScreenTarget
    ) -> (controller: ChatViewController, viewModel: ChatViewModel) {
        let viewModel: ChatViewModel
        switch target {
        case .live(let room):
            viewModel = ChatViewModel(room: room)
        case .cached(let room):
            viewModel = ChatViewModel(cachedRoom: room)
        }
        let vc = ChatViewController(viewModel: viewModel, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onCallTapped = { [weak self] in
            guard let room = viewModel.liveRoom,
                  let timelineService = viewModel.liveTimelineService else { return }
            self?.startCall(in: room, timelineService: timelineService)
        }
        vc.onTitleTapped = { [weak self] userId in
            self?.showProfile(userId: userId)
        }
        vc.onSecurityUserTapped = { [weak self] userId in
            guard let room = viewModel.liveRoom else { return }
            self?.showMemberDetail(room: room, userId: userId)
        }
        vc.onRoomDetailsTapped = { [weak self] in
            guard let room = viewModel.liveRoom else { return }
            self?.showRoomDetails(
                room: room,
                memberCount: viewModel.memberCount,
                directUserId: viewModel.partnerUserId
            )
        }
        vc.onForwardMessage = { [weak self] message in
            self?.showForwardPicker(message: message)
        }
        return (vc, viewModel)
    }

    private func openChatWithForward(
        roomModel: RoomModel,
        forwardPreview: ChatMessage
    ) {
        // Pop back to root, then open the target chat
        navigationController.popToRoot(animated: false)

        let target: ChatScreenTarget
        if let room = roomListService.room(for: roomModel.id)
            ?? (try? MatrixClientService.shared.client?.getRoom(roomId: roomModel.id)) {
            target = .live(room)
        } else {
            target = .cached(roomModel)
        }

        let (vc, viewModel) = makeChatScreen(target: target)
        navigationController.push(vc)

        // Set pending forward after push so the input bar shows it
        viewModel.setPendingForward(forwardPreview)
    }

    private func showProfile(userId: String) {
        let vc = ProfileViewController(mode: .other(userId: userId), audioPlayer: audioPlayer)
        vc.onSearchTapped = { [weak self] in
            self?.popAndActivateSearch()
        }
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func showRoomDetails(
        room: Room,
        memberCount: Int?,
        directUserId: String? = nil
    ) {
        let vc = RoomDetailsViewController(
            room: room,
            memberCount: memberCount,
            directUserId: directUserId,
            audioPlayer: audioPlayer
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onSearchTapped = { [weak self] in
            self?.popAndActivateSearch()
        }
        vc.onInviteMembersTapped = { [weak self] in
            self?.showInviteMembers(room: room)
        }
        vc.onMembersTapped = { [weak self] in
            self?.showMembersList(room: room)
        }
        vc.onProfileTapped = { [weak self] userId in
            self?.showProfile(userId: userId)
        }
        vc.onPinnedMessagesTapped = { [weak self] in
            self?.showPinnedMessages(room: room)
        }
        vc.onSecurityPrivacyTapped = { [weak self] in
            self?.showRoomSecurityPrivacy(room: room)
        }
        vc.onRolesPermissionsTapped = { [weak self] in
            self?.showRoomRolesPermissions(room: room)
        }
        vc.onRoomLeft = { [weak self] roomId in
            self?.handleRoomLeft(roomId: roomId)
        }
        navigationController.push(vc)
    }

    private func handleRoomLeft(roomId: String) {
        roomListService.removeRoomLocally(roomId: roomId)
        navigationController.popToRoot(animated: true)
    }

    private func showPinnedMessages(room: Room) {
        let vc = PinnedMessagesViewController(room: room, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onSelectEvent = { [weak self] eventId in
            self?.openPinnedEvent(eventId)
        }
        navigationController.push(vc)
    }

    private func openPinnedEvent(_ eventId: String) {
        guard let index = navigationController.stack.lastIndex(where: { $0 is ChatViewController }),
              let chatVC = navigationController.stack[index] as? ChatViewController
        else {
            navigationController.pop()
            return
        }

        let targetStack = Array(navigationController.stack.prefix(index + 1))
        navigationController.setStack(targetStack, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            chatVC.navigateToEvent(eventId: eventId)
        }
    }

    private func showRoomSecurityPrivacy(room: Room) {
        let vc = RoomSecurityPrivacyViewController(room: room, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func showRoomRolesPermissions(room: Room) {
        let vc = RoomRolesPermissionsViewController(room: room, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func showMembersList(room: Room) {
        let vc = MembersListViewController(room: room, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onSelectUser = { [weak self] userId in
            self?.showMemberDetail(room: room, userId: userId)
        }
        navigationController.push(vc)
    }

    private func showMemberDetail(room: Room, userId: String) {
        let vc = MemberDetailViewController(
            room: room,
            userId: userId,
            audioPlayer: audioPlayer
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onSendMessage = { [weak self] targetUserId in
            self?.openDM(with: targetUserId)
        }
        vc.onDismiss = { [weak self] in
            self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func openDM(with userId: String) {
        Task { [weak self] in
            guard let self,
                  let client = MatrixClientService.shared.client else { return }
            do {
                if let existing = try client.getDmRoom(userId: userId) {
                    await MainActor.run {
                        self.navigationController.popToRoot(animated: false)
                        self.showChat(existing)
                    }
                    return
                }
                let params = CreateRoomParameters(
                    name: nil, topic: nil, isEncrypted: true, isDirect: true,
                    visibility: .private, preset: .trustedPrivateChat,
                    invite: [userId], avatar: nil, powerLevelContentOverride: nil,
                    joinRuleOverride: nil, historyVisibilityOverride: nil,
                    canonicalAlias: nil
                )
                let roomId = try await client.createRoom(request: params)
                guard let dmRoom = roomListService.room(for: roomId) else { return }
                await MainActor.run {
                    self.navigationController.popToRoot(animated: false)
                    self.showChat(dmRoom)
                }
            } catch {
                ScopedLog(.rooms)("Failed to open DM: \(error)")
            }
        }
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
        inviteUsersInBackground(users, to: room)
    }

    private func inviteUsersInBackground(_ users: [UserProfile], to room: Room) {
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
        let (vc, viewModel) = makeChatScreen(target: .live(room))
        navigationController.push(vc, animated: false)
        if let timelineService = viewModel.liveTimelineService {
            startCall(in: room, timelineService: timelineService)
        }
    }

    // MARK: - Calls

    private func startCall(in room: Room, timelineService: TimelineService) {
        guard canSendEncryptedEvents(in: room) else {
            presentVerificationRequiredForCall()
            return
        }
        CallService.shared.startCall(room: room, timelineService: timelineService)
        presentCallScreen(roomName: room.displayName() ?? "Call")
    }

    private func canSendEncryptedEvents(in room: Room) -> Bool {
        room.encryptionState() == .notEncrypted
            || SessionVerificationService.shared.canSendEncryptedMessages
    }

    private func presentVerificationRequiredForCall() {
        guard navigationController.presentedViewController == nil else { return }

        let alert = UIAlertController(
            title: String(localized: "Verify This Device"),
            message: String(localized: "Zyna only sends encrypted messages from verified devices. Verify this device or restore with your recovery key, then retry the message."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Verify Device"), style: .default) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.presentSessionVerificationFromCall()
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        navigationController.present(alert, animated: true)
    }

    private func presentSessionVerificationFromCall() {
        guard navigationController.presentedViewController == nil else { return }

        let viewModel = SessionVerificationViewModel()
        viewModel.onVerified = { [weak self] in
            self?.navigationController.dismiss(animated: true)
        }
        viewModel.onSkipped = { [weak self] in
            self?.navigationController.dismiss(animated: true)
        }

        let vc = SessionVerificationView(viewModel: viewModel).wrapped()
        vc.modalPresentationStyle = .fullScreen
        navigationController.present(vc, animated: true)
    }

    func presentCallScreen(roomName: String) {
        let callVC = CallViewController(roomName: roomName)
        callVC.onDismiss = { [weak self] in
            self?.navigationController.dismiss(animated: true)
        }
        navigationController.present(callVC, animated: true)
    }
}
