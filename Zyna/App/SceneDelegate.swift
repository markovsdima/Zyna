//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    let appCoordinator = AppCoordinator()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {

        guard let windowScene = (scene as? UIWindowScene) else { return }
        window = UIWindow(windowScene: windowScene)
        guard let window = self.window else { return }

        DeviceInsets.configure(from: window)

        #if DEBUG
        // Launch into the crypto diagnostics tool instead of the messenger
        // when enabled (scheme arg `-zynaDiagnostics 1`). Must branch BEFORE
        // `appCoordinator.start()` so no Matrix client opens the crypto store
        // and destructive wipes run against files that are not held open.
        if CryptoDiagnosticsGate.isEnabled {
            window.rootViewController = CryptoDiagnosticsView().wrapped()
            window.makeKeyAndVisible()
            return
        }
        #endif

        appCoordinator.window = window
        appCoordinator.start()
        window.makeKeyAndVisible()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        PresenceTracker.shared.disconnect()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        appCoordinator.resumeHeartbeatIfNeeded()
    }
}
