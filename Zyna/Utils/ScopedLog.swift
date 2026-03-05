//
//  ScopedLog.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 05.03.2026.
//

import Foundation
import os.log

// MARK: - Log Scope (OptionSet)

struct LogScope: OptionSet {
    let rawValue: UInt64

    // MARK: - Private helper

    /// Returns the bit mask for a given position.
    /// Asserts if the bit index is out of range (0-63).
    private static func bit(_ n: UInt64) -> UInt64 {
        assert(n < 64, "LogScope only supports bits 0-63")
        return 1 << n
    }

    // MARK: - Scopes

    static let auth        = LogScope(rawValue: bit(0))
    static let sync        = LogScope(rawValue: bit(1))
    static let rooms       = LogScope(rawValue: bit(2))
    static let timeline    = LogScope(rawValue: bit(3))
    static let keychain    = LogScope(rawValue: bit(4))
    static let navigation  = LogScope(rawValue: bit(5))
    static let media       = LogScope(rawValue: bit(6))
    static let crypto      = LogScope(rawValue: bit(7))
    static let ui          = LogScope(rawValue: bit(8))

    // MARK: - Presets

    static let all: LogScope = [
        .auth,
        .sync,
        .rooms,
        .timeline,
        .keychain,
        .navigation,
        .media,
        .crypto,
        .ui
    ]

    static let none: LogScope = []
}

// MARK: - Team Member Presets

fileprivate enum Dmitry {
    static let base: LogScope = .all
}

// MARK: - Global Log Configuration

enum LogConfig {
    /// Enabled logging scopes
    ///
    /// Examples:
    /// - .messageSend
    /// - .all
    /// - .none
    /// - [.messageSend, .calls]
    /// - .all.subtracting(.network)
    /// - .all.subtracting([.network, .calls])
    static var enabled: LogScope = Dmitry.base

    static func enableAll() { enabled = .all }
    static func disableAll() { enabled = .none }
}

// MARK: - Scoped Logger

struct ScopedLog {

    /// Determines how multiple scopes are evaluated.
    enum Mode {
        /// Log if **at least one** of the specified scopes is enabled
        case any
        /// Log only if **all** of the specified scopes are enabled
        case all
    }

    let scope: LogScope
    let prefix: String
    let mode: Mode

    /// - Parameters:
    ///   - scope: Single or multiple scopes to log
    ///   - prefix: Optional prefix for logs. Defaults to scope names.
    ///   - mode: Determines how multiple scopes are evaluated. Defaults to `.any`.
    init(_ scope: LogScope, prefix: String? = nil, mode: Mode = .any) {
        self.scope = scope
        self.prefix = prefix ?? "[\(scope.name)]"
        self.mode = mode
    }

    func callAsFunction(_ message: String) {
#if DEBUG
        let shouldLog: Bool
        switch mode {
        case .any:
            shouldLog = !scope.intersection(LogConfig.enabled).isEmpty
        case .all:
            shouldLog = scope.isSubset(of: LogConfig.enabled)
        }

        guard shouldLog else { return }
        os_log("%{public}s %{public}s", log: .default, type: .debug, prefix, message)
#endif
    }

}

// MARK: - Scope Naming

private extension LogScope {
    var name: String {
        var names: [String] = []
        if contains(.auth)       { names.append("auth") }
        if contains(.sync)       { names.append("sync") }
        if contains(.rooms)      { names.append("rooms") }
        if contains(.timeline)   { names.append("timeline") }
        if contains(.keychain)   { names.append("keychain") }
        if contains(.navigation) { names.append("navigation") }
        if contains(.media)      { names.append("media") }
        if contains(.crypto)     { names.append("crypto") }
        if contains(.ui)         { names.append("ui") }
        return names.isEmpty ? "NONE" : names.joined(separator: "|")
    }
}
