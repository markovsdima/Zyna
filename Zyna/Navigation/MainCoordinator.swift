//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class MainCoordinator {

    private let voicePlayback = AudioPlayerService()
    let tabBarController = ZynaTabBarController()
    var onLogout: (() -> Void)?

    private var chatsCoordinator: ChatsCoordinator?
    private var contactsCoordinator: ContactsCoordinator?
    private var callsCoordinator: CallsCoordinator?
    private var profileCoordinator: ProfileCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var pendingElementCallRoute: (roomID: String, isVoiceCall: Bool)?
    private var pendingElementCallRetryWorkItem: DispatchWorkItem?
    private var pendingElementCallRetryCount = 0
    private var incomingCallSyncBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var incomingCallSyncEndWorkItem: DispatchWorkItem?

    func start() {
        let chats = ChatsCoordinator(audioPlayer: voicePlayback)
        chats.start()

        let contacts = ContactsCoordinator(audioPlayer: voicePlayback)
        contacts.start()

        let calls = CallsCoordinator(audioPlayer: voicePlayback)
        calls.start()

        let profile = ProfileCoordinator(audioPlayer: voicePlayback)
        profile.onLogout = { [weak self] in
            self?.onLogout?()
        }
        profile.start()

        let items: [ZynaTabBarItem] = [
            ZynaTabBarItem(title: String(localized: "Contacts"), icon: UIImage(systemName: "person.2")),
            ZynaTabBarItem(title: String(localized: "Calls"),    icon: UIImage(systemName: "phone")),
            ZynaTabBarItem(title: String(localized: "Chats"),    icon: UIImage(systemName: "message")),
            ZynaTabBarItem(title: String(localized: "Profile"),  icon: UIImage(systemName: "person")),
        ]

        tabBarController.setControllers(
            [
                contacts.navigationController,
                calls.navigationController,
                chats.navigationController,
                profile.navigationController,
            ],
            items: items,
            selectedIndex: 2
        )

        self.chatsCoordinator = chats
        self.contactsCoordinator = contacts
        self.callsCoordinator = calls
        self.profileCoordinator = profile

        tabBarController.onSelectionChanged = { [weak self] in
            self?.publishBannerVisibilityContext()
        }
        for navigationController in [
            contacts.navigationController,
            calls.navigationController,
            chats.navigationController,
            profile.navigationController
        ] {
            navigationController.onStackChanged = { [weak self] in
                self?.publishBannerVisibilityContext()
            }
        }
        publishBannerVisibilityContext()

        contacts.onOpenChat = { [weak self] room in
            self?.routeToChat(room: room)
        }
        contacts.onStartCall = { [weak self] room in
            self?.routeToChatAndCall(room: room)
        }

        calls.onRoomSelected = { [weak self] roomId in
            self?.routeToCallHistory(roomId: roomId)
        }

        observeElementCallKitActions()
        observeMatrixClientState()
    }

    // MARK: - Route entry points

    func stopVoicePlayback() {
        voicePlayback.stop()
    }

    private func publishBannerVisibilityContext() {
        let currentRoomId: String?
        if let chats = chatsCoordinator,
           tabBarController.selectedController === chats.navigationController,
           let chat = chats.navigationController.topViewController as? ChatViewController {
            currentRoomId = chat.roomIdentifier
        } else {
            currentRoomId = nil
        }
        AppBannerCenter.shared.updateVisibility(
            BannerVisibilityContext(currentRoomId: currentRoomId)
        )
    }

    private func routeToChat(room: Room) {
        guard let chats = chatsCoordinator else { return }
        if tabBarController.selectedController === chats.navigationController {
            chats.navigationController.popToRoot(animated: false)
            chats.showChat(room)
            return
        }

        guard let sourceNavigationController = tabBarController.selectedController as? ZynaNavigationController else {
            selectChatsTab(chats) { [weak chats] in
                guard let chats else { return }
                chats.navigationController.popToRoot(animated: false)
                chats.showChat(room)
            }
            return
        }

        CrossStackTransitionCoordinator.runPushTransition(
            in: tabBarController,
            sourceNavigationController: sourceNavigationController,
            destinationNavigationController: chats.navigationController,
            prepareDestination: { [weak self, weak chats] in
                guard let self, let chats else { return }
                self.selectChatsTab(chats, animated: false)
                self.tabBarController.setTabBarHidden(
                    chats.navigationController.topViewController?.hidesBottomBarWhenPushed ?? false,
                    animated: false
                )
                chats.navigationController.popToRoot(animated: false)
                chats.showChat(room, animated: false)
                self.tabBarController.setTabBarHidden(
                    chats.navigationController.topViewController?.hidesBottomBarWhenPushed ?? false,
                    animated: false
                )
            },
            cleanupSource: { [weak sourceNavigationController] in
                sourceNavigationController?.popToRoot(animated: false)
            },
            completion: nil
        )
    }

    private func routeToChatAndCall(room: Room) {
        guard let chats = chatsCoordinator else { return }
        selectChatsTab(chats) { [weak chats] in
            chats?.showChatAndCall(room: room)
        }
    }

    private func routeToCallHistory(roomId: String) {
        guard let client = MatrixClientService.shared.client,
              let room = try? client.getRoom(roomId: roomId) else { return }

        guard let chats = chatsCoordinator else { return }
        selectChatsTab(chats) { [weak chats] in
            chats?.showChatAndCall(room: room)
        }
    }

    private func observeElementCallKitActions() {
        ElementCallKitService.shared.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                switch action {
                case .receivedIncomingCallRequest:
                    self?.startIncomingCallSyncKeepalive()
                case .startCall(let roomID, let isVoiceCall):
                    self?.presentElementCall(roomID: roomID, isVoiceCall: isVoiceCall)
                case .endCall, .setAudioEnabled:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func startIncomingCallSyncKeepalive() {
        beginIncomingCallBackgroundTaskIfNeeded()

        Task {
            await MatrixClientService.shared.ensureSyncRunningForIncomingCall()
            await MainActor.run {
                ElementCallKitService.shared.retryObservingIncomingCall()
            }
        }

        incomingCallSyncEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endIncomingCallBackgroundTask()
        }
        incomingCallSyncEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: workItem)
    }

    private func beginIncomingCallBackgroundTaskIfNeeded() {
        guard incomingCallSyncBackgroundTask == .invalid else { return }
        incomingCallSyncBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Incoming Element Call Sync"
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.endIncomingCallBackgroundTask()
            }
        }
    }

    private func endIncomingCallBackgroundTask() {
        incomingCallSyncEndWorkItem?.cancel()
        incomingCallSyncEndWorkItem = nil
        guard incomingCallSyncBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(incomingCallSyncBackgroundTask)
        incomingCallSyncBackgroundTask = .invalid
    }

    private func observeMatrixClientState() {
        MatrixClientService.shared.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.flushPendingElementCallRoute()
            }
            .store(in: &cancellables)
    }

    private func presentElementCall(roomID: String, isVoiceCall: Bool) {
        guard let client = MatrixClientService.shared.client,
              let room = try? client.getRoom(roomId: roomID) else {
            queuePendingElementCallRoute(roomID: roomID, isVoiceCall: isVoiceCall)
            ScopedLog(.call, prefix: "[ElementCallKit]")("Failed to resolve room \(roomID) for Element Call")
            return
        }

        pendingElementCallRoute = nil
        pendingElementCallRetryWorkItem?.cancel()
        pendingElementCallRetryWorkItem = nil
        pendingElementCallRetryCount = 0
        presentElementCall(room: room, isVoiceCall: isVoiceCall)
    }

    private func flushPendingElementCallRoute() {
        guard let route = pendingElementCallRoute else { return }
        presentElementCall(roomID: route.roomID, isVoiceCall: route.isVoiceCall)
    }

    private func queuePendingElementCallRoute(roomID: String, isVoiceCall: Bool) {
        if pendingElementCallRoute?.roomID != roomID {
            pendingElementCallRetryCount = 0
        }
        pendingElementCallRoute = (roomID, isVoiceCall)
        schedulePendingElementCallRetry()
    }

    private func schedulePendingElementCallRetry() {
        pendingElementCallRetryWorkItem?.cancel()
        guard pendingElementCallRetryCount < 20 else { return }

        pendingElementCallRetryCount += 1
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingElementCallRoute()
        }
        pendingElementCallRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func presentElementCall(room: Room, isVoiceCall: Bool) {
        let credentials = MatrixClientService.shared.sessionRecoveryCredentials
        let callVC = ElementCallViewController(
            room: room,
            roomName: room.displayName() ?? "Call",
            deviceID: credentials?.deviceId,
            voiceOnly: isVoiceCall
        )
        callVC.onDismiss = { [weak callVC] in
            callVC?.dismiss(animated: true)
        }

        topPresentationController().present(callVC, animated: true)
    }

    private func topPresentationController() -> UIViewController {
        var controller: UIViewController = tabBarController
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func selectChatsTab(
        _ chats: ChatsCoordinator,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        if let index = tabBarController.controllers.firstIndex(where: {
            $0 === chats.navigationController
        }) {
            tabBarController.setSelectedIndex(index, animated: animated, completion: completion)
        } else {
            completion?()
        }
    }
}
