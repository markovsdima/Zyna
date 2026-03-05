//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class MainCoordinator {

    let tabBarController: ASTabBarController = MainTabBarController()

    private var chatsCoordinator: ChatsCoordinator?
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

        let profile = ProfileCoordinator()
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
            [profile.navigationController, chats.navigationController, settings.navigationController],
            animated: false
        )
        tabBarController.selectedIndex = 1

        self.chatsCoordinator = chats
        self.profileCoordinator = profile
        self.settingsCoordinator = settings
    }
}
