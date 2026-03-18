//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

final class StartChatViewModel {

    @Published private(set) var users: [UserProfile] = []
    @Published private(set) var isSearching = false

    var onDMReady: ((Room) -> Void)?
    var onNewGroup: (() -> Void)?
    var onError: ((String) -> Void)?

    private var searchTask: Task<Void, Never>?
    private let roomListService: ZynaRoomListService

    init(roomListService: ZynaRoomListService) {
        self.roomListService = roomListService
    }

    func searchUsers(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            users = []
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }

            guard let client = MatrixClientService.shared.client else { return }
            do {
                let results = try await client.searchUsers(searchTerm: trimmed, limit: 20)
                if !Task.isCancelled {
                    // Filter out self
                    let currentUserId = try? client.userId()
                    await MainActor.run {
                        self.users = results.results.filter { $0.userId != currentUserId }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { self.users = [] }
                }
            }
        }
    }

    func selectUser(_ user: UserProfile) {
        Task {
            guard let client = MatrixClientService.shared.client else { return }
            do {
                // Check existing DM
                if let existingRoom = try client.getDmRoom(userId: user.userId) {
                    await MainActor.run { onDMReady?(existingRoom) }
                    return
                }

                // Create new DM
                let params = CreateRoomParameters(
                    name: nil,
                    topic: nil,
                    isEncrypted: true,
                    isDirect: true,
                    visibility: .private,
                    preset: .trustedPrivateChat,
                    invite: [user.userId],
                    avatar: nil,
                    powerLevelContentOverride: nil,
                    joinRuleOverride: nil,
                    historyVisibilityOverride: nil,
                    canonicalAlias: nil
                )
                let roomId = try await client.createRoom(request: params)

                // Find Room object from list service
                if let room = roomListService.room(for: roomId) {
                    await MainActor.run { onDMReady?(room) }
                }
            } catch {
                await MainActor.run { onError?("Failed to create chat: \(error.localizedDescription)") }
            }
        }
    }

    func newGroupTapped() {
        onNewGroup?()
    }
}
