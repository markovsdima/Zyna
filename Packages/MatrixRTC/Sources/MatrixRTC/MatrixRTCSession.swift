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
    public let membershipEventExpiryHeadroomMilliseconds: Int64
    public let membershipEventExpiryRefreshRetryDelayMilliseconds: UInt64
    public let callIntent: String?
    public let joinedUserIds: Set<String>?
    public let mediaKeyRotationConfiguration: MatrixRTCMediaKeyRotationConfiguration

    public init(
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        roomVersion: String? = nil,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection = .oldestMembership,
        fociPreferred: [MatrixRTCTransport],
        expires: Int64 = MatrixRTCCallMembership.defaultExpireDurationMilliseconds,
        membershipEventExpiryHeadroomMilliseconds: Int64 = 5_000,
        membershipEventExpiryRefreshRetryDelayMilliseconds: UInt64 = 5_000,
        callIntent: String? = nil,
        joinedUserIds: Set<String>? = nil,
        mediaKeyRotationConfiguration: MatrixRTCMediaKeyRotationConfiguration = .init()
    ) {
        self.slot = slot
        self.roomVersion = roomVersion
        self.focusSelection = focusSelection
        self.fociPreferred = fociPreferred
        self.expires = expires
        self.membershipEventExpiryHeadroomMilliseconds = membershipEventExpiryHeadroomMilliseconds
        self.membershipEventExpiryRefreshRetryDelayMilliseconds = membershipEventExpiryRefreshRetryDelayMilliseconds
        self.callIntent = callIntent
        self.joinedUserIds = joinedUserIds
        self.mediaKeyRotationConfiguration = mediaKeyRotationConfiguration
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

public final class MatrixRTCSession: @unchecked Sendable {
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
    private let sessionUpdateQueue = MatrixRTCSessionAsyncSerialExecutor()
    private let stateLock = NSLock()
    private var mutableState = MatrixRTCSessionMutableState()

    public var state: MatrixRTCSessionState {
        withStateLock { mutableState.state }
    }

    public var ownMembership: MatrixRTCCallMembership? {
        withStateLock { mutableState.ownMembership }
    }

    public var memberships: [MatrixRTCCallMembership] {
        withStateLock { mutableState.memberships }
    }

    private static let maximumSleepMilliseconds = UInt64.max / 1_000_000

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
        stopMembershipExpiryRefresh()
        withStateLock {
            mutableState.mediaKeyManager
        }?.stop()
    }

    @discardableResult
    public func join() async throws -> MatrixRTCSessionJoinResult {
        try await sessionUpdateQueue.run { [self] in
            guard withStateLock({ mutableState.state != .joining && mutableState.state != .joined }) else {
                throw MatrixRTCSessionError.alreadyJoined
            }

            withStateLock {
                mutableState.state = .joining
            }

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
                    rotationConfiguration: configuration.mediaKeyRotationConfiguration,
                    timestampProvider: timestampProvider,
                    onKeyChanged: onKeyChanged,
                    onError: onError
                )
                manager.start()
                startedMediaKeyManager = manager

                let keyShareResult = try await manager.ensureKeyDistribution(with: activeMemberships)

                withStateLock {
                    mutableState.ownMembership = ownMembership
                    mutableState.memberships = activeMemberships
                    mutableState.mediaKeyManager = manager
                    mutableState.state = .joined
                }
                startMembershipExpiryRefresh()

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
                stopMembershipExpiryRefresh()
                withStateLock {
                    mutableState.ownMembership = nil
                    mutableState.memberships = []
                    mutableState.mediaKeyManager = nil
                    mutableState.state = .idle
                }
                throw error
            }
        }
    }

    @discardableResult
    public func refreshMemberships(
        joinedUserIds: Set<String>? = nil
    ) async throws -> MatrixRTCSessionMembershipRefreshResult {
        try await sessionUpdateQueue.run { [self] in
            let snapshot = withStateLock {
                (
                    state: mutableState.state,
                    ownMembership: mutableState.ownMembership,
                    mediaKeyManager: mutableState.mediaKeyManager
                )
            }
            guard snapshot.state == .joined,
                  let ownMembership = snapshot.ownMembership,
                  let mediaKeyManager = snapshot.mediaKeyManager else {
                throw MatrixRTCSessionError.notJoined
            }

            let loadedMemberships = try await membershipClient.loadActiveMemberships(
                slot: configuration.slot,
                joinedUserIds: joinedUserIds ?? configuration.joinedUserIds,
                now: timestampProvider()
            )
            let activeMemberships = Self.memberships(loadedMemberships, including: ownMembership)

            let keyShareResult = try await mediaKeyManager.ensureKeyDistribution(with: activeMemberships)
            withStateLock {
                mutableState.memberships = activeMemberships
            }

            return .init(
                memberships: activeMemberships,
                keyShareResult: keyShareResult
            )
        }
    }

    @discardableResult
    public func refreshOwnMembershipExpiry() async throws -> MatrixRTCCallMembership {
        try await sessionUpdateQueue.run { [self] in
            let snapshot = withStateLock {
                (
                    state: mutableState.state,
                    ownMembership: mutableState.ownMembership,
                    mediaKeyManager: mutableState.mediaKeyManager,
                    membershipExpiryRefreshIteration: mutableState.membershipExpiryRefreshIteration
                )
            }
            guard snapshot.state == .joined, let ownMembership = snapshot.ownMembership else {
                throw MatrixRTCSessionError.notJoined
            }

            let nextIteration = snapshot.membershipExpiryRefreshIteration + 1
            let nextExpires = membershipEventExpires(for: nextIteration)
            let refreshedMembership = try await membershipClient.publishOwnLegacyMembership(
                slot: configuration.slot,
                roomVersion: configuration.roomVersion,
                focusSelection: configuration.focusSelection,
                fociPreferred: configuration.fociPreferred,
                createdTimestamp: ownMembership.createdTimestamp,
                expires: nextExpires,
                callIntent: configuration.callIntent
            )

            guard withStateLock({
                mutableState.state == .joined && mutableState.ownMembership?.identity == ownMembership.identity
            }) else {
                throw CancellationError()
            }

            let refreshedMemberships = withStateLock {
                mutableState.membershipExpiryRefreshIteration = nextIteration
                mutableState.ownMembership = refreshedMembership
                let retainedMemberships = mutableState.memberships.filter { $0.identity != ownMembership.identity }
                mutableState.memberships = Self.memberships(retainedMemberships, including: refreshedMembership)
                return mutableState.memberships
            }
            snapshot.mediaKeyManager?.updateMemberships(refreshedMemberships)

            return refreshedMembership
        }
    }

    @discardableResult
    public func leave() async throws -> String? {
        try await sessionUpdateQueue.run { [self] in
            let shouldLeave = withStateLock {
                mutableState.ownMembership != nil
                    || mutableState.mediaKeyManager != nil
                    || mutableState.state == .joining
                    || mutableState.state == .joined
            }
            guard shouldLeave else {
                withStateLock {
                    mutableState.state = .left
                }
                return nil
            }

            stopMembershipExpiryRefresh()

            let stoppedMediaKeyManager = withStateLock {
                mutableState.mediaKeyManager
            }
            defer {
                stoppedMediaKeyManager?.stop()
                withStateLock {
                    mutableState.mediaKeyManager = nil
                    mutableState.ownMembership = nil
                    mutableState.memberships = []
                    mutableState.state = .left
                }
            }

            return try await membershipClient.leaveOwnLegacyMembership(
                slot: configuration.slot,
                roomVersion: configuration.roomVersion
            )
        }
    }

    public func encryptionKeys() -> [MatrixRTCMediaKeyMapKey: [MatrixRTCMediaKey]] {
        withStateLock {
            mutableState.mediaKeyManager
        }?.encryptionKeys() ?? [:]
    }

    public func reemitEncryptionKeys() {
        withStateLock {
            mutableState.mediaKeyManager
        }?.reemitEncryptionKeys()
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

    private func startMembershipExpiryRefresh() {
        stopMembershipExpiryRefresh()

        guard configuration.expires > 0 else {
            return
        }

        withStateLock {
            mutableState.membershipExpiryRefreshIteration = 1
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let refreshDelay = self?.membershipExpiryRefreshDelayMilliseconds() else {
                    return
                }

                do {
                    try await Self.sleep(milliseconds: refreshDelay)
                    try Task.checkCancellation()
                    _ = try await self?.refreshOwnMembershipExpiry()
                } catch is CancellationError {
                    return
                } catch {
                    self?.onError?(error)
                    guard let retryDelay = self?.configuration.membershipEventExpiryRefreshRetryDelayMilliseconds else {
                        return
                    }
                    do {
                        try await Self.sleep(milliseconds: retryDelay)
                    } catch {
                        return
                    }
                }
            }
        }
        withStateLock {
            mutableState.membershipExpiryRefreshTask = task
        }
    }

    private func stopMembershipExpiryRefresh() {
        let task = withStateLock {
            let task = mutableState.membershipExpiryRefreshTask
            mutableState.membershipExpiryRefreshTask = nil
            return task
        }
        task?.cancel()
    }

    private func membershipExpiryRefreshDelayMilliseconds() -> UInt64 {
        let snapshot = withStateLock {
            (
                ownMembership: mutableState.ownMembership,
                membershipExpiryRefreshIteration: mutableState.membershipExpiryRefreshIteration
            )
        }
        guard let ownMembership = snapshot.ownMembership else {
            return 0
        }

        let nextExpiryTimestamp = membershipExpiryTimestamp(
            createdTimestamp: ownMembership.createdTimestamp,
            iteration: snapshot.membershipExpiryRefreshIteration
        )
        let refreshTimestamp = nextExpiryTimestamp - effectiveMembershipEventExpiryHeadroomMilliseconds()
        let delay = max(0, refreshTimestamp - timestampProvider())
        return UInt64(delay)
    }

    private func effectiveMembershipEventExpiryHeadroomMilliseconds() -> Int64 {
        min(
            max(0, configuration.membershipEventExpiryHeadroomMilliseconds),
            max(0, configuration.expires - 1)
        )
    }

    private func membershipExpiryTimestamp(createdTimestamp: Int64, iteration: Int64) -> Int64 {
        let expires = membershipEventExpires(for: iteration)
        let (timestamp, overflow) = createdTimestamp.addingReportingOverflow(expires)
        return overflow ? Int64.max : timestamp
    }

    private func membershipEventExpires(for iteration: Int64) -> Int64 {
        let (expires, overflow) = configuration.expires.multipliedReportingOverflow(by: iteration)
        return overflow ? Int64.max : expires
    }

    private static func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: min(milliseconds, maximumSleepMilliseconds) * 1_000_000)
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}

private struct MatrixRTCSessionMutableState {
    var state: MatrixRTCSessionState = .idle
    var ownMembership: MatrixRTCCallMembership?
    var memberships: [MatrixRTCCallMembership] = []
    var mediaKeyManager: MatrixRTCMediaKeyManager?
    var membershipExpiryRefreshTask: Task<Void, Never>?
    var membershipExpiryRefreshIteration: Int64 = 1
}

private actor MatrixRTCSessionAsyncSerialExecutor {
    private var previousTask: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let previousTask = previousTask
        let task = Task {
            await previousTask?.value
            return try await operation()
        }
        self.previousTask = Task {
            _ = try? await task.value
        }
        return try await task.value
    }
}
