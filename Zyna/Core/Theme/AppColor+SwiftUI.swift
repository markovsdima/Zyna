//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// SwiftUI mirror of `AppColor`, kept partial on purpose — add tokens as
/// screens need them. The `UIColor`s underneath are dynamic, so these
/// re-resolve on light/dark switches like their UIKit twins.
extension Color {

    /// Also the glass clear color; keep the two in step.
    static let appBackground = Color(uiColor: .appBG)

    static let appAccent = Color(uiColor: AppColor.accent)
    static let appOnAccent = Color(uiColor: AppColor.onAccent)
    static let appDestructive = Color(uiColor: AppColor.destructive)
}
