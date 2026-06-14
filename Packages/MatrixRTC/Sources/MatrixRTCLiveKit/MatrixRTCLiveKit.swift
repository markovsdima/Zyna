import Foundation
import LiveKit
import MatrixRTC

public struct MatrixRTCLiveKitMediaKey: Equatable, Sendable {
    public let rawKey: Data
    public let participantId: String
    public let keyIndex: Int32
    public let membership: MatrixRTCMembershipIdentity

    public init(
        rawKey: Data,
        participantId: String,
        keyIndex: Int32,
        membership: MatrixRTCMembershipIdentity
    ) {
        self.rawKey = rawKey
        self.participantId = participantId
        self.keyIndex = keyIndex
        self.membership = membership
    }
}

public enum MatrixRTCLiveKitKeyProviderError: Error, Equatable {
    case invalidBase64Key
    case invalidKeyByteCount(Int)
    case invalidKeyIndex(Int)
    case missingParticipantId
    case unsupportedNativeKeyIndex(Int)
}

// MatrixRTC media keys are raw 16-byte keys. Passing their base64 text to
// BaseKeyProvider.setKey(key:) would use UTF-8 bytes and is not Element Call compatible.
public struct MatrixRTCLiveKitKeyProviderConfiguration: Equatable, Sendable {
    public static let elementCallCompatible = Self()

    public let ratchetWindowSize: Int32
    public let keyRingSize: Int32
    public let keyByteCount: Int
    public let encryptionType: EncryptionType
    public let keyDerivationAlgorithm: KeyDerivationAlgorithm

    public init(
        ratchetWindowSize: Int32 = 10,
        keyRingSize: Int32 = 256,
        keyByteCount: Int = 16,
        encryptionType: EncryptionType = .gcm,
        keyDerivationAlgorithm: KeyDerivationAlgorithm = .hkdf
    ) {
        self.ratchetWindowSize = ratchetWindowSize
        self.keyRingSize = keyRingSize
        self.keyByteCount = keyByteCount
        self.encryptionType = encryptionType
        self.keyDerivationAlgorithm = keyDerivationAlgorithm
    }

    public func liveKitKeyProviderOptions() -> KeyProviderOptions {
        KeyProviderOptions(
            sharedKey: false,
            ratchetWindowSize: ratchetWindowSize,
            keyRingSize: keyRingSize,
            keyDerivationAlgorithm: keyDerivationAlgorithm
        )
    }

    public func liveKitBaseKeyProvider() -> BaseKeyProvider {
        BaseKeyProvider(options: liveKitKeyProviderOptions())
    }

    public func liveKitEncryptionOptions(keyProvider: BaseKeyProvider) -> EncryptionOptions {
        EncryptionOptions(keyProvider: keyProvider, encryptionType: encryptionType)
    }
}

public final class MatrixRTCLiveKitKeyProvider: @unchecked Sendable {
    public typealias ErrorHandler = @Sendable (Error) -> Void

    public let configuration: MatrixRTCLiveKitKeyProviderConfiguration
    public let baseKeyProvider: BaseKeyProvider

    // MatrixRTC key IDs are one-byte values, so 255 is valid on the wire.
    // LiveKitWebRTC currently aborts when setting keyRingSize 256 at index 255.
    private static let unsupportedLiveKitWebRTCKeyIndex: Int32 = 255

    public init(
        configuration: MatrixRTCLiveKitKeyProviderConfiguration = .elementCallCompatible,
        baseKeyProvider: BaseKeyProvider? = nil
    ) {
        self.configuration = configuration
        self.baseKeyProvider = baseKeyProvider ?? configuration.liveKitBaseKeyProvider()
    }

    public func liveKitEncryptionOptions() -> EncryptionOptions {
        configuration.liveKitEncryptionOptions(keyProvider: baseKeyProvider)
    }

    @discardableResult
    public func apply(_ event: MatrixRTCMediaKeyChangedEvent) throws -> MatrixRTCLiveKitMediaKey {
        try apply(event.key)
    }

    @discardableResult
    public func apply(_ mediaKey: MatrixRTCMediaKey) throws -> MatrixRTCLiveKitMediaKey {
        let liveKitKey = try liveKitMediaKey(from: mediaKey)
        baseKeyProvider.setKey(
            data: liveKitKey.rawKey,
            participantId: liveKitKey.participantId,
            index: liveKitKey.keyIndex
        )
        return liveKitKey
    }

    public func keyChangedHandler(onError: ErrorHandler? = nil) -> MatrixRTCMediaKeyManager.KeyChangedHandler {
        { [weak self] event in
            do {
                try self?.apply(event)
            } catch {
                onError?(error)
            }
        }
    }
}

private extension MatrixRTCLiveKitKeyProvider {
    func liveKitMediaKey(from mediaKey: MatrixRTCMediaKey) throws -> MatrixRTCLiveKitMediaKey {
        guard !mediaKey.rtcBackendIdentity.isEmpty else {
            throw MatrixRTCLiveKitKeyProviderError.missingParticipantId
        }
        guard let keyIndex = Int32(exactly: mediaKey.keyIndex),
              (0..<configuration.keyRingSize).contains(keyIndex) else {
            throw MatrixRTCLiveKitKeyProviderError.invalidKeyIndex(mediaKey.keyIndex)
        }
        guard keyIndex != Self.unsupportedLiveKitWebRTCKeyIndex else {
            throw MatrixRTCLiveKitKeyProviderError.unsupportedNativeKeyIndex(mediaKey.keyIndex)
        }

        let rawKey = try Self.rawKey(fromBase64: mediaKey.keyBase64Encoded)
        guard rawKey.count == configuration.keyByteCount else {
            throw MatrixRTCLiveKitKeyProviderError.invalidKeyByteCount(rawKey.count)
        }

        return .init(
            rawKey: rawKey,
            participantId: mediaKey.rtcBackendIdentity,
            keyIndex: keyIndex,
            membership: mediaKey.membership
        )
    }

    static func rawKey(fromBase64 value: String) throws -> Data {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: normalized), !data.isEmpty else {
            throw MatrixRTCLiveKitKeyProviderError.invalidBase64Key
        }
        return data
    }
}
