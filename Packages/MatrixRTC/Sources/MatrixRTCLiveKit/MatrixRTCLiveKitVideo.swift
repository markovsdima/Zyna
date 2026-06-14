import CoreGraphics
import Foundation
import LiveKit

public final class MatrixRTCLiveKitLocalVideoTrack: @unchecked Sendable, Equatable {
    public let trackSid: String
    public let trackName: String

    weak var videoTrack: LocalVideoTrack?

    public var id: String {
        "local:\(trackSid)"
    }

    private init(
        trackSid: String,
        trackName: String,
        videoTrack: LocalVideoTrack?
    ) {
        self.trackSid = trackSid
        self.trackName = trackName
        self.videoTrack = videoTrack
    }

    convenience init(publication: LocalTrackPublication, videoTrack: LocalVideoTrack) {
        self.init(
            trackSid: publication.sid.stringValue,
            trackName: publication.name,
            videoTrack: videoTrack
        )
    }

    public static func == (
        lhs: MatrixRTCLiveKitLocalVideoTrack,
        rhs: MatrixRTCLiveKitLocalVideoTrack
    ) -> Bool {
        lhs.id == rhs.id
    }
}

@_spi(Testing) public extension MatrixRTCLiveKitLocalVideoTrack {
    static func testing(
        trackSid: String,
        trackName: String = ""
    ) -> MatrixRTCLiveKitLocalVideoTrack {
        MatrixRTCLiveKitLocalVideoTrack(
            trackSid: trackSid,
            trackName: trackName,
            videoTrack: nil
        )
    }
}

public final class MatrixRTCLiveKitRemoteVideoTrack: @unchecked Sendable, Equatable {
    public let participantIdentity: String?
    public let participantSid: String?
    public let trackSid: String
    public let trackName: String

    weak var videoTrack: RemoteVideoTrack?

    public var id: String {
        "\(participantIdentity ?? participantSid ?? "unknown"):\(trackSid)"
    }

    private init(
        participantIdentity: String?,
        participantSid: String?,
        trackSid: String,
        trackName: String,
        videoTrack: RemoteVideoTrack?
    ) {
        self.participantIdentity = participantIdentity
        self.participantSid = participantSid
        self.trackSid = trackSid
        self.trackName = trackName
        self.videoTrack = videoTrack
    }

    convenience init(
        participant: RemoteParticipant,
        publication: RemoteTrackPublication,
        videoTrack: RemoteVideoTrack
    ) {
        self.init(
            participantIdentity: participant.identity?.stringValue,
            participantSid: participant.sid?.stringValue,
            trackSid: publication.sid.stringValue,
            trackName: publication.name,
            videoTrack: videoTrack
        )
    }

    public static func == (
        lhs: MatrixRTCLiveKitRemoteVideoTrack,
        rhs: MatrixRTCLiveKitRemoteVideoTrack
    ) -> Bool {
        lhs.id == rhs.id
    }
}

@_spi(Testing) public extension MatrixRTCLiveKitRemoteVideoTrack {
    static func testing(
        participantIdentity: String?,
        participantSid: String? = nil,
        trackSid: String,
        trackName: String = ""
    ) -> MatrixRTCLiveKitRemoteVideoTrack {
        MatrixRTCLiveKitRemoteVideoTrack(
            participantIdentity: participantIdentity,
            participantSid: participantSid,
            trackSid: trackSid,
            trackName: trackName,
            videoTrack: nil
        )
    }
}

public final class MatrixRTCLiveKitVideoView: NativeView {
    private let videoView = VideoView()

    override public init(frame: CGRect = .zero) {
        super.init(frame: frame)
        addSubview(videoView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var layoutMode: VideoView.LayoutMode {
        get { videoView.layoutMode }
        set { videoView.layoutMode = newValue }
    }

    public var mirrorMode: VideoView.MirrorMode {
        get { videoView.mirrorMode }
        set { videoView.mirrorMode = newValue }
    }

    public func setLocalVideoTrack(_ localVideoTrack: MatrixRTCLiveKitLocalVideoTrack?) {
        videoView.track = localVideoTrack?.videoTrack
    }

    public func setRemoteVideoTrack(_ remoteVideoTrack: MatrixRTCLiveKitRemoteVideoTrack?) {
        videoView.track = remoteVideoTrack?.videoTrack
    }

    override public func performLayout() {
        super.performLayout()
        videoView.frame = bounds
    }
}
