#if os(iOS) || os(visionOS) || os(tvOS)

import AVFoundation
import LiveKit

public enum MatrixRTCLiveKitAudioRouting {
    public static var isSpeakerOutputPreferred: Bool {
        AudioManager.shared.isSpeakerOutputPreferred
    }

    public static func setSpeakerOutputPreferred(_ preferred: Bool) {
        AudioManager.shared.isSpeakerOutputPreferred = preferred
    }

    public static var isBuiltInSpeakerActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .builtInSpeaker
        }
    }
}

#else

public enum MatrixRTCLiveKitAudioRouting {
    public static var isSpeakerOutputPreferred: Bool {
        false
    }

    public static func setSpeakerOutputPreferred(_ preferred: Bool) {}

    public static var isBuiltInSpeakerActive: Bool {
        false
    }
}

#endif
