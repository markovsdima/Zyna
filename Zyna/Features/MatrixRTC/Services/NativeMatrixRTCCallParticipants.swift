//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTCLiveKit

struct NativeMatrixRTCCallTrackState: Equatable, Sendable {
    let sid: String
    var name: String
    var kind: String
    var source: String
    var isMuted: Bool
    var isSubscribed: Bool
    var e2eeState: String?
    var streamState: String?
    var subscriptionError: String?

    var isAudio: Bool {
        source.localizedCaseInsensitiveContains("microphone")
            || kind.localizedCaseInsensitiveContains("audio")
    }

    var isVideo: Bool {
        source.localizedCaseInsensitiveContains("camera")
            || source.localizedCaseInsensitiveContains("screen")
            || kind.localizedCaseInsensitiveContains("video")
    }
}

struct NativeMatrixRTCCallParticipantState: Equatable, Sendable, Identifiable {
    let id: String
    var identity: String?
    var sid: String?
    var tracks: [String: NativeMatrixRTCCallTrackState] = [:]
    var mediaKeyIndex: Int32?

    var sortedTracks: [NativeMatrixRTCCallTrackState] {
        tracks.values.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source < rhs.source
            }
            return lhs.sid < rhs.sid
        }
    }

    var hasSubscribedAudio: Bool {
        tracks.values.contains { $0.isAudio && $0.isSubscribed && !$0.isMuted }
    }

    var hasSubscribedVideo: Bool {
        tracks.values.contains { $0.isVideo && $0.isSubscribed && !$0.isMuted }
    }
}

struct NativeMatrixRTCCallParticipantsSnapshot: Equatable, Sendable {
    static let empty = Self(roomId: nil)

    var roomId: String?
    var localIdentity: String?
    var localTracks: [String: NativeMatrixRTCCallTrackState] = [:]
    var remoteParticipantsById: [String: NativeMatrixRTCCallParticipantState] = [:]
    var mediaKeyIndexesByParticipantId: [String: Int32] = [:]

    var remoteParticipants: [NativeMatrixRTCCallParticipantState] {
        remoteParticipantsById.values.sorted { lhs, rhs in
            let lhsName = lhs.identity ?? lhs.sid ?? lhs.id
            let rhsName = rhs.identity ?? rhs.sid ?? rhs.id
            return lhsName < rhsName
        }
    }

    var remoteParticipantCount: Int {
        remoteParticipantsById.count
    }

    var totalParticipantCount: Int {
        roomId == nil ? 0 : remoteParticipantCount + 1
    }

    var remoteSubscribedAudioTrackCount: Int {
        remoteParticipantsById.values.reduce(0) { partial, participant in
            partial + participant.tracks.values.filter {
                $0.isAudio && $0.isSubscribed && !$0.isMuted
            }.count
        }
    }

    var remoteSubscribedVideoTrackCount: Int {
        remoteParticipantsById.values.reduce(0) { partial, participant in
            partial + participant.tracks.values.filter {
                $0.isVideo && $0.isSubscribed && !$0.isMuted
            }.count
        }
    }
}

struct NativeMatrixRTCCallParticipantStore: Equatable, Sendable {
    private(set) var snapshot: NativeMatrixRTCCallParticipantsSnapshot

    init(roomId: String? = nil) {
        self.snapshot = NativeMatrixRTCCallParticipantsSnapshot(roomId: roomId)
    }

    mutating func reset(roomId: String?) -> NativeMatrixRTCCallParticipantsSnapshot {
        snapshot = NativeMatrixRTCCallParticipantsSnapshot(roomId: roomId)
        return snapshot
    }

    mutating func setLocalIdentity(_ identity: String?) -> NativeMatrixRTCCallParticipantsSnapshot {
        snapshot.localIdentity = identity
        return snapshot
    }

    mutating func apply(
        _ event: MatrixRTCLiveKitRoomSessionEvent
    ) -> NativeMatrixRTCCallParticipantsSnapshot? {
        switch event {
        case .connectionStateChanged, .connected, .disconnected, .failedToConnect:
            return nil

        case .localTrackPublished(let publication):
            snapshot.localTracks[publication.sid] = trackState(from: publication)

        case .localTrackUnpublished(let publication):
            snapshot.localTracks.removeValue(forKey: publication.sid)

        case .localTrackSubscribedByRemote(let publication):
            upsertLocalTrack(publication)

        case .remoteParticipantJoined(let participant):
            upsertRemoteParticipant(participant)

        case .remoteParticipantLeft(let participant):
            snapshot.remoteParticipantsById.removeValue(forKey: participant.participantStateId)

        case .remoteTrackPublished(let participant, let publication),
             .remoteTrackSubscribed(let participant, let publication):
            upsertRemoteTrack(participant: participant, publication: publication)

        case .remoteTrackUnpublished(let participant, let publication):
            removeRemoteTrack(participant: participant, publication: publication)

        case .remoteTrackUnsubscribed(let participant, let publication):
            upsertRemoteTrack(participant: participant, publication: publication)

        case .remoteTrackSubscriptionFailed(let participant, let trackSid, let error):
            markRemoteTrackSubscriptionFailed(
                participant: participant,
                trackSid: trackSid,
                error: error
            )

        case .trackMutedChanged(let participant, let publication, let isMuted):
            updateMutedState(
                participant: participant,
                publication: publication,
                isMuted: isMuted
            )

        case .remoteTrackStreamStateChanged(let participant, let publication, let state):
            updateRemoteTrackStreamState(
                participant: participant,
                publication: publication,
                streamState: state
            )

        case .trackE2EEStateChanged(let publication, let state):
            updateTrackE2EEState(publication: publication, e2eeState: state)

        case .mediaKeyApplied(let keyIndex, let participantId):
            snapshot.mediaKeyIndexesByParticipantId[participantId] = keyIndex
            updateParticipantMediaKeyIndex(participantId: participantId, keyIndex: keyIndex)
        }

        return snapshot
    }
}

private extension NativeMatrixRTCCallParticipantStore {
    mutating func upsertLocalTrack(_ publication: MatrixRTCLiveKitTrackPublicationInfo) {
        var track = snapshot.localTracks[publication.sid] ?? trackState(from: publication)
        track.update(from: publication)
        snapshot.localTracks[publication.sid] = track
    }

    mutating func upsertRemoteParticipant(_ participant: MatrixRTCLiveKitParticipantInfo) {
        let id = participant.participantStateId
        var state = snapshot.remoteParticipantsById[id]
            ?? NativeMatrixRTCCallParticipantState(id: id)
        state.identity = participant.identity
        state.sid = participant.sid
        if let identity = participant.identity,
           let keyIndex = snapshot.mediaKeyIndexesByParticipantId[identity] {
            state.mediaKeyIndex = keyIndex
        }
        snapshot.remoteParticipantsById[id] = state
    }

    mutating func upsertRemoteTrack(
        participant: MatrixRTCLiveKitParticipantInfo,
        publication: MatrixRTCLiveKitTrackPublicationInfo
    ) {
        upsertRemoteParticipant(participant)
        let id = participant.participantStateId
        var participantState = snapshot.remoteParticipantsById[id]!
        var track = participantState.tracks[publication.sid] ?? trackState(from: publication)
        track.update(from: publication)
        track.subscriptionError = nil
        participantState.tracks[publication.sid] = track
        snapshot.remoteParticipantsById[id] = participantState
    }

    mutating func removeRemoteTrack(
        participant: MatrixRTCLiveKitParticipantInfo,
        publication: MatrixRTCLiveKitTrackPublicationInfo
    ) {
        let id = participant.participantStateId
        guard var participantState = snapshot.remoteParticipantsById[id] else { return }
        participantState.tracks.removeValue(forKey: publication.sid)
        snapshot.remoteParticipantsById[id] = participantState
    }

    mutating func markRemoteTrackSubscriptionFailed(
        participant: MatrixRTCLiveKitParticipantInfo,
        trackSid: String,
        error: String
    ) {
        upsertRemoteParticipant(participant)
        let id = participant.participantStateId
        var participantState = snapshot.remoteParticipantsById[id]!
        var track = participantState.tracks[trackSid] ?? NativeMatrixRTCCallTrackState(
            sid: trackSid,
            name: "",
            kind: "",
            source: "",
            isMuted: false,
            isSubscribed: false
        )
        track.subscriptionError = error
        participantState.tracks[trackSid] = track
        snapshot.remoteParticipantsById[id] = participantState
    }

    mutating func updateMutedState(
        participant: MatrixRTCLiveKitParticipantInfo,
        publication: MatrixRTCLiveKitTrackPublicationInfo,
        isMuted: Bool
    ) {
        if snapshot.localTracks[publication.sid] != nil {
            var track = snapshot.localTracks[publication.sid]!
            track.update(from: publication)
            track.isMuted = isMuted
            snapshot.localTracks[publication.sid] = track
            return
        }

        upsertRemoteTrack(participant: participant, publication: publication)
        let id = participant.participantStateId
        guard var participantState = snapshot.remoteParticipantsById[id],
              var track = participantState.tracks[publication.sid]
        else { return }
        track.isMuted = isMuted
        participantState.tracks[publication.sid] = track
        snapshot.remoteParticipantsById[id] = participantState
    }

    mutating func updateRemoteTrackStreamState(
        participant: MatrixRTCLiveKitParticipantInfo,
        publication: MatrixRTCLiveKitTrackPublicationInfo,
        streamState: String
    ) {
        upsertRemoteTrack(participant: participant, publication: publication)
        let id = participant.participantStateId
        guard var participantState = snapshot.remoteParticipantsById[id],
              var track = participantState.tracks[publication.sid]
        else { return }
        track.streamState = streamState
        participantState.tracks[publication.sid] = track
        snapshot.remoteParticipantsById[id] = participantState
    }

    mutating func updateTrackE2EEState(
        publication: MatrixRTCLiveKitTrackPublicationInfo,
        e2eeState: String
    ) {
        if snapshot.localTracks[publication.sid] != nil {
            var track = snapshot.localTracks[publication.sid]!
            track.update(from: publication)
            track.e2eeState = e2eeState
            snapshot.localTracks[publication.sid] = track
        }

        for participantId in snapshot.remoteParticipantsById.keys {
            guard var participant = snapshot.remoteParticipantsById[participantId],
                  var track = participant.tracks[publication.sid]
            else { continue }
            track.update(from: publication)
            track.e2eeState = e2eeState
            participant.tracks[publication.sid] = track
            snapshot.remoteParticipantsById[participantId] = participant
        }
    }

    mutating func updateParticipantMediaKeyIndex(participantId: String, keyIndex: Int32) {
        for id in snapshot.remoteParticipantsById.keys {
            guard var participant = snapshot.remoteParticipantsById[id],
                  participant.identity == participantId
            else { continue }
            participant.mediaKeyIndex = keyIndex
            snapshot.remoteParticipantsById[id] = participant
        }
    }

    func trackState(
        from publication: MatrixRTCLiveKitTrackPublicationInfo
    ) -> NativeMatrixRTCCallTrackState {
        NativeMatrixRTCCallTrackState(
            sid: publication.sid,
            name: publication.name,
            kind: publication.kind,
            source: publication.source,
            isMuted: publication.isMuted,
            isSubscribed: publication.isSubscribed
        )
    }
}

private extension NativeMatrixRTCCallTrackState {
    mutating func update(from publication: MatrixRTCLiveKitTrackPublicationInfo) {
        name = publication.name
        kind = publication.kind
        source = publication.source
        isMuted = publication.isMuted
        isSubscribed = publication.isSubscribed
    }
}

private extension MatrixRTCLiveKitParticipantInfo {
    var participantStateId: String {
        identity ?? sid ?? "unknown"
    }
}
