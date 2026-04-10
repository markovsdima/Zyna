//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import GRDB
import MatrixRustSDK

final class ContactsViewModel {

    @Published private(set) var contacts: [ContactModel] = []
    @Published private(set) var isSearching = false

    var onContactSelected: ((ContactModel) -> Void)?

    private var searchTask: Task<Void, Never>?
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseService.shared.dbQueue) {
        self.dbQueue = dbQueue
        loadDMContacts()
    }

    func selectContact(at index: Int) {
        guard index < contacts.count else { return }
        onContactSelected?(contacts[index])
    }

    // MARK: - Search

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchTask?.cancel()
            loadDMContacts()
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }

            guard let client = MatrixClientService.shared.client else { return }
            do {
                let results = try await client.searchUsers(searchTerm: trimmed, limit: 30)
                guard !Task.isCancelled else { return }

                let currentUserId = try? client.userId()
                let dmRoomMap = self.dmRoomMap()

                let models = results.results
                    .filter { $0.userId != currentUserId }
                    .map { user in
                        ContactModel(
                            userId: user.userId,
                            displayName: user.displayName ?? user.userId,
                            avatar: AvatarViewModel(
                                userId: user.userId,
                                displayName: user.displayName,
                                mxcAvatarURL: user.avatarUrl
                            ),
                            roomId: dmRoomMap[user.userId]
                        )
                    }

                await MainActor.run { self.contacts = models }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.loadDMContacts() }
            }
        }
    }

    // MARK: - Private

    /// Loads contacts from existing DM rooms in GRDB.
    private func loadDMContacts() {
        let results: [ContactModel] = (try? dbQueue.read { db in
            try StoredRoom
                .filter(Column("directUserId") != nil)
                .order(Column("displayName").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
                .map { room in
                    ContactModel(
                        userId: room.directUserId!,
                        displayName: room.displayName,
                        avatar: AvatarViewModel(
                            userId: room.directUserId!,
                            displayName: room.displayName,
                            mxcAvatarURL: room.avatarURL
                        ),
                        roomId: room.id
                    )
                }
        }) ?? []

        contacts = results
    }

    /// Returns a map of userId → roomId for existing DM rooms.
    private func dmRoomMap() -> [String: String] {
        (try? dbQueue.read { db in
            let rooms = try StoredRoom
                .filter(Column("directUserId") != nil)
                .fetchAll(db)
            var map: [String: String] = [:]
            for room in rooms {
                if let userId = room.directUserId {
                    map[userId] = room.id
                }
            }
            return map
        }) ?? [:]
    }
}
