//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import SwiftUI

@MainActor
final class CryptoDiagnosticsViewModel: ObservableObject {
    @Published var output = "Ready. Generate a safe snapshot first.\n"
    @Published var isBusy = false
    @Published var storeWasOpened = false
    @Published var lastSnapshot = ""

    @Published var showConfirm = false
    @Published var showRestartPrompt = false
    @Published var showShareSheet = false
    @Published var showShareLogsConfirm = false
    @Published var pendingTitle = ""
    @Published var pendingMessage = ""
    @Published var shareItems: [Any] = []

    private var pendingPerform: (() -> String)?
    private var pendingExitAfterRun = false
    private var pendingLogFiles: [URL] = []

    var destructiveActionsDisabled: Bool {
        isBusy || storeWasOpened
    }

    func generateSafeSnapshot() {
        let snapshot = CryptoDiagnosticsService.safeSnapshot()
        lastSnapshot = snapshot
        log("Safe snapshot", snapshot)
    }

    func inspect(_ title: String, _ body: () -> String) {
        log(title, body())
    }

    func copySnapshot() {
        let snapshot = lastSnapshot.isEmpty ? CryptoDiagnosticsService.safeSnapshot() : lastSnapshot
        lastSnapshot = snapshot
        UIPasteboard.general.string = snapshot
        log("Copy snapshot", "Copied \(snapshot.count) characters to pasteboard.")
    }

    func shareSnapshot() {
        let snapshot = lastSnapshot.isEmpty ? CryptoDiagnosticsService.safeSnapshot() : lastSnapshot
        lastSnapshot = snapshot
        shareItems = [snapshot]
        showShareSheet = true
    }

    func tracingStatus() {
        log("Rust SDK tracing", CryptoDiagnosticsService.tracingStatusReport())
    }

    func shareLogs() {
        let files = CryptoDiagnosticsService.tracingLogFiles()
        guard !files.isEmpty else {
            log("Share logs", "No SDK log files yet. Run the app normally first so tracing can write some.")
            return
        }
        pendingLogFiles = files
        showShareLogsConfirm = true
    }

    func confirmShareLogs() {
        shareItems = pendingLogFiles
        pendingLogFiles = []
        showShareSheet = true
    }

    func clearLogs() {
        log("Clear logs", CryptoDiagnosticsService.clearTracingLogs())
    }

    func clearOutput() {
        output = "Output cleared.\n"
    }

    func readIdentity() {
        runOpeningStoreTask(title: "Read local device identity") {
            await CryptoDiagnosticsService.readIdentity()
        }
    }

    func compareStoredFingerprintWithServer() {
        runNetworkTask(title: "Stored fingerprint vs server") {
            await CryptoDiagnosticsService.compareStoredFingerprintWithServer()
        }
    }

    func compareLocalIdentityWithServer() {
        runOpeningStoreTask(title: "Local identity vs server") {
            await CryptoDiagnosticsService.compareLocalIdentityWithServer()
        }
    }

    func requestDestructive(
        title: String,
        message: String,
        exitAfterRun: Bool = false,
        perform: @escaping () -> String
    ) {
        pendingTitle = title
        pendingMessage = message
        pendingPerform = perform
        pendingExitAfterRun = exitAfterRun
        showConfirm = true
    }

    func confirmDestructive() {
        let title = pendingTitle
        let perform = pendingPerform
        let exitAfterRun = pendingExitAfterRun
        pendingPerform = nil
        pendingExitAfterRun = false

        guard let perform else { return }
        log(title, perform())

        if exitAfterRun {
            exit(0)
        } else {
            showRestartPrompt = true
        }
    }

    private func runNetworkTask(title: String, operation: @escaping () async -> String) {
        isBusy = true
        Task {
            let result = await operation()
            log(title, result)
            isBusy = false
        }
    }

    private func runOpeningStoreTask(title: String, operation: @escaping () async -> String) {
        let willOpenStore = CryptoDiagnosticsService.localIdentityReadWouldOpenStore()
        isBusy = true
        Task {
            let result = await operation()
            log(title, result)
            if willOpenStore {
                storeWasOpened = true
            }
            isBusy = false
        }
    }

    private func log(_ title: String, _ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        output = "[\(stamp)] \(title)\n\(message)\n\n" + output
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct CryptoDiagnosticsView: View {
    @StateObject private var viewModel = CryptoDiagnosticsViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    safeSection
                    serverSection
                    logsSection
                    destructiveSection
                    advancedSection
                }
                .listStyle(.insetGrouped)

                if viewModel.isBusy {
                    ProgressView()
                        .padding(.vertical, 8)
                }

                outputView
            }
            .navigationTitle("Crypto Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Exit", role: .destructive) {
                        exit(0)
                    }
                }
            }
        }
        .alert(viewModel.pendingTitle, isPresented: $viewModel.showConfirm) {
            Button("Run", role: .destructive) { viewModel.confirmDestructive() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(viewModel.pendingMessage)
        }
        .alert("Restart required", isPresented: $viewModel.showRestartPrompt) {
            Button("Exit now", role: .destructive) { exit(0) }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Quit and relaunch before opening the normal app or running another destructive operation.")
        }
        .alert("Share SDK logs?", isPresented: $viewModel.showShareLogsConfirm) {
            Button("Share", role: .destructive) { viewModel.confirmShareLogs() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("SDK logs can contain Matrix metadata such as user IDs, room IDs, event IDs, device IDs, session IDs, and server names. Do not share them publicly.")
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            CryptoDiagnosticsActivityView(activityItems: viewModel.shareItems)
        }
    }

    private var safeSection: some View {
        Section("Safe reports") {
            Button("Generate safe snapshot") {
                viewModel.generateSafeSnapshot()
            }
            Button("Copy snapshot") {
                viewModel.copySnapshot()
            }
            Button("Share snapshot") {
                viewModel.shareSnapshot()
            }
            Button("Store health") {
                viewModel.inspect("Store health", CryptoDiagnosticsService.storeHealthSnapshot)
            }
            Button("NSE readiness") {
                viewModel.inspect("NSE readiness", CryptoDiagnosticsService.nseReadinessReport)
            }
            Button("Keychain session") {
                viewModel.inspect("Keychain session", CryptoDiagnosticsService.inspectKeychainSession)
            }
            Button("UserDefaults markers") {
                viewModel.inspect("UserDefaults markers", CryptoDiagnosticsService.inspectUserDefaults)
            }
        }
    }

    private var serverSection: some View {
        Section("Identity checks") {
            Button("Stored fingerprint vs server") {
                viewModel.compareStoredFingerprintWithServer()
            }
            .disabled(viewModel.isBusy)

            Button("Local identity vs server") {
                viewModel.compareLocalIdentityWithServer()
            }
            .disabled(viewModel.isBusy)

            Button("Read local identity") {
                viewModel.readIdentity()
            }
            .disabled(viewModel.isBusy)

            if viewModel.storeWasOpened {
                Text("Store was opened. Destructive operations are disabled until restart.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destructiveSection: some View {
        Section("Post-fix / destructive") {
            Button("Post-fix missing-store test", role: .destructive) {
                viewModel.requestDestructive(
                    title: "Post-fix missing-store test",
                    message: "Deletes all known Matrix store directories, keeps keychain, then exits. Next normal launch should clear the saved session instead of resurrecting the same deviceId.",
                    exitAfterRun: true,
                    perform: CryptoDiagnosticsService.preparePostFixMissingCryptoStoreTest
                )
            }
            .disabled(viewModel.destructiveActionsDisabled)

            Button("Wipe crypto store, keep keychain", role: .destructive) {
                viewModel.requestDestructive(
                    title: "Wipe crypto store, keep keychain",
                    message: "Deletes all known Matrix store directories but keeps the keychain session and passphrase.",
                    perform: CryptoDiagnosticsService.wipeCryptoStoreKeepKeychain
                )
            }
            .disabled(viewModel.destructiveActionsDisabled)

            Button("Wipe keychain session, keep store", role: .destructive) {
                viewModel.requestDestructive(
                    title: "Wipe keychain session, keep store",
                    message: "Clears Matrix session keychain entries while leaving the local Matrix store in place.",
                    perform: CryptoDiagnosticsService.wipeKeychainSessionKeepStore
                )
            }
            .disabled(viewModel.destructiveActionsDisabled)

            Button("Wipe everything", role: .destructive) {
                viewModel.requestDestructive(
                    title: "Wipe everything",
                    message: "Removes Matrix stores, session/passphrase keychains, shared lastUserId, and com.zyna.* defaults.",
                    perform: CryptoDiagnosticsService.wipeEverything
                )
            }
            .disabled(viewModel.destructiveActionsDisabled)
        }
    }

    private var logsSection: some View {
        Section("SDK logs (rust tracing)") {
            Button("Tracing status") {
                viewModel.tracingStatus()
            }
            Button("Share logs") {
                viewModel.shareLogs()
            }
            Button("Clear logs", role: .destructive) {
                viewModel.clearLogs()
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced destructive") {
                Button("Corrupt crypto DB header", role: .destructive) {
                    viewModel.requestDestructive(
                        title: "Corrupt crypto DB header",
                        message: "Overwrites the first bytes of every known matrix-sdk-crypto.sqlite3. This intentionally damages the local crypto store.",
                        perform: CryptoDiagnosticsService.corruptCryptoDb
                    )
                }
                .disabled(viewModel.destructiveActionsDisabled)
            }
        }
    }

    private var outputView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    viewModel.clearOutput()
                }
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))

            ScrollView {
                Text(viewModel.output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(height: 260)
        .background(Color(.secondarySystemBackground))
    }
}

private struct CryptoDiagnosticsActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
