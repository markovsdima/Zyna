import Foundation
import LiveKit
import MatrixRTC
import MatrixRTCLiveKit
import Testing

@Test func buildsElementCallCompatibleLiveKitOptions() {
    let configuration = MatrixRTCLiveKitKeyProviderConfiguration.elementCallCompatible
    let options = configuration.liveKitKeyProviderOptions()
    let keyProvider = configuration.liveKitBaseKeyProvider()
    let encryptionOptions = configuration.liveKitEncryptionOptions(keyProvider: keyProvider)

    #expect(options.sharedKey == false)
    #expect(options.ratchetWindowSize == 10)
    #expect(options.keyRingSize == 256)
    #expect(options.keyDerivationAlgorithm == .hkdf)
    #expect(keyProvider.options.keyDerivationAlgorithm == .hkdf)
    #expect(encryptionOptions.keyProvider == keyProvider)
    #expect(encryptionOptions.encryptionType == .gcm)
}

@Test func appliesMatrixRTCKeyAsRawLiveKitKey() throws {
    let provider = MatrixRTCLiveKitKeyProvider()
    let rawKey = Data((0..<16).map(UInt8.init))
    let mediaKey = MatrixRTCMediaKey(
        keyBase64Encoded: rawKey.base64EncodedString(),
        keyIndex: 7,
        membership: .init(
            userId: "@alice:example.org",
            deviceId: "ALICEDEVICE",
            memberId: "@alice:example.org:ALICEDEVICE"
        ),
        rtcBackendIdentity: "@alice:example.org:ALICEDEVICE"
    )

    let liveKitKey = try provider.apply(.init(key: mediaKey))

    #expect(liveKitKey.rawKey == rawKey)
    #expect(liveKitKey.keyIndex == 7)
    #expect(liveKitKey.participantId == "@alice:example.org:ALICEDEVICE")

    let exportedKey = try #require(provider.baseKeyProvider.exportKey(
        participantId: "@alice:example.org:ALICEDEVICE",
        index: 7
    ))
    #expect(exportedKey == rawKey)
    #expect(provider.baseKeyProvider.getCurrentKeyIndex() == 7)
}

@Test func acceptsUnpaddedURLSafeBase64MediaKey() throws {
    let provider = MatrixRTCLiveKitKeyProvider()
    let rawKey = Data([
        0xfb, 0xff, 0xee, 0x00,
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
    ])
    let unpaddedURLSafeKey = rawKey
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    let liveKitKey = try provider.apply(mediaKey(keyBase64Encoded: unpaddedURLSafeKey))

    #expect(liveKitKey.rawKey == rawKey)
    let exportedKey = try #require(provider.baseKeyProvider.exportKey(
        participantId: liveKitKey.participantId,
        index: liveKitKey.keyIndex
    ))
    #expect(exportedKey == rawKey)
}

@Test func rejectsInvalidMediaKeys() throws {
    let provider = MatrixRTCLiveKitKeyProvider()

    #expect(throws: MatrixRTCLiveKitKeyProviderError.invalidBase64Key) {
        try provider.apply(mediaKey(keyBase64Encoded: "!!!"))
    }

    #expect(throws: MatrixRTCLiveKitKeyProviderError.invalidKeyByteCount(15)) {
        try provider.apply(mediaKey(keyBase64Encoded: Data(repeating: 1, count: 15).base64EncodedString()))
    }

    #expect(throws: MatrixRTCLiveKitKeyProviderError.invalidKeyIndex(256)) {
        try provider.apply(mediaKey(
            keyBase64Encoded: Data(repeating: 1, count: 16).base64EncodedString(),
            keyIndex: 256
        ))
    }

    #expect(throws: MatrixRTCLiveKitKeyProviderError.unsupportedNativeKeyIndex(255)) {
        try provider.apply(mediaKey(
            keyBase64Encoded: Data(repeating: 1, count: 16).base64EncodedString(),
            keyIndex: 255
        ))
    }

    #expect(throws: MatrixRTCLiveKitKeyProviderError.missingParticipantId) {
        try provider.apply(mediaKey(
            keyBase64Encoded: Data(repeating: 1, count: 16).base64EncodedString(),
            rtcBackendIdentity: ""
        ))
    }
}

@Test func keyChangedHandlerReportsErrors() {
    let errorBox = LiveKitErrorBox()
    let provider = MatrixRTCLiveKitKeyProvider()
    let handler = provider.keyChangedHandler { error in
        errorBox.errors.append(error)
    }

    handler(.init(key: mediaKey(keyBase64Encoded: "!!!")))

    #expect(errorBox.errors.count == 1)
    #expect(errorBox.errors.first as? MatrixRTCLiveKitKeyProviderError == .invalidBase64Key)
}

private final class LiveKitErrorBox: @unchecked Sendable {
    var errors: [Error] = []
}

private func mediaKey(
    keyBase64Encoded: String,
    keyIndex: Int = 0,
    rtcBackendIdentity: String = "@alice:example.org:ALICEDEVICE"
) -> MatrixRTCMediaKey {
    MatrixRTCMediaKey(
        keyBase64Encoded: keyBase64Encoded,
        keyIndex: keyIndex,
        membership: .init(
            userId: "@alice:example.org",
            deviceId: "ALICEDEVICE",
            memberId: "@alice:example.org:ALICEDEVICE"
        ),
        rtcBackendIdentity: rtcBackendIdentity
    )
}
