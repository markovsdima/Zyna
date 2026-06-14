//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import MatrixRustSDK
import os.log

/// Initializes matrix-rust-sdk's internal tracing once per process and writes
/// rotated log files to a known directory. DEBUG-only.
///
/// Without this, the SDK's crypto logs (key sharing, Olm, withheld codes,
/// backup, verification) are never written anywhere - only the Swift-side
/// `os_log` and the UTD delegate are visible. Enabling file tracing means that
/// when any crypto breakage happens during normal use, the SDK trace is already
/// captured and can be collected from the diagnostics tool.
///
/// Must be called before the first Matrix `Client` is built - see
/// `AppDelegate`. `initPlatform` is a process-global, one-time setup.
enum MatrixRustSDKTracing {

    private static let lock = NSLock()
    private static var didSetup = false
    private static var setupError: String?
    private static var setupProcessName: String?

    /// Global log level. `.debug` is a good signal/noise default that still
    /// includes crypto key-sharing / UTD events. Bump to `.trace` for maximum
    /// verbosity when chasing a hard crypto bug.
    private static let logLevel: LogLevel = .debug

    /// Crypto-relevant targets forced to the global level even if the SDK pins
    /// them lower by default. Unknown target names are harmless no-ops.
    private static let extraTargets = [
        "matrix_sdk_crypto",
        "matrix_sdk_crypto::backups",
        "matrix_sdk_crypto::store",
        "matrix_sdk::encryption"
    ]

    static var isInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return didSetup
    }

    private static var shouldWriteToSystemLog: Bool {
        let value = ProcessInfo.processInfo.environment["ZYNA_RUST_TRACING_STDOUT"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Directory holding the rotated `.log` files. Prefers the App Group
    /// container (so NSE logs could land alongside) with a sandbox fallback,
    /// mirroring where the Matrix store lives.
    static var logsDirectory: URL {
        let base = ZynaSecurityConfig.appGroupContainerURL() ?? LocalDataProtection.appSupportRoot()
        return base.appendingPathComponent("logs", isDirectory: true)
    }

    static func setupOnce(
        processName: String = "app",
        useLightweightTokioRuntime: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didSetup else { return }

        let directory = logsDirectory
        do {
            try LocalDataProtection.createProtectedDirectory(
                at: directory,
                protection: .backgroundReadable,
                excludeFromBackup: true
            )
        } catch {
            let message = "failed to create logs dir: \(error)"
            setupError = message
            os_log("%{public}@", log: .default, type: .error, "[tracing] \(message)")
            return
        }

        let fileConfig = TracingFileConfiguration(
            path: directory.path,
            filePrefix: "zyna-\(processName)",
            fileSuffix: ".log",
            maxTotalSizeBytes: 64 * 1024 * 1024, // 64 MB total, rotated
            maxAgeSeconds: 7 * 24 * 60 * 60 // one week
        )

        let config = TracingConfiguration(
            logLevel: logLevel,
            traceLogPacks: [],
            extraTargets: extraTargets,
            writeToStdoutOrSystem: shouldWriteToSystemLog,
            writeToFiles: fileConfig,
            sentryConfig: nil
        )

        do {
            try initPlatform(config: config, useLightweightTokioRuntime: useLightweightTokioRuntime)
            didSetup = true
            setupError = nil
            setupProcessName = processName
            os_log("%{public}@", log: .default, type: .default, "[tracing] initialized process=\(processName); logs at \(directory.path)")
        } catch {
            setupError = "initPlatform failed: \(error)"
            os_log("%{public}@", log: .default, type: .error, "[tracing] initPlatform failed: \(error)")
        }
    }

    /// Log files sorted newest-first.
    static func logFiles() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsSubdirectoryDescendants
        ) else {
            return []
        }
        return items
            .filter {
                $0.lastPathComponent.hasPrefix("zyna-") && $0.lastPathComponent.hasSuffix(".log")
            }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
    }

    static func clearLogs() -> String {
        let files = logFiles()
        guard !files.isEmpty else { return "No log files to clear in \(logsDirectory.path)." }
        var removed = 0
        for file in files {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return "Cleared \(removed)/\(files.count) log files.\nNote: the active writer may recreate its file on the next SDK log."
    }

    static func statusReport() -> String {
        let files = logFiles()
        let totalBytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var out = "Rust SDK tracing\n"
        out += "initialized=\(isInitialized)\n"
        out += "process=\(setupProcessName ?? "<nil>")\n"
        out += "logLevel=\(logLevel)\n"
        out += "writeToStdoutOrSystem=\(shouldWriteToSystemLog)\n"
        out += "directory=\(logsDirectory.path)\n"
        out += "lastError=\(setupError ?? "<nil>")\n"
        out += "fileCount=\(files.count) totalSize=\(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))\n"
        if files.isEmpty {
            out += "files=<none yet>"
        } else {
            out += "files:\n"
            for file in files.prefix(10) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                out += "  \(file.lastPathComponent)  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))\n"
            }
        }
        return out
    }
}
#endif
