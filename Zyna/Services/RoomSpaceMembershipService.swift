//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

enum RoomSpaceMembershipStatus: Equatable {
    case linked
    case listedBySpaceOnly
    case declaredByRoomOnly

    var needsAttention: Bool {
        self != .linked
    }

    var title: String {
        switch self {
        case .linked:
            return String(localized: "Linked")
        case .listedBySpaceOnly:
            return String(localized: "Listed by Storyline")
        case .declaredByRoomOnly:
            return String(localized: "Declared by Chat")
        }
    }

    var detail: String {
        switch self {
        case .linked:
            return String(localized: "Both sides recognize this link.")
        case .listedBySpaceOnly:
            return String(localized: "The Storyline shows this chat, but the chat does not confirm it.")
        case .declaredByRoomOnly:
            return String(localized: "The chat points to this Storyline, but the Storyline does not show it.")
        }
    }

    var hasSpaceSide: Bool {
        switch self {
        case .linked, .listedBySpaceOnly:
            return true
        case .declaredByRoomOnly:
            return false
        }
    }

    var hasRoomSide: Bool {
        switch self {
        case .linked, .declaredByRoomOnly:
            return true
        case .listedBySpaceOnly:
            return false
        }
    }
}

struct RoomSpaceMembership: Identifiable, Equatable {
    let id: String
    let displayName: String
    let avatarURL: String?
    let status: RoomSpaceMembershipStatus
    let canEditSpaceSide: Bool
    let canEditRoomSide: Bool
}

struct RoomSpaceMembershipSummary: Equatable {
    let count: Int
    let attentionCount: Int
}

enum RoomSpaceMembershipAction {
    case setRoomSideLink
    case setSpaceSideLink
    case removeSpaceSideLink
    case removeRoomSideLink

    var title: String {
        switch self {
        case .setRoomSideLink:
            return String(localized: "Confirm in Chat")
        case .setSpaceSideLink:
            return String(localized: "Add to Storyline")
        case .removeSpaceSideLink:
            return String(localized: "Remove from Storyline List")
        case .removeRoomSideLink:
            return String(localized: "Remove Chat Link")
        }
    }

    var isDestructive: Bool {
        switch self {
        case .removeSpaceSideLink, .removeRoomSideLink:
            return true
        case .setRoomSideLink, .setSpaceSideLink:
            return false
        }
    }
}

final class RoomSpaceMembershipService {

    private struct MatrixStateEvent {
        let type: String
        let stateKey: String
        let content: [String: Any]
    }

    private struct SpaceCandidate {
        let id: String
        let displayName: String
        let avatarURL: String?

        init(id: String, displayName: String, avatarURL: String?) {
            self.id = id
            self.displayName = displayName
            self.avatarURL = avatarURL
        }

        init(space: SpaceRoom) {
            self.init(
                id: space.roomId,
                displayName: space.displayName.nilIfEmpty
                    ?? space.canonicalAlias
                    ?? String(localized: "Untitled"),
                avatarURL: space.avatarUrl
            )
        }
    }

    private let roomListService: ZynaRoomListService

    init(roomListService: ZynaRoomListService) {
        self.roomListService = roomListService
    }

    func loadMemberships(for roomId: String) async throws -> [RoomSpaceMembership] {
        guard let client = MatrixClientService.shared.client else {
            throw spaceMembershipError(String(localized: "Matrix client is not ready."))
        }

        let spaceService = await client.spaceService()
        let roomSummaries = await roomListService.joinedRoomSummaries()
        let summariesById = Dictionary(
            roomSummaries.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        async let loadedParentIds = loadParentSpaceIds(for: roomId, client: client)
        async let loadedEditableSpaces = spaceService.editableSpaces()
        _ = await spaceService.topLevelJoinedSpaces()

        var candidatesById: [String: SpaceCandidate] = [:]
        for summary in roomSummaries where summary.isSpace {
            candidatesById[summary.id] = SpaceCandidate(
                id: summary.id,
                displayName: summary.displayName.nilIfEmpty ?? String(localized: "Untitled"),
                avatarURL: summary.avatarURL
            )
        }

        let editableSpaces = await loadedEditableSpaces
        for space in editableSpaces {
            candidatesById[space.roomId] = SpaceCandidate(space: space)
        }

        let parentIds = try await loadedParentIds
        for parentId in parentIds where candidatesById[parentId] == nil {
            if let space = try? await spaceService.getSpaceRoom(roomId: parentId) {
                candidatesById[parentId] = SpaceCandidate(space: space)
            } else if let summary = summariesById[parentId] {
                candidatesById[parentId] = SpaceCandidate(
                    id: summary.id,
                    displayName: summary.displayName.nilIfEmpty ?? String(localized: "Untitled"),
                    avatarURL: summary.avatarURL
                )
            } else {
                candidatesById[parentId] = SpaceCandidate(
                    id: parentId,
                    displayName: parentId,
                    avatarURL: nil
                )
            }
        }

        var childSideIds = Set<String>()
        for candidate in candidatesById.values {
            if try await spaceListsChild(spaceId: candidate.id, childId: roomId, client: client) {
                childSideIds.insert(candidate.id)
            }
        }

        let allIds = childSideIds.union(parentIds)
        guard !allIds.isEmpty else { return [] }

        let canEditRoomSide = await canOwnUserSendState(in: roomId, stateEvent: .spaceParent)
        var memberships: [RoomSpaceMembership] = []
        memberships.reserveCapacity(allIds.count)

        for spaceId in allIds {
            let candidate = candidatesById[spaceId] ?? SpaceCandidate(
                id: spaceId,
                displayName: spaceId,
                avatarURL: nil
            )
            let status: RoomSpaceMembershipStatus
            let hasSpaceSide = childSideIds.contains(spaceId)
            let hasRoomSide = parentIds.contains(spaceId)

            switch (hasSpaceSide, hasRoomSide) {
            case (true, true):
                status = .linked
            case (true, false):
                status = .listedBySpaceOnly
            case (false, true):
                status = .declaredByRoomOnly
            case (false, false):
                continue
            }

            memberships.append(RoomSpaceMembership(
                id: spaceId,
                displayName: candidate.displayName.nilIfEmpty ?? String(localized: "Untitled"),
                avatarURL: candidate.avatarURL,
                status: status,
                canEditSpaceSide: await canOwnUserSendState(in: spaceId, stateEvent: .spaceChild),
                canEditRoomSide: canEditRoomSide
            ))
        }

        return memberships.sorted { lhs, rhs in
            if lhs.status.needsAttention != rhs.status.needsAttention {
                return lhs.status.needsAttention && !rhs.status.needsAttention
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func loadSummary(for roomId: String) async throws -> RoomSpaceMembershipSummary {
        let memberships = try await loadMemberships(for: roomId)
        return RoomSpaceMembershipSummary(
            count: memberships.count,
            attentionCount: memberships.filter(\.status.needsAttention).count
        )
    }

    func perform(_ action: RoomSpaceMembershipAction, membership: RoomSpaceMembership, roomId: String) async throws {
        switch action {
        case .setRoomSideLink:
            try await roomListService.setParentLink(
                membership.id,
                forChild: roomId,
                context: "room-details"
            )
        case .setSpaceSideLink:
            try await roomListService.setChildLink(
                roomId,
                toSpace: membership.id,
                context: "room-details"
            )
        case .removeSpaceSideLink:
            try await roomListService.removeChildLink(
                roomId,
                fromSpace: membership.id,
                context: "room-details"
            )
        case .removeRoomSideLink:
            try await roomListService.removeParentLink(
                membership.id,
                fromChild: roomId,
                context: "room-details"
            )
        }
    }

    private func loadParentSpaceIds(for roomId: String, client: Client) async throws -> Set<String> {
        let events = try await loadStateEvents(roomId: roomId, client: client)
        let ids = events.compactMap { event -> String? in
            guard event.type == "m.space.parent",
                  isValidSpaceRelationshipContent(event.content)
            else { return nil }
            return event.stateKey
        }
        return Set(ids)
    }

    private func spaceListsChild(spaceId: String, childId: String, client: Client) async throws -> Bool {
        let content = try await loadStateEventContent(
            roomId: spaceId,
            eventType: "m.space.child",
            stateKey: childId,
            client: client
        )
        guard let content else { return false }
        return isValidSpaceRelationshipContent(content)
    }

    private func loadStateEvents(roomId: String, client: Client) async throws -> [MatrixStateEvent] {
        let data = try await matrixRequest(
            path: "/_matrix/client/v3/rooms/\(Self.percentEncodedPathComponent(roomId))/state",
            client: client
        )
        guard let rawEvents = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return rawEvents.compactMap { event in
            guard let type = event["type"] as? String,
                  let stateKey = event["state_key"] as? String,
                  let content = event["content"] as? [String: Any]
            else { return nil }
            return MatrixStateEvent(type: type, stateKey: stateKey, content: content)
        }
    }

    private func loadStateEventContent(
        roomId: String,
        eventType: String,
        stateKey: String,
        client: Client
    ) async throws -> [String: Any]? {
        let path = "/_matrix/client/v3/rooms/\(Self.percentEncodedPathComponent(roomId))/state/"
            + "\(Self.percentEncodedPathComponent(eventType))/\(Self.percentEncodedPathComponent(stateKey))"

        do {
            let data = try await matrixRequest(path: path, client: client)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch MatrixStateHTTPError.notFound {
            return nil
        }
    }

    private func matrixRequest(path: String, client: Client) async throws -> Data {
        let session = try client.session()
        let url = try Self.matrixURL(homeserverUrl: session.homeserverUrl, percentEncodedPath: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixStateHTTPError.invalidResponse
        }

        if http.statusCode == 404 {
            throw MatrixStateHTTPError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MatrixStateHTTPError.httpStatus(http.statusCode)
        }
        return data
    }

    private func canOwnUserSendState(in roomId: String, stateEvent: StateEventType) async -> Bool {
        guard let room = roomListService.room(for: roomId) else { return false }
        if let info = try? await room.roomInfo(),
           let powerLevels = info.powerLevels {
            return powerLevels.canOwnUserSendState(stateEvent: stateEvent)
        }
        guard let powerLevels = try? await room.getPowerLevels() else {
            return false
        }
        return powerLevels.canOwnUserSendState(stateEvent: stateEvent)
    }

    private func isValidSpaceRelationshipContent(_ content: [String: Any]) -> Bool {
        guard let via = content["via"] as? [String] else { return false }
        return !via.isEmpty
    }

    private func spaceMembershipError(_ message: String) -> NSError {
        NSError(
            domain: "Zyna.RoomSpaceMembership",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func matrixURL(homeserverUrl: String, percentEncodedPath: String) throws -> URL {
        var raw = homeserverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            throw MatrixStateHTTPError.invalidURL
        }

        components.percentEncodedPath = percentEncodedPath
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MatrixStateHTTPError.invalidURL
        }
        return url
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private enum MatrixStateHTTPError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notFound
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid homeserver URL")
        case .invalidResponse:
            return String(localized: "Invalid Matrix response.")
        case .notFound:
            return String(localized: "Matrix state event was not found.")
        case .httpStatus(let status):
            return String.localizedStringWithFormat(
                String(localized: "Matrix request failed with HTTP %lld."),
                status
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
