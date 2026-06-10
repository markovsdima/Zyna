import Foundation
import Security

public struct MatrixRTCMediaKey: Equatable, Sendable {
    public let keyBase64Encoded: String
    public let keyIndex: Int
    public let membership: MatrixRTCMembershipIdentity
    public let rtcBackendIdentity: String

    public init(
        keyBase64Encoded: String,
        keyIndex: Int,
        membership: MatrixRTCMembershipIdentity,
        rtcBackendIdentity: String
    ) {
        self.keyBase64Encoded = keyBase64Encoded
        self.keyIndex = keyIndex
        self.membership = membership
        self.rtcBackendIdentity = rtcBackendIdentity
    }
}

public struct MatrixRTCMediaKeyChangedEvent: Equatable, Sendable {
    public let key: MatrixRTCMediaKey

    public init(key: MatrixRTCMediaKey) {
        self.key = key
    }
}

public struct MatrixRTCMediaKeyShareResult: Equatable, Sendable {
    public let failures: [MatrixRTCCustomToDeviceSendFailure]
    public let sharedWith: [MatrixRTCToDeviceTarget]

    public init(
        failures: [MatrixRTCCustomToDeviceSendFailure],
        sharedWith: [MatrixRTCToDeviceTarget]
    ) {
        self.failures = failures
        self.sharedWith = sharedWith
    }
}

public struct MatrixRTCMediaKeyRotationConfiguration: Equatable, Sendable {
    public let useKeyDelayMilliseconds: UInt64
    public let keyRotationGracePeriodMilliseconds: Int64

    public init(
        useKeyDelayMilliseconds: UInt64 = 1_000,
        keyRotationGracePeriodMilliseconds: Int64 = 10_000
    ) {
        self.useKeyDelayMilliseconds = useKeyDelayMilliseconds
        self.keyRotationGracePeriodMilliseconds = keyRotationGracePeriodMilliseconds
    }
}

public struct MatrixRTCMediaKeyMapKey: Hashable, Sendable {
    public let userId: String
    public let deviceId: String
    public let memberId: String

    public init(userId: String, deviceId: String, memberId: String) {
        self.userId = userId
        self.deviceId = deviceId
        self.memberId = memberId
    }

    public init(membership: MatrixRTCMembershipIdentity) {
        self.init(
            userId: membership.userId,
            deviceId: membership.deviceId,
            memberId: membership.memberId
        )
    }
}

public protocol MatrixRTCMediaKeyGenerating: Sendable {
    func generateMediaKeyBase64Encoded() -> String
}

public struct MatrixRTCRandomMediaKeyGenerator: MatrixRTCMediaKeyGenerating {
    private let byteCount: Int

    public init(byteCount: Int = 16) {
        self.byteCount = byteCount
    }

    public func generateMediaKeyBase64Encoded() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Failed to generate MatrixRTC media key")
        return Data(bytes).base64EncodedString()
    }
}

public final class MatrixRTCMediaKeyManager: @unchecked Sendable {
    public typealias KeyChangedHandler = @Sendable (MatrixRTCMediaKeyChangedEvent) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    private let ownMembership: MatrixRTCCallMembership
    private let transport: MatrixRTCToDeviceKeyTransport
    private let keyGenerator: any MatrixRTCMediaKeyGenerating
    private let rotationConfiguration: MatrixRTCMediaKeyRotationConfiguration
    private let timestampProvider: @Sendable () -> Int64
    private let onKeyChanged: KeyChangedHandler
    private let onError: ErrorHandler?
    private let lock = NSLock()
    private let distributionQueue = MatrixRTCAsyncSerialExecutor()

    private var memberships: [MatrixRTCCallMembership]
    private var inboundKeys: [MatrixRTCMediaKeyMapKey: [MatrixRTCMediaKey]] = [:]
    private var pendingInboundKeys: [MatrixRTCReceivedCallEncryptionKey] = []
    private var inboundKeyTimestamps: [MatrixRTCInboundMediaKeyTimestampKey: Int64] = [:]
    private var outboundSession: MatrixRTCOutboundMediaKeySession?

    public init(
        ownMembership: MatrixRTCCallMembership,
        memberships: [MatrixRTCCallMembership] = [],
        transport: MatrixRTCToDeviceKeyTransport,
        keyGenerator: any MatrixRTCMediaKeyGenerating = MatrixRTCRandomMediaKeyGenerator(),
        rotationConfiguration: MatrixRTCMediaKeyRotationConfiguration = .init(),
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        },
        onKeyChanged: @escaping KeyChangedHandler,
        onError: ErrorHandler? = nil
    ) {
        self.ownMembership = ownMembership
        self.memberships = memberships
        self.transport = transport
        self.keyGenerator = keyGenerator
        self.rotationConfiguration = rotationConfiguration
        self.timestampProvider = timestampProvider
        self.onKeyChanged = onKeyChanged
        self.onError = onError
        self.transport.setReceivedKeyHandler { [weak self] result in
            switch result {
            case .success(let receivedKey):
                self?.handleReceivedKey(receivedKey)
            case .failure(let error):
                self?.onError?(error)
            }
        }
    }

    deinit {
        stop()
    }

    public func start() {
        transport.start()
    }

    public func stop() {
        transport.stop()
    }

    public func updateMemberships(_ memberships: [MatrixRTCCallMembership]) {
        let changedKeys = withLock {
            self.memberships = memberships
            return flushPendingInboundKeysLocked()
        }

        for changedKey in changedKeys {
            onKeyChanged(.init(key: changedKey))
        }
    }

    public func encryptionKeys() -> [MatrixRTCMediaKeyMapKey: [MatrixRTCMediaKey]] {
        withLock {
            inboundKeys
        }
    }

    public func reemitEncryptionKeys() {
        let keys = withLock {
            inboundKeys.values.flatMap { $0 }.sorted { lhs, rhs in
                if lhs.membership.userId != rhs.membership.userId {
                    return lhs.membership.userId < rhs.membership.userId
                }
                if lhs.membership.deviceId != rhs.membership.deviceId {
                    return lhs.membership.deviceId < rhs.membership.deviceId
                }
                if lhs.membership.memberId != rhs.membership.memberId {
                    return lhs.membership.memberId < rhs.membership.memberId
                }
                return lhs.keyIndex < rhs.keyIndex
            }
        }

        for key in keys {
            onKeyChanged(.init(key: key))
        }
    }

    @discardableResult
    public func ensureOutboundSession() -> MatrixRTCMediaKey {
        let result = withLock {
            if let outboundSession {
                return (mediaKey: outboundSession.mediaKey, isNew: false)
            }

            let session = MatrixRTCOutboundMediaKeySession(
                mediaKey: .init(
                    keyBase64Encoded: keyGenerator.generateMediaKeyBase64Encoded(),
                    keyIndex: 0,
                    membership: ownMembership.identity,
                    rtcBackendIdentity: ownMembership.rtcBackendIdentity
                ),
                createdTimestamp: timestampProvider()
            )
            outboundSession = session
            addKeyLocked(session.mediaKey)
            return (mediaKey: session.mediaKey, isNew: true)
        }

        if result.isNew {
            onKeyChanged(.init(key: result.mediaKey))
        }

        return result.mediaKey
    }

    @discardableResult
    public func ensureKeyDistribution(
        with memberships: [MatrixRTCCallMembership]? = nil
    ) async throws -> MatrixRTCMediaKeyShareResult {
        if let memberships {
            updateMemberships(memberships)
        }

        return try await distributionQueue.run { [self] in
            try await self.rolloutOutboundKey()
        }
    }

    @discardableResult
    public func shareCurrentKey(
        with memberships: [MatrixRTCCallMembership]? = nil
    ) async throws -> MatrixRTCMediaKeyShareResult {
        let outboundKey = ensureOutboundSession()
        let targetMemberships = memberships ?? withLock { self.memberships }
        let shareTargets = withLock {
            self.shareTargets(for: targetMemberships)
        }

        guard !shareTargets.isEmpty else {
            return .init(failures: [], sharedWith: [])
        }

        let targets = shareTargets.map(\.target)
        let failures = try await transport.sendKey(
            keyBase64Encoded: outboundKey.keyBase64Encoded,
            index: outboundKey.keyIndex,
            targets: targets
        )

        let successfulShareTargets = Self.successfulShareTargets(shareTargets, excluding: failures)
        if !successfulShareTargets.isEmpty {
            withLock {
                for shareTarget in successfulShareTargets {
                    outboundSession?.sharedWith.insert(shareTarget.participant)
                }
            }
        }

        return .init(
            failures: failures,
            sharedWith: successfulShareTargets.map(\.target)
        )
    }

    @discardableResult
    public func reshareCurrentKey(
        with memberships: [MatrixRTCCallMembership]? = nil
    ) async throws -> MatrixRTCMediaKeyShareResult {
        if let memberships {
            updateMemberships(memberships)
        }

        return try await distributionQueue.run { [self] in
            try await self.forceShareCurrentKey(with: memberships ?? withLock { self.memberships })
        }
    }

    public func handleReceivedKey(_ receivedKey: MatrixRTCReceivedCallEncryptionKey) {
        let changedKey = withLock {
            addOrQueueInboundKeyLocked(receivedKey)
        }

        if let changedKey {
            onKeyChanged(.init(key: changedKey))
        }
    }
}

private extension MatrixRTCMediaKeyManager {
    static let liveKitUnsupportedOutboundKeyIndex = 255

    func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    func rolloutOutboundKey() async throws -> MatrixRTCMediaKeyShareResult {
        _ = ensureOutboundSession()

        guard let rollout = withLock({ makeOutboundRolloutLocked(now: timestampProvider()) }) else {
            return .init(failures: [], sharedWith: [])
        }

        let targets = rollout.shareTargets.map(\.target)
        let failures: [MatrixRTCCustomToDeviceSendFailure]
        if targets.isEmpty {
            failures = []
        } else {
            failures = try await transport.sendKey(
                keyBase64Encoded: rollout.mediaKey.keyBase64Encoded,
                index: rollout.mediaKey.keyIndex,
                targets: targets
            )
        }

        let successfulShareTargets = Self.successfulShareTargets(rollout.shareTargets, excluding: failures)
        if !successfulShareTargets.isEmpty {
            withLock {
                for shareTarget in successfulShareTargets {
                    outboundSession?.sharedWith.insert(shareTarget.participant)
                }
            }
        }

        if rollout.shouldApplyLocallyAfterDelay {
            try await sleepForKeyDelay()
            withLock {
                addKeyLocked(rollout.mediaKey)
            }
            onKeyChanged(.init(key: rollout.mediaKey))
        }

        return .init(
            failures: failures,
            sharedWith: successfulShareTargets.map(\.target)
        )
    }

    func sleepForKeyDelay() async throws {
        guard rotationConfiguration.useKeyDelayMilliseconds > 0 else {
            return
        }

        try await Task.sleep(nanoseconds: rotationConfiguration.useKeyDelayMilliseconds * 1_000_000)
    }

    func forceShareCurrentKey(with memberships: [MatrixRTCCallMembership]) async throws -> MatrixRTCMediaKeyShareResult {
        let outboundKey = ensureOutboundSession()
        let shareTargets = withLock {
            self.allShareTargets(for: memberships)
        }

        guard !shareTargets.isEmpty else {
            return .init(failures: [], sharedWith: [])
        }

        let targets = shareTargets.map(\.target)
        let failures = try await transport.sendKey(
            keyBase64Encoded: outboundKey.keyBase64Encoded,
            index: outboundKey.keyIndex,
            targets: targets
        )

        let successfulShareTargets = Self.successfulShareTargets(shareTargets, excluding: failures)
        if !successfulShareTargets.isEmpty {
            withLock {
                for shareTarget in successfulShareTargets {
                    outboundSession?.sharedWith.insert(shareTarget.participant)
                }
            }
        }

        return .init(
            failures: failures,
            sharedWith: successfulShareTargets.map(\.target)
        )
    }

    static func successfulShareTargets(
        _ shareTargets: [MatrixRTCMediaKeyShareTarget],
        excluding failures: [MatrixRTCCustomToDeviceSendFailure]
    ) -> [MatrixRTCMediaKeyShareTarget] {
        let failedTargets = Set(failures.map { MatrixRTCToDeviceTarget(userId: $0.userId, deviceId: $0.deviceId) })
        return shareTargets.filter { !failedTargets.contains($0.target) }
    }

    func makeOutboundRolloutLocked(now: Int64) -> MatrixRTCOutboundMediaKeyRollout? {
        guard var session = outboundSession else {
            return nil
        }

        let shareTargets = allShareTargets(for: memberships)
        let currentParticipants = Set(shareTargets.map(\.participant))
        let resetSharedWith = session.sharedWith.filter { sharedParticipant in
            !currentParticipants.contains {
                $0.userId == sharedParticipant.userId
                    && $0.deviceId == sharedParticipant.deviceId
                    && $0.createdTimestamp != sharedParticipant.createdTimestamp
            }
        }
        outboundSession?.sharedWith = resetSharedWith
        session.sharedWith = resetSharedWith

        let leftParticipants = resetSharedWith.filter { !currentParticipants.contains($0) }
        let joinedShareTargets = shareTargets.filter { !resetSharedWith.contains($0.participant) }

        if !leftParticipants.isEmpty {
            let newSession = createNewOutboundSessionLocked(now: now)
            return .init(
                mediaKey: newSession.mediaKey,
                shareTargets: shareTargets,
                shouldApplyLocallyAfterDelay: true
            )
        }

        guard !joinedShareTargets.isEmpty else {
            return nil
        }

        let keyAge = now - session.createdTimestamp
        if keyAge < rotationConfiguration.keyRotationGracePeriodMilliseconds {
            return .init(
                mediaKey: session.mediaKey,
                shareTargets: joinedShareTargets,
                shouldApplyLocallyAfterDelay: false
            )
        }

        let newSession = createNewOutboundSessionLocked(now: now)
        return .init(
            mediaKey: newSession.mediaKey,
            shareTargets: shareTargets,
            shouldApplyLocallyAfterDelay: true
        )
    }

    func createNewOutboundSessionLocked(now: Int64) -> MatrixRTCOutboundMediaKeySession {
        let session = MatrixRTCOutboundMediaKeySession(
            mediaKey: .init(
                keyBase64Encoded: keyGenerator.generateMediaKeyBase64Encoded(),
                keyIndex: nextOutboundKeyIndexLocked(),
                membership: ownMembership.identity,
                rtcBackendIdentity: ownMembership.rtcBackendIdentity
            ),
            createdTimestamp: now
        )
        outboundSession = session
        return session
    }

    func nextOutboundKeyIndexLocked() -> Int {
        guard let outboundSession else {
            return 0
        }

        var nextIndex = (outboundSession.mediaKey.keyIndex + 1) % 256
        // LiveKitWebRTC currently crashes on outbound index 255. Keep the MatrixRTC
        // ring compatible by wrapping past it until the native provider is fixed.
        if nextIndex == Self.liveKitUnsupportedOutboundKeyIndex {
            nextIndex = 0
        }
        return nextIndex
    }

    func shareTargets(for memberships: [MatrixRTCCallMembership]) -> [MatrixRTCMediaKeyShareTarget] {
        allShareTargets(for: memberships).filter { shareTarget in
            outboundSession?.sharedWith.contains(shareTarget.participant) != true
        }
    }

    func allShareTargets(for memberships: [MatrixRTCCallMembership]) -> [MatrixRTCMediaKeyShareTarget] {
        var seen = Set<MatrixRTCToDeviceTarget>()
        return memberships.compactMap { membership in
            guard membership.userId != ownMembership.userId || membership.deviceId != ownMembership.deviceId else {
                return nil
            }

            let participant = MatrixRTCParticipantDevice(
                userId: membership.userId,
                deviceId: membership.deviceId,
                createdTimestamp: membership.createdTimestamp
            )

            let target = membership.toDeviceTarget
            guard seen.insert(target).inserted else {
                return nil
            }

            return .init(participant: participant, target: target)
        }
    }

    func mediaKey(from receivedKey: MatrixRTCReceivedCallEncryptionKey) -> MatrixRTCMediaKey? {
        guard let membership = memberships.first(where: {
            $0.userId == receivedKey.membership.userId
                && $0.deviceId == receivedKey.membership.deviceId
        }) else {
            return .init(
                keyBase64Encoded: receivedKey.keyBase64Encoded,
                keyIndex: receivedKey.keyIndex,
                membership: receivedKey.membership,
                rtcBackendIdentity: ""
            )
        }

        return .init(
            keyBase64Encoded: receivedKey.keyBase64Encoded,
            keyIndex: receivedKey.keyIndex,
            membership: membership.identity,
            rtcBackendIdentity: membership.rtcBackendIdentity
        )
    }

    func addOrQueueInboundKeyLocked(_ receivedKey: MatrixRTCReceivedCallEncryptionKey) -> MatrixRTCMediaKey? {
        guard let mediaKey = mediaKey(from: receivedKey) else {
            return nil
        }

        guard !mediaKey.rtcBackendIdentity.isEmpty else {
            pendingInboundKeys.append(receivedKey)
            return nil
        }

        guard !isOutdatedInboundKeyLocked(mediaKey: mediaKey, sentTimestamp: receivedKey.sentTimestamp) else {
            return nil
        }

        addKeyLocked(mediaKey)
        return mediaKey
    }

    func flushPendingInboundKeysLocked() -> [MatrixRTCMediaKey] {
        guard !pendingInboundKeys.isEmpty else {
            return []
        }

        let pendingKeys = pendingInboundKeys
        pendingInboundKeys = []
        var changedKeys: [MatrixRTCMediaKey] = []

        for receivedKey in pendingKeys {
            if let changedKey = addOrQueueInboundKeyLocked(receivedKey) {
                changedKeys.append(changedKey)
            }
        }

        return changedKeys
    }

    func isOutdatedInboundKeyLocked(mediaKey: MatrixRTCMediaKey, sentTimestamp: Int64?) -> Bool {
        guard let sentTimestamp else {
            return false
        }

        let timestampKey = MatrixRTCInboundMediaKeyTimestampKey(
            mapKey: .init(membership: mediaKey.membership),
            keyIndex: mediaKey.keyIndex
        )
        if let latestTimestamp = inboundKeyTimestamps[timestampKey], latestTimestamp > sentTimestamp {
            return true
        }

        inboundKeyTimestamps[timestampKey] = sentTimestamp
        return false
    }

    func addKeyLocked(_ mediaKey: MatrixRTCMediaKey) {
        let mapKey = MatrixRTCMediaKeyMapKey(membership: mediaKey.membership)
        var keys = inboundKeys[mapKey] ?? []
        keys.removeAll { $0.keyIndex == mediaKey.keyIndex }
        keys.append(mediaKey)
        inboundKeys[mapKey] = keys.sorted { $0.keyIndex < $1.keyIndex }
    }
}

private struct MatrixRTCOutboundMediaKeySession: Sendable {
    let mediaKey: MatrixRTCMediaKey
    let createdTimestamp: Int64
    var sharedWith: Set<MatrixRTCParticipantDevice> = []
}

private struct MatrixRTCOutboundMediaKeyRollout: Sendable {
    let mediaKey: MatrixRTCMediaKey
    let shareTargets: [MatrixRTCMediaKeyShareTarget]
    let shouldApplyLocallyAfterDelay: Bool
}

private struct MatrixRTCParticipantDevice: Hashable, Sendable {
    let userId: String
    let deviceId: String
    let createdTimestamp: Int64
}

private struct MatrixRTCInboundMediaKeyTimestampKey: Hashable, Sendable {
    let mapKey: MatrixRTCMediaKeyMapKey
    let keyIndex: Int
}

private struct MatrixRTCMediaKeyShareTarget: Sendable {
    let participant: MatrixRTCParticipantDevice
    let target: MatrixRTCToDeviceTarget
}

private actor MatrixRTCAsyncSerialExecutor {
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
