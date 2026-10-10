// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import MatrixRustSDK
import Testing
@testable import Zyna

actor ProfileTestRequest<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    var isPending: Bool { continuation != nil }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

final class ProfileTestSource: RoomProfileSource, @unchecked Sendable {
    let initial: RoomProfileSnapshot
    let loadRequest: ProfileTestRequest<RoomProfileSnapshot>?
    private let callback = Atomic<(@Sendable (RoomProfileSnapshot) -> Void)?>(nil)
    var isObserving: Bool { callback.wrappedValue != nil }

    init(_ initial: RoomProfileSnapshot, loadRequest: ProfileTestRequest<RoomProfileSnapshot>? = nil) {
        self.initial = initial
        self.loadRequest = loadRequest
    }
    func load() async throws -> RoomProfileSnapshot {
        if let loadRequest { return try await loadRequest.wait() }
        return initial
    }
    func observe(_ update: @escaping @Sendable (RoomProfileSnapshot) -> Void) -> RoomProfileObservation {
        callback.wrappedValue = update
        return RoomProfileObservation { [weak self] in self?.callback.wrappedValue = nil }
    }
    func send(_ snapshot: RoomProfileSnapshot) { callback.wrappedValue?(snapshot) }

    static func snapshot(direct: Bool = false) -> RoomProfileSnapshot {
        var value = RoomProfileSnapshot(roomID: "!profile:example.org", title: "Design team",
            directUserID: direct ? "@alice:example.org" : nil, memberCount: direct ? 2 : 12)
        value.isJoined = true
        value.topic = direct ? nil : "Discuss ideas and share photos."
        value.address = direct ? value.directUserID : "#design:example.org"
        value.permissions = .init(invite: true, editName: true, editAvatar: false)
        value.notificationContext = RoomNotificationContext(roomID: value.roomID, isEncrypted: true, isOneToOne: direct)
        return value
    }
}

final class ProfileTestNotificationSettings: NotificationSettings, @unchecked Sendable {
    struct State {
        var mode: RoomNotificationMode?
        var defaultMode: RoomNotificationMode = .mentionsAndKeywordsOnly
        var delegate: (any NotificationSettingsDelegate)?
        var writes: [RoomNotificationSelection] = []
        var reads: [RoomNotificationContext] = []
        var failRead = false
        var failWrite = false
        var readRequest: ProfileTestRequest<RoomNotificationSettings>?
        var modeReadRequest: ProfileTestRequest<RoomNotificationMode?>?
        var modeReads = 0
        var partiallyApplyFailedWrite = false
        var writeRequest: ProfileTestRequest<Void>?
    }
    let state = Atomic(State())
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }

    override func setDelegate(delegate: (any NotificationSettingsDelegate)?) {
        state.modify { $0.delegate = delegate }
    }
    override func getRoomNotificationSettings(roomId: String, isEncrypted: Bool, isOneToOne: Bool) async throws -> RoomNotificationSettings {
        let current = state.withValue { value in
            value.reads.append(.init(roomID: roomId, isEncrypted: isEncrypted, isOneToOne: isOneToOne))
            let snapshot = value
            value.readRequest = nil
            return snapshot
        }
        if let request = current.readRequest { return try await request.wait() }
        if current.failRead { throw TestError.failed }
        return RoomNotificationSettings(mode: current.mode ?? current.defaultMode, isDefault: current.mode == nil)
    }
    override func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {
        try await write(RoomNotificationSelection(.init(mode: mode, isDefault: false)))
    }
    override func restoreDefaultRoomNotificationMode(roomId: String) async throws { try await write(.inherited) }
    override func getUserDefinedRoomNotificationMode(roomId: String) async throws -> RoomNotificationMode? {
        let current = state.withValue { value in
            value.modeReads += 1
            let snapshot = value
            value.modeReadRequest = nil
            return snapshot
        }
        if let request = current.modeReadRequest { return try await request.wait() }
        if current.failRead { throw TestError.failed }
        return current.mode
    }
    private func write(_ selection: RoomNotificationSelection) async throws {
        let current = state.withValue { value in
            value.writes.append(selection)
            let snapshot = value
            value.writeRequest = nil
            return snapshot
        }
        if let request = current.writeRequest { try await request.wait() }
        if current.failWrite {
            if current.partiallyApplyFailedWrite { state.modify { $0.mode = selection.mode } }
            throw TestError.failed
        }
        state.modify { $0.mode = selection.mode }
    }
    func remote(mode: RoomNotificationMode?, defaultMode: RoomNotificationMode = .mentionsAndKeywordsOnly) {
        state.modify { $0.mode = mode; $0.defaultMode = defaultMode }
        state.wrappedValue.delegate?.settingsDidChange()
    }
    enum TestError: Error { case failed }
}

@Suite("Room profile data and notifications", .serialized)
@MainActor
struct RoomProfileViewModelTests {
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    @Test("Room-list mute overrides read only local writes and yield to synced rules")
    func localMuteOverrides() async throws {
        let sdk = ProfileTestNotificationSettings()
        let service = RoomNotificationSettingsService(settings: sdk)
        let id = "!profile:example.org"
        #expect(service.localMuteOverrides.isEmpty)
        try await service.set(.muted, roomID: id)
        #expect(service.localMuteOverrides[id] == true)
        for _ in 0..<100 { _ = service.localMuteOverrides }
        #expect(sdk.state.wrappedValue.modeReads == 1)
        #expect(sdk.state.wrappedValue.reads.isEmpty)
        sdk.remote(mode: .allMessages)
        #expect(service.localMuteOverrides.isEmpty)
        try await service.set(.inherited, roomID: id)
        #expect(service.localMuteOverrides[id] == false)

        sdk.state.modify { $0.failWrite = true; $0.partiallyApplyFailedWrite = true }
        do {
            try await service.set(.muted, roomID: id)
            Issue.record("Expected the partial write error")
        } catch ProfileTestNotificationSettings.TestError.failed { }
        #expect(service.localMuteOverrides[id] == true)
        sdk.remote(mode: nil)
        #expect(service.localMuteOverrides.isEmpty)
    }

    @Test("A delayed local mute read cannot override a later sync or write")
    func staleLocalMuteRead() async throws {
        let sdk = ProfileTestNotificationSettings()
        let service = RoomNotificationSettingsService(settings: sdk)
        let id = "!profile:example.org"
        for supersededBySync in [true, false] {
            let read = ProfileTestRequest<RoomNotificationMode?>()
            sdk.state.modify { $0.modeReadRequest = read }
            let write = Task { try await service.set(.muted, roomID: id) }
            try await wait { await read.isPending }
            if supersededBySync { sdk.remote(mode: .allMessages) }
            else { try await service.set(.allMessages, roomID: id) }
            await read.finish(.mute)
            try await write.value
            #expect(service.localMuteOverrides[id] == (supersededBySync ? nil : false))
        }
    }

    @Test("SDK room data distinguishes identity, membership and notification room type")
    func sdkMetadata() {
        var info = RoomInfo(id: "!room:example.org", encryptionState: .encrypted, creators: nil,
            displayName: "Room name", rawName: nil, topic: "A group topic", avatarUrl: nil,
            isDirect: true, isDm: true, isPublic: false, isSpace: false, successorRoom: nil,
            isFavourite: false, isLowPriority: false, canonicalAlias: "#room:example.org", alternativeAliases: [],
            membership: .joined, inviter: nil,
            heroes: [.init(userId: "@alice:example.org", displayName: "Alice", avatarUrl: "mxc://example.org/alice")],
            activeMembersCount: 2, invitedMembersCount: 0, joinedMembersCount: 2,
            activeServiceMembersCount: 0, serviceMembers: [], highlightCount: 0, notificationCount: 0,
            cachedUserDefinedNotificationMode: nil, hasRoomCall: false, activeRoomCallParticipants: [],
            activeRoomCallConsensusIntent: .none, isMarkedUnread: false, numUnreadMessages: 0,
            numUnreadNotifications: 0, numUnreadMentions: 0, pinnedEventIds: [], joinRule: .invite,
            historyVisibility: .shared, powerLevels: nil, roomVersion: "10", privilegedCreatorsRole: false)
        let direct = RoomProfileSnapshot(info: info, fallbackUserID: "@old:example.org")
        #expect(direct.title == "Room name")
        #expect(direct.directUserID == "@alice:example.org")
        #expect(direct.avatarURL == "mxc://example.org/alice")
        #expect(direct.address == direct.directUserID && direct.topic == nil)
        #expect(direct.notificationContext?.isOneToOne == true)

        info.isDirect = false
        info.isDm = false
        info.avatarUrl = "mxc://example.org/group"
        info.membership = .left
        let group = RoomProfileSnapshot(info: info, fallbackUserID: "@old:example.org")
        #expect(group.directUserID == nil)
        #expect(group.topic == "A group topic" && group.address == "#room:example.org")
        #expect(group.avatarURL == "mxc://example.org/group")
        #expect(group.notificationContext?.isOneToOne == true)
        #expect(!RoomProfileAction.notifications.isEnabled(in: group))
        #expect(!RoomProfileAction.invite.isEnabled(in: group))
        info.activeMembersCount = 3
        #expect(!RoomNotificationContext(info).isOneToOne)
    }

    @Test("Inherited mode, local writes and remote changes use the same SDK rules")
    func notificationModes() async throws {
        let sdk = ProfileTestNotificationSettings()
        let service = RoomNotificationSettingsService(settings: sdk)
        let snapshot = ProfileTestSource.snapshot(direct: true)
        let model = RoomProfileViewModel(snapshot: snapshot, source: ProfileTestSource(snapshot),
            notifications: service, isCurrentSession: { true })
        model.start()
        defer { model.stop() }
        try await wait { model.canChangeNotifications }
        #expect(model.notifications == .init(mode: .mentionsAndKeywordsOnly, isDefault: true))
        #expect(sdk.state.wrappedValue.reads.last == snapshot.notificationContext)

        let write = ProfileTestRequest<Void>()
        sdk.state.modify { $0.writeRequest = write }
        model.setNotifications(.muted)
        try await wait { await write.isPending }
        #expect(!model.canChangeNotifications)
        #expect(model.notifications?.mode == .mentionsAndKeywordsOnly)
        model.setNotifications(.allMessages)
        sdk.remote(mode: nil, defaultMode: .allMessages)
        await write.finish(())
        try await wait { model.canChangeNotifications && model.notifications?.mode == .mute }
        #expect(sdk.state.wrappedValue.writes == [.muted])
        #expect(model.notifications?.isDefault == false)

        model.setNotifications(.inherited)
        try await wait { model.canChangeNotifications && model.notifications?.isDefault == true }
        #expect(model.notifications?.mode == .allMessages)
        sdk.remote(mode: .mentionsAndKeywordsOnly)
        try await wait { model.notifications == .init(mode: .mentionsAndKeywordsOnly, isDefault: false) }
        #expect(sdk.state.wrappedValue.writes == [.muted, .inherited])
    }

    @Test("A stale settings read cannot overwrite a later sync notification")
    func staleNotificationRead() async throws {
        let sdk = ProfileTestNotificationSettings()
        let initialRead = ProfileTestRequest<RoomNotificationSettings>()
        sdk.state.modify { $0.readRequest = initialRead }
        let snapshot = ProfileTestSource.snapshot()
        let model = RoomProfileViewModel(snapshot: snapshot, source: ProfileTestSource(snapshot),
            notifications: RoomNotificationSettingsService(settings: sdk), isCurrentSession: { true })
        model.start()
        defer { model.stop() }
        try await wait { await initialRead.isPending }
        sdk.remote(mode: .mute)
        try await wait { model.notifications?.mode == .mute }
        await initialRead.finish(.init(mode: .allMessages, isDefault: true))
        // Drain the resumed task before asserting its stale result was ignored.
        await Task.yield()
        #expect(model.notifications == .init(mode: .mute, isDefault: false))
    }

    @Test("Read and write failures preserve confirmed state and can be retried")
    func failures() async throws {
        let sdk = ProfileTestNotificationSettings()
        sdk.state.modify { $0.failRead = true }
        let snapshot = ProfileTestSource.snapshot()
        let model = RoomProfileViewModel(snapshot: snapshot, source: ProfileTestSource(snapshot),
            notifications: RoomNotificationSettingsService(settings: sdk), isCurrentSession: { true })
        model.start()
        defer { model.stop() }
        try await wait { model.notificationsError != nil }
        #expect(model.notifications == nil && !model.canChangeNotifications)
        sdk.state.modify { $0.failRead = false; $0.failWrite = true }
        model.refreshNotifications()
        try await wait { model.canChangeNotifications }
        model.setNotifications(.muted)
        try await wait { model.actionError != nil && model.canChangeNotifications }
        #expect(model.notifications == .init(mode: .mentionsAndKeywordsOnly, isDefault: true))
        sdk.state.modify { $0.failWrite = false }
        model.setNotifications(.allMessages)
        try await wait { model.canChangeNotifications && model.notifications?.mode == .allMessages }
    }

    @Test("Live room metadata wins over bootstrap; revoked permissions disable actions")
    func metadataRace() async throws {
        let initial = ProfileTestSource.snapshot()
        let load = ProfileTestRequest<RoomProfileSnapshot>()
        let source = ProfileTestSource(initial, loadRequest: load)
        let model = RoomProfileViewModel(snapshot: initial, source: source, notifications: nil, isCurrentSession: { true })
        model.start()
        defer { model.stop() }
        try await wait { await load.isPending }
        var latest = initial
        latest.title = "New name"
        latest.permissions = .init(invite: false, editName: false, editAvatar: false)
        source.send(latest)
        try await wait { model.snapshot.title == "New name" }
        await load.finish(initial)
        await Task.yield()
        #expect(model.snapshot == latest)
        #expect(RoomProfileAction.primary(for: model.snapshot) == [.invite, .search, .notifications, .more])
        #expect(!RoomProfileAction.invite.isEnabled(in: model.snapshot))
        #expect(!RoomProfileAction.edit.isEnabled(in: model.snapshot))
        #expect(RoomProfileAction.primary(for: ProfileTestSource.snapshot(direct: true)).first == .call)
        model.stop()
        #expect(!source.isObserving)
    }

    @Test("Unchanged metadata does not publish UI updates or restart a pending settings read")
    func unchangedMetadata() async throws {
        let sdk = ProfileTestNotificationSettings()
        let read = ProfileTestRequest<RoomNotificationSettings>()
        sdk.state.modify { $0.readRequest = read }
        let snapshot = ProfileTestSource.snapshot()
        let source = ProfileTestSource(snapshot)
        let model = RoomProfileViewModel(snapshot: snapshot, source: source,
            notifications: RoomNotificationSettingsService(settings: sdk), isCurrentSession: { true })
        model.start()
        defer { model.stop() }
        try await wait { await read.isPending }
        var informationUpdates = 0
        var snapshotUpdates = 0
        let errors = model.$informationError.dropFirst().sink { _ in informationUpdates += 1 }
        let metadata = model.$snapshot.dropFirst().sink { _ in snapshotUpdates += 1 }
        defer { errors.cancel(); metadata.cancel() }
        for _ in 0..<50 { source.send(snapshot) }
        var renamed = snapshot
        renamed.title = "Renamed"
        source.send(renamed)
        try await wait { model.snapshot.title == renamed.title }
        await read.finish(.init(mode: .mute, isDefault: false))
        try await wait { model.canChangeNotifications }
        #expect(informationUpdates == 0)
        #expect(snapshotUpdates == 1)
        #expect(sdk.state.wrappedValue.reads.count == 1)
        #expect(model.notifications?.mode == .mute)
    }

    @Test("An old account's pending request cannot publish into a closed profile")
    func sessionChange() async throws {
        let sdk = ProfileTestNotificationSettings()
        let read = ProfileTestRequest<RoomNotificationSettings>()
        sdk.state.modify { $0.readRequest = read }
        let initial = ProfileTestSource.snapshot()
        var sameSession = true
        let source = ProfileTestSource(initial)
        let model = RoomProfileViewModel(snapshot: initial, source: source,
            notifications: RoomNotificationSettingsService(settings: sdk), isCurrentSession: { sameSession })
        model.start()
        try await wait { await read.isPending }
        sameSession = false
        model.stop()
        await read.finish(.init(mode: .mute, isDefault: false))
        await Task.yield()
        #expect(model.notifications == nil)
        #expect(!source.isObserving)
        model.setNotifications(.muted)
        #expect(sdk.state.wrappedValue.writes.isEmpty)
    }
}
