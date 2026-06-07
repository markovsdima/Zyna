import Foundation

public struct MatrixRTCReceivedCallEncryptionKey: Equatable, Sendable {
    public let sender: String
    public let membership: MatrixRTCMembershipIdentity
    public let keyBase64Encoded: String
    public let keyIndex: Int
    public let sentTimestamp: Int64?
    public let encryptionInfo: MatrixRTCCustomToDeviceEncryptionInfo?

    public init(
        sender: String,
        membership: MatrixRTCMembershipIdentity,
        keyBase64Encoded: String,
        keyIndex: Int,
        sentTimestamp: Int64?,
        encryptionInfo: MatrixRTCCustomToDeviceEncryptionInfo?
    ) {
        self.sender = sender
        self.membership = membership
        self.keyBase64Encoded = keyBase64Encoded
        self.keyIndex = keyIndex
        self.sentTimestamp = sentTimestamp
        self.encryptionInfo = encryptionInfo
    }
}

public enum MatrixRTCToDeviceKeyTransportError: Error, Equatable {
    case missingEncryptionInfo
    case missingSender
}

public final class MatrixRTCToDeviceKeyTransport {
    public typealias ReceivedKeyHandler = @Sendable (Result<MatrixRTCReceivedCallEncryptionKey, Error>) -> Void

    private let roomId: String
    private let ownIdentity: MatrixRTCMembershipIdentity
    private let client: any MatrixRTCCustomToDeviceEncrypting
    private let sentTimestampProvider: @Sendable () -> Int64
    private var onReceivedKey: ReceivedKeyHandler
    private var listenerToken: (any MatrixRTCCancellable)?

    public init(
        roomId: String,
        ownIdentity: MatrixRTCMembershipIdentity,
        client: any MatrixRTCCustomToDeviceEncrypting,
        sentTimestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        },
        onReceivedKey: @escaping ReceivedKeyHandler = { _ in }
    ) {
        self.roomId = roomId
        self.ownIdentity = ownIdentity
        self.client = client
        self.sentTimestampProvider = sentTimestampProvider
        self.onReceivedKey = onReceivedKey
    }

    deinit {
        stop()
    }

    public func setReceivedKeyHandler(_ onReceivedKey: @escaping ReceivedKeyHandler) {
        self.onReceivedKey = onReceivedKey
    }

    public func start() {
        stop()

        let handler = MatrixRTCToDeviceKeyEventHandler(roomId: roomId, onReceivedKey: onReceivedKey)
        listenerToken = client.addCustomToDeviceEventListener(
            eventType: MatrixRTCCallEncryptionKeysContent.eventType,
            encryptedOnly: true
        ) { event in
            handler.handle(event: event)
        }
    }

    public func stop() {
        listenerToken?.cancel()
        listenerToken = nil
    }

    public func sendKey(
        keyBase64Encoded: String,
        index: Int,
        targets: [MatrixRTCToDeviceTarget]
    ) async throws -> [MatrixRTCCustomToDeviceSendFailure] {
        let content = MatrixRTCCallEncryptionKeysContent(
            keys: .init(index: index, key: keyBase64Encoded),
            member: .init(id: ownIdentity.memberId, claimedDeviceId: ownIdentity.deviceId),
            roomId: roomId,
            sentTimestamp: sentTimestampProvider()
        )

        return try await client.encryptAndSendRawToDevice(
            eventType: MatrixRTCCallEncryptionKeysContent.eventType,
            targets: targets,
            contentJSON: content.jsonString()
        )
    }
}

private struct MatrixRTCToDeviceKeyEventHandler: Sendable {
    let roomId: String
    let onReceivedKey: MatrixRTCToDeviceKeyTransport.ReceivedKeyHandler

    func handle(event: MatrixRTCCustomToDeviceEvent) {
        do {
            guard event.eventType == MatrixRTCCallEncryptionKeysContent.eventType else {
                return
            }

            let content = try MatrixRTCCallEncryptionKeysContent(contentJSON: event.contentJSON)
            guard content.roomId == roomId else {
                return
            }

            guard let encryptionInfo = event.encryptionInfo else {
                throw MatrixRTCToDeviceKeyTransportError.missingEncryptionInfo
            }

            let sender = encryptionInfo.sender
            guard !sender.isEmpty else {
                throw MatrixRTCToDeviceKeyTransportError.missingSender
            }

            let memberId = content.member.id ?? "\(sender):\(content.member.claimedDeviceId)"
            let membership = MatrixRTCMembershipIdentity(
                userId: sender,
                deviceId: content.member.claimedDeviceId,
                memberId: memberId
            )

            onReceivedKey(.success(.init(
                sender: sender,
                membership: membership,
                keyBase64Encoded: content.keys.key,
                keyIndex: content.keys.index,
                sentTimestamp: content.sentTimestamp,
                encryptionInfo: encryptionInfo
            )))
        } catch {
            onReceivedKey(.failure(error))
        }
    }
}
