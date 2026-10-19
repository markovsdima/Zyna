// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB
import MatrixRustSDK
import SwiftUI
import Testing
import UIKit
@testable import Zyna

private func reportDatabase() async throws -> AccountDatabase {
    try await Task.detached {
        let queue = try DatabaseQueue()
        try DatabaseService.migrator.migrate(queue)
        return AccountDatabase(queue)
    }.value
}

private final class ReportTestClient: Client, @unchecked Sendable {
    let ignoredReads = Atomic(0)
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func userId() throws -> String { "@me:example.org" }
    override func homeserver() -> String { "https://example.org" }
    override func ignoredUsers() async throws -> [String] {
        ignoredReads.modify { $0 += 1 }
        throw ContentReportFailure.unavailable
    }
}

private final class ReportTestSource: ContentReportSource, @unchecked Sendable {
    struct Call: Equatable { let step: ContentReportStep; let reason: String; let userID: String? }
    struct State {
        var context = ContentReportContext(recipient: "example.org", canReport: true,
            blockUserID: "@alice:example.org", isBlocked: false, isEncrypted: true)
        var failures: Set<ContentReportStep> = []
        var calls: [Call] = []
        var gate: ProfileTestRequest<Void>?
        var read: ProfileTestRequest<ContentReportContext>?
    }
    let state = Atomic(State())
    func load() async throws -> ContentReportContext {
        if let read = state.wrappedValue.read { return try await read.wait() }
        return state.wrappedValue.context
    }
    func perform(_ step: ContentReportStep, reason: String, userID: String?) async throws {
        state.modify { $0.calls.append(.init(step: step, reason: reason, userID: userID)) }
        if let gate = state.wrappedValue.gate { try await gate.wait() }
        if state.wrappedValue.failures.contains(step) { throw ContentReportFailure.unavailable }
    }
}

private final class ReportTestRoom: Room, @unchecked Sendable {
    let reports = Atomic<[(String, String?)]>([])
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func encryptionState() -> EncryptionState { .encrypted }
    override func roomInfo() async throws -> RoomInfo {
        RoomInfo(id: "!reports:example.org", encryptionState: .encrypted, creators: nil,
            displayName: "Group", rawName: "Group", topic: nil, avatarUrl: nil,
            isDirect: false, isDm: false, isPublic: false, isSpace: false, successorRoom: nil,
            isFavourite: false, isLowPriority: false, canonicalAlias: nil, alternativeAliases: [],
            membership: .joined, inviter: nil, heroes: [], activeMembersCount: 3,
            invitedMembersCount: 0, joinedMembersCount: 3, activeServiceMembersCount: 0,
            serviceMembers: [], highlightCount: 0, notificationCount: 0,
            cachedUserDefinedNotificationMode: nil, hasRoomCall: false, activeRoomCallParticipants: [],
            activeRoomCallConsensusIntent: .none, isMarkedUnread: false, numUnreadMessages: 0,
            numUnreadNotifications: 0, numUnreadMentions: 0, pinnedEventIds: [], joinRule: .invite,
            historyVisibility: .shared, powerLevels: nil, roomVersion: "10", privilegedCreatorsRole: false)
    }
    override func reportContent(eventId: String, reason: String?) async throws {
        reports.modify { $0.append((eventId, reason)) }
    }
}

@Suite("Content reporting", .serialized)
@MainActor
struct ContentReportTests {
    private func wait(_ predicate: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate(), sourceLocation: sourceLocation)
    }

    private func loaded(_ source: ReportTestSource, target: ContentReportTarget = .message(eventID: "$event", senderID: "@alice:example.org")) async throws -> ContentReportViewModel {
        let model = ContentReportViewModel(target: target, source: source, isCurrentSession: { true })
        model.load()
        try await wait { !model.isLoading }
        return model
    }

    @Test("Retrying a failed block never resends a successful report")
    func partialSuccess() async throws {
        let source = ReportTestSource()
        source.state.modify { $0.failures = [.block] }
        let model = try await loaded(source)
        #expect(!model.canSubmit)
        model.reason = "  Spam\n"; model.shouldBlock = true
        model.submit(); model.submit()
        try await wait { !model.isSubmitting }
        #expect(model.completed == [.report])
        #expect(model.failures[.block] != nil)
        #expect(model.state(of: .report) == .completed)
        #expect(model.remainingSteps == [.block])
        #expect(model.submittedReason == "Spam")
        model.reason = "Changed after submission"
        source.state.modify { $0.failures = [] }
        model.submit()
        try await wait { model.isComplete }
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report, .block, .block])
        #expect(source.state.wrappedValue.calls.first?.reason == "Spam")
        #expect(source.state.wrappedValue.calls.allSatisfy { $0.reason == "Spam" })
        #expect(model.submittedReason == "Spam")
        #expect(model.activeStep == nil && model.remainingSteps.isEmpty)
        model.submit()
        #expect(source.state.wrappedValue.calls.count == 3)
    }

    @Test("Report failure still allows blocking; requested leave waits for a successful report")
    func independentBlock() async throws {
        let source = ReportTestSource()
        source.state.modify { $0.failures = [.report] }
        let model = try await loaded(source, target: .room(isDirect: true))
        model.reason = "Abuse"; model.shouldBlock = true; model.shouldLeave = true
        model.submit()
        try await wait { !model.isSubmitting }
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report, .block])
        #expect(model.completed == [.block])
        #expect(model.state(of: .block) == .completed)
        #expect(model.state(of: .leave) == .waitingForReport)
        #expect(model.remainingSteps == [.report, .leave])
        source.state.modify { $0.failures = [] }
        model.submit()
        try await wait { model.isComplete }
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report, .block, .report, .leave])
        #expect(model.state(of: .leave) == .completed)
    }

    @Test("An ordinary decline never blocks by default; unsupported reports still allow an explicit block", arguments: [false, true])
    func unsupportedInvitation(block: Bool) async throws {
        let source = ReportTestSource()
        source.state.modify { $0.context.canReport = false }
        let model = try await loaded(source, target: .invitation)
        #expect(!model.shouldReport)
        #expect(!model.shouldBlock && model.shouldLeave && model.canSubmit)
        model.shouldBlock = block
        model.submit()
        try await wait { model.isComplete }
        #expect(source.state.wrappedValue.calls.map(\.step) == (block ? [.leave, .block] : [.leave]))
        let room = try await loaded(source, target: .room(isDirect: false))
        room.reason = "Abuse"
        #expect(!room.canSubmit)
    }

    @Test("Leave failure retries only leave and reports its actual result")
    func leaveFailure() async throws {
        let source = ReportTestSource()
        source.state.modify { $0.failures = [.leave] }
        let model = try await loaded(source, target: .room(isDirect: false))
        model.reason = "Abuse"; model.shouldLeave = true
        model.submit()
        try await wait { !model.isSubmitting }
        var didLeave: Bool?
        model.onClose = { didLeave = $0 }
        model.close()
        #expect(didLeave == false)
        source.state.modify { $0.failures = [] }
        model.submit()
        try await wait { model.isComplete }
        model.close()
        #expect(didLeave == true)
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report, .leave, .leave])
    }

    @Test("Switching account during a write prevents later steps and stale UI publication", arguments: [false, true])
    func invalidatedWrite(stop: Bool) async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        var active = true
        let model = ContentReportViewModel(target: .room(isDirect: true), source: source, isCurrentSession: { active })
        model.load(); try await wait { !model.isLoading }
        model.reason = "Abuse"; model.shouldBlock = true; model.shouldLeave = true
        model.submit()
        try await wait { await gate.isPending }
        #expect(model.activeStep == .report)
        #expect(model.state(of: .report) == .running)
        #expect(model.state(of: .block) == .pending)
        var closed = false
        model.onClose = { _ in closed = true }
        model.close(); #expect(closed)
        if stop { model.stop() } else { active = false }
        await gate.finish(())
        await model.waitForOperationForTesting()
        #expect(model.completed.isEmpty)
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report])
        #expect(!model.canSubmit)
        model.stop()
    }

    @Test("Late reads cannot revive a closed report form")
    func staleRead() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<ContentReportContext>()
        source.state.modify { $0.read = gate }
        let model = ContentReportViewModel(target: .invitation, source: source, isCurrentSession: { true })
        model.load(); try await wait { await gate.isPending }
        model.stop()
        await gate.finish(source.state.wrappedValue.context)
        await model.waitForOperationForTesting()
        #expect(model.context == nil)
        #expect(!model.canSubmit)
    }

    @Test("The SDK report contains only the selected event ID and user-supplied reason")
    func reportPayload() async throws {
        let room = ReportTestRoom(), client = Client(noHandle: .init())
        let source = SDKContentReportSource(client: client, room: room,
            target: .message(eventID: "$selected-album-item", senderID: "@alice:example.org"),
            database: try await reportDatabase())
        try await source.perform(.report, reason: "My description", userID: nil)
        #expect(room.reports.wrappedValue.count == 1)
        #expect(room.reports.wrappedValue.first?.0 == "$selected-album-item")
        #expect(room.reports.wrappedValue.first?.1 == "My description")
    }

    @Test("Opening a report uses the persisted block status before sync without a network read", arguments: [false, true])
    func cachedBlockStatus(blocked: Bool) async throws {
        let database = try await reportDatabase()
        let senderID = "@alice:example.org"
        try await database.write { try IgnoredContentStore.replace(blocked ? [senderID] : [], in: $0) }
        let client = ReportTestClient()
        let source = SDKContentReportSource(client: client, room: ReportTestRoom(),
            target: .message(eventID: "$event", senderID: senderID), database: database)
        let context = try await source.load()
        #expect(context.blockUserID == senderID)
        #expect(context.isBlocked == blocked)
        #expect(context.canReport)
        #expect(client.ignoredReads.wrappedValue == 0)
    }

    @Test("A direct-room marker alone cannot select someone to block")
    func directRecipient() {
        let own = "@me:example.org", alice = "@alice:example.org", bob = "@bob:example.org"
        #expect(SDKContentReportSource.directBlockTarget(isDirect: true, activeMembers: 2,
            heroIDs: [alice], ownID: own) == alice)
        #expect(SDKContentReportSource.directBlockTarget(isDirect: true, activeMembers: 3,
            heroIDs: [alice], ownID: own) == nil)
        #expect(SDKContentReportSource.directBlockTarget(isDirect: true, activeMembers: 2,
            heroIDs: [alice, bob], ownID: own) == nil)
        #expect(SDKContentReportSource.directBlockTarget(isDirect: true, activeMembers: 1,
            heroIDs: [own], ownID: own) == nil)
        #expect(SDKContentReportSource.directBlockTarget(isDirect: false, activeMembers: 2,
            heroIDs: [alice], ownID: own) == nil)
    }

    @Test("Local and missing selected-item IDs cannot reach the report API", arguments: ["local-item", "", "$"])
    func invalidSelectedEvent(eventID: String) async throws {
        let room = ReportTestRoom()
        let source = SDKContentReportSource(client: Client(noHandle: .init()), room: room,
            target: .message(eventID: eventID, senderID: "@alice:example.org"),
            database: try await reportDatabase())
        await #expect(throws: ContentReportFailure.self) {
            try await source.perform(.report, reason: "Description", userID: nil)
        }
        #expect(room.reports.wrappedValue.isEmpty)
    }

    @Test("Closing and reopening an in-flight report keeps one operation and allows VoiceOver back")
    func backgroundReopen() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        let model = try await loaded(source, target: .room(isDirect: false))
        let root = UIViewController(), navigation = ZynaNavigationController()
        navigation.setStack([root], animated: false)
        let session = UUID().uuidString
        ContentReportFlow.present(model: model, roomID: "!report:test", sessionID: session,
                                  in: navigation, isCurrentSession: { true })
        model.reason = "Abuse"; model.shouldBlock = true; model.shouldLeave = true
        model.submit()
        try await wait { await gate.isPending }
        weak var oldController = navigation.topViewController
        model.close()
        #expect(navigation.topViewController === root)
        #expect(model.isSubmitting)
        try await wait { oldController == nil }

        let candidate = ContentReportViewModel(target: model.target, source: source, isCurrentSession: { true })
        ContentReportFlow.present(model: candidate, roomID: "!report:test", sessionID: session,
                                  in: navigation, isCurrentSession: { true })
        #expect(candidate.context == nil)
        #expect(model.onClose != nil)
        #expect(navigation.performEscapeAction())
        #expect(navigation.topViewController === root)
        source.state.modify { $0.gate = nil }
        await gate.finish(())
        await model.waitForOperationForTesting()
        #expect(model.isComplete)
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report, .block, .leave])
        AppBannerCenter.shared.dismissAll()
    }

    @Test("A detached operation outlives its screen and releases after completion")
    func detachedLifetime() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        var model: ContentReportViewModel? = try await loaded(source)
        weak var weakModel = model
        let navigation = ZynaNavigationController(rootViewController: UIViewController())
        ContentReportFlow.present(model: try #require(model), roomID: "!lifetime:test", sessionID: UUID().uuidString,
                                  in: navigation, isCurrentSession: { true })
        model?.reason = "Abuse"; model?.submit()
        try await wait { await gate.isPending }
        model?.close()
        model = nil
        #expect(weakModel != nil)
        source.state.modify { $0.gate = nil }
        await gate.finish(())
        await weakModel?.waitForOperationForTesting()
        AppBannerCenter.shared.dismissAll()
        try await wait { weakModel == nil }
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report])
    }

    @Test("Switching account cancels a detached report and prevents subsequent block and leave")
    func detachedAccountChange() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        var active = true
        let model = ContentReportViewModel(target: .room(isDirect: false), source: source, isCurrentSession: { active })
        let root = UIViewController(), navigation = ZynaNavigationController(rootViewController: UIViewController())
        navigation.setStack([root], animated: false)
        ContentReportFlow.present(model: model, roomID: "!account:test", sessionID: UUID().uuidString,
                                  in: navigation, isCurrentSession: { active })
        try await wait { model.context != nil }
        model.reason = "Abuse"; model.shouldBlock = true; model.shouldLeave = true; model.submit()
        try await wait { await gate.isPending }
        model.close()
        active = false
        ContentReportFlow.discardInactiveSessions()
        source.state.modify { $0.gate = nil }
        await gate.finish(())
        await model.waitForOperationForTesting()
        #expect(model.completed.isEmpty && !model.isSubmitting && !model.canSubmit)
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report])
        #expect(navigation.topViewController === root)
    }

    @Test("A partial failure during animated dismissal remains retryable without resending the report")
    func completionDuringDismissal() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate; $0.failures = [.block] }
        let model = try await loaded(source)
        let root = UIViewController(), navigation = ZynaNavigationController(rootViewController: UIViewController())
        navigation.setStack([root], animated: false)
        ContentReportFlow.present(model: model, roomID: "!dismissing:test", sessionID: UUID().uuidString,
                                  in: navigation, isCurrentSession: { true })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation; window.isHidden = false
        navigation.view.layoutIfNeeded()
        defer {
            AppBannerCenter.shared.dismissAll()
            window.isHidden = true; window.rootViewController = nil
        }
        model.reason = "Abuse"; model.shouldBlock = true; model.submit()
        try await wait { await gate.isPending }
        let controller = try #require(navigation.topViewController)
        model.close()
        #expect(navigation.isTransitionInFlight && navigation.topViewController === root)
        #expect(controller.parent === navigation)
        source.state.modify { $0.gate = nil }
        await gate.finish(())
        await model.waitForOperationForTesting()
        try await wait { !navigation.isTransitionInFlight }
        #expect(controller.parent == nil)
        #expect(model.completed == [.report] && model.canSubmit)
        source.state.modify { $0.failures = [] }
        model.submit()
        await model.waitForOperationForTesting()
        #expect(model.isComplete)
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report, .block, .block])
    }

    @Test("A late leave preserves the chat opened while the report was running")
    func lateLeavePreservesNewChat() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        let model = try await loaded(source, target: .room(isDirect: false))
        let root = UIViewController(), firstProfile = UIViewController(), secondProfile = UIViewController()
        let first = ChatRouteViewController(roomID: "!first:test") { _ in nil }
        let second = ChatRouteViewController(roomID: "!second:test") { _ in nil }
        let navigation = ZynaNavigationController(rootViewController: root)
        navigation.setStack([root, first, firstProfile], animated: false)
        ContentReportFlow.present(model: model, roomID: "!first:test", sessionID: UUID().uuidString,
                                  in: navigation, isCurrentSession: { true })
        model.reason = "Abuse"; model.shouldLeave = true; model.submit()
        try await wait { await gate.isPending }
        model.close()
        navigation.push(second, animated: false)
        navigation.push(secondProfile, animated: false)
        source.state.modify { $0.gate = nil }
        await gate.finish(())
        await model.waitForOperationForTesting()
        try await wait { !navigation.stack.contains(where: { $0 === first }) }
        #expect(navigation.stack.elementsEqual([root, second, secondProfile], by: { $0 === $1 }))
        #expect(model.isComplete)
        AppBannerCenter.shared.dismissAll()
    }

    @Test("The receipt banner preserves sheets and full-screen presentations until the user closes them",
          arguments: [UIModalPresentationStyle.none, .pageSheet, .fullScreen])
    func bannerRevealsReceipt(modalStyle: UIModalPresentationStyle) async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        let model = try await loaded(source)
        let root = UIViewController(), otherRoot = UIViewController()
        let navigation = ZynaNavigationController(rootViewController: root)
        let otherNavigation = ZynaNavigationController(rootViewController: otherRoot)
        let tabs = ZynaTabBarController()
        tabs.setControllers([navigation, otherNavigation], items: [
            ZynaTabBarItem(title: "Reports", icon: nil), ZynaTabBarItem(title: "Other", icon: nil)
        ])
        ContentReportFlow.present(model: model, roomID: "!banner:test", sessionID: UUID().uuidString,
                                  in: navigation, isCurrentSession: { true })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs; window.isHidden = false
        tabs.view.layoutIfNeeded()
        AppBannerCenter.shared.attach(to: window)
        defer {
            AppBannerCenter.shared.dismissAll()
            navigation.setStack([root], animated: false)
            window.isHidden = true; window.rootViewController = nil
            if let originalWindow { AppBannerCenter.shared.attach(to: originalWindow) }
        }
        model.reason = "Abuse"; model.submit()
        try await wait { await gate.isPending }
        model.close()
        try await wait { !navigation.isTransitionInFlight }
        tabs.setSelectedIndex(1, animated: false, completion: nil)
        let modal = UIViewController()
        let draft = UITextField()
        draft.text = "Unfinished selection"
        modal.view = draft
        modal.modalPresentationStyle = modalStyle
        let withModal = modalStyle != .none
        if withModal {
            await withCheckedContinuation { continuation in
                otherRoot.present(modal, animated: false) { continuation.resume() }
            }
            #expect(modal.presentingViewController != nil)
        }
        AppBannerCenter.shared.performPrimaryAction()
        if withModal {
            #expect(navigation.topViewController === root && tabs.selectedController === otherNavigation)
            #expect(modal.presentingViewController != nil && !modal.isBeingDismissed)
            #expect(modal.view.window === window && draft.text == "Unfinished selection")
            // A new result replaces the pending banner without losing the
            // deferred receipt or displacing the screen the user is using.
            source.state.modify { $0.gate = nil }
            await gate.finish(())
            await model.waitForOperationForTesting()
            AppBannerCenter.shared.performPrimaryAction()
            #expect(navigation.topViewController === root && tabs.selectedController === otherNavigation)
            #expect(modal.presentingViewController != nil && !modal.isBeingDismissed)
            await withCheckedContinuation { continuation in
                modal.dismiss(animated: false) { continuation.resume() }
            }
            #expect(draft.text == "Unfinished selection")
            AppBannerCenter.shared.performPrimaryAction()
        }
        try await wait {
            tabs.selectedController === navigation && navigation.topViewController !== root
                && !navigation.isTransitionInFlight && modal.presentingViewController == nil
        }
        #expect(navigation.topViewController?.viewIfLoaded?.window === window)
        #expect(otherNavigation.stack.elementsEqual([otherRoot], by: { $0 === $1 }))
        #expect(model.requested == [.report])
        if !withModal {
            source.state.modify { $0.gate = nil }
            await gate.finish(())
            await model.waitForOperationForTesting()
        }
        #expect(model.isComplete)
        #expect(source.state.wrappedValue.calls.map(\.step) == [.report])
    }

    @Test("An expired receipt banner cannot route after a modal is closed")
    func invalidatedBannerRoute() async throws {
        let source = ReportTestSource(), gate = ProfileTestRequest<Void>()
        source.state.modify { $0.gate = gate }
        var active = true
        let model = ContentReportViewModel(target: .room(isDirect: false), source: source, isCurrentSession: { active })
        let root = UIViewController(), other = UIViewController()
        let navigation = ZynaNavigationController(rootViewController: root)
        let tabs = ZynaTabBarController()
        tabs.setControllers([navigation, other], items: [
            ZynaTabBarItem(title: "Reports", icon: nil), ZynaTabBarItem(title: "Other", icon: nil)
        ])
        ContentReportFlow.present(model: model, roomID: "!stale-banner:test", sessionID: UUID().uuidString,
                                  in: navigation, isCurrentSession: { active })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = tabs; window.isHidden = false
        tabs.view.layoutIfNeeded()
        AppBannerCenter.shared.attach(to: window)
        defer {
            AppBannerCenter.shared.dismissAll()
            window.isHidden = true; window.rootViewController = nil
            if let originalWindow { AppBannerCenter.shared.attach(to: originalWindow) }
        }
        try await wait { model.context != nil }
        model.reason = "Abuse"; model.submit()
        try await wait { await gate.isPending }
        model.close()
        try await wait { !navigation.isTransitionInFlight }
        tabs.setSelectedIndex(1, animated: false, completion: nil)
        let modal = UIViewController()
        await withCheckedContinuation { continuation in
            other.present(modal, animated: false) { continuation.resume() }
        }
        AppBannerCenter.shared.performPrimaryAction()
        source.state.modify { $0.gate = nil }
        await gate.finish(())
        await model.waitForOperationForTesting()
        #expect(model.isComplete)
        active = false
        ContentReportFlow.discardInactiveSessions()
        await withCheckedContinuation { continuation in
            modal.dismiss(animated: false) { continuation.resume() }
        }
        AppBannerCenter.shared.performPrimaryAction()
        #expect(tabs.selectedController === other)
        #expect(navigation.stack.elementsEqual([root], by: { $0 === $1 }))
    }
}
