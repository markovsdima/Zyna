public struct MatrixRTCToDeviceTarget: Equatable, Hashable, Sendable {
    public let userId: String
    public let deviceId: String

    public init(userId: String, deviceId: String) {
        self.userId = userId
        self.deviceId = deviceId
    }
}

public enum MatrixRTCCustomToDeviceSendFailureReason: Equatable, Sendable {
    case missingDevice
    case withheld
    case sendFailed
}

public struct MatrixRTCCustomToDeviceSendFailure: Equatable, Sendable {
    public let userId: String
    public let deviceId: String
    public let reason: MatrixRTCCustomToDeviceSendFailureReason

    public init(userId: String, deviceId: String, reason: MatrixRTCCustomToDeviceSendFailureReason) {
        self.userId = userId
        self.deviceId = deviceId
        self.reason = reason
    }
}

public struct MatrixRTCCustomToDeviceEncryptionInfo: Equatable, Sendable {
    public let sender: String
    public let senderDevice: String?
    public let senderCurve25519KeyBase64: String?
    public let senderVerified: Bool

    public init(
        sender: String,
        senderDevice: String?,
        senderCurve25519KeyBase64: String?,
        senderVerified: Bool
    ) {
        self.sender = sender
        self.senderDevice = senderDevice
        self.senderCurve25519KeyBase64 = senderCurve25519KeyBase64
        self.senderVerified = senderVerified
    }
}

public struct MatrixRTCCustomToDeviceEvent: Equatable, Sendable {
    public let eventType: String
    public let sender: String
    public let contentJSON: String
    public let rawJSON: String
    public let encryptionInfo: MatrixRTCCustomToDeviceEncryptionInfo?

    public init(
        eventType: String,
        sender: String,
        contentJSON: String,
        rawJSON: String,
        encryptionInfo: MatrixRTCCustomToDeviceEncryptionInfo?
    ) {
        self.eventType = eventType
        self.sender = sender
        self.contentJSON = contentJSON
        self.rawJSON = rawJSON
        self.encryptionInfo = encryptionInfo
    }
}

public protocol MatrixRTCCustomToDeviceEncrypting: Sendable {
    func encryptAndSendRawToDevice(
        eventType: String,
        targets: [MatrixRTCToDeviceTarget],
        contentJSON: String
    ) async throws -> [MatrixRTCCustomToDeviceSendFailure]

    func addCustomToDeviceEventListener(
        eventType: String,
        encryptedOnly: Bool,
        listener: @escaping @Sendable (MatrixRTCCustomToDeviceEvent) -> Void
    ) -> any MatrixRTCCancellable
}
