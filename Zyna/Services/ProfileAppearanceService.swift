//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

// Combine's subject annotations are not strict enough for Swift 6 checks here.
// Mutable cache state below is isolated by cacheQueue, and UI notifications are
// delivered from MainActor after the cache mutation is complete.
@preconcurrency import Combine
import Foundation
import MatrixRustSDK
import UIKit

struct ZynaProfileAppearance: Codable, Equatable {
    static let profileFieldKey = "com.zyna.appearance"

    var nameColorHex: String?

    init(nameColorHex: String? = nil) {
        self.nameColorHex = Self.normalizedColorHex(nameColorHex)
    }

    init(payload: [String: Any]) {
        self.init(
            nameColorHex: payload["name_color"] as? String
        )
    }

    var nameColor: UIColor? {
        nameColorHex.flatMap(UIColor.fromHexString)
    }

    var payload: [String: Any] {
        var result: [String: Any] = ["v": 1]
        if let nameColorHex { result["name_color"] = nameColorHex }
        return result
    }

    static func normalizedColorHex(_ raw: String?) -> String? {
        guard let raw,
              let color = UIColor.fromHexString(raw) else {
            return nil
        }
        return color.hexString
    }
}

final class ProfileAppearanceService {
    static let shared = ProfileAppearanceService()

    let appearanceDidChange = PassthroughSubject<String, Never>()

    private struct CacheEntry: Codable {
        let appearance: ZynaProfileAppearance?
        let loadedAt: Date
    }

    private enum CacheLookup {
        case cached(ZynaProfileAppearance?)
        case task(Task<FetchOutcome, Never>)
    }

    private enum FetchOutcome {
        case fetched(ZynaProfileAppearance?, startedAt: Date)
        case failed
    }

    private let cacheQueue = DispatchQueue(label: "com.zyna.profileAppearance.cache")
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<FetchOutcome, Never>] = [:]
    private let cacheTTL: TimeInterval = 10 * 60
    private static let cacheStoreKey = "com.zyna.profileAppearance.cache.v1"
    private static let maxPersistedEntries = 500

    private init() {
        cache = Self.loadPersistedCache()
    }

    func cachedAppearance(userId: String) -> ZynaProfileAppearance? {
        cacheQueue.sync {
            cache[userId]?.appearance
        }
    }

    func prefetchAppearance(userId: String) {
        guard !userId.isEmpty else { return }
        Task { [weak self] in
            _ = await self?.loadAppearance(userId: userId)
        }
    }

    func loadAppearance(userId: String, force: Bool = false) async -> ZynaProfileAppearance? {
        guard !userId.isEmpty else { return nil }

        let lookup: CacheLookup = cacheQueue.sync {
            if !force,
               let entry = cache[userId],
               Date().timeIntervalSince(entry.loadedAt) < cacheTTL {
                return .cached(entry.appearance)
            }

            if let task = inFlight[userId] {
                return .task(task)
            }

            let startedAt = Date()
            let task = Task<FetchOutcome, Never> {
                do {
                    return .fetched(
                        try await Self.fetchAppearance(userId: userId),
                        startedAt: startedAt
                    )
                } catch {
                    return .failed
                }
            }
            inFlight[userId] = task
            return .task(task)
        }

        let task: Task<FetchOutcome, Never>
        switch lookup {
        case .cached(let appearance):
            return appearance
        case .task(let inFlightTask):
            task = inFlightTask
        }

        let outcome = await task.value

        guard case .fetched(let appearance, let startedAt) = outcome else {
            let cached = cacheQueue.sync {
                let cached = cache[userId]?.appearance
                if let entry = cache[userId] {
                    cache[userId] = CacheEntry(appearance: entry.appearance, loadedAt: Date())
                }
                inFlight[userId] = nil
                return cached
            }
            return cached
        }

        let result: (appearance: ZynaProfileAppearance?, shouldNotify: Bool) = cacheQueue.sync {
            // A save can update the cache while an older GET is still in flight.
            if let entry = cache[userId], entry.loadedAt > startedAt {
                inFlight[userId] = nil
                return (entry.appearance, false)
            }

            let previous = cache[userId]?.appearance
            cache[userId] = CacheEntry(appearance: appearance, loadedAt: Date())
            inFlight[userId] = nil
            return (appearance, previous != appearance)
        }
        persistCache()

        if result.shouldNotify {
            await MainActor.run {
                appearanceDidChange.send(userId)
            }
        }

        return result.appearance
    }

    func saveOwnAppearance(_ appearance: ZynaProfileAppearance) async throws {
        guard let client = MatrixClientService.shared.client else {
            throw AuthenticationError.clientNotInitialized
        }
        let session = try client.session()
        try await Self.putAppearance(appearance, session: session)

        let shouldNotify: Bool = cacheQueue.sync {
            let previous = cache[session.userId]?.appearance
            cache[session.userId] = CacheEntry(appearance: appearance, loadedAt: Date())
            return previous != appearance
        }
        persistCache()

        if shouldNotify {
            await MainActor.run {
                appearanceDidChange.send(session.userId)
            }
        }
    }

    private func persistCache() {
        let snapshot = cacheQueue.sync { cache }
        Self.persistCacheSnapshot(snapshot)
    }

    private static func loadPersistedCache() -> [String: CacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: cacheStoreKey),
              let cache = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else {
            return [:]
        }
        return cache.mapValues {
            CacheEntry(appearance: $0.appearance, loadedAt: .distantPast)
        }
    }

    private static func persistCacheSnapshot(_ snapshot: [String: CacheEntry]) {
        let sortedEntries = snapshot.sorted { $0.value.loadedAt > $1.value.loadedAt }
        let prunedEntries = sortedEntries.prefix(maxPersistedEntries)
        let pruned = Dictionary<String, CacheEntry>(
            uniqueKeysWithValues: prunedEntries.map { ($0.key, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        UserDefaults.standard.set(data, forKey: cacheStoreKey)
    }

    private static func fetchAppearance(userId: String) async throws -> ZynaProfileAppearance? {
        guard let client = MatrixClientService.shared.client else {
            throw AuthenticationError.clientNotInitialized
        }
        let session = try client.session()
        let url = try profileFieldURL(
            baseURL: session.homeserverUrl,
            userId: userId
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.statusCode == 403 {
            return nil
        }
        guard (200..<300).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root[ZynaProfileAppearance.profileFieldKey] as? [String: Any] else {
            return nil
        }
        return ZynaProfileAppearance(payload: payload)
    }

    private static func putAppearance(
        _ appearance: ZynaProfileAppearance,
        session: MatrixRustSDK.Session
    ) async throws {
        let url = try profileFieldURL(
            baseURL: session.homeserverUrl,
            userId: session.userId
        )
        let body = [
            ZynaProfileAppearance.profileFieldKey: appearance.payload
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func profileFieldURL(baseURL: String, userId: String) throws -> URL {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }

        let encodedUserId = percentEncodedPathComponent(userId)
        let encodedKey = percentEncodedPathComponent(ZynaProfileAppearance.profileFieldKey)
        guard let url = URL(string: "\(base)/_matrix/client/v3/profile/\(encodedUserId)/\(encodedKey)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
