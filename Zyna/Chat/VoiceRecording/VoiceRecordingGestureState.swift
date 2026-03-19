//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum VoiceRecordingGestureState: Equatable {
    case idle                     // nothing is happening
    case holding                  // finger is holding the button
    case locked                   // swiped up — recording locked
    case slidingToCancel(CGFloat) // swiping left — cancel progress 0...1
    case cancelled                // swipe completed — cancelled
}
