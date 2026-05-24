//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

final class RoomAddToSpaceViewModel {

    let roomName: String

    private(set) var candidates: [RoomSpaceAddCandidate] = []
    private(set) var isLoading = false
    private(set) var addingSpaceId: String?

    var onChanged: (() -> Void)?
    var onAdded: ((RoomSpaceAddCandidate) -> Void)?
    var onError: ((String) -> Void)?

    private let roomId: String
    private let service: RoomSpaceMembershipService
    private var allCandidates: [RoomSpaceAddCandidate] = []
    private var searchQuery = ""
    private var loadTask: Task<Void, Never>?
    private var addTask: Task<Void, Never>?

    init(
        roomId: String,
        roomName: String,
        service: RoomSpaceMembershipService
    ) {
        self.roomId = roomId
        self.roomName = roomName
        self.service = service
    }

    deinit {
        loadTask?.cancel()
        addTask?.cancel()
    }

    var title: String {
        String(localized: "Add to Storyline")
    }

    var subtitle: String {
        String(localized: "Select a Storyline for \(roomName).")
    }

    var emptyMessage: String {
        if isLoading {
            return String(localized: "Loading Storylines...")
        }

        return allCandidates.isEmpty
            ? String(localized: "No Storylines to add")
            : String(localized: "No Storylines found")
    }

    func loadSpaces() {
        loadTask?.cancel()
        isLoading = true
        onChanged?()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await service.loadAddCandidates(for: roomId)
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.isLoading = false
                    self.allCandidates = candidates
                    self.applyFilter()
                    self.onChanged?()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.isLoading = false
                    self.allCandidates = []
                    self.candidates = []
                    self.onChanged?()
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        applyFilter()
        onChanged?()
    }

    func addSpace(at index: Int) {
        guard candidates.indices.contains(index),
              addingSpaceId == nil
        else { return }

        let candidate = candidates[index]
        guard candidate.canAddSpaceSideLink else { return }
        addSpace(candidate)
    }

    private func addSpace(_ candidate: RoomSpaceAddCandidate) {
        addingSpaceId = candidate.id
        onChanged?()

        addTask?.cancel()
        addTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.addRoom(roomId, to: candidate)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.addingSpaceId = nil
                    self.onChanged?()
                    self.onAdded?(candidate)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.addingSpaceId = nil
                    self.onChanged?()
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func applyFilter() {
        guard !searchQuery.isEmpty else {
            candidates = allCandidates
            return
        }

        candidates = allCandidates.filter { candidate in
            candidate.displayName.lowercased().contains(searchQuery)
                || candidate.id.lowercased().contains(searchQuery)
        }
    }
}
