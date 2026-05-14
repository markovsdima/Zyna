//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import MatrixRustSDK

enum RoomSendSecurityIssueKind: Equatable {
    case identityChanged
    case unsignedDevices
    case noPublishedIdentity
    case unknown
}

struct RoomSendSecurityIssue: Identifiable, Equatable {
    let userId: String
    let displayName: String?
    let kind: RoomSendSecurityIssueKind
    let deviceIds: [String]
    let canAcceptIdentityChange: Bool

    var id: String {
        "\(userId)|\(kind)|\(deviceIds.joined(separator: ","))"
    }

    var title: String {
        guard let displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return userId
        }
        return displayName
    }
}

@MainActor
final class RoomSendSecurityViewModel: ObservableObject {
    @Published private(set) var issues: [RoomSendSecurityIssue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var acceptingUserIds = Set<String>()
    @Published var errorMessage: String?

    var onClose: (() -> Void)?
    var onOpenUser: ((String) -> Void)?

    private let room: Room
    private let context: OutgoingSendFailureContext
    private var hasLoaded = false

    init(room: Room, context: OutgoingSendFailureContext) {
        self.room = room
        self.context = context
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load()
    }

    func reload() {
        hasLoaded = true
        load()
    }

    func openUser(_ userId: String) {
        onOpenUser?(userId)
    }

    func acceptIdentityChange(for issue: RoomSendSecurityIssue) {
        guard issue.canAcceptIdentityChange else { return }
        acceptingUserIds.insert(issue.userId)

        Task {
            do {
                guard let identity = try await MatrixClientService.shared.client?
                    .encryption()
                    .userIdentity(userId: issue.userId, fallbackToServer: true)
                else {
                    throw RoomSendSecurityError.identityUnavailable
                }

                if identity.hasVerificationViolation() || identity.wasPreviouslyVerified() {
                    try await identity.withdrawVerification()
                } else {
                    try await identity.pin()
                }

                acceptingUserIds.remove(issue.userId)
                reload()
            } catch {
                acceptingUserIds.remove(issue.userId)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func load() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let members = try await loadMembers()
                let models = await buildIssues(from: members)
                issues = models
                isLoading = false
            } catch {
                issues = []
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadMembers() async throws -> [RoomMember] {
        let iterator = try await room.members()
        return iterator.nextChunk(chunkSize: 10_000) ?? []
    }

    private func buildIssues(from members: [RoomMember]) async -> [RoomSendSecurityIssue] {
        let ownUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        let membersByUserId = members.reduce(into: [String: RoomMember]()) { result, member in
            result[member.userId] = member
        }
        let hintedUserIds = Set(context.affectedUserIds + context.insecureDevicesByUserId.keys)
        let candidateUserIds: [String]

        if hintedUserIds.isEmpty {
            candidateUserIds = members
                .filter { $0.membership == .join || $0.membership == .invite }
                .map(\.userId)
                .filter { $0 != ownUserId }
                .sorted()
        } else {
            candidateUserIds = hintedUserIds
                .filter { $0 != ownUserId }
                .sorted()
        }

        var result: [RoomSendSecurityIssue] = []
        for userId in candidateUserIds {
            let member: RoomMember?
            if let cachedMember = membersByUserId[userId] {
                member = cachedMember
            } else {
                member = try? await room.member(userId: userId)
            }
            let identity = try? await MatrixClientService.shared.client?
                .encryption()
                .userIdentity(userId: userId, fallbackToServer: true)
            let devices = context.insecureDevicesByUserId[userId] ?? []
            let isExplicitIdentityViolation = context.affectedUserIds.contains(userId)
                && context.insecureDevicesByUserId[userId] == nil

            let kind: RoomSendSecurityIssueKind?
            if !devices.isEmpty {
                kind = .unsignedDevices
            } else if isExplicitIdentityViolation {
                kind = .identityChanged
            } else if identity == nil {
                kind = .noPublishedIdentity
            } else if identity?.hasVerificationViolation() == true {
                kind = .identityChanged
            } else if hintedUserIds.isEmpty {
                kind = nil
            } else {
                kind = .unknown
            }

            guard let kind else { continue }

            result.append(
                RoomSendSecurityIssue(
                    userId: userId,
                    displayName: member?.displayName,
                    kind: kind,
                    deviceIds: devices,
                    canAcceptIdentityChange: kind == .identityChanged && identity != nil
                )
            )
        }

        return result.sorted { lhs, rhs in
            if lhs.kind.sortRank != rhs.kind.sortRank {
                return lhs.kind.sortRank < rhs.kind.sortRank
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private enum RoomSendSecurityError: LocalizedError {
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            return String(localized: "Zyna could not load this participant's identity.")
        }
    }
}

struct RoomSendSecurityView: View {
    @ObservedObject var viewModel: RoomSendSecurityViewModel
    @State private var identityChangeToAccept: RoomSendSecurityIssue?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerContent
                }

                if viewModel.isLoading {
                    loadingRow
                } else if viewModel.issues.isEmpty {
                    emptyRow
                } else {
                    Section(String(localized: "Participants To Check")) {
                        ForEach(viewModel.issues) { issue in
                            issueRow(issue)
                        }
                    }
                }

                Section {
                    retryGuidance
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Message Not Sent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) {
                        viewModel.onClose?()
                    }
                }
            }
        }
        .task {
            viewModel.loadIfNeeded()
        }
        .alert(
            String(localized: "Accept Identity Change?"),
            isPresented: Binding(
                get: { identityChangeToAccept != nil },
                set: { if !$0 { identityChangeToAccept = nil } }
            )
        ) {
            Button(String(localized: "Cancel"), role: .cancel) {
                identityChangeToAccept = nil
            }
            Button(String(localized: "Accept Change"), role: .destructive) {
                if let issue = identityChangeToAccept {
                    viewModel.acceptIdentityChange(for: issue)
                }
                identityChangeToAccept = nil
            }
        } message: {
            Text("This accepts the participant's new encryption identity for sending. It does not verify who controls it. Use this only after confirming the change with the participant.")
        }
        .alert(
            String(localized: "Could Not Update Trust"),
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Zyna could not safely share room keys for this message.")
                    .font(.headline)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }

            Text("Check the participants below, resolve the trust issue, then retry the failed message manually.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Checking participant identities…")
                .foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Specific Participant Found")
                .font(.headline)
            Text("The SDK rejected sending, but Zyna could not identify a specific participant from local state. Refresh the room or retry after participants verify their devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var retryGuidance: some View {
        Label {
            Text("Zyna will not retry this message automatically. After the trust issue is fixed, tap the failed message and retry it explicitly.")
                .font(.subheadline)
        } icon: {
            Image(systemName: "arrow.clockwise")
        }
    }

    private func issueRow(_ issue: RoomSendSecurityIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                avatar(title: issue.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title)
                        .font(.headline)
                    Text(issue.userId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(description(for: issue))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !issue.deviceIds.isEmpty {
                deviceList(issue.deviceIds)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.openUser(issue.userId)
                } label: {
                    Label(String(localized: "Open Profile"), systemImage: "person.crop.circle")
                }
                .buttonStyle(.bordered)

                if issue.canAcceptIdentityChange {
                    Button(role: .destructive) {
                        identityChangeToAccept = issue
                    } label: {
                        if viewModel.acceptingUserIds.contains(issue.userId) {
                            ProgressView()
                        } else {
                            Label(String(localized: "Accept Change"), systemImage: "exclamationmark.triangle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.acceptingUserIds.contains(issue.userId))
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func avatar(title: String) -> some View {
        let initial = title.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "?"
        return Text(initial.uppercased())
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.accentColor))
            .accessibilityHidden(true)
    }

    private func deviceList(_ deviceIds: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unsigned devices")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(deviceIds, id: \.self) { deviceId in
                Text(deviceId)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 52)
    }

    private func description(for issue: RoomSendSecurityIssue) -> String {
        switch issue.kind {
        case .identityChanged:
            return String(localized: "This participant's encryption identity changed. Verify them again, or accept the change only after confirming it out of band.")
        case .unsignedDevices:
            return String(localized: "Some devices are not signed by this participant's identity. Ask them to verify those devices.")
        case .noPublishedIdentity:
            return String(localized: "This participant does not have a published encryption identity yet. They need to finish verification or recovery on their account.")
        case .unknown:
            return String(localized: "Zyna could not classify the trust problem for this participant. Open their profile and verify their identity before retrying.")
        }
    }
}

private extension RoomSendSecurityIssueKind {
    var sortRank: Int {
        switch self {
        case .identityChanged:
            return 0
        case .unsignedDevices:
            return 1
        case .noPublishedIdentity:
            return 2
        case .unknown:
            return 3
        }
    }
}
