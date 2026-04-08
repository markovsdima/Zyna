//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class MainCoordinator {

    let tabBarController: ASTabBarController = MainTabBarController()
    var onLogout: (() -> Void)?

    private var chatsCoordinator: ChatsCoordinator?
    private var contactsCoordinator: ContactsCoordinator?
    private var callsCoordinator: CallsCoordinator?
    private var profileCoordinator: ProfileCoordinator?

    func start() {
        let chats = ChatsCoordinator()
        chats.start()
        chats.navigationController.tabBarItem = UITabBarItem(
            title: "Чаты",
            image: UIImage(systemName: "message"),
            selectedImage: nil
        )

        let contacts = ContactsCoordinator()
        contacts.start()
        contacts.navigationController.tabBarItem = UITabBarItem(
            title: "Контакты",
            image: UIImage(systemName: "person.2"),
            selectedImage: nil
        )

        let calls = CallsCoordinator()
        calls.start()
        calls.navigationController.tabBarItem = UITabBarItem(
            title: "Звонки",
            image: UIImage(systemName: "phone"),
            selectedImage: nil
        )

        let profile = ProfileCoordinator()
        profile.onLogout = { [weak self] in
            self?.onLogout?()
        }
        profile.start()
        profile.navigationController.tabBarItem = UITabBarItem(
            title: "Профиль",
            image: UIImage(systemName: "person"),
            selectedImage: nil
        )

        tabBarController.setViewControllers(
            [
                contacts.navigationController,
                calls.navigationController,
                chats.navigationController,
                profile.navigationController
            ],
            animated: false
        )
        tabBarController.selectedIndex = 2

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
        tabBarController.selectedViewController = chats.navigationController
        chats.navigationController.popToRootViewController(animated: false)
        chats.showChat(room)
    }

    private func switchToChatAndCall(room: Room) {
        guard let chats = chatsCoordinator else { return }
        tabBarController.selectedViewController = chats.navigationController
        chats.showChatAndCall(room: room)
    }

    private func callFromHistory(roomId: String) {
        guard let client = MatrixClientService.shared.client,
              let room = try? client.getRoom(roomId: roomId) else { return }

        // Switch to Chats tab and open the chat
        guard let chats = chatsCoordinator else { return }
        tabBarController.selectedViewController = chats.navigationController
        chats.showChatAndCall(room: room)
    }
}
