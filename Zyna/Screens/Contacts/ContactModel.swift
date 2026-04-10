//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

struct ContactModel {
    let userId: String
    let displayName: String
    let avatar: AvatarViewModel
    /// Room ID of the existing DM, nil if no chat yet.
    let roomId: String?
}
