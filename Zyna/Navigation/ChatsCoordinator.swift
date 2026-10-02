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

    var roomID: String {
        switch self { case .live(let room): room.id(); case .cached(let room): room.id }
    }
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
        vm.onNewStoryline = { [weak self] in
            self?.showCreateSpace(mode: .storyline, in: nav)
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
            if requiresRoomJoinPreview(room) {
                showRoomJoinPreview(room, animated: animated)
            } else {
                showChatScreen(.cached(room), animated: animated)
            }
        case .space(let space):
            if requiresSpaceJoinPreview(space) {
                showSpaceJoinPreview(space, animated: animated, presentation: .storyline)
            } else {
                showSpace(space, animated: animated)
            }
        }
    }

    private func showChatScreen(_ target: ChatScreenTarget, animated: Bool, forward: ChatMessage? = nil) {
        if navigationController.returnToChat(roomID: target.roomID, animated: animated, forward: forward) { return }
        #if DEBUG || CHAT_LIST_PLAYGROUND
        if ChatListPlaygroundSettings.isEnabled, forward == nil {
            showChatListPlaygroundPicker(target, animated: animated)
            return
        }
        #endif
        #if DEBUG
        if AttachmentsResearchSettings.isTraceEnabled {
            LogConfig.enabled.insert(.attachments)
        }
        #endif
        let vc = makeChatRoute(target: target)
        if let forward { vc.setPendingForward(forward) }
        navigationController.push(vc, animated: animated)
        #if DEBUG
        if AttachmentsResearchSettings.isAutoDiagnosticsEnabled {
            // Keep the real chat alive underneath the probe. This reproduces
            // its background `.all` pagination and DB writes instead of
            // measuring an artificially isolated attachments timeline.
            runAttachmentsAutoDiagnostics(for: target)
        }
        #endif
    }

    #if DEBUG || CHAT_LIST_PLAYGROUND
    private func showChatListPlaygroundPicker(_ target: ChatScreenTarget, animated: Bool) {
        let picker = UIAlertController(
            title: "Chat list playground", message: "Choose a container for this chat.",
            preferredStyle: .actionSheet
        )
        picker.addAction(UIAlertAction(title: "Collection · Full chat", style: .default) { [weak self] _ in
            guard let self else { return }
            let (controller, _) = self.makeChatScreen(target: target)
            self.navigationController.push(controller, animated: animated)
        })
        picker.addAction(UIAlertAction(title: "Custom · Playground", style: .default) { [weak self] _ in
            guard let self else { return }
            let model: ChatViewModel
            switch target {
            case .live(let room): model = ChatViewModel(room: room)
            case .cached(let room): model = ChatViewModel(cachedRoom: room)
            }
            let controller = ChatListPlaygroundController(
                viewModel: model, audioPlayer: self.audioPlayer
            )
            controller.onBack = { [weak self] in self?.navigationController.pop() }
            self.navigationController.push(controller, animated: animated)
        })
        picker.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        picker.popoverPresentationController?.sourceView = navigationController.view
        picker.popoverPresentationController?.sourceRect = CGRect(
            x: navigationController.view.bounds.midX,
            y: navigationController.view.bounds.midY, width: 1, height: 1
        )
        navigationController.present(picker, animated: true)
    }
    #endif

    private func showSpace(
        _ space: RoomModel,
        animated: Bool,
        presentation: SpacePresentationKind = .storyline
    ) {
        let vc = SpaceViewController(
            space: space,
            presentation: presentation,
            roomListService: roomListService
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onSettings = { [weak self, weak vc] space in
            self?.showSpaceSettings(space: space, source: vc)
        }
        vc.onChatSelected = { [weak self] chat in
            if self?.requiresRoomJoinPreview(chat) == true {
                self?.showRoomJoinPreview(chat)
            } else if let room = self?.roomListService.room(for: chat.id) {
                self?.showChat(room)
            } else {
                self?.showChat(.cached(chat))
            }
        }
        vc.onSpaceSelected = { [weak self] space in
            if self?.requiresSpaceJoinPreview(space) == true {
                self?.showSpaceJoinPreview(space, presentation: .track)
            } else {
                self?.showSpace(space, animated: true, presentation: .track)
            }
        }
        vc.onCreateContent = { [weak self, weak vc] parent, presentation in
            self?.showSpaceComposeSheet(
                parent: parent,
                presentation: presentation,
                onContentChanged: {
                    vc?.reloadChildren()
                }
            )
        }
        navigationController.push(vc, animated: animated)
    }

    private func requiresSpaceJoinPreview(_ space: RoomModel) -> Bool {
        guard let metadata = space.spaceMetadata else { return false }
        return metadata.membership != .joined
    }

    private func requiresRoomJoinPreview(_ room: RoomModel) -> Bool {
        guard !room.isSpace,
              let metadata = room.spaceMetadata else { return false }
        return metadata.membership != .joined
    }

    private func showSpaceJoinPreview(
        _ space: RoomModel,
        animated: Bool = true,
        presentation: SpacePresentationKind
    ) {
        let vc = SpaceJoinPreviewViewController(
            space: space,
            presentation: presentation,
            roomListService: roomListService
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onJoined = { [weak self, weak vc] joinedSpace in
            guard let self,
                  let vc,
                  self.navigationController.topViewController === vc else { return }
            self.navigationController.pop(animated: false)
            self.showSpace(joinedSpace, animated: true, presentation: presentation)
        }
        navigationController.push(vc, animated: animated)
    }

    private func showRoomJoinPreview(
        _ room: RoomModel,
        animated: Bool = true
    ) {
        let vc = SpaceJoinPreviewViewController(
            room: room,
            roomListService: roomListService
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onJoined = { [weak self, weak vc] joinedRoom in
            guard let self,
                  let vc,
                  self.navigationController.topViewController === vc else { return }
            self.navigationController.pop(animated: false)
            if let room = self.roomListService.room(for: joinedRoom.id) {
                self.showChat(room)
            } else {
                self.showChat(.cached(joinedRoom))
            }
        }
        navigationController.push(vc, animated: animated)
    }

    private func showSpaceSettings(
        space: RoomModel,
        source: SpaceViewController?
    ) {
        let room = roomListService.room(for: space.id)
            ?? (try? MatrixClientService.shared.client?.getRoom(roomId: space.id))
        guard let room else {
            presentSimpleAlert(
                title: String(localized: "Could Not Open Storyline Settings"),
                message: String(localized: "This Storyline is not available locally yet.")
            )
            return
        }

        let vc = SpaceSettingsViewController(
            space: space,
            room: room,
            audioPlayer: audioPlayer
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onProfileUpdated = { [weak source] updatedSpace in
            source?.updateSpace(updatedSpace)
        }
        vc.onAccessTapped = { [weak self] in
            self?.showSpaceAccess(room: room)
        }
        vc.onPermissionsTapped = { [weak self] in
            self?.showRoomRolesPermissions(room: room)
        }
        vc.onParentStorylinesTapped = { [weak self] in
            self?.showRoomSpaceMembership(room: room)
        }
        vc.onMembersTapped = { [weak self] in
            self?.showMembersList(room: room)
        }

        navigationController.push(vc)
    }

    private func showSpaceAccess(room: Room) {
        let vc = SpaceAccessViewController(
            room: room,
            audioPlayer: audioPlayer,
            roomListService: roomListService
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        navigationController.push(vc)
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        navigationController.topViewController?.present(alert, animated: true)
    }

    private func showSpaceComposeSheet(
        parent: RoomModel,
        presentation: SpacePresentationKind,
        onContentChanged: @escaping () -> Void
    ) {
        let vc = SpaceComposeChoiceViewController(parent: parent, presentation: presentation)
        let nav = ZynaNavigationController(rootViewController: vc)

        vc.onCancel = { [weak nav] in
            nav?.dismiss(animated: true)
        }
        vc.onExistingChat = { [weak self, weak nav] in
            guard let self, let nav else { return }
            self.showAddExistingChat(
                parent: parent,
                in: nav,
                onContentChanged: onContentChanged
            )
        }
        vc.onNewChat = { [weak self, weak nav] in
            guard let self, let nav else { return }
            self.showCreateChat(parent: parent, in: nav)
        }
        vc.onNewTrack = { [weak self, weak nav] in
            guard let self, let nav else { return }
            self.showCreateSpace(mode: .track(parent: parent), in: nav)
        }

        configureComposeSheet(nav)
        navigationController.present(nav, animated: true)
    }

    private func showAddExistingChat(
        parent: RoomModel,
        in nav: ZynaNavigationController,
        onContentChanged: @escaping () -> Void
    ) {
        let vm = SpaceAddExistingChatViewModel(
            parent: parent,
            roomListService: roomListService
        )
        let vc = SpaceAddExistingChatViewController(viewModel: vm)

        vc.onBack = { [weak nav] in
            nav?.pop()
        }
        vc.onChatAdded = { [weak nav] _ in
            onContentChanged()
            nav?.dismiss(animated: true)
        }

        nav.push(vc)
    }

    private func showCreateChat(parent: RoomModel, in nav: ZynaNavigationController) {
        let vm = CreateGroupViewModel(
            roomListService: roomListService,
            parentSpaceId: parent.id
        )
        let vc = CreateGroupViewController(viewModel: vm, presentation: .spaceChildChat)

        vm.onRoomCreated = { [weak self, weak nav] room in
            guard let self, let flowNav = nav else { return }
            if flowNav === self.navigationController {
                flowNav.pop(animated: false)
                self.showChat(room)
            } else {
                self.navigationController.dismiss(animated: true) { [weak self] in
                    self?.showChat(room)
                }
            }
        }

        nav.push(vc)
    }

    private func showCreateSpace(mode: SpaceCreationMode, in nav: ZynaNavigationController) {
        let vm = SpaceCreationViewModel(mode: mode, roomListService: roomListService)
        let vc = SpaceCreationViewController(viewModel: vm)

        vc.onBack = { [weak nav] in
            nav?.pop()
        }
        vm.onSpaceCreated = { [weak self, weak nav] space in
            guard let self, let flowNav = nav else { return }
            if flowNav === self.navigationController {
                flowNav.pop(animated: false)
                self.showSpace(space, animated: true, presentation: mode.presentationKind)
            } else {
                self.navigationController.dismiss(animated: true) { [weak self] in
                    self?.showSpace(space, animated: true, presentation: mode.presentationKind)
                }
            }
        }

        nav.push(vc)
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
            self?.navigationController.dismiss(animated: true) { [weak self] in
                self?.openChatWithForward(roomModel: selectedRoom, forwardPreview: message)
            }
        }

        navigationController.present(nav, animated: true)
    }

    private func makeChatRoute(target: ChatScreenTarget) -> ChatRouteViewController {
        let sessionID = MatrixClientService.shared.currentLocalSessionId
        return ChatRouteViewController(roomID: target.roomID) { [weak self] restoration in
            guard let self, MatrixClientService.shared.currentLocalSessionId == sessionID else { return nil }
            return self.makeChatScreen(target: target, restoration: restoration).controller
        }
    }

    private func makeChatScreen(
        target: ChatScreenTarget, restoration: ChatNavigationState? = nil
    ) -> (controller: ChatViewController, viewModel: ChatViewModel) {
        let viewModel: ChatViewModel
        switch target {
        case .live(let room):
            viewModel = ChatViewModel(room: room, navigationAnchor: restoration?.anchor)
        case .cached(let room):
            viewModel = ChatViewModel(cachedRoom: room, navigationAnchor: restoration?.anchor)
        }
        let vc = ChatViewController(viewModel: viewModel, audioPlayer: audioPlayer)
        vc.restoreNavigationState(restoration)
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onCallTapped = { [weak self] in
            guard let room = viewModel.liveRoom,
                  let timelineService = viewModel.liveTimelineService else { return }
            self?.startCall(in: room, timelineService: timelineService, voiceOnly: true)
        }
        vc.onTitleTapped = { [weak self] userId in
            Task { @MainActor in self?.showProfile(userId: userId, room: viewModel.liveRoom) }
        }
        vc.onSecurityUserTapped = { [weak self] userId in
            guard let room = viewModel.liveRoom else { return }
            self?.showMemberDetail(room: room, userId: userId)
        }
        vc.onRoomDetailsTapped = { [weak self] in
            // The view model resolves its live room on a 1s poll, so a chat
            // opened from cache can still have none while the client already
            // knows the room. Resolve on demand rather than drop the tap.
            var liveRoom = viewModel.liveRoom
            if liveRoom == nil,
               let resolved = try? MatrixClientService.shared.client?.getRoom(
                   roomId: viewModel.roomIdentifier
               ) {
                liveRoom = resolved
            }
            guard let room = liveRoom else { return }
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
        let target: ChatScreenTarget
        if let room = roomListService.room(for: roomModel.id)
            ?? (try? MatrixClientService.shared.client?.getRoom(roomId: roomModel.id)) {
            target = .live(room)
        } else {
            target = .cached(roomModel)
        }

        showChatScreen(target, animated: true, forward: forwardPreview)
    }

    @MainActor private func showProfile(userId: String, room: Room? = nil) {
        guard let model = PersonProfileViewModel.make(userID: userId, room: room) else { return }
        let vc = RoomProfileViewController(personModel: model, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in self?.navigationController.pop() }
        model.onRemovedFromGroup = { [weak self, weak vc] in
            guard let self, let vc, self.navigationController.topViewController === vc else { return }
            self.navigationController.pop()
        }
        model.onOpenChat = { [weak self, weak vc] room in
            guard let self, let vc, self.navigationController.topViewController === vc else { return }
            self.showChat(room)
        }
        navigationController.push(vc)
    }

    private func showRoomDetails(
        room: Room,
        memberCount: Int?,
        directUserId: String? = nil
    ) {
        Task { @MainActor [weak self] in
            self?.showRoomAttachments(room: room, profile: true, memberCount: memberCount, directUserId: directUserId)
        }
    }

    private func showRoomInformation(
        room: Room,
        memberCount: Int?,
        directUserId: String? = nil,
        sharing viewModel: RoomAttachmentsViewModel,
        editing: Bool = false
    ) {
        let vc = RoomDetailsViewController(
            room: room,
            memberCount: memberCount,
            directUserId: directUserId,
            roomListService: roomListService,
            audioPlayer: audioPlayer,
            initiallyEditing: editing
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
        vc.onPinnedMessagesTapped = { [weak self] in
            self?.showPinnedMessages(room: room)
        }
        vc.onAttachmentsTapped = { [weak self, weak viewModel] in
            Task { @MainActor in
                guard let viewModel else { return }
                self?.showRoomAttachments(room: room, sharing: viewModel)
            }
        }
        vc.onStorylinesTapped = { [weak self] in
            self?.showRoomSpaceMembership(room: room)
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

    private func showRoomSpaceMembership(room: Room) {
        let vc = RoomSpaceMembershipViewController(
            room: room,
            roomListService: roomListService,
            audioPlayer: audioPlayer
        )
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
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

    // MARK: - Room attachments

    #if DEBUG
    /// Research mode: the tapped chat is opened normally, then the attachments
    /// pipeline is exercised headlessly beside it and reported to the console.
    private func runAttachmentsAutoDiagnostics(for target: ChatScreenTarget) {
        let room: Room?
        switch target {
        case .live(let liveRoom):
            room = liveRoom
        case .cached(let cached):
            room = try? MatrixClientService.shared.client?.getRoom(roomId: cached.id)
        }
        guard let room else { return }
        Task { @MainActor in
            await AttachmentsAutoDiagnostics.run(room: room)
        }
    }
    #endif

    /// The screen that asked for a download must still be on top when it
    /// finishes; otherwise a late viewer would appear over another screen.
    private final class AttachmentPresenterBox {
        weak var viewController: UIViewController?
    }

    @MainActor
    private func showRoomAttachments(room: Room, profile: Bool = false, memberCount: Int? = nil, directUserId: String? = nil,
                                     sharing sharedModel: RoomAttachmentsViewModel? = nil) {
        let sessionId = MatrixClientService.shared.currentLocalSessionId
        let catalog = RoomPollCatalog(roomId: room.id(), database: DatabaseService.shared.dbQueue)
        let pollsViewModel = RoomPollsViewModel(catalog: catalog,
            source: SDKRoomPollHistorySource(room: room,
                userID: (try? MatrixClientService.shared.client?.userId()) ?? "", catalog: catalog),
            isCurrentSession: { MatrixClientService.shared.currentLocalSessionId == sessionId })
        let viewModel = sharedModel ?? RoomAttachmentsViewModel(
            room: room,
            filterMode: AttachmentsResearchSettings.filterMode,
            tilePixelSize: RoomAttachmentsMetrics.tilePixelSize(),
            usesPagedMedia: profile
        )
        let presenter = AttachmentPresenterBox()
        let actions = RoomAttachmentsActions(
            openImages: { [weak self] items, initialIndex in
                Task { @MainActor in
                    self?.presentAttachmentImages(items, initialIndex: initialIndex, presenter: presenter)
                }
            },
            openVideo: { [weak self] item, previewImage, sourceFrame, onEvent in
                Task { @MainActor in
                    self?.openAttachmentVideo(
                        item,
                        previewImage: previewImage,
                        sourceFrame: sourceFrame,
                        presenter: presenter,
                        onEvent: onEvent
                    )
                }
            },
            openFile: { [weak self] item, onEvent in
                Task { @MainActor in
                    self?.openAttachmentFile(item, presenter: presenter, onEvent: onEvent)
                }
            },
            openPoll: { [weak self] eventId in
                guard let self, self.activeAttachmentPresenter(presenter) != nil,
                      MatrixClientService.shared.currentLocalSessionId == sessionId,
                      let destination = self.navigationController.stack.last(where: {
                          $0.chatRoomIdentifier == room.id()
                      }), let chat = destination.materializedChat() else { throw PollNavigationError.unavailable }
                let prepared = try await chat.preparePollNavigation(eventId: eventId)
                return PreparedPollNavigation { [weak self, weak chat, weak destination] in
                    guard let self, let chat, let destination, self.activeAttachmentPresenter(presenter) != nil,
                          MatrixClientService.shared.currentLocalSessionId == sessionId,
                          let index = self.navigationController.stack.firstIndex(where: { $0 === destination }),
                          destination.residentChat === chat, prepared.open() else { return false }
                    self.navigationController.setStack(Array(self.navigationController.stack.prefix(index + 1)), animated: true)
                    return true
                }
            }
        )
        if profile {
            let subtitle = directUserId ?? memberCount.map { String(localized: "\($0) members") } ?? String(localized: "Chat")
            let profileModel = RoomProfileViewModel(snapshot: RoomProfileSnapshot(roomID: room.id(),
                title: room.displayName() ?? String(localized: "Chat"), directUserID: directUserId, memberCount: memberCount),
                source: SDKRoomProfileSource(room: room, fallbackUserID: directUserId),
                notifications: MatrixClientService.shared.notificationSettingsService,
                isCurrentSession: { MatrixClientService.shared.currentLocalSessionId == sessionId })
            let vc = RoomProfileViewController(room: room,
                title: room.displayName() ?? String(localized: "Chat"), subtitle: subtitle,
                model: viewModel, actions: actions, audioPlayer: audioPlayer,
                mediaCatalog: RoomMediaCatalog(source: RoomMediaDatabase(database: DatabaseService.shared.dbQueue, roomID: room.id())),
                profileModel: profileModel)
            presenter.viewController = vc
            vc.onOpenMediaImage = { [weak self] source, item, frame in
                let page = try await source.galleryPage(item: item, frame: frame)
                try Task.checkCancellation()
                guard let self, let host = self.activeAttachmentPresenter(presenter),
                      MatrixClientService.shared.currentLocalSessionId == sessionId else { return }
                let viewer = ImageViewerController(page: page, adjacentPage: { page, direction in
                    try await source.adjacent(to: page, direction: direction)
                })
                host.present(viewer, animated: false) { viewer.animateIn(from: frame) }
            }
            vc.onBack = { [weak self] in self?.navigationController.pop() }
            vc.onAction = { [weak self, weak viewModel] action in
                guard let self, self.activeAttachmentPresenter(presenter) != nil,
                      MatrixClientService.shared.currentLocalSessionId == sessionId else { return }
                switch action {
                case .search: self.popAndActivateSearch()
                case .call:
                    let chat = self.navigationController.stack.last {
                        $0.chatRoomIdentifier == room.id()
                    }
                    chat?.materializedChat()?.onCallTapped?()
                case .invite: self.showInviteMembers(room: room)
                case .members: self.showMembersList(room: room)
                case .edit:
                    guard let viewModel else { return }
                    self.showRoomInformation(room: room, memberCount: profileModel.snapshot.memberCount,
                        directUserId: profileModel.snapshot.directUserID, sharing: viewModel, editing: true)
                default: break
                }
            }
            vc.onInformation = { [weak self, weak viewModel] in
                guard let viewModel else { return }
                self?.showRoomInformation(room: room, memberCount: profileModel.snapshot.memberCount,
                                         directUserId: profileModel.snapshot.directUserID, sharing: viewModel)
            }
            vc.onLegacyAttachments = { [weak self, weak viewModel] in
                guard let viewModel else { return }
                self?.showRoomAttachments(room: room, sharing: viewModel)
            }
            vc.onShowInChat = { [weak self] eventId in
                guard let self, self.activeAttachmentPresenter(presenter) != nil,
                      MatrixClientService.shared.currentLocalSessionId == sessionId,
                      let destination = self.navigationController.stack.dropLast().last,
                      destination.chatRoomIdentifier == room.id(), let chat = destination.materializedChat() else { throw PollNavigationError.unavailable }
                // Prepare the existing chat while the profile still covers
                // it, then reveal the positioned list with the normal pop.
                let prepared = try await chat.preparePollNavigation(eventId: eventId, targetKind: .attachment)
                try Task.checkCancellation()
                guard self.activeAttachmentPresenter(presenter) != nil,
                      !self.navigationController.isTransitionInFlight,
                      MatrixClientService.shared.currentLocalSessionId == sessionId else { throw CancellationError() }
                return PreparedPollNavigation { [weak self, weak chat, weak destination] in
                    guard let self, self.activeAttachmentPresenter(presenter) != nil,
                          let chat, let destination, destination.residentChat === chat,
                          self.navigationController.stack.dropLast().last === destination,
                          !self.navigationController.isTransitionInFlight,
                          MatrixClientService.shared.currentLocalSessionId == sessionId,
                          prepared.open() else { return false }
                    self.navigationController.pop()
                    return true
                }
            }
            navigationController.push(vc)
            return
        }
        let previousTab = viewModel.tab
        viewModel.tab = .media
        viewModel.setLegacyMediaPresentation(true)
        let vc = GlassHostingController(
            title: String(localized: "Attachments"),
            rootView: RoomAttachmentsView(
                viewModel: viewModel,
                pollsViewModel: pollsViewModel,
                audioPlayer: audioPlayer,
                roomName: room.displayName() ?? String(localized: "Chat"),
                actions: actions
            ),
            audioPlayer: audioPlayer,
            onBack: { [weak self] in
                _ = self?.navigationController.pop()
            }
        )
        presenter.viewController = vc
        vc.onRemovedFromParent = { [weak viewModel, weak pollsViewModel] in
            if sharedModel != nil {
                viewModel?.setLegacyMediaPresentation(false)
                viewModel?.tab = previousTab
            } else {
                viewModel?.stop()
            }
            pollsViewModel?.stop()
        }
        navigationController.push(vc)
    }

    @MainActor
    private func activeAttachmentPresenter(_ box: AttachmentPresenterBox) -> UIViewController? {
        guard let viewController = box.viewController,
              navigationController.topViewController === viewController,
              viewController.presentedViewController == nil else {
            return nil
        }
        return viewController
    }

    @MainActor
    private func presentAttachmentImages(
        _ items: [ImageViewerController.Item],
        initialIndex: Int,
        presenter: AttachmentPresenterBox
    ) {
        guard !items.isEmpty, let host = activeAttachmentPresenter(presenter) else { return }
        let index = max(0, min(initialIndex, items.count - 1))
        let viewer = ImageViewerController(items: items, initialIndex: index)
        host.present(viewer, animated: false) {
            viewer.animateIn(from: items[index].sourceFrame)
        }
    }

    @MainActor
    private func openAttachmentVideo(
        _ item: AttachmentItem,
        previewImage: UIImage?,
        sourceFrame: CGRect,
        presenter: AttachmentPresenterBox,
        onEvent: @escaping (AttachmentDownloadEvent) -> Void
    ) {
        Task { @MainActor [weak self] in
            do {
                let url = try await FileCacheService.shared.downloadFile(
                    source: item.source,
                    filename: item.filename,
                    mimetype: item.mimetype
                ) { progress in
                    onEvent(.progress(progress))
                }
                onEvent(.finished)
                guard let self, let host = self.activeAttachmentPresenter(presenter) else { return }
                let controller = VideoViewerController(
                    url: url,
                    previewImage: previewImage,
                    sourceFrame: sourceFrame,
                    aspectRatio: item.aspectRatio
                )
                host.present(controller, animated: false) {
                    controller.animateIn()
                }
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    @MainActor
    private func openAttachmentFile(
        _ item: AttachmentItem,
        presenter: AttachmentPresenterBox,
        onEvent: @escaping (AttachmentDownloadEvent) -> Void
    ) {
        Task { @MainActor [weak self] in
            do {
                let url = try await FileCacheService.shared.downloadFile(
                    source: item.source,
                    filename: item.filename,
                    mimetype: item.mimetype
                ) { progress in
                    onEvent(.progress(progress))
                }
                onEvent(.finished)
                guard let self, let host = self.activeAttachmentPresenter(presenter) else { return }
                QuickLookPresenter.present(url: url, from: host)
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    private func openPinnedEvent(_ eventId: String) {
        guard let index = navigationController.stack.lastIndex(where: { $0.chatRoomIdentifier != nil }),
              let chatVC = navigationController.stack[index].materializedChat()
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
        vc.onInviteTapped = { [weak self] in
            self?.showInviteMembers(room: room)
        }
        navigationController.push(vc)
    }

    private func showMemberDetail(room: Room, userId: String) {
        Task { @MainActor [weak self] in self?.showProfile(userId: userId, room: room) }
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

    func popAndActivateSearch() {
        guard let destination = navigationController.stack.last(where: { $0.chatRoomIdentifier != nil }) else { return }
        navigationController.pop(to: destination) { [weak self, weak destination] in
            guard let self, let destination,
                  self.navigationController.topViewController === destination else { return }
            destination.materializedChat()?.activateSearch()
        }
    }

    /// Opens a chat and immediately starts a call. Used by the Calls tab.
    func showChatAndCall(room: Room) {
        navigationController.popToRoot(animated: false)
        let vc = makeChatRoute(target: .live(room))
        navigationController.push(vc, animated: false)
        vc.materializedChat()?.onCallTapped?()
    }

    // MARK: - Calls

    private func startCall(in room: Room, timelineService: TimelineService, voiceOnly: Bool) {
        guard canSendEncryptedEvents(in: room) else {
            presentVerificationRequiredForCall()
            return
        }
        switch CallBackendPreferenceStore.shared.selectedBackend {
        case .zynaDirect:
            CallService.shared.startCall(room: room, timelineService: timelineService)
            presentCallScreen(roomName: room.displayName() ?? "Call")
        case .elementCallWeb:
            presentElementCallScreen(room: room, voiceOnly: voiceOnly)
        case .nativeMatrixRTC:
            startNativeMatrixRTCAudioCall(room: room)
        }
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

        let vc = SessionVerificationView(viewModel: viewModel).wrapped(forcedStyle: .light)
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

    func presentElementCallScreen(room: Room, voiceOnly: Bool) {
        let credentials = MatrixClientService.shared.sessionRecoveryCredentials
        ElementCallPresentationManager.shared.present(
            room: room,
            roomDisplayName: room.displayName() ?? "Call",
            deviceID: credentials?.deviceId,
            voiceOnly: voiceOnly,
            from: navigationController
        )
    }

    private func startNativeMatrixRTCAudioCall(room: Room) {
        NativeMatrixRTCCallPresentationManager.shared.present(
            room: room,
            roomDisplayName: room.displayName() ?? "Call",
            from: navigationController
        )
    }
}
