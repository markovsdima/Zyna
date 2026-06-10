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

    @discardableResult
    func scheduleDelayedLeaveOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?,
        delayMilliseconds: UInt64
    ) async throws -> String

    func restartDelayedEvent(delayId: String) async throws

    func sendDelayedEvent(delayId: String) async throws

    func cancelDelayedEvent(delayId: String) async throws
}

public extension MatrixRTCSessionMembershipClient {
    @discardableResult
    func scheduleDelayedLeaveOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?,
        delayMilliseconds: UInt64
    ) async throws -> String {
        throw MatrixRTCSessionDelayedEventError.unsupported
    }

    func restartDelayedEvent(delayId: String) async throws {
        throw MatrixRTCSessionDelayedEventError.unsupported
    }

    func sendDelayedEvent(delayId: String) async throws {
        throw MatrixRTCSessionDelayedEventError.unsupported
    }

    func cancelDelayedEvent(delayId: String) async throws {
        throw MatrixRTCSessionDelayedEventError.unsupported
    }
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
    case ownMembershipIdentityMismatch(expected: MatrixRTCMembershipIdentity, actual: MatrixRTCMembershipIdentity)
}

public enum MatrixRTCSessionDelayedEventError: Error, Equatable, Sendable {
    case unsupported
    case notFound
    case rateLimited(retryAfterMilliseconds: UInt64?)
    case maxDelayExceeded(maxDelayMilliseconds: UInt64?)
    case generic(String)
}

public struct MatrixRTCSessionConfiguration: Equatable, Sendable {
    public let slot: MatrixRTCSlotDescription
    public let roomVersion: String?
    public let ownMembershipIdentity: MatrixRTCMembershipIdentity?
    public let focusSelection: MatrixRTCLegacyCallMembershipFocusSelection
    public let fociPreferred: [MatrixRTCTransport]
    public let expires: Int64
    public let membershipEventExpiryHeadroomMilliseconds: Int64
    public let membershipEventExpiryRefreshRetryDelayMilliseconds: UInt64
    public let delayedLeaveEventDelayMilliseconds: UInt64?
    public let delayedLeaveEventRestartMilliseconds: UInt64
    public let callIntent: String?
    public let joinedUserIds: Set<String>?
    public let mediaKeyRotationConfiguration: MatrixRTCMediaKeyRotationConfiguration

    public init(
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        roomVersion: String? = nil,
        ownMembershipIdentity: MatrixRTCMembershipIdentity? = nil,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection = .oldestMembership,
        fociPreferred: [MatrixRTCTransport],
        expires: Int64 = MatrixRTCCallMembership.defaultExpireDurationMilliseconds,
        membershipEventExpiryHeadroomMilliseconds: Int64 = 5_000,
        membershipEventExpiryRefreshRetryDelayMilliseconds: UInt64 = 5_000,
        delayedLeaveEventDelayMilliseconds: UInt64? = 18_000,
        delayedLeaveEventRestartMilliseconds: UInt64 = 4_000,
        callIntent: String? = nil,
        joinedUserIds: Set<String>? = nil,
        mediaKeyRotationConfiguration: MatrixRTCMediaKeyRotationConfiguration = .init()
    ) {
        self.slot = slot
        self.roomVersion = roomVersion
        self.ownMembershipIdentity = ownMembershipIdentity
        self.focusSelection = focusSelection
        self.fociPreferred = fociPreferred
        self.expires = expires
        self.membershipEventExpiryHeadroomMilliseconds = membershipEventExpiryHeadroomMilliseconds
        self.membershipEventExpiryRefreshRetryDelayMilliseconds = membershipEventExpiryRefreshRetryDelayMilliseconds
        self.delayedLeaveEventDelayMilliseconds = delayedLeaveEventDelayMilliseconds
        self.delayedLeaveEventRestartMilliseconds = delayedLeaveEventRestartMilliseconds
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
        stopDelayedLeaveRefresh()
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
            var prestartedKeyTransport: MatrixRTCToDeviceKeyTransport?
            var scheduledDelayedLeaveEventID: String?
            let earlyReceivedKeys = MatrixRTCEarlyReceivedKeyBuffer()

            do {
                if let ownMembershipIdentity = configuration.ownMembershipIdentity {
                    let transport = keyTransportFactory(ownMembershipIdentity)
                    transport.setReceivedKeyHandler { result in
                        earlyReceivedKeys.append(result)
                    }
                    transport.start()
                    prestartedKeyTransport = transport
                }

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
                if let expectedIdentity = configuration.ownMembershipIdentity,
                   expectedIdentity != ownMembership.identity {
                    throw MatrixRTCSessionError.ownMembershipIdentityMismatch(
                        expected: expectedIdentity,
                        actual: ownMembership.identity
                    )
                }
                scheduledDelayedLeaveEventID = await scheduleDelayedLeaveIfPossible()

                let loadedMemberships = try await membershipClient.loadActiveMemberships(
                    slot: configuration.slot,
                    joinedUserIds: configuration.joinedUserIds,
                    now: timestampProvider()
                )
                let activeMemberships = Self.memberships(loadedMemberships, including: ownMembership)

                let manager = MatrixRTCMediaKeyManager(
                    ownMembership: ownMembership,
                    memberships: activeMemberships,
                    transport: prestartedKeyTransport ?? keyTransportFactory(ownMembership.identity),
                    keyGenerator: keyGenerator,
                    rotationConfiguration: configuration.mediaKeyRotationConfiguration,
                    timestampProvider: timestampProvider,
                    onKeyChanged: onKeyChanged,
                    onError: onError
                )
                if prestartedKeyTransport == nil {
                    manager.start()
                }
                startedMediaKeyManager = manager

                let deliverReceivedKey: @Sendable (Result<MatrixRTCReceivedCallEncryptionKey, Error>) -> Void = { result in
                    switch result {
                    case .success(let receivedKey):
                        manager.handleReceivedKey(receivedKey)
                    case .failure(let error):
                        self.onError?(error)
                    }
                }
                for result in earlyReceivedKeys.drain(forwardingTo: deliverReceivedKey) {
                    deliverReceivedKey(result)
                }

                let keyShareResult = try await manager.ensureKeyDistribution(with: activeMemberships)

                withStateLock {
                    mutableState.ownMembership = ownMembership
                    mutableState.memberships = activeMemberships
                    mutableState.mediaKeyManager = manager
                    mutableState.delayedLeaveEventID = scheduledDelayedLeaveEventID
                    mutableState.state = .joined
                }
                startMembershipExpiryRefresh()
                startDelayedLeaveRefresh()

                return .init(
                    ownMembership: ownMembership,
                    memberships: activeMemberships,
                    keyShareResult: keyShareResult
                )
            } catch {
                startedMediaKeyManager?.stop()
                if startedMediaKeyManager == nil {
                    prestartedKeyTransport?.stop()
                }
                if publishedOwnMembership != nil {
                    _ = try? await leaveOwnLegacyMembership(delayedLeaveEventID: scheduledDelayedLeaveEventID)
                }
                stopMembershipExpiryRefresh()
                stopDelayedLeaveRefresh()
                withStateLock {
                    mutableState.ownMembership = nil
                    mutableState.memberships = []
                    mutableState.mediaKeyManager = nil
                    mutableState.delayedLeaveEventID = nil
                    mutableState.state = .idle
                }
                throw error
            }
        }
    }

    @discardableResult
    public func refreshMemberships(
        joinedUserIds: Set<String>? = nil,
        distributeKeys: Bool = true
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

            let keyShareResult: MatrixRTCMediaKeyShareResult
            if distributeKeys {
                keyShareResult = try await mediaKeyManager.ensureKeyDistribution(with: activeMemberships)
            } else {
                mediaKeyManager.updateMemberships(activeMemberships)
                keyShareResult = .init(failures: [], sharedWith: [])
            }
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
    public func reshareCurrentMediaKey(
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

            let keyShareResult = try await mediaKeyManager.reshareCurrentKey(with: activeMemberships)
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
            stopDelayedLeaveRefresh()

            let snapshot = withStateLock {
                (
                    mediaKeyManager: mutableState.mediaKeyManager,
                    delayedLeaveEventID: mutableState.delayedLeaveEventID
                )
            }
            defer {
                snapshot.mediaKeyManager?.stop()
                withStateLock {
                    mutableState.mediaKeyManager = nil
                    mutableState.ownMembership = nil
                    mutableState.memberships = []
                    mutableState.delayedLeaveEventID = nil
                    mutableState.state = .left
                }
            }

            return try await leaveOwnLegacyMembership(delayedLeaveEventID: snapshot.delayedLeaveEventID)
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

    private func startDelayedLeaveRefresh() {
        stopDelayedLeaveRefresh()

        let shouldStart = withStateLock {
            mutableState.delayedLeaveEventID != nil
        }
        guard shouldStart, configuration.delayedLeaveEventRestartMilliseconds > 0 else {
            return
        }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let restartDelay = self?.configuration.delayedLeaveEventRestartMilliseconds else {
                    return
                }

                do {
                    try await Self.sleep(milliseconds: restartDelay)
                    try Task.checkCancellation()
                    guard await self?.restartDelayedLeaveEvent() == true else {
                        return
                    }
                } catch {
                    return
                }
            }
        }
        withStateLock {
            mutableState.delayedLeaveRefreshTask = task
        }
    }

    private func stopDelayedLeaveRefresh() {
        let task = withStateLock {
            let task = mutableState.delayedLeaveRefreshTask
            mutableState.delayedLeaveRefreshTask = nil
            return task
        }
        task?.cancel()
    }

    private func scheduleDelayedLeaveIfPossible(delayMilliseconds: UInt64? = nil) async -> String? {
        guard let configuredDelay = configuration.delayedLeaveEventDelayMilliseconds else {
            return nil
        }

        let effectiveDelay = delayMilliseconds ?? configuredDelay
        do {
            return try await membershipClient.scheduleDelayedLeaveOwnLegacyMembership(
                slot: configuration.slot,
                roomVersion: configuration.roomVersion,
                delayMilliseconds: effectiveDelay
            )
        } catch MatrixRTCSessionDelayedEventError.maxDelayExceeded(let maxDelayMilliseconds) {
            guard let maxDelayMilliseconds,
                  maxDelayMilliseconds > 0,
                  maxDelayMilliseconds < effectiveDelay else {
                reportDelayedLeaveError(MatrixRTCSessionDelayedEventError.maxDelayExceeded(maxDelayMilliseconds: maxDelayMilliseconds))
                return nil
            }

            return await scheduleDelayedLeaveIfPossible(delayMilliseconds: maxDelayMilliseconds)
        } catch {
            reportDelayedLeaveError(error)
            return nil
        }
    }

    private func restartDelayedLeaveEvent() async -> Bool {
        let snapshot = withStateLock {
            (
                state: mutableState.state,
                delayedLeaveEventID: mutableState.delayedLeaveEventID
            )
        }
        guard snapshot.state == .joined else {
            return false
        }
        guard let delayedLeaveEventID = snapshot.delayedLeaveEventID else {
            return false
        }

        do {
            try await membershipClient.restartDelayedEvent(delayId: delayedLeaveEventID)
            return true
        } catch MatrixRTCSessionDelayedEventError.notFound {
            guard let rescheduledID = await scheduleDelayedLeaveIfPossible() else {
                withStateLock {
                    if mutableState.delayedLeaveEventID == delayedLeaveEventID {
                        mutableState.delayedLeaveEventID = nil
                    }
                }
                return false
            }

            return withStateLock {
                guard mutableState.state == .joined,
                      mutableState.delayedLeaveEventID == delayedLeaveEventID else {
                    return false
                }
                mutableState.delayedLeaveEventID = rescheduledID
                return true
            }
        } catch {
            if Self.isDelayedEventsUnsupported(error) {
                withStateLock {
                    if mutableState.delayedLeaveEventID == delayedLeaveEventID {
                        mutableState.delayedLeaveEventID = nil
                    }
                }
                return false
            }

            reportDelayedLeaveError(error)
            return true
        }
    }

    private func leaveOwnLegacyMembership(delayedLeaveEventID: String?) async throws -> String? {
        guard let delayedLeaveEventID else {
            return try await membershipClient.leaveOwnLegacyMembership(
                slot: configuration.slot,
                roomVersion: configuration.roomVersion
            )
        }

        do {
            try await membershipClient.sendDelayedEvent(delayId: delayedLeaveEventID)
            return nil
        } catch {
            reportDelayedLeaveError(error)
            return try await membershipClient.leaveOwnLegacyMembership(
                slot: configuration.slot,
                roomVersion: configuration.roomVersion
            )
        }
    }

    private func reportDelayedLeaveError(_ error: Error) {
        guard !Self.isDelayedEventsUnsupported(error) else {
            return
        }
        onError?(error)
    }

    private static func isDelayedEventsUnsupported(_ error: Error) -> Bool {
        guard let error = error as? MatrixRTCSessionDelayedEventError else {
            return false
        }

        if case .unsupported = error {
            return true
        }
        return false
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
    var delayedLeaveEventID: String?
    var delayedLeaveRefreshTask: Task<Void, Never>?
}

private final class MatrixRTCEarlyReceivedKeyBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<MatrixRTCReceivedCallEncryptionKey, Error>] = []
    private var forwardingHandler: (@Sendable (Result<MatrixRTCReceivedCallEncryptionKey, Error>) -> Void)?

    func append(_ result: Result<MatrixRTCReceivedCallEncryptionKey, Error>) {
        lock.lock()
        if let forwardingHandler {
            lock.unlock()
            forwardingHandler(result)
            return
        }

        results.append(result)
        lock.unlock()
    }

    func drain(
        forwardingTo forwardingHandler: @escaping @Sendable (Result<MatrixRTCReceivedCallEncryptionKey, Error>) -> Void
    ) -> [Result<MatrixRTCReceivedCallEncryptionKey, Error>] {
        lock.lock()
        defer { lock.unlock() }
        let drained = results
        results = []
        self.forwardingHandler = forwardingHandler
        return drained
    }
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
