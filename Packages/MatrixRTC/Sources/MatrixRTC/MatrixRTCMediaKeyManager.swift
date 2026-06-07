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
    private let onKeyChanged: KeyChangedHandler
    private let onError: ErrorHandler?
    private let lock = NSLock()

    private var memberships: [MatrixRTCCallMembership]
    private var inboundKeys: [MatrixRTCMediaKeyMapKey: [MatrixRTCMediaKey]] = [:]
    private var pendingInboundKeys: [MatrixRTCMediaKey] = []
    private var outboundSession: MatrixRTCOutboundMediaKeySession?

    public init(
        ownMembership: MatrixRTCCallMembership,
        memberships: [MatrixRTCCallMembership] = [],
        transport: MatrixRTCToDeviceKeyTransport,
        keyGenerator: any MatrixRTCMediaKeyGenerating = MatrixRTCRandomMediaKeyGenerator(),
        onKeyChanged: @escaping KeyChangedHandler,
        onError: ErrorHandler? = nil
    ) {
        self.ownMembership = ownMembership
        self.memberships = memberships
        self.transport = transport
        self.keyGenerator = keyGenerator
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
                )
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

        let failures = try await transport.sendKey(
            keyBase64Encoded: outboundKey.keyBase64Encoded,
            index: outboundKey.keyIndex,
            targets: shareTargets.map(\.target)
        )

        if failures.isEmpty {
            withLock {
                for shareTarget in shareTargets {
                    outboundSession?.sharedWith.insert(shareTarget.participant)
                }
            }
        }

        return .init(
            failures: failures,
            sharedWith: shareTargets.map(\.target)
        )
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
    func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    func shareTargets(for memberships: [MatrixRTCCallMembership]) -> [MatrixRTCMediaKeyShareTarget] {
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
            guard outboundSession?.sharedWith.contains(participant) != true else {
                return nil
            }

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
                && $0.memberId == receivedKey.membership.memberId
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
            pendingInboundKeys.append(mediaKey)
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

        for pendingKey in pendingKeys {
            let receivedKey = MatrixRTCReceivedCallEncryptionKey(
                sender: pendingKey.membership.userId,
                membership: pendingKey.membership,
                keyBase64Encoded: pendingKey.keyBase64Encoded,
                keyIndex: pendingKey.keyIndex,
                sentTimestamp: nil,
                encryptionInfo: nil
            )
            if let changedKey = addOrQueueInboundKeyLocked(receivedKey) {
                changedKeys.append(changedKey)
            }
        }

        return changedKeys
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
    var sharedWith: Set<MatrixRTCParticipantDevice> = []
}

private struct MatrixRTCParticipantDevice: Hashable, Sendable {
    let userId: String
    let deviceId: String
    let createdTimestamp: Int64
}

private struct MatrixRTCMediaKeyShareTarget: Sendable {
    let participant: MatrixRTCParticipantDevice
    let target: MatrixRTCToDeviceTarget
}
