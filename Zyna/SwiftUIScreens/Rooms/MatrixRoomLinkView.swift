// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct MatrixRoomLinkView: View {
    @ObservedObject var model: MatrixRoomLinkModel
    @State private var avatar: UIImage?

    var body: some View {
        Form {
            if let preview = model.preview {
                Section {
                    VStack(spacing: 12) {
                        Group {
                            if let avatar { Image(uiImage: avatar).resizable().scaledToFill() }
                            else {
                                Image(systemName: preview.info.roomType == .space ? "square.stack.3d.up" : "bubble.left.and.bubble.right")
                                    .font(.system(size: 34)).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .foregroundStyle(Color.accentColor).background(Color.accentColor.opacity(0.12))
                            }
                        }
                        .frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                        Text(preview.info.name ?? preview.info.canonicalAlias ?? preview.info.roomId)
                            .font(.title2.bold()).multilineTextAlignment(.center)
                        Text(preview.info.canonicalAlias ?? preview.info.roomId)
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(String(localized: "\(preview.info.numJoinedMembers) members"))
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    if let topic = preview.info.topic, !topic.isEmpty { Text(topic).textSelection(.enabled) }
                }
                Section {
                    if let action = preview.action {
                        Button(actionTitle(action, invited: preview.info.membership == .invited)) { model.performAction() }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("matrix.link.primary")
                    }
                    Text(explanation(preview)).foregroundStyle(.secondary)
                }
            }
            if model.isBusy {
                ProgressView(String(localized: "Opening link…", table: "MatrixLinks"))
                    .frame(maxWidth: .infinity)
            }
            if let error = model.error {
                Section {
                    Text(error)
                    Button(String(localized: "Try Again")) { model.retry() }.disabled(model.isBusy)
                    if model.link.eventID != nil, model.preview?.action == .open {
                        Button(String(localized: "Open Room")) { model.openRoom() }.disabled(model.isBusy)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .onAppear { model.start() }
        .task(id: model.preview?.info.avatarUrl) {
            avatar = nil
            guard let url = model.preview?.info.avatarUrl else { return }
            let value = await MediaCache.shared.loadThumbnail(mxcUrl: url, size: 256)
            guard !Task.isCancelled else { return }
            avatar = value
        }
    }

    private func actionTitle(_ action: MatrixLinkedRoom.Action, invited: Bool) -> String {
        switch action {
        case .open: model.link.eventID == nil
            ? String(localized: "Open Room")
            : String(localized: "Open message", table: "MatrixLinks")
        case .join: invited ? String(localized: "Accept Invite") : String(localized: "Join Room")
        case .knock: String(localized: "Ask to Join")
        }
    }

    private func explanation(_ preview: MatrixLinkedRoom) -> String {
        switch preview.info.membership {
        case .knocked: return String(localized: "Your request to join is waiting for approval.", table: "MatrixLinks")
        case .banned: return String(localized: "You cannot join this room.", table: "MatrixLinks")
        case .joined: return String(localized: "You are already a member of this room.", table: "MatrixLinks")
        default: break
        }
        if preview.action == nil {
            return String(localized: "This room requires an invitation or membership in an allowed space.", table: "MatrixLinks")
        }
        if preview.action == .knock {
            return String(localized: "Send a request to the room's administrators to join.", table: "MatrixLinks")
        }
        return String(localized: "Join this room to open the conversation. Opening a link doesn't join automatically.", table: "MatrixLinks")
    }
}
