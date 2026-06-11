//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

@_spi(Testing) import MatrixRTCLiveKit
import Foundation
import Testing
@testable import Zyna

@Suite("NativeMatrixRTCCallParticipantStore")
struct NativeMatrixRTCCallParticipantsTests {
    @Test("Local video preview is hidden when camera is muted or unpublished")
    func localVideoPreviewCleanup() {
        var store = NativeMatrixRTCCallParticipantStore(roomId: roomId)
        let publication = trackPublication(
            sid: "local-camera",
            kind: "video",
            source: "camera",
            isMuted: false,
            isSubscribed: true
        )
        let localVideoTrack = MatrixRTCLiveKitLocalVideoTrack.testing(
            trackSid: publication.sid,
            trackName: publication.name
        )

        var snapshot = store.apply(.localVideoTrackPublished(
            publication: publication,
            videoTrack: localVideoTrack
        ))

        #expect(snapshot?.localVideoTrack == localVideoTrack)
        #expect(snapshot?.localTracks[publication.sid]?.localVideoTrack == localVideoTrack)

        snapshot = store.apply(.trackMutedChanged(
            participant: localParticipant,
            publication: trackPublication(
                sid: publication.sid,
                kind: publication.kind,
                source: publication.source,
                isMuted: true,
                isSubscribed: true
            ),
            isMuted: true
        ))

        #expect(snapshot?.localVideoTrack == nil)
        #expect(snapshot?.localTracks[publication.sid]?.localVideoTrack == localVideoTrack)

        snapshot = store.apply(.localVideoTrackUnpublished(publication))

        #expect(snapshot?.localVideoTrack == nil)
        #expect(snapshot?.localTracks[publication.sid]?.localVideoTrack == nil)

        snapshot = store.apply(.localTrackUnpublished(publication))

        #expect(snapshot?.localTracks[publication.sid] == nil)
    }

    @Test("Remote video handles are cleared on unsubscribe and unpublish")
    func remoteVideoCleanup() {
        var store = NativeMatrixRTCCallParticipantStore(roomId: roomId)
        let participant = remoteParticipant(identity: "@bob:example.org", sid: "bob-sid")
        let publication = trackPublication(
            sid: "remote-camera",
            kind: "video",
            source: "camera",
            isMuted: false,
            isSubscribed: true
        )
        let videoTrack = MatrixRTCLiveKitRemoteVideoTrack.testing(
            participantIdentity: participant.identity,
            participantSid: participant.sid,
            trackSid: publication.sid,
            trackName: publication.name
        )

        var snapshot = store.apply(.remoteVideoTrackSubscribed(
            participant: participant,
            publication: publication,
            videoTrack: videoTrack
        ))

        #expect(snapshot?.primaryRemoteVideoTrack == videoTrack)
        #expect(snapshot?.remoteVideoTracks == [videoTrack])
        #expect(snapshot?.remoteParticipantsById[participant.identity!]?.tracks[publication.sid]?.remoteVideoTrack == videoTrack)

        let unsubscribedPublication = trackPublication(
            sid: publication.sid,
            kind: publication.kind,
            source: publication.source,
            isMuted: false,
            isSubscribed: false
        )
        _ = store.apply(.remoteTrackUnsubscribed(
            participant: participant,
            publication: unsubscribedPublication
        ))
        snapshot = store.apply(.remoteVideoTrackUnsubscribed(
            participant: participant,
            publication: unsubscribedPublication
        ))

        let unsubscribedTrack = snapshot?.remoteParticipantsById[participant.identity!]?.tracks[publication.sid]
        #expect(snapshot?.remoteVideoTracks.isEmpty == true)
        #expect(unsubscribedTrack?.isSubscribed == false)
        #expect(unsubscribedTrack?.remoteVideoTrack == nil)

        _ = store.apply(.remoteVideoTrackSubscribed(
            participant: participant,
            publication: publication,
            videoTrack: videoTrack
        ))
        snapshot = store.apply(.remoteTrackUnpublished(
            participant: participant,
            publication: publication
        ))

        #expect(snapshot?.remoteVideoTracks.isEmpty == true)
        #expect(snapshot?.remoteParticipantsById[participant.identity!]?.tracks[publication.sid] == nil)
    }

    @Test("Participant leave removes their video state without touching others")
    func participantLeaveRemovesVideoState() {
        var store = NativeMatrixRTCCallParticipantStore(roomId: roomId)
        let alice = remoteParticipant(identity: "@alice:example.org", sid: "alice-sid")
        let bob = remoteParticipant(identity: "@bob:example.org", sid: "bob-sid")
        let alicePublication = trackPublication(sid: "alice-camera")
        let bobPublication = trackPublication(sid: "bob-camera")
        let aliceVideoTrack = MatrixRTCLiveKitRemoteVideoTrack.testing(
            participantIdentity: alice.identity,
            participantSid: alice.sid,
            trackSid: alicePublication.sid
        )
        let bobVideoTrack = MatrixRTCLiveKitRemoteVideoTrack.testing(
            participantIdentity: bob.identity,
            participantSid: bob.sid,
            trackSid: bobPublication.sid
        )

        _ = store.apply(.remoteVideoTrackSubscribed(
            participant: alice,
            publication: alicePublication,
            videoTrack: aliceVideoTrack
        ))
        var snapshot = store.apply(.remoteVideoTrackSubscribed(
            participant: bob,
            publication: bobPublication,
            videoTrack: bobVideoTrack
        ))

        #expect(snapshot?.remoteVideoTracks == [aliceVideoTrack, bobVideoTrack])

        snapshot = store.apply(.remoteParticipantLeft(bob))

        #expect(snapshot?.remoteVideoTracks == [aliceVideoTrack])
        #expect(snapshot?.remoteParticipantsById[alice.identity!] != nil)
        #expect(snapshot?.remoteParticipantsById[bob.identity!] == nil)
    }

    @Test("Speaking updates sort remote participants by activity and last spoke time")
    func speakingUpdatesSortRemoteParticipants() {
        var store = NativeMatrixRTCCallParticipantStore(roomId: roomId)
        let alice = remoteParticipant(identity: "@alice:example.org", sid: "alice-sid")
        let bob = remoteParticipant(identity: "@bob:example.org", sid: "bob-sid")
        let aliceSpokeAt = Date(timeIntervalSince1970: 2_000)
        let bobSpokeAt = Date(timeIntervalSince1970: 1_000)

        _ = store.apply(.remoteParticipantJoined(alice))
        _ = store.apply(.remoteParticipantJoined(bob))

        var snapshot = store.apply(.speakingParticipantsChanged([
            speakingParticipant(identity: bob.identity, sid: bob.sid, lastSpokeAt: bobSpokeAt)
        ]))

        #expect(snapshot?.remoteParticipants.map(\.identity) == [bob.identity, alice.identity])
        #expect(snapshot?.remoteParticipantsById[bob.identity!]?.speaking.isSpeaking == true)

        snapshot = store.apply(.speakingParticipantsChanged([]))

        #expect(snapshot?.remoteParticipants.map(\.identity) == [bob.identity, alice.identity])
        #expect(snapshot?.remoteParticipantsById[bob.identity!]?.speaking.isSpeaking == false)
        #expect(snapshot?.remoteParticipantsById[bob.identity!]?.speaking.lastSpokeAt == bobSpokeAt)

        snapshot = store.apply(.speakingParticipantsChanged([
            speakingParticipant(identity: alice.identity, sid: alice.sid, lastSpokeAt: aliceSpokeAt)
        ]))

        #expect(snapshot?.remoteParticipants.map(\.identity) == [alice.identity, bob.identity])
        #expect(snapshot?.remoteParticipantsById[alice.identity!]?.speaking.isSpeaking == true)
        #expect(snapshot?.remoteParticipantsById[bob.identity!]?.speaking.isSpeaking == false)
    }

    @Test("Speaking updates track local participant activity")
    func speakingUpdatesTrackLocalParticipant() {
        var store = NativeMatrixRTCCallParticipantStore(roomId: roomId)
        let spokeAt = Date(timeIntervalSince1970: 3_000)

        _ = store.setLocalIdentity(localParticipant.identity)

        var snapshot = store.apply(.speakingParticipantsChanged([
            speakingParticipant(
                identity: localParticipant.identity,
                sid: localParticipant.sid,
                lastSpokeAt: spokeAt
            )
        ]))

        #expect(snapshot?.localSpeaking.isSpeaking == true)
        #expect(snapshot?.localSpeaking.lastSpokeAt == spokeAt)

        snapshot = store.apply(.speakingParticipantsChanged([]))

        #expect(snapshot?.localSpeaking.isSpeaking == false)
        #expect(snapshot?.localSpeaking.lastSpokeAt == spokeAt)
    }
}

private let roomId = "!room:example.org"

private let localParticipant = MatrixRTCLiveKitParticipantInfo(
    identity: "@me:example.org:DEVICE",
    sid: "local-sid"
)

private func remoteParticipant(
    identity: String,
    sid: String
) -> MatrixRTCLiveKitParticipantInfo {
    MatrixRTCLiveKitParticipantInfo(identity: identity, sid: sid)
}

private func trackPublication(
    sid: String,
    name: String = "camera",
    kind: String = "video",
    source: String = "camera",
    isMuted: Bool = false,
    isSubscribed: Bool = true
) -> MatrixRTCLiveKitTrackPublicationInfo {
    MatrixRTCLiveKitTrackPublicationInfo(
        sid: sid,
        name: name,
        kind: kind,
        source: source,
        isMuted: isMuted,
        isSubscribed: isSubscribed
    )
}

private func speakingParticipant(
    identity: String?,
    sid: String?,
    isSpeaking: Bool = true,
    audioLevel: Float = 0.7,
    lastSpokeAt: Date
) -> MatrixRTCLiveKitSpeakingParticipantInfo {
    MatrixRTCLiveKitSpeakingParticipantInfo(
        identity: identity,
        sid: sid,
        isSpeaking: isSpeaking,
        audioLevel: audioLevel,
        lastSpokeAt: lastSpokeAt
    )
}
