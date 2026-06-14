//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import MatrixRustSDK
import os.log

/// Minimal matrix-rust-sdk tracing bootstrap for the Notification Service
/// Extension. The NSE is a separate process, so the app-side tracing setup
/// does not apply here.
enum NSEMatrixRustSDKTracing {
    private static let lock = NSLock()
    private static var didSetup = false

    private static let appGroupIdentifier = "group.com.app.zyna"
    private static let logLevel: LogLevel = .debug
    private static let extraTargets = [
        "matrix_sdk_crypto",
        "matrix_sdk_crypto::backups",
        "matrix_sdk_crypto::store",
        "matrix_sdk::encryption",
        "matrix_sdk_ui::notification_client"
    ]

    private static var shouldWriteToSystemLog: Bool {
        let value = ProcessInfo.processInfo.environment["ZYNA_RUST_TRACING_STDOUT"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    private static var logsDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("logs", isDirectory: true)
    }

    static func setupOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !didSetup else { return }

        guard let directory = logsDirectory else {
            os_log("%{public}@", log: .default, type: .error, "[nse-tracing] App Group container unavailable")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableDirectory.setResourceValues(values)
        } catch {
            os_log("%{public}@", log: .default, type: .error, "[nse-tracing] failed to create logs dir: \(error)")
            return
        }

        let fileConfig = TracingFileConfiguration(
            path: directory.path,
            filePrefix: "zyna-nse",
            fileSuffix: ".log",
            maxTotalSizeBytes: 64 * 1024 * 1024,
            maxAgeSeconds: 7 * 24 * 60 * 60
        )

        let config = TracingConfiguration(
            logLevel: logLevel,
            traceLogPacks: [.notificationClient],
            extraTargets: extraTargets,
            writeToStdoutOrSystem: shouldWriteToSystemLog,
            writeToFiles: fileConfig,
            sentryConfig: nil
        )

        do {
            try initPlatform(config: config, useLightweightTokioRuntime: true)
            didSetup = true
            os_log("%{public}@", log: .default, type: .default, "[nse-tracing] initialized; logs at \(directory.path)")
        } catch {
            os_log("%{public}@", log: .default, type: .error, "[nse-tracing] initPlatform failed: \(error)")
        }
    }
}
#endif
