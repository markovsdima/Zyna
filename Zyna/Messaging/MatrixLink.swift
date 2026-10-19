// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

enum MatrixLink: Equatable, Sendable {
    case person(String)
    case room(MatrixRoomLink)

    /// Cheap dispatch only. Validation and percent decoding use the SDK's
    /// synchronous string parser; routing calls it off-main. Text fields
    /// also use it for local validation, with no network or database access.
    static func isCandidate(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "matrix" { return true }
        return ["https", "http"].contains(url.scheme?.lowercased())
            && url.host?.lowercased() == "matrix.to"
            && url.user == nil && url.password == nil && url.port == nil
            && ["", "/"].contains(url.path) && url.fragment != nil
    }

    static func browserFallback(_ url: URL) -> URL? {
        guard isCandidate(url), ["https", "http"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    static func parse(_ url: URL) -> MatrixLink? {
        guard isCandidate(url) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.scheme?.lowercased() == "matrix" {
            components?.scheme = "matrix"
        } else {
            components?.scheme = "https"
            components?.host = "matrix.to"
            components?.path = "/"
            // The landing page accepts client/web-instance hints that the
            // SDK's strict Matrix parser doesn't understand. They select a
            // web application, not a different Matrix destination. Keep the
            // percent-encoded ID untouched and preserve every routing hint.
            if let fragment = components?.percentEncodedFragment,
               let separator = fragment.firstIndex(of: "?") {
                var query = URLComponents()
                query.percentEncodedQuery = String(fragment[fragment.index(after: separator)...])
                query.queryItems = query.queryItems?.filter { $0.name == "via" }
                let suffix = query.percentEncodedQuery.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? ""
                components?.percentEncodedFragment = String(fragment[..<separator]) + suffix
            }
        }
        guard let value = components?.string,
              let entity = parseMatrixEntityFrom(uri: value) else { return nil }
        switch entity.id {
        case .user(let id): return .person(id)
        case .room(let id): return .room(.init(reference: id, via: entity.via))
        case .roomAlias(let alias): return .room(.init(reference: alias, via: entity.via))
        case .eventOnRoomId(let id, let event):
            return .room(.init(reference: id, via: entity.via, eventID: event))
        case .eventOnRoomAlias(let alias, let event):
            return .room(.init(reference: alias, via: entity.via, eventID: event))
        }
    }
}

struct MatrixRoomLink: Equatable, Sendable {
    let reference: String
    let via: [String]
    var eventID: String?
}
