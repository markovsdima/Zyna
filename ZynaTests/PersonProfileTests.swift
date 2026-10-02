// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private final class PersonTestHandle: TaskHandle, @unchecked Sendable {
    var onCancel: (() -> Void)?
    override func cancel() { onCancel?() }
}

final class PersonTestBlockingSource: IgnoredUsersProviding, @unchecked Sendable {
    struct State {
        var ids: [String] = []
        var callback: (@Sendable ([String]) -> Void)?
        var read: ProfileTestRequest<[String]>?
        var write: ProfileTestRequest<Void>?
        var writes: [Bool] = []
        var fails = false
        var reads = 0
    }
    let state = Atomic(State())
    func ignoredUserIds() async throws -> [String] {
        state.modify { $0.reads += 1 }
        let value = state.wrappedValue
        if let request = value.read { return try await request.wait() }
        return value.ids
    }
    func observeIgnoredUsers(_ onChange: @escaping @Sendable ([String]) -> Void) -> TaskHandle? {
        state.modify { $0.callback = onChange }
        let handle = PersonTestHandle(noHandle: .init())
        handle.onCancel = { [weak self] in self?.state.modify { $0.callback = nil } }
        return handle
    }
    func ignore(userId: String) async throws { try await write(true, userID: userId) }
    func unignore(userId: String) async throws { try await write(false, userID: userId) }
    private func write(_ blocked: Bool, userID: String) async throws {
        state.modify { $0.writes.append(blocked) }
        if let request = state.wrappedValue.write { try await request.wait() }
        if state.wrappedValue.fails { throw PersonProfileError.actionUnavailable }
        state.modify { $0.ids = blocked ? [userID] : [] }
        send(state.wrappedValue.ids)
    }
    func send(_ ids: [String]) {
        state.modify { $0.ids = ids }
        state.wrappedValue.callback?(ids)
    }
}

private final class PersonTestSource: PersonProfileSource, @unchecked Sendable {
    struct State {
        var snapshot: PersonProfileSnapshot
        var read: ProfileTestRequest<PersonProfileSnapshot>?
        var callback: (@Sendable () -> Void)?
        var actions: [PersonProfileModeration] = []
        var reads = 0
    }
    let state: Atomic<State>
    init(_ snapshot: PersonProfileSnapshot) { state = Atomic(State(snapshot: snapshot)) }
    func load() async throws -> PersonProfileSnapshot {
        state.modify { $0.reads += 1 }
        if let read = state.wrappedValue.read { return try await read.wait() }
        return state.wrappedValue.snapshot
    }
    func observe(_ invalidate: @escaping @Sendable () -> Void) -> RoomProfileObservation? {
        state.modify { $0.callback = invalidate }
        return RoomProfileObservation { [weak self] in self?.state.modify { $0.callback = nil } }
    }
    func perform(_ action: PersonProfileModeration, reason: String?) async throws {
        state.modify { $0.actions.append(action) }
    }
}

private final class PersonFallbackClient: Client, @unchecked Sendable {
    let reads = Atomic(0)
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func getProfile(userId: String) async throws -> UserProfile {
        reads.modify { $0 += 1 }
        return .init(userId: userId, displayName: "Global Alice", avatarUrl: "mxc://global/avatar")
    }
}

private final class PersonMissingMemberRoom: Room, @unchecked Sendable {
    let error: ClientError
    init(error: ClientError) { self.error = error; super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func member(userId: String) async throws -> RoomMember { throw error }
}

@Suite("Unified person profiles", .serialized)
@MainActor
struct PersonProfileTests {
    private let userID = "@alice:example.org"
    private func snapshot(isSelf: Bool = false) -> PersonProfileSnapshot {
        .init(userID: userID, title: "Room-specific Alice", isSelf: isSelf,
            group: .init(roomID: "!group:example.org", title: "Design team", membership: .join,
                role: .member, availableRoles: [.admin, .moderator, .member], canKick: true, canBan: true,
                ownPowerLevel: 100))
    }
    private func blocking(_ source: PersonTestBlockingSource, isSelf: Bool = false,
                          session: @escaping () -> Bool = { true }) -> UserBlockingViewModel {
        UserBlockingViewModel(userID: userID, ownUserID: isSelf ? userID : "@me:example.org",
            source: source, isCurrentSession: session)
    }
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    @Test("Missing room membership falls back to the global profile without moderation")
    func missingMemberFallback() async throws {
        let client = PersonFallbackClient()
        let source = SDKPersonProfileSource(client: client, userID: userID, ownUserID: "@me:example.org",
            room: PersonMissingMemberRoom(error: .Generic(msg: "User not found", details: nil)))
        let profile = try await source.load()
        #expect(profile.title == "Global Alice" && profile.avatarURL == "mxc://global/avatar")
        #expect(profile.group == nil && !profile.allows(.ban) && !profile.allows(.role(.admin)))
        #expect(client.reads.wrappedValue == 1)
    }

    @Test("Other member-read failures remain retryable errors, not global-profile success")
    func memberReadFailure() async throws {
        let client = PersonFallbackClient()
        let error = ClientError.Generic(msg: "Request timed out", details: nil)
        let source = SDKPersonProfileSource(client: client, userID: userID, ownUserID: "@me:example.org",
            room: PersonMissingMemberRoom(error: error))
        await #expect(throws: error) { try await source.load() }
        #expect(client.reads.wrappedValue == 0)
    }

    @Test("First appearance reads once; returning refreshes without replacing an unchanged menu")
    func appearanceReadsAndMenu() async throws {
        let source = PersonTestSource(snapshot()), ignored = PersonTestBlockingSource()
        let model = PersonProfileViewModel(snapshot: snapshot(), source: source,
            blocking: blocking(ignored), tracksPresence: false, isCurrentSession: { true },
            openConversation: { throw PersonProfileError.actionUnavailable })
        let controller = RoomProfileViewController(personModel: model)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        try await wait { !model.isLoading && model.blocking.canChange }
        #expect(source.state.wrappedValue.reads == 1 && ignored.state.wrappedValue.reads == 1)
        // Drain queued Combine UI deliveries before comparing menu identifiers.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        controller.view.layoutIfNeeded()
        func findMenu(in view: UIView) -> UIMenu? {
            if view.accessibilityIdentifier == "profile.action.more" { return (view as? UIButton)?.menu }
            return view.subviews.lazy.compactMap { findMenu(in: $0) }.first
        }
        let menu = try #require(findMenu(in: controller.view))
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        try await wait {
            source.state.wrappedValue.reads == 2 && ignored.state.wrappedValue.reads == 2 && !model.isLoading
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // UIButton may copy UIMenu. A rebuild creates a new generated identifier.
        #expect(findMenu(in: controller.view)?.identifier == menu.identifier)
    }

    @Test("Subscription wins over an old block-status read; repeated writes are serialized")
    func blockingRaces() async throws {
        let source = PersonTestBlockingSource()
        let read = ProfileTestRequest<[String]>()
        source.state.modify { $0.read = read }
        let model = blocking(source)
        model.start()
        defer { model.stop() }
        try await wait { await read.isPending }
        source.send([userID])
        try await wait { model.isBlocked == true }
        source.state.modify { $0.read = nil }
        await read.finish([])
        let write = ProfileTestRequest<Void>()
        source.state.modify { $0.write = write }
        model.setBlocked(false)
        model.setBlocked(false)
        try await wait { await write.isPending }
        #expect(model.isSaving && source.state.wrappedValue.writes == [false])
        await write.finish(())
        try await wait { !model.isSaving && model.isBlocked == false }
        source.send([userID]) // e.g. another screen or device changes account data
        try await wait { model.isBlocked == true }
    }

    @Test("A failed block restores confirmed state; self and old-session writes are rejected")
    func failedBlockingAndSession() async throws {
        let source = PersonTestBlockingSource()
        var current = true
        let model = blocking(source, session: { current })
        model.start()
        defer { model.stop() }
        try await wait { model.isBlocked == false }
        source.state.modify { $0.fails = true }
        model.setBlocked(true)
        try await wait { !model.isSaving && model.actionError != nil }
        #expect(model.isBlocked == false)
        current = false
        model.setBlocked(true)
        #expect(source.state.wrappedValue.writes == [true])
        let own = blocking(source, isSelf: true)
        own.start(); own.setBlocked(true)
        #expect(!own.canChange && source.state.wrappedValue.writes == [true])
        own.stop()
    }

    @Test("Viewing a profile does not open a DM; Chat deduplicates and ignores completion after closing")
    func explicitChatOnly() async throws {
        let initial = snapshot(), source = PersonTestSource(snapshot())
        let opens = Atomic(0), opened = Atomic(0)
        let request = ProfileTestRequest<Room>()
        let model = PersonProfileViewModel(snapshot: initial, source: source,
            blocking: blocking(PersonTestBlockingSource()), tracksPresence: false,
            isCurrentSession: { true }, openConversation: {
                opens.modify { $0 += 1 }
                return try await request.wait()
            })
        model.onOpenChat = { _ in opened.modify { $0 += 1 } }
        model.start()
        try await wait { !model.isLoading }
        #expect(opens.wrappedValue == 0)
        #expect(model.snapshot.title == "Room-specific Alice" && model.snapshot.group?.roomID == "!group:example.org")
        model.openChat(); model.openChat()
        try await wait { await request.isPending }
        #expect(opens.wrappedValue == 1)
        model.stop()
        await request.finish(Room(noHandle: .init()))
        #expect(opened.wrappedValue == 0)
        #expect(source.state.wrappedValue.callback == nil)
    }

    @Test("Moderation rechecks permissions after confirmation and rejects a revoked role")
    func revokedPermission() async throws {
        let initial = snapshot(), source = PersonTestSource(snapshot())
        let model = PersonProfileViewModel(snapshot: initial, source: source,
            blocking: blocking(PersonTestBlockingSource()), tracksPresence: false,
            isCurrentSession: { true }, openConversation: { throw PersonProfileError.actionUnavailable })
        model.start()
        defer { model.stop() }
        try await wait { !model.isLoading }
        source.state.modify { $0.snapshot.group?.availableRoles = []; $0.snapshot.group?.canKick = false }
        model.perform(.role(.admin))
        try await wait { !model.isPerformingAction && model.actionError != nil }
        #expect(source.state.wrappedValue.actions.isEmpty)
        #expect(model.snapshot.group?.availableRoles.isEmpty == true)
        model.perform(.kick)
        #expect(!model.isPerformingAction)
        #expect(!snapshot(isSelf: true).allows(.ban))
    }

    @Test("A delayed profile read cannot overwrite a newer room update")
    func stalePersonRead() async throws {
        let source = PersonTestSource(snapshot())
        let read = ProfileTestRequest<PersonProfileSnapshot>()
        source.state.modify { $0.read = read }
        let model = PersonProfileViewModel(snapshot: snapshot(), source: source,
            blocking: blocking(PersonTestBlockingSource()), tracksPresence: false,
            isCurrentSession: { true }, openConversation: { throw PersonProfileError.actionUnavailable })
        model.start()
        defer { model.stop() }
        try await wait { await read.isPending }
        source.state.modify { $0.read = nil; $0.snapshot.title = "Updated room name" }
        source.state.wrappedValue.callback?()
        try await wait { model.snapshot.title == "Updated room name" }
        await read.finish(snapshot())
        #expect(model.snapshot.title == "Updated room name")
    }

    @Test("Granting the same level removes moderation actions until a newer permission snapshot arrives")
    func confirmedRole() async throws {
        let source = PersonTestSource(snapshot())
        let model = PersonProfileViewModel(snapshot: snapshot(), source: source,
            blocking: blocking(PersonTestBlockingSource()), tracksPresence: false,
            isCurrentSession: { true }, openConversation: { throw PersonProfileError.actionUnavailable })
        model.start()
        defer { model.stop() }
        try await wait { !model.isLoading }
        model.perform(.role(.admin))
        try await wait { !model.isPerformingAction }
        #expect(model.snapshot.group?.role == .admin)
        #expect(!model.snapshot.allows(.kick) && !model.snapshot.allows(.ban))
        #expect(source.state.wrappedValue.actions == [.role(.admin)])
    }

    @Test("The DM profile uses the shared block state and removes it when the peer context disappears")
    func directRoomBlocking() async throws {
        let initial = ProfileTestSource.snapshot(direct: true)
        let source = ProfileTestSource(initial)
        let ignored = PersonTestBlockingSource()
        let blocking = blocking(ignored)
        let profile = RoomProfileViewModel(snapshot: initial, source: source, notifications: nil, isCurrentSession: { true })
        let controller = RoomProfileViewController(room: nil, title: initial.title, subtitle: "",
            model: nil, actions: .none, profileModel: profile, blockingFactory: { _ in blocking })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.isHidden = false
        defer { profile.stop(); blocking.stop(); window.isHidden = true; window.rootViewController = nil }
        func findMenu(in view: UIView) -> UIButton? {
            if view.accessibilityIdentifier == "profile.action.more" { return view as? UIButton }
            return view.subviews.lazy.compactMap { findMenu(in: $0) }.first
        }
        controller.view.layoutIfNeeded()
        #expect(findMenu(in: controller.view) != nil)
        func has(_ key: String) -> Bool {
            findMenu(in: controller.view)?.menu?.children.compactMap { $0 as? UIAction }.contains { $0.title == String(localized: String.LocalizationValue(key), table: "RoomProfile") } == true
        }
        try await wait { has("Block") }
        ignored.send([userID])
        try await wait { has("Unblock") }
        source.send(ProfileTestSource.snapshot())
        try await wait {
            controller.view.layoutIfNeeded()
            return !profile.snapshot.isDirect && findMenu(in: controller.view)?.menu != nil
                && !has("Block") && !has("Unblock")
        }
        #expect(ignored.state.wrappedValue.callback == nil)
    }

    @Test("The person card reuses the avatar header without media pages and exposes Chat and blocking")
    func personCard() async throws {
        var value = snapshot()
        value.avatarURL = "mxc://profile.invalid/avatar"
        let ignored = PersonTestBlockingSource()
        let model = PersonProfileViewModel(snapshot: value, source: PersonTestSource(value),
            blocking: blocking(ignored), tracksPresence: false,
            isCurrentSession: { true }, openConversation: { throw PersonProfileError.actionUnavailable })
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let controller = RoomProfileViewController(room: nil, title: value.title, subtitle: value.userID,
            model: nil, actions: .none, personModel: model, avatarLoader: { _, _ in photo })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        func find(_ id: String, in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        controller.view.layoutIfNeeded()
        let avatar = try #require(find("profile.avatar", in: controller.view) as? RoomProfileAvatarView)
        try await wait { controller.view.layoutIfNeeded(); return avatar.isAccessibilityElement && model.blocking.canChange }
        let chat = try #require(find("profile.action.message", in: controller.view) as? UIButton)
        let more = try #require(find("profile.action.more", in: controller.view) as? UIButton)
        let tabs = try #require(find("profile.sections", in: controller.view))
        #expect(controller.mediaGrid == nil && tabs.superview?.isHidden == true)
        #expect(chat.isEnabled && more.showsMenuAsPrimaryAction)
        try await wait { more.menu?.children.compactMap { $0 as? UIAction }.contains { $0.title == String(localized: "Block", table: "RoomProfile") } == true }
        #expect(avatar.accessibilityActivate())
        try await wait { avatar.bounds.width == controller.view.bounds.width }
        ignored.send([userID])
        try await wait { more.menu?.children.compactMap { $0 as? UIAction }.contains { $0.title == String(localized: "Unblock", table: "RoomProfile") } == true }
        #expect(avatar.bounds.width == controller.view.bounds.width)
    }
}
