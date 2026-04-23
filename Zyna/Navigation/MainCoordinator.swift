//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class MainCoordinator {

    let tabBarController = ZynaTabBarController()
    var onLogout: (() -> Void)?

    private var chatsCoordinator: ChatsCoordinator?
    private var contactsCoordinator: ContactsCoordinator?
    private var callsCoordinator: CallsCoordinator?
    private var profileCoordinator: ProfileCoordinator?

    func start() {
        let chats = ChatsCoordinator()
        chats.start()

        let contacts = ContactsCoordinator()
        contacts.start()

        let calls = CallsCoordinator()
        calls.start()

        let profile = ProfileCoordinator()
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

        contacts.onOpenChat = { [weak self] room in
            self?.routeToChat(room: room)
        }
        contacts.onStartCall = { [weak self] room in
            self?.routeToChatAndCall(room: room)
        }

        calls.onRoomSelected = { [weak self] roomId in
            self?.routeToCallHistory(roomId: roomId)
        }
    }

    // MARK: - Route entry points

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
