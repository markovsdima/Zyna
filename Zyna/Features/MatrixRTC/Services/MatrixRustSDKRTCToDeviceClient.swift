//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRTC
import MatrixRustSDK

final class MatrixRustSDKRTCToDeviceClient: MatrixRTCCustomToDeviceEncrypting, @unchecked Sendable {
    private let client: Client
    private let encryption: Encryption

    init(client: Client) {
        self.client = client
        self.encryption = client.encryption()
    }

    func encryptAndSendRawToDevice(
        eventType: String,
        targets: [MatrixRTCToDeviceTarget],
        contentJSON: String
    ) async throws -> [MatrixRTCCustomToDeviceSendFailure] {
        let rustTargets = targets.map {
            ToDeviceTarget(userId: $0.userId, deviceId: $0.deviceId)
        }

        let failures = try await encryption.encryptAndSendRawToDevice(
            eventType: eventType,
            targets: rustTargets,
            contentJson: contentJSON
        )

        return failures.map(MatrixRTCCustomToDeviceSendFailure.init(rustFailure:))
    }

    func addCustomToDeviceEventListener(
        eventType: String,
        encryptedOnly: Bool,
        listener: @escaping @Sendable (MatrixRTCCustomToDeviceEvent) -> Void
    ) -> any MatrixRTCCancellable {
        let rustListener = MatrixRustSDKCustomToDeviceEventListener(listener: listener)
        let handle = client.addCustomToDeviceEventListener(
            eventType: eventType,
            encryptedOnly: encryptedOnly,
            listener: rustListener
        )

        return MatrixRustSDKCustomToDeviceListenerToken(handle: handle, listener: rustListener)
    }
}

private final class MatrixRustSDKCustomToDeviceEventListener: CustomToDeviceEventListener, @unchecked Sendable {
    private let listener: @Sendable (MatrixRTCCustomToDeviceEvent) -> Void

    init(listener: @escaping @Sendable (MatrixRTCCustomToDeviceEvent) -> Void) {
        self.listener = listener
    }

    func onEvent(event: CustomToDeviceEvent) {
        listener(MatrixRTCCustomToDeviceEvent(rustEvent: event))
    }
}

private final class MatrixRustSDKCustomToDeviceListenerToken: MatrixRTCCancellable, @unchecked Sendable {
    private let handle: TaskHandle
    private let listener: MatrixRustSDKCustomToDeviceEventListener

    init(handle: TaskHandle, listener: MatrixRustSDKCustomToDeviceEventListener) {
        self.handle = handle
        self.listener = listener
    }

    func cancel() {
        handle.cancel()
    }
}

private extension MatrixRTCCustomToDeviceSendFailure {
    init(rustFailure: CustomToDeviceEventSendFailure) {
        self.init(
            userId: rustFailure.userId,
            deviceId: rustFailure.deviceId,
            reason: .init(rustReason: rustFailure.reason)
        )
    }
}

private extension MatrixRTCCustomToDeviceSendFailureReason {
    init(rustReason: CustomToDeviceEventSendFailureReason) {
        switch rustReason {
        case .missingDevice:
            self = .missingDevice
        case .withheld:
            self = .withheld
        case .sendFailed:
            self = .sendFailed
        }
    }
}

private extension MatrixRTCCustomToDeviceEvent {
    init(rustEvent: CustomToDeviceEvent) {
        self.init(
            eventType: rustEvent.eventType,
            sender: rustEvent.sender,
            contentJSON: rustEvent.contentJson,
            rawJSON: rustEvent.rawJson,
            encryptionInfo: rustEvent.encryptionInfo.map(MatrixRTCCustomToDeviceEncryptionInfo.init(rustInfo:))
        )
    }
}

private extension MatrixRTCCustomToDeviceEncryptionInfo {
    init(rustInfo: CustomToDeviceEventEncryptionInfo) {
        self.init(
            sender: rustInfo.sender,
            senderDevice: rustInfo.senderDevice,
            senderCurve25519KeyBase64: rustInfo.senderCurve25519KeyBase64,
            senderVerified: rustInfo.senderVerified
        )
    }
}
