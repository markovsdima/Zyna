//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

/// Temporary brand switch for white-label builds.
/// When a second Xcode target is set up for App Store
/// distribution, this enum will be replaced by per-target
/// configuration (separate Info.plist, assets, xcconfig).
enum Brand {
    case zyna
    case sds

    static let current: Brand = .sds

    var defaultHomeserver: String {
        switch self {
        case .zyna: return "matrix.org"
        case .sds:  return ""
        }
    }

    var theme: AppTheme {
        switch self {
        case .zyna: return ZynaTheme()
        case .sds:  return SDSTheme()
        }
    }
}
