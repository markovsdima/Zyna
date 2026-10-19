// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
import UIKit
@testable import Zyna

@Suite("Chat profile navigation", .serialized)
@MainActor
struct ChatsCoordinatorNavigationTests {
    private final class Resident: UIViewController, NavigationResidentScreen {
        var visible = false
        var preparesHidden = false
        func materializeContent() {}
        func releaseContent() {}
        func setContentVisible(_ visible: Bool) { setContentVisible(visible, prepareWhileHidden: false) }
        func setContentVisible(_ visible: Bool, prepareWhileHidden: Bool) {
            self.visible = visible
            preparesHidden = prepareWhileHidden
        }
    }

    @Test("Only the nearest chat under a child screen prepares while hidden")
    func coveredResident() async throws {
        let older = Resident(), nearest = Resident(), profile = UIViewController()
        let navigation = ZynaNavigationController(rootViewController: UIViewController())
        navigation.setStack([navigation.stack[0], older, nearest, profile], animated: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { nearest.preparesHidden }
        #expect(!older.visible && !older.preparesHidden && !nearest.visible)
        navigation.pop(animated: false)
        try await wait { nearest.visible }
        #expect(!nearest.preparesHidden && !older.preparesHidden)
        navigation.viewDidDisappear(false)
        #expect(!nearest.visible && !nearest.preparesHidden)
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test("Search returns through nested profiles and waits for the pop to finish", arguments: [1, 3], [false, true])
    func search(depth: Int, duringPush: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let roomID = TimelineWriteFixture.roomID
        let model = ChatViewModel(testingRoomId: roomID, dbQueue: database,
                                  window: MessageWindow(roomId: roomID, dbQueue: database), mode: .normal)
        let audio = AudioPlayerService()
        let chat = ChatViewController(viewModel: model, audioPlayer: audio)
        let coordinator = ChatsCoordinator(audioPlayer: audio)
        let navigation = coordinator.navigationController
        let root = UIViewController()
        let profiles = (0..<depth).map { _ in UIViewController() }
        navigation.setStack([root, chat] + profiles, animated: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.isHidden = false
        defer {
            chat.view.endEditing(true)
            window.isHidden = true; window.rootViewController = nil; model.cleanup()
        }
        navigation.view.layoutIfNeeded()
        let next = UIViewController()
        if duringPush { navigation.push(next) }

        coordinator.popAndActivateSearch()
        #expect(navigation.isTransitionInFlight)
        #expect(model.searchState == nil)
        try await wait { !navigation.isTransitionInFlight && model.searchState != nil }
        #expect(navigation.stack.count == 2)
        #expect(navigation.stack.first === root)
        #expect(navigation.topViewController === chat)
        #expect(profiles.allSatisfy { $0.parent == nil })
        #expect(next.parent == nil)
    }

    @Test("A queued pop to a removed destination leaves the remaining queue usable")
    func removedDestination() async throws {
        let root = UIViewController()
        let destination = UIViewController()
        let navigation = ZynaNavigationController(rootViewController: root)
        navigation.push(destination, animated: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        navigation.view.layoutIfNeeded()
        navigation.push(UIViewController())
        navigation.popToRoot()
        var completed = false
        navigation.pop(to: destination) { completed = true }
        let next = UIViewController()
        navigation.push(next, animated: false)
        try await wait { !navigation.isTransitionInFlight && navigation.topViewController === next }
        #expect(!completed)
        #expect(navigation.stack.count == 2)
        #expect(destination.parent == nil)
    }
}
