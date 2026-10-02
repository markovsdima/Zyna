// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

/// Navigation keeps route identities; only a small tail owns expensive UI.
@MainActor
protocol NavigationResidentScreen: AnyObject {
    func materializeContent()
    func releaseContent()
    func setContentVisible(_ visible: Bool)
}
