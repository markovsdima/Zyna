//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation

/// Decides whether the app launches into the crypto diagnostics tool
/// instead of the normal messenger UI. DEBUG-only.
///
/// Toggle via the Xcode scheme without recompiling:
/// Run > Arguments > "Arguments Passed On Launch": `-zynaDiagnostics 1`,
/// or set `ZYNA_DIAGNOSTICS=1` in the environment.
enum CryptoDiagnosticsGate {
    static var isEnabled: Bool {
        hasLaunchArgument("-zynaDiagnostics") || isTruthyEnvironmentValue("ZYNA_DIAGNOSTICS")
    }

    static func isTruthyEnvironmentValue(_ name: String) -> Bool {
        isTruthy(ProcessInfo.processInfo.environment[name])
    }

    private static func hasLaunchArgument(_ name: String) -> Bool {
        for argument in ProcessInfo.processInfo.arguments {
            if argument == name {
                return true
            }

            if argument.hasPrefix("\(name)=") {
                return isTruthy(argument.dropFirst(name.count + 1))
            }

            if argument.hasPrefix("\(name) ") {
                return isTruthy(argument.dropFirst(name.count + 1))
            }
        }
        return false
    }

    private static func isTruthy<S: StringProtocol>(_ value: S?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}
#endif
