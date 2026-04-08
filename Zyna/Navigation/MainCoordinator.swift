//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class MainCoordinator {

    let tabBarController: ASTabBarController = MainTabBarController()
    var onLogout: (() -> Void)?

    private var chatsCoordinator: ChatsCoordinator?
    private var callsCoordinator: CallsCoordinator?
    private var profileCoordinator: ProfileCoordinator?
    private var settingsCoordinator: SettingsCoordinator?

    func start() {
        let chats = ChatsCoordinator()
        chats.start()
        chats.navigationController.tabBarItem = UITabBarItem(
            title: "Чаты",
            image: UIImage(systemName: "message"),
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

        let settings = SettingsCoordinator()
        settings.start()
        settings.navigationController.tabBarItem = UITabBarItem(
            title: "Настройки",
            image: UIImage(systemName: "gear"),
            selectedImage: nil
        )

        tabBarController.setViewControllers(
            [settings.navigationController, chats.navigationController, calls.navigationController, profile.navigationController],
            animated: false
        )
        tabBarController.selectedIndex = 1

        self.chatsCoordinator = chats
        self.callsCoordinator = calls
        self.profileCoordinator = profile
        self.settingsCoordinator = settings

        calls.onRoomSelected = { [weak self] roomId in
            self?.callFromHistory(roomId: roomId)
        }
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
