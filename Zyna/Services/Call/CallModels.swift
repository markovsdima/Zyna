//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Call State

enum CallState: Equatable {
    case idle
    case outgoingRinging(callId: String, roomId: String)
    case incomingRinging(callId: String, roomId: String, callerName: String?)
    case connecting(callId: String, roomId: String)
    case connected(callId: String, roomId: String)
    case ended(callId: String, reason: CallHangupReason)

    var isActive: Bool {
        switch self {
        case .idle, .ended:
            return false
        default:
            return true
        }
    }

    var callId: String? {
        switch self {
        case .idle:
            return nil
        case .outgoingRinging(let callId, _),
             .incomingRinging(let callId, _, _),
             .connecting(let callId, _),
             .connected(let callId, _),
             .ended(let callId, _):
            return callId
        }
    }

    var roomId: String? {
        switch self {
        case .idle, .ended:
            return nil
        case .outgoingRinging(_, let roomId),
             .incomingRinging(_, let roomId, _),
             .connecting(_, let roomId),
             .connected(_, let roomId):
            return roomId
        }
    }

}

// MARK: - Call Hangup Reason

enum CallHangupReason: String, Codable {
    case normal = "normal"
    case busy = "busy"
    case timeout = "timeout"
    case iceFailed = "ice_failed"
    case userHangup = "user_hangup"
    case remoteHangup = "remote_hangup"
    case declined = "declined"
}

// MARK: - Call Direction

enum CallDirection {
    case outgoing
    case incoming
}

// MARK: - Signaling Events

enum CallSignalingEvent {
    case invite(CallInviteContent)
    case answer(CallAnswerContent)
    case candidates(CallCandidatesContent)
    case hangup(CallHangupContent)
}

// MARK: - m.call.invite

struct CallInviteContent: Codable {
    let callId: String
    let version: Int
    let lifetime: Int
    let offer: SDPContent

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case version, lifetime, offer
    }

    init(callId: String, sdp: String, lifetime: Int = 60000) {
        self.callId = callId
        self.version = 0
        self.lifetime = lifetime
        self.offer = SDPContent(type: "offer", sdp: sdp)
    }
}

// MARK: - m.call.answer

struct CallAnswerContent: Codable {
    let callId: String
    let version: Int
    let answer: SDPContent

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case version, answer
    }

    init(callId: String, sdp: String) {
        self.callId = callId
        self.version = 0
        self.answer = SDPContent(type: "answer", sdp: sdp)
    }
}

// MARK: - m.call.candidates

struct CallCandidatesContent: Codable {
    let callId: String
    let version: Int
    let candidates: [ICECandidate]

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case version, candidates
    }

    init(callId: String, candidates: [ICECandidate]) {
        self.callId = callId
        self.version = 0
        self.candidates = candidates
    }
}

// MARK: - m.call.hangup

struct CallHangupContent: Codable {
    let callId: String
    let version: Int
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case version, reason
    }

    init(callId: String, reason: CallHangupReason = .userHangup) {
        self.callId = callId
        self.version = 0
        self.reason = reason.rawValue
    }
}

// MARK: - Shared Types

struct SDPContent: Codable {
    let type: String
    let sdp: String
}

struct ICECandidate: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdpMid"
        case sdpMLineIndex = "sdpMLineIndex"
    }
}

// MARK: - JSON Helpers

enum CallEventJSON {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from jsonString: String) -> T? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Call ID Generator

enum CallIdGenerator {
    static func generate() -> String {
        UUID().uuidString.lowercased()
    }
}
