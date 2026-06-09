//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import CallKit
import MatrixRustSDK
import os.log
@preconcurrency import KeychainAccess

struct NSEPushPayload: Sendable {
    let roomId: String?
    let eventId: String?
    let pusherNotificationClientIdentifier: String?

    init(userInfo: [AnyHashable: Any]) {
        roomId = userInfo["room_id"] as? String
        eventId = userInfo["event_id"] as? String
        pusherNotificationClientIdentifier = userInfo["pusher_notification_client_identifier"] as? String
    }
}

struct NSEPreparedNotification: Sendable {
    let title: String
    let subtitle: String?
    let body: String
    let isNoisy: Bool
}

private enum NSESecurityConfig {
    static let appGroupIdentifier = "group.com.app.zyna"
    static let matrixLastUserIdKey = "com.zyna.matrix.lastUserId"
    static let sessionKeychainService = "com.zyna.matrix.session"
    static let passphraseKeychainService = "com.zyna.matrix.crypto"
    static let passphraseKeychainKey = "com.zyna.matrix.storePassphrase"
    static let matrixCryptoStoreDatabaseName = "matrix-sdk-crypto.sqlite3"

    private static let keychainAccessGroupInfoPlistKey = "ZynaKeychainAccessGroup"
    private static let fallbackKeychainAccessGroup = "UM3QPHF8E3.com.app.zyna.shared"

    static let keychainAccessGroup: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: keychainAccessGroupInfoPlistKey) as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return fallbackKeychainAccessGroup
        }
        return value
    }()

    static func sharedKeychain(service: String) -> Keychain {
        Keychain(service: service, accessGroup: keychainAccessGroup)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }
}

enum NSEProcessedNotification: Sendable {
    case display(NSEPreparedNotification)
    case discard
}

/// Builds the minimal Matrix runtime inside the Notification Service Extension
/// so a push payload can be resolved into locally decrypted notification text.
final class NSEMatrixBootstrap {
    private struct SessionData: Codable {
        let accessToken: String
        let refreshToken: String?
        let userId: String
        let deviceId: String
        let homeserverUrl: String
        let oauthData: String?
    }

    private struct Context {
        let userId: String
        let session: MatrixRustSDK.Session
        let passphrase: String
        let dataPath: String
        let cachePath: String
    }

    private enum BootstrapError: Error, CustomStringConvertible {
        case appGroupUnavailable
        case matrixStoreUnavailable(dataHasContents: Bool, cacheHasContents: Bool, cryptoStoreExists: Bool)
        case userIdUnavailable
        case sessionUnavailable(String)
        case passphraseUnavailable

        var description: String {
            switch self {
            case .appGroupUnavailable:
                return "App Group container is unavailable"
            case .matrixStoreUnavailable(let dataHasContents, let cacheHasContents, let cryptoStoreExists):
                return "Matrix store is unavailable data=\(dataHasContents) cache=\(cacheHasContents) crypto=\(cryptoStoreExists)"
            case .userIdUnavailable:
                return "Last Matrix userId is unavailable"
            case .sessionUnavailable(let userId):
                return "Shared Matrix session is unavailable for \(userId)"
            case .passphraseUnavailable:
                return "Shared Matrix store passphrase is unavailable"
            }
        }
    }

    private static let callNotificationDiscardDelta: TimeInterval = 15

    private let decoder = JSONDecoder()

    func run(payload: NSEPushPayload) async -> NSEProcessedNotification? {
        log(
            "start roomId=\(payload.roomId ?? "nil") eventId=\(payload.eventId ?? "nil") clientId=\(payload.pusherNotificationClientIdentifier ?? "nil")"
        )

        guard let roomId = payload.roomId, let eventId = payload.eventId else {
            log("missing roomId or eventId in payload; nothing to decrypt")
            return nil
        }

        do {
            let context = try loadContext()
            log("shared state ready userId=\(context.userId)")

            let client = try await buildClient(context: context)
            try await client.restoreSessionWith(
                session: context.session,
                roomLoadSettings: .one(roomId: roomId)
            )
            let notificationClient = try await client.notificationClient(processSetup: .multipleProcesses)

            let status = try await notificationClient.getNotification(roomId: roomId, eventId: eventId)
            switch status {
            case .event(let item):
                let result = await makeProcessedNotification(
                    from: item,
                    roomID: roomId,
                    eventID: eventId,
                    client: client
                )
                switch result {
                case .display(let prepared):
                    log("notification ready title=\(prepared.title.isEmpty ? "nil" : "set") body=\(prepared.body.isEmpty ? "nil" : "set")")
                case .discard:
                    log("notification processed and discarded")
                case nil:
                    log("notification produced no display content")
                }
                return result
            case .eventNotFound:
                log("notification event not found")
                return nil
            case .eventFilteredOut:
                log("notification event filtered out by push rules")
                return nil
            case .eventRedacted:
                log("notification event was redacted")
                return nil
            }
        } catch {
            log("notification fetch failed: \(error)")
            return nil
        }
    }

    private func makeProcessedNotification(
        from item: NotificationItem,
        roomID: String,
        eventID: String,
        client: Client
    ) async -> NSEProcessedNotification? {
        let roomDisplayName = item.roomInfo.displayName
        let senderDisplayName = item.senderInfo.displayName ?? roomDisplayName
        let isNoisy = item.isNoisy ?? false

        switch item.event {
        case .invite:
            let body: String
            if item.roomInfo.isDm {
                body = "Invited you to chat"
            } else if item.roomInfo.isSpace {
                body = "Invited you to a space"
            } else {
                body = "Invited you to a room"
            }
            return .display(
                NSEPreparedNotification(
                    title: senderDisplayName,
                    subtitle: nil,
                    body: body,
                    isNoisy: isNoisy
                )
            )
        case .timeline(let event):
            guard case let .messageLike(messageContent) = (try? event.content()),
                  let result = await processedMessageLikeNotification(
                    messageContent,
                    event: event,
                    roomID: roomID,
                    eventID: eventID,
                    roomDisplayName: roomDisplayName,
                    senderDisplayName: senderDisplayName,
                    isNoisy: isNoisy,
                    client: client
                  ) else {
                return nil
            }
            return result
        }
    }

    private func processedMessageLikeNotification(
        _ content: MessageLikeEventContent,
        event: TimelineEvent,
        roomID: String,
        eventID: String,
        roomDisplayName: String,
        senderDisplayName: String,
        isNoisy: Bool,
        client: Client
    ) async -> NSEProcessedNotification? {
        if case let .rtcNotification(notificationType, expirationTimestamp, callIntent) = content,
           await handleCallNotification(
            notificationType: notificationType,
            rtcNotifyEventID: eventID,
            timestamp: event.timestamp(),
            expirationTimestamp: expirationTimestamp,
            roomID: roomID,
            roomDisplayName: roomDisplayName,
            callIntent: callIntent,
            client: client
           ) {
            return .discard
        }

        guard let body = Self.bodyForMessageContent(content, senderDisplayName: senderDisplayName) else {
            return nil
        }

        let subtitle: String? = senderDisplayName == roomDisplayName ? nil : roomDisplayName
        return .display(
            NSEPreparedNotification(
                title: senderDisplayName,
                subtitle: subtitle,
                body: body,
                isNoisy: isNoisy
            )
        )
    }

    private func handleCallNotification(
        notificationType: RtcNotificationType,
        rtcNotifyEventID: String,
        timestamp: Timestamp,
        expirationTimestamp: Timestamp,
        roomID: String,
        roomDisplayName: String,
        callIntent: RtcCallIntent?,
        client: Client
    ) async -> Bool {
        guard notificationType == .ring else {
            log("non-ringing call notification; keeping regular notification")
            return false
        }

        let eventDate = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        guard abs(eventDate.timeIntervalSinceNow) < Self.callNotificationDiscardDelta else {
            log("call notification is too old; keeping regular notification")
            return false
        }

        let expirationDate = Date(timeIntervalSince1970: TimeInterval(expirationTimestamp) / 1000)
        guard expirationDate > Date() else {
            log("call notification is expired; keeping regular notification")
            return false
        }

        if let room = try? client.getRoom(roomId: roomID), !room.hasActiveRoomCall() {
            log("room has no active call yet; waiting for room call state")
            guard await waitForActiveRoomCall(in: room, timeout: 5) else {
                log("room still has no active call; keeping regular notification")
                return false
            }
        }

        let payload = [
            "roomID": roomID,
            "roomDisplayName": roomDisplayName,
            "expirationDate": expirationDate,
            "rtcNotifyEventID": rtcNotifyEventID,
            "isVoiceCall": callIntent == .audio
        ] as [String: Any]

        do {
            try await CXProvider.reportNewIncomingVoIPPushPayload(payload)
            log("call notification delegated to CallKit")
            return true
        } catch {
            log("failed delegating call notification to CallKit: \(error)")
            return false
        }
    }

    private static func bodyForMessageContent(_ content: MessageLikeEventContent, senderDisplayName: String) -> String? {
        switch content {
        case .roomMessage(let messageType, _):
            return bodyForMessageType(messageType, senderDisplayName: senderDisplayName)
        case .poll(let question):
            return "Poll: \(question)"
        case .sticker:
            return "Sticker"
        case .roomEncrypted:
            return "Encrypted message"
        case .rtcNotification, .callInvite:
            return "Incoming call"
        case .callAnswer, .callHangup, .callCandidates,
             .keyVerificationReady, .keyVerificationStart, .keyVerificationCancel,
             .keyVerificationAccept, .keyVerificationKey, .keyVerificationMac,
             .keyVerificationDone, .reactionContent, .roomRedaction:
            return nil
        }
    }

    private func waitForActiveRoomCall(in room: Room, timeout: TimeInterval) async -> Bool {
        await NSEActiveRoomCallWaiter(room: room).wait(timeout: timeout)
    }

    private static func bodyForMessageType(_ messageType: MessageType, senderDisplayName: String) -> String {
        switch messageType {
        case .text(let content):
            return content.body
        case .notice(let content):
            return content.body
        case .emote(let content):
            return "* \(senderDisplayName) \(content.body)"
        case .image(let content):
            return content.caption ?? "Image"
        case .video(let content):
            return content.caption ?? "Video"
        case .audio(let content):
            if content.voice != nil {
                return "Voice message"
            }
            return content.caption ?? "Audio"
        case .file(let content):
            return content.caption ?? "File"
        case .location:
            return "Shared location"
        case .gallery(let content):
            return content.body
        case .other(_, let body):
            return body
        }
    }

    private func loadContext() throws -> Context {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NSESecurityConfig.appGroupIdentifier) else {
            throw BootstrapError.appGroupUnavailable
        }

        let dataDirectory = container
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
        let cacheDirectory = container
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)

        let dataHasContents = directoryHasContents(dataDirectory)
        let cacheHasContents = directoryHasContents(cacheDirectory)
        let cryptoStoreExists = matrixCryptoStoreExists(in: dataDirectory)
        guard dataHasContents, cacheHasContents, cryptoStoreExists else {
            throw BootstrapError.matrixStoreUnavailable(
                dataHasContents: dataHasContents,
                cacheHasContents: cacheHasContents,
                cryptoStoreExists: cryptoStoreExists
            )
        }

        let sessionKeychain = sharedKeychain(service: NSESecurityConfig.sessionKeychainService)
        guard let userId = sharedUserId() ?? sessionKeychain.allKeys().sorted().first else {
            throw BootstrapError.userIdUnavailable
        }

        guard let sessionDataString = try sessionKeychain.get(userId),
              let sessionData = sessionDataString.data(using: .utf8) else {
            throw BootstrapError.sessionUnavailable(userId)
        }

        let decoded = try decoder.decode(SessionData.self, from: sessionData)
        let session = MatrixRustSDK.Session(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            userId: decoded.userId,
            deviceId: decoded.deviceId,
            homeserverUrl: decoded.homeserverUrl,
            oauthData: decoded.oauthData,
            slidingSyncVersion: .native
        )

        let passphraseKeychain = sharedKeychain(service: NSESecurityConfig.passphraseKeychainService)
        guard let passphrase = try passphraseKeychain.get(NSESecurityConfig.passphraseKeychainKey) else {
            throw BootstrapError.passphraseUnavailable
        }

        return Context(
            userId: userId,
            session: session,
            passphrase: passphrase,
            dataPath: dataDirectory.path,
            cachePath: cacheDirectory.path
        )
    }

    private func buildClient(context: Context) async throws -> Client {
        let storeConfig = SqliteStoreBuilder(dataPath: context.dataPath, cachePath: context.cachePath)
            .passphrase(passphrase: context.passphrase)
        let sessionDelegate = NSESessionDelegate()

        return try await ClientBuilder()
            .homeserverUrl(url: context.session.homeserverUrl)
            .sqliteStore(config: storeConfig)
            .systemIsMemoryConstrained()
            .crossProcessLockConfig(
                crossProcessLockConfig: .multiProcess(holderName: Bundle.main.bundleIdentifier ?? "ZynaNotificationService")
            )
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            .userAgent(userAgent: "ZynaNotificationService")
            .requestConfig(config: RequestConfig(retryLimit: 1, timeout: 10000, maxConcurrentRequests: nil, maxRetryTime: nil))
            .build()
    }

    private func sharedUserId() -> String? {
        UserDefaults(suiteName: NSESecurityConfig.appGroupIdentifier)?
            .string(forKey: NSESecurityConfig.matrixLastUserIdKey)
    }

    private func sharedKeychain(service: String) -> Keychain {
        NSESecurityConfig.sharedKeychain(service: service)
    }

    private func directoryHasContents(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? fm.contentsOfDirectory(atPath: url.path) else {
            return false
        }

        return !contents.isEmpty
    }

    private func matrixCryptoStoreExists(in directory: URL) -> Bool {
        let databaseURL = directory.appendingPathComponent(
            NSESecurityConfig.matrixCryptoStoreDatabaseName,
            isDirectory: false
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let resourceValues = try? databaseURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resourceValues.fileSize else {
            return false
        }

        return fileSize > 0
    }

    private func log(_ message: String) {
        os_log("%{public}@", log: .default, type: .default, "[nse] \(message)")
    }
}

private final class NSEActiveRoomCallWaiter: @unchecked Sendable, RoomInfoListener {
    private let room: Room
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var handle: TaskHandle?

    init(room: Room) {
        self.room = room
    }

    func wait(timeout: TimeInterval) async -> Bool {
        if room.hasActiveRoomCall() {
            return true
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let handle = room.subscribeToRoomInfoUpdates(listener: self)
            lock.lock()
            if self.continuation == nil {
                lock.unlock()
                handle.cancel()
            } else {
                self.handle = handle
                lock.unlock()
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.finish(room.hasActiveRoomCall())
            }
        }
    }

    func call(roomInfo: RoomInfo) {
        guard roomInfo.hasRoomCall else { return }
        finish(true)
    }

    private func finish(_ result: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let handle = handle
        self.handle = nil
        lock.unlock()

        handle?.cancel()
        continuation?.resume(returning: result)
    }
}

private final class NSESessionDelegate: ClientSessionDelegate {
    private struct SessionData: Codable {
        let accessToken: String
        let refreshToken: String?
        let userId: String
        let deviceId: String
        let homeserverUrl: String
        let oauthData: String?
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func retrieveSessionFromKeychain(userId: String) throws -> MatrixRustSDK.Session {
        let keychain = sharedKeychain()
        guard let sessionDataString = try keychain.get(userId),
              let sessionData = sessionDataString.data(using: .utf8) else {
            throw ClientError.Generic(msg: "NSE session missing for \(userId)", details: nil)
        }

        let decoded = try decoder.decode(SessionData.self, from: sessionData)
        return MatrixRustSDK.Session(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            userId: decoded.userId,
            deviceId: decoded.deviceId,
            homeserverUrl: decoded.homeserverUrl,
            oauthData: decoded.oauthData,
            slidingSyncVersion: .native
        )
    }

    func saveSessionInKeychain(session: MatrixRustSDK.Session) {
        let sessionData = SessionData(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData
        )

        do {
            let data = try encoder.encode(sessionData)
            guard let dataString = String(data: data, encoding: .utf8) else { return }
            try sharedKeychain().set(dataString, key: session.userId)
        } catch {
            os_log("%{public}@", log: .default, type: .debug, "[nse] failed to save refreshed session: \(error)")
        }
    }

    private func sharedKeychain() -> Keychain {
        NSESecurityConfig.sharedKeychain(service: NSESecurityConfig.sessionKeychainService)
    }
}
