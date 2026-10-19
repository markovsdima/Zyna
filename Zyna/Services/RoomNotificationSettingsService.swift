// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import MatrixRustSDK

enum RoomNotificationSelection: CaseIterable, Sendable {
    case inherited, allMessages, mentions, muted

    init(_ settings: RoomNotificationSettings) {
        if settings.isDefault { self = .inherited }
        else {
            switch settings.mode {
            case .allMessages: self = .allMessages
            case .mentionsAndKeywordsOnly: self = .mentions
            case .mute: self = .muted
            }
        }
    }

    var mode: RoomNotificationMode? {
        switch self {
        case .inherited: nil
        case .allMessages: .allMessages
        case .mentions: .mentionsAndKeywordsOnly
        case .muted: .mute
        }
    }
}

struct RoomNotificationContext: Equatable, Sendable {
    let roomID: String
    let isEncrypted: Bool
    let isOneToOne: Bool

    init(roomID: String, isEncrypted: Bool, isOneToOne: Bool) {
        self.roomID = roomID
        self.isEncrypted = isEncrypted
        self.isOneToOne = isOneToOne
    }

    init(_ info: RoomInfo) {
        roomID = info.id
        isEncrypted = info.encryptionState != .notEncrypted
        // Matrix push rules use the member count, not the m.direct tag.
        isOneToOne = info.activeMembersCount == 2
    }
}

protocol RoomNotificationSettingsProviding: AnyObject, Sendable {
    var changes: AnyPublisher<Void, Never> { get }
    func settings(for context: RoomNotificationContext) async throws -> RoomNotificationSettings
    func set(_ selection: RoomNotificationSelection, roomID: String) async throws
}

/// One delegate per SDK settings object, shared by profiles and the room list.
/// SDK reads use its in-memory rules; these calls do not fetch room history.
final class RoomNotificationSettingsService: RoomNotificationSettingsProviding, @unchecked Sendable {
    private let settings: any NotificationSettingsProtocol
    private let subject = PassthroughSubject<Void, Never>()
    private struct LocalState {
        var syncRevision: UInt64 = 0
        var nextWrite: UInt64 = 0
        var writes: [String: UInt64] = [:]
        var muted: [String: Bool] = [:]
    }
    private let local = Atomic(LocalState())
    /// Only locally changed rooms need an override until push rules sync.
    /// The list takes one immutable snapshot, without a per-room SDK read.
    var localMuteOverrides: [String: Bool] { local.wrappedValue.muted }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    init(settings: any NotificationSettingsProtocol) {
        self.settings = settings
        settings.setDelegate(delegate: NotificationSettingsObserver { [weak self] in
            guard let self else { return }
            // Sliding sync updates RoomInfo's cached modes before invoking
            // push-rule event handlers. Remote changes now take precedence.
            self.local.modify { state in
                state.syncRevision &+= 1
                state.muted.removeAll()
            }
            self.subject.send(())
        })
    }

    deinit { settings.setDelegate(delegate: nil) }

    func settings(for context: RoomNotificationContext) async throws -> RoomNotificationSettings {
        try await settings.getRoomNotificationSettings(roomId: context.roomID,
            isEncrypted: context.isEncrypted, isOneToOne: context.isOneToOne)
    }

    func set(_ selection: RoomNotificationSelection, roomID: String) async throws {
        let write = local.withValue { state in
            state.nextWrite &+= 1
            state.writes[roomID] = state.nextWrite
            return state.nextWrite
        }
        var failure: Error?
        do {
            if let mode = selection.mode {
                try await settings.setRoomNotificationMode(roomId: roomID, mode: mode)
            } else {
                try await settings.restoreDefaultRoomNotificationMode(roomId: roomID)
            }
        } catch { failure = error }

        // Read confirmed SDK rules once, even after a partial write failure.
        // A sync or a newer write must invalidate this in-flight result.
        let revision = local.wrappedValue.syncRevision
        do {
            let mode = try await settings.getUserDefinedRoomNotificationMode(roomId: roomID)
            local.modify { state in
                guard state.writes[roomID] == write else { return }
                state.writes.removeValue(forKey: roomID)
                guard state.syncRevision == revision else { return }
                state.muted[roomID] = mode == .mute
            }
        } catch {
            local.modify { state in
                guard state.writes[roomID] == write else { return }
                state.writes.removeValue(forKey: roomID)
                state.muted.removeValue(forKey: roomID)
            }
        }
        subject.send(())
        if let failure { throw failure }
    }
}

private final class NotificationSettingsObserver: NotificationSettingsDelegate {
    private let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func settingsDidChange() { callback() }
}
