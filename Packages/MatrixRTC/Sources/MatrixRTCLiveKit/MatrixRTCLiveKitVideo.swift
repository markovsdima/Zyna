import CoreGraphics
import Foundation
import LiveKit

public final class MatrixRTCLiveKitRemoteVideoTrack: @unchecked Sendable, Equatable {
    public let participantIdentity: String?
    public let participantSid: String?
    public let trackSid: String
    public let trackName: String

    weak var videoTrack: RemoteVideoTrack?

    public var id: String {
        "\(participantIdentity ?? participantSid ?? "unknown"):\(trackSid)"
    }

    init(
        participant: RemoteParticipant,
        publication: RemoteTrackPublication,
        videoTrack: RemoteVideoTrack
    ) {
        self.participantIdentity = participant.identity?.stringValue
        self.participantSid = participant.sid?.stringValue
        self.trackSid = publication.sid.stringValue
        self.trackName = publication.name
        self.videoTrack = videoTrack
    }

    public static func == (
        lhs: MatrixRTCLiveKitRemoteVideoTrack,
        rhs: MatrixRTCLiveKitRemoteVideoTrack
    ) -> Bool {
        lhs.id == rhs.id
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

    public func setRemoteVideoTrack(_ remoteVideoTrack: MatrixRTCLiveKitRemoteVideoTrack?) {
        videoView.track = remoteVideoTrack?.videoTrack
    }

    override public func performLayout() {
        super.performLayout()
        videoView.frame = bounds
    }
}
