import Foundation

public protocol MatrixRTCSessionMembershipClient: Sendable {
    @discardableResult
    func publishOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection,
        fociPreferred: [MatrixRTCTransport],
        createdTimestamp: Int64?,
        expires: Int64,
        callIntent: String?
    ) async throws -> MatrixRTCCallMembership

    func loadActiveMemberships(
        slot: MatrixRTCSlotDescription,
        joinedUserIds: Set<String>?,
        now: Int64
    ) async throws -> [MatrixRTCCallMembership]

    @discardableResult
    func leaveOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?
    ) async throws -> String
}

public enum MatrixRTCSessionState: Equatable, Sendable {
    case idle
    case joining
    case joined
    case left
}

public enum MatrixRTCSessionError: Error, Equatable {
    case alreadyJoined
    case notJoined
}

public struct MatrixRTCSessionConfiguration: Equatable, Sendable {
    public let slot: MatrixRTCSlotDescription
    public let roomVersion: String?
    public let focusSelection: MatrixRTCLegacyCallMembershipFocusSelection
    public let fociPreferred: [MatrixRTCTransport]
    public let expires: Int64
    public let callIntent: String?
    public let joinedUserIds: Set<String>?

    public init(
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        roomVersion: String? = nil,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection = .oldestMembership,
        fociPreferred: [MatrixRTCTransport],
        expires: Int64 = MatrixRTCCallMembership.defaultExpireDurationMilliseconds,
        callIntent: String? = nil,
        joinedUserIds: Set<String>? = nil
    ) {
        self.slot = slot
        self.roomVersion = roomVersion
        self.focusSelection = focusSelection
        self.fociPreferred = fociPreferred
        self.expires = expires
        self.callIntent = callIntent
        self.joinedUserIds = joinedUserIds
    }
}

public struct MatrixRTCSessionJoinResult: Equatable, Sendable {
    public let ownMembership: MatrixRTCCallMembership
    public let memberships: [MatrixRTCCallMembership]
    public let keyShareResult: MatrixRTCMediaKeyShareResult

    public init(
        ownMembership: MatrixRTCCallMembership,
        memberships: [MatrixRTCCallMembership],
        keyShareResult: MatrixRTCMediaKeyShareResult
    ) {
        self.ownMembership = ownMembership
        self.memberships = memberships
        self.keyShareResult = keyShareResult
    }
}

public struct MatrixRTCSessionMembershipRefreshResult: Equatable, Sendable {
    public let memberships: [MatrixRTCCallMembership]
    public let keyShareResult: MatrixRTCMediaKeyShareResult

    public init(
        memberships: [MatrixRTCCallMembership],
        keyShareResult: MatrixRTCMediaKeyShareResult
    ) {
        self.memberships = memberships
        self.keyShareResult = keyShareResult
    }
}

public final class MatrixRTCSession {
    public typealias KeyTransportFactory = @Sendable (MatrixRTCMembershipIdentity) -> MatrixRTCToDeviceKeyTransport
    public typealias TimestampProvider = @Sendable () -> Int64
    public typealias KeyChangedHandler = MatrixRTCMediaKeyManager.KeyChangedHandler
    public typealias ErrorHandler = MatrixRTCMediaKeyManager.ErrorHandler

    private let configuration: MatrixRTCSessionConfiguration
    private let membershipClient: any MatrixRTCSessionMembershipClient
    private let keyTransportFactory: KeyTransportFactory
    private let keyGenerator: any MatrixRTCMediaKeyGenerating
    private let timestampProvider: TimestampProvider
    private let onKeyChanged: KeyChangedHandler
    private let onError: ErrorHandler?

    public private(set) var state: MatrixRTCSessionState = .idle
    public private(set) var ownMembership: MatrixRTCCallMembership?
    public private(set) var memberships: [MatrixRTCCallMembership] = []

    private var mediaKeyManager: MatrixRTCMediaKeyManager?

    public init(
        configuration: MatrixRTCSessionConfiguration,
        membershipClient: any MatrixRTCSessionMembershipClient,
        keyTransportFactory: @escaping KeyTransportFactory,
        keyGenerator: any MatrixRTCMediaKeyGenerating = MatrixRTCRandomMediaKeyGenerator(),
        timestampProvider: @escaping TimestampProvider = {
            Int64(Date().timeIntervalSince1970 * 1000)
        },
        onKeyChanged: @escaping KeyChangedHandler,
        onError: ErrorHandler? = nil
    ) {
        self.configuration = configuration
        self.membershipClient = membershipClient
        self.keyTransportFactory = keyTransportFactory
        self.keyGenerator = keyGenerator
        self.timestampProvider = timestampProvider
        self.onKeyChanged = onKeyChanged
        self.onError = onError
    }

    deinit {
        mediaKeyManager?.stop()
    }

    @discardableResult
    public func join() async throws -> MatrixRTCSessionJoinResult {
        guard state != .joining && state != .joined else {
            throw MatrixRTCSessionError.alreadyJoined
        }

        state = .joining
        var publishedOwnMembership: MatrixRTCCallMembership?
        var startedMediaKeyManager: MatrixRTCMediaKeyManager?

        do {
            let createdTimestamp = timestampProvider()
            let ownMembership = try await membershipClient.publishOwnLegacyMembership(
                slot: configuration.slot,
                roomVersion: configuration.roomVersion,
                focusSelection: configuration.focusSelection,
                fociPreferred: configuration.fociPreferred,
                createdTimestamp: createdTimestamp,
                expires: configuration.expires,
                callIntent: configuration.callIntent
            )
            publishedOwnMembership = ownMembership

            let loadedMemberships = try await membershipClient.loadActiveMemberships(
                slot: configuration.slot,
                joinedUserIds: configuration.joinedUserIds,
                now: timestampProvider()
            )
            let activeMemberships = Self.memberships(loadedMemberships, including: ownMembership)

            let manager = MatrixRTCMediaKeyManager(
                ownMembership: ownMembership,
                memberships: activeMemberships,
                transport: keyTransportFactory(ownMembership.identity),
                keyGenerator: keyGenerator,
                onKeyChanged: onKeyChanged,
                onError: onError
            )
            manager.start()
            startedMediaKeyManager = manager

            let keyShareResult = try await manager.shareCurrentKey(with: activeMemberships)

            self.ownMembership = ownMembership
            memberships = activeMemberships
            mediaKeyManager = manager
            state = .joined

            return .init(
                ownMembership: ownMembership,
                memberships: activeMemberships,
                keyShareResult: keyShareResult
            )
        } catch {
            startedMediaKeyManager?.stop()
            if publishedOwnMembership != nil {
                _ = try? await membershipClient.leaveOwnLegacyMembership(
                    slot: configuration.slot,
                    roomVersion: configuration.roomVersion
                )
            }
            ownMembership = nil
            memberships = []
            mediaKeyManager = nil
            state = .idle
            throw error
        }
    }

    @discardableResult
    public func refreshMemberships(
        joinedUserIds: Set<String>? = nil
    ) async throws -> MatrixRTCSessionMembershipRefreshResult {
        guard let ownMembership, let mediaKeyManager else {
            throw MatrixRTCSessionError.notJoined
        }

        let loadedMemberships = try await membershipClient.loadActiveMemberships(
            slot: configuration.slot,
            joinedUserIds: joinedUserIds ?? configuration.joinedUserIds,
            now: timestampProvider()
        )
        let activeMemberships = Self.memberships(loadedMemberships, including: ownMembership)

        mediaKeyManager.updateMemberships(activeMemberships)
        let keyShareResult = try await mediaKeyManager.shareCurrentKey(with: activeMemberships)
        memberships = activeMemberships

        return .init(
            memberships: activeMemberships,
            keyShareResult: keyShareResult
        )
    }

    @discardableResult
    public func leave() async throws -> String? {
        guard ownMembership != nil || mediaKeyManager != nil || state == .joining || state == .joined else {
            state = .left
            return nil
        }

        defer {
            mediaKeyManager?.stop()
            mediaKeyManager = nil
            ownMembership = nil
            memberships = []
            state = .left
        }

        return try await membershipClient.leaveOwnLegacyMembership(
            slot: configuration.slot,
            roomVersion: configuration.roomVersion
        )
    }

    public func encryptionKeys() -> [MatrixRTCMediaKeyMapKey: [MatrixRTCMediaKey]] {
        mediaKeyManager?.encryptionKeys() ?? [:]
    }

    public func reemitEncryptionKeys() {
        mediaKeyManager?.reemitEncryptionKeys()
    }

    private static func memberships(
        _ memberships: [MatrixRTCCallMembership],
        including ownMembership: MatrixRTCCallMembership
    ) -> [MatrixRTCCallMembership] {
        guard !memberships.contains(where: { $0.identity == ownMembership.identity }) else {
            return memberships
        }

        return (memberships + [ownMembership]).sorted { lhs, rhs in
            if lhs.createdTimestamp == rhs.createdTimestamp {
                lhs.eventId < rhs.eventId
            } else {
                lhs.createdTimestamp < rhs.createdTimestamp
            }
        }
    }
}
