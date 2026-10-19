//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// App-owned values: persistence and UI never retain SDK timeline objects.
struct PollDefinition: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case disclosed, undisclosed }

    struct Answer: Codable, Equatable, Identifiable, Sendable {
        let id: String
        var text: String

        init(id: String = UUID().uuidString, text: String = "") {
            self.id = id
            self.text = text
        }
    }

    var question: String
    var answers: [Answer]
    var maxSelections: UInt64
    var kind: Kind

    static var draft: Self {
        Self(question: "", answers: [.init(), .init()], maxSelections: 1, kind: .disclosed)
    }

    var normalized: Self {
        var value = self
        value.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        value.answers = answers.map {
            Answer(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return value
    }

    var isValidForCreation: Bool {
        let value = normalized
        return !value.question.isEmpty && value.question.count <= 1024
            && (2...20).contains(value.answers.count)
            && value.answers.allSatisfy { !$0.id.isEmpty && !$0.text.isEmpty && $0.text.count <= 240 }
            && Set(value.answers.map(\.id)).count == value.answers.count
            && value.maxSelections >= 1 && value.maxSelections <= UInt64(value.answers.count)
    }

    func sdkData() throws -> DirectPollData {
        guard isValidForCreation, let selections = UInt8(exactly: maxSelections) else {
            throw PollError.invalidContent
        }
        return DirectPollData(
            question: question,
            answers: answers.map { PollAnswer(id: $0.id, text: $0.text) },
            maxSelections: selections,
            pollKind: kind == .disclosed ? .disclosed : .undisclosed
        )
    }
}

struct PollSnapshot: Codable, Equatable, Sendable {
    var definition: PollDefinition
    var voteCounts: [String: Int]
    var selectedAnswerIDs: [String]
    var totalVoters: Int
    var endTimestamp: TimeInterval?
    var isEditable: Bool
    var isEdited: Bool
    /// Identity of the effective edit chosen by the SDK, not local intent.
    var latestEditEventID: String? = nil
    /// Local intent is separate from the confirmed aggregate. Counts always
    /// describe SDK results, even while the selection is optimistic.
    var pending: PollPendingPresentation? = nil

    var hasEnded: Bool { endTimestamp != nil }
    var showsResults: Bool { hasEnded || definition.kind == .disclosed }
    var displayedSelection: [String] { pending?.answers ?? selectedAnswerIDs }
    var allowsVote: Bool { !hasEnded && (pending == nil || pending?.failed == true || pending?.kind == .response) }
    var selectionLimit: Int { max(1, Int(min(definition.maxSelections, UInt64(definition.answers.count)))) }

    var accessibilityDescription: String {
        var parts = [String(localized: "Poll: \(definition.question)")]
        for answer in definition.answers {
            var text = answer.text
            if displayedSelection.contains(answer.id) { text += ", " + String(localized: "Selected") }
            if showsResults { text += ", " + String(localized: "\(voteCounts[answer.id] ?? 0) votes") }
            parts.append(text)
        }
        parts.append(showsResults ? String(localized: "\(totalVoters) voters") : String(localized: "Results after the poll ends"))
        if hasEnded { parts.append(String(localized: "Poll ended")) }
        return parts.joined(separator: ", ")
    }

    static func empty(_ definition: PollDefinition) -> Self {
        Self(definition: definition, voteCounts: [:], selectedAnswerIDs: [], totalVoters: 0,
             endTimestamp: nil, isEditable: true, isEdited: false)
    }

    static func fromSDK(
        question: String, kind: PollKind, maxSelections: UInt64,
        answers: [PollAnswer], votes: [String: [String]], endTime: UInt64?,
        isEditable: Bool, isEdited: Bool, currentUserID: String
    ) -> Self {
        var answerIDs = Set<String>()
        let answers = answers.filter { answerIDs.insert($0.id).inserted }
        var participants = Set<String>()
        var counts: [String: Int] = [:]
        var selected: [String] = []
        for answer in answers {
            let voters = Set(votes[answer.id] ?? [])
            counts[answer.id] = voters.count
            participants.formUnion(voters)
            if voters.contains(currentUserID) { selected.append(answer.id) }
        }
        return Self(
            definition: PollDefinition(question: question,
                answers: answers.map { .init(id: $0.id, text: $0.text) },
                maxSelections: maxSelections, kind: kind == .disclosed ? .disclosed : .undisclosed),
            voteCounts: counts, selectedAnswerIDs: selected, totalVoters: participants.count,
            endTimestamp: endTime.map { Double($0) / 1000 }, isEditable: isEditable, isEdited: isEdited
        )
    }

    func validatesResponse(_ ids: [String]) -> Bool {
        let unique = Set(ids)
        return !hasEnded && unique.count == ids.count && ids.count <= selectionLimit
            && unique.isSubset(of: Set(definition.answers.map(\.id)))
    }
}

enum PollOperationKind: String, Codable, Sendable { case start, response, edit, end }

struct PollPermissions: Equatable {
    var start = false
    var response = false
    var end = false

    init() {}
    init(_ powers: RoomPowerLevels) {
        start = powers.canOwnUserSendMessage(message: .unstablePollStart)
        response = powers.canOwnUserSendMessage(message: .unstablePollResponse)
        end = powers.canOwnUserSendMessage(message: .unstablePollEnd)
    }
}

/// Ready-to-render catalog entry. Decoding and pending-state projection happen
/// in PollStore, so a future SwiftUI or Texture tab does neither on main.
struct RoomPollItem: Identifiable, Equatable, Sendable {
    var id: String { eventId }
    let roomId: String
    let eventId: String
    let timestamp: TimeInterval
    let senderId: String
    let senderName: String?
    let snapshot: PollSnapshot
}

struct PollPendingPresentation: Codable, Equatable, Sendable {
    let operationID: String
    let kind: PollOperationKind
    let answers: [String]?
    let failed: Bool
    let awaitingSync: Bool
    var failureReason: PollFailureReason? = nil

    var canRetry: Bool { failed && failureReason != .staleSession }
}

enum PollFailureReason: String, Codable, Sendable { case staleSession }

enum PollError: LocalizedError {
    case invalidContent, unavailable, notAllowed, staleSession

    var errorDescription: String? {
        switch self {
        case .invalidContent: return String(localized: "Check the question and answer options.")
        case .unavailable: return String(localized: "This poll is no longer available for this action.")
        case .notAllowed: return String(localized: "You don't have permission to perform this poll action.")
        case .staleSession: return String(localized: "This action belongs to a previous session. Please try again.")
        }
    }
}

enum PollCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
