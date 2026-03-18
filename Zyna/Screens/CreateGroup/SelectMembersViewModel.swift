//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

final class SelectMembersViewModel {

    @Published private(set) var searchResults: [UserProfile] = []
    @Published private(set) var selectedUsers: [UserProfile] = []

    var onNext: (([UserProfile]) -> Void)?

    private var searchTask: Task<Void, Never>?

    func searchUsers(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            searchResults = []
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            guard let client = MatrixClientService.shared.client else { return }
            do {
                let results = try await client.searchUsers(searchTerm: trimmed, limit: 20)
                if !Task.isCancelled {
                    let currentUserId = try? client.userId()
                    await MainActor.run {
                        self.searchResults = results.results.filter { $0.userId != currentUserId }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { self.searchResults = [] }
                }
            }
        }
    }

    func toggleUser(_ user: UserProfile) {
        if let idx = selectedUsers.firstIndex(where: { $0.userId == user.userId }) {
            selectedUsers.remove(at: idx)
        } else {
            selectedUsers.append(user)
        }
    }

    func isSelected(_ user: UserProfile) -> Bool {
        selectedUsers.contains { $0.userId == user.userId }
    }

    func removeUser(_ user: UserProfile) {
        selectedUsers.removeAll { $0.userId == user.userId }
    }

    func proceed() {
        onNext?(selectedUsers)
    }
}
