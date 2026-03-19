//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

final class CreateGroupViewModel {

    let members: [UserProfile]
    var roomName = ""
    var roomTopic = ""

    var onRoomCreated: ((Room) -> Void)?
    var onError: ((String) -> Void)?

    private let roomListService: ZynaRoomListService

    init(members: [UserProfile], roomListService: ZynaRoomListService) {
        self.members = members
        self.roomListService = roomListService
    }

    func createRoom() {
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            onError?("Room name is required")
            return
        }

        Task {
            guard let client = MatrixClientService.shared.client else { return }
            do {
                let params = CreateRoomParameters(
                    name: name,
                    topic: roomTopic.isEmpty ? nil : roomTopic,
                    isEncrypted: true,
                    isDirect: false,
                    visibility: .private,
                    preset: .privateChat,
                    invite: members.map(\.userId),
                    avatar: nil,
                    powerLevelContentOverride: nil,
                    joinRuleOverride: nil,
                    historyVisibilityOverride: nil,
                    canonicalAlias: nil
                )
                let roomId = try await client.createRoom(request: params)

                if let room = roomListService.room(for: roomId) {
                    await MainActor.run { onRoomCreated?(room) }
                }
            } catch {
                await MainActor.run { onError?("Failed to create room: \(error.localizedDescription)") }
            }
        }
    }
}
