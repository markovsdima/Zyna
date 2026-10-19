// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK

enum MatrixActionFailure {
    enum Action { case previewRoom, roomAction, loadTopic, saveTopic, createLink, loadPins, unpin }

    static func message(for error: Error, action: Action) -> String {
        if case ClientError.MatrixApi(_, let code, _, _) = error {
            if action == .previewRoom, ["M_FORBIDDEN", "M_NOT_FOUND"].contains(code) {
                return String(localized: "This room is private or does not exist.")
            }
            switch code {
            case "M_FORBIDDEN":
                return String(localized: "You don't have permission to do this.")
            case "M_NOT_FOUND":
                return String(localized: "This content is no longer available.")
            case "M_UNRECOGNIZED", "M_UNSUPPORTED":
                return action == .previewRoom
                    ? String(localized: "Your server does not support room previews.")
                    : String(localized: "Your server does not support this action.")
            case "M_LIMIT_EXCEEDED":
                return String(localized: "Too many requests. Please wait and try again.")
            default: break
            }
        }
        if let error = error as? URLError {
            if error.code == .resourceUnavailable, action == .previewRoom {
                return String(localized: "This room is private or does not exist.")
            }
            if [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
                return String(localized: "Couldn't connect to the server. Check your connection and try again.")
            }
        }
        // SDK Generic and unknown errors can contain debug dumps, URLs and
        // transport details. Never show their localizedDescription in the UI.
        switch action {
        case .previewRoom: return String(localized: "Couldn't load this room. Please try again.")
        case .roomAction: return String(localized: "Couldn't open this room. Please try again.")
        case .loadTopic: return String(localized: "Couldn't load the description. Please try again.")
        case .saveTopic: return String(localized: "Couldn't save the description. Please try again.")
        case .createLink: return String(localized: "Couldn't create the link. Please try again.")
        case .loadPins: return String(localized: "Couldn't load pinned messages. Please try again.", table: "RoomProfile")
        case .unpin: return String(localized: "Couldn't unpin the message. Please try again.", table: "RoomProfile")
        }
    }
}
