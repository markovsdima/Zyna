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
            self?.switchToChat(room: room)
        }
        contacts.onStartCall = { [weak self] room in
            self?.switchToChatAndCall(room: room)
        }

        calls.onRoomSelected = { [weak self] roomId in
            self?.callFromHistory(roomId: roomId)
        }
    }

    private func switchToChat(room: Room) {
        guard let chats = chatsCoordinator else { return }
        selectChatsTab(chats)
        chats.navigationController.popToRoot(animated: false)
        chats.showChat(room)
    }

    private func switchToChatAndCall(room: Room) {
        guard let chats = chatsCoordinator else { return }
        selectChatsTab(chats)
        chats.showChatAndCall(room: room)
    }

    private func callFromHistory(roomId: String) {
        guard let client = MatrixClientService.shared.client,
              let room = try? client.getRoom(roomId: roomId) else { return }

        // Switch to Chats tab and open the chat
        guard let chats = chatsCoordinator else { return }
        selectChatsTab(chats)
        chats.showChatAndCall(room: room)
    }

    private func selectChatsTab(_ chats: ChatsCoordinator) {
        if let index = tabBarController.controllers.firstIndex(where: {
            $0 === chats.navigationController
        }) {
            tabBarController.selectedIndex = index
        }
    }
}
