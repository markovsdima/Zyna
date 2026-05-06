//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

private let logProfile = ScopedLog(.ui, prefix: "[Profile]")

enum ProfileMode {
    case own
    case other(userId: String)
}

final class ProfileViewModel {

    let mode: ProfileMode

    @Published private(set) var displayName: String?
    @Published private(set) var userId: String = ""
    @Published private(set) var avatar: AvatarViewModel?
    @Published private(set) var isEditing = false
    @Published private(set) var isSaving = false
    @Published private(set) var presence: UserPresence?

    var onLogout: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(mode: ProfileMode) {
        self.mode = mode
    }

    // MARK: - Load

    func load() {
        switch mode {
        case .own:       loadOwnProfile()
        case .other(let userId): loadOtherProfile(userId: userId)
        }
    }

    private func loadOwnProfile() {
        guard let client = MatrixClientService.shared.client else { return }
        Task { @MainActor in
            let uid = try? client.userId()
            let name = try? await client.displayName()
            let mxcUrl = try? await client.avatarUrl()
            logProfile("Loaded own profile uid=\(uid ?? "nil") hasName=\(name != nil) hasAvatar=\(mxcUrl != nil)")
            self.userId = uid ?? ""
            self.displayName = name
            if let uid {
                OwnProfileCache.shared.setDisplayName(name, userId: uid)
            }
            self.avatar = AvatarViewModel(userId: uid ?? "", displayName: name, mxcAvatarURL: mxcUrl)
        }
    }

    private func loadOtherProfile(userId: String) {
        guard let client = MatrixClientService.shared.client else { return }
        Task { @MainActor in
            self.userId = userId
            let profile = try? await client.getProfile(userId: userId)
            self.displayName = profile?.displayName
            self.avatar = AvatarViewModel(
                userId: userId,
                displayName: profile?.displayName,
                mxcAvatarURL: profile?.avatarUrl
            )
        }

        PresenceTracker.shared.register(userIds: [userId], for: "profile")
        PresenceTracker.shared.$statuses
            .map { $0[userId] }
            .receive(on: DispatchQueue.main)
            .assign(to: &$presence)
    }

    // MARK: - Edit (own profile only)

    func toggleEditing() {
        guard case .own = mode else { return }
        isEditing.toggle()
    }

    func cancelEditing() {
        isEditing = false
        load()
    }

    func save(displayName: String?, avatarData: Data?) {
        guard case .own = mode, let client = MatrixClientService.shared.client else { return }
        isSaving = true
        Task { @MainActor in
            if let name = displayName {
                do {
                    try await client.setDisplayName(name: name)
                    if let userId = try? client.userId() {
                        OwnProfileCache.shared.setDisplayName(name, userId: userId)
                    }
                } catch {
                    logProfile("Display name save failed: \(error)")
                }
            }
            if let data = avatarData {
                do {
                    try await client.uploadAvatar(mimeType: "image/jpeg", data: data)
                    logProfile("Avatar uploaded")
                } catch {
                    logProfile("Avatar upload failed: \(error)")
                }
            }
            self.isSaving = false
            self.isEditing = false
            try? await Task.sleep(for: .seconds(1))
            self.load()
        }
    }

    // MARK: - Logout

    func logout() {
        onLogout?()
    }

    // MARK: - Cleanup

    func cleanup() {
        if case .other(let userId) = mode {
            PresenceTracker.shared.unregister(for: "profile")
            _ = userId
        }
    }
}
