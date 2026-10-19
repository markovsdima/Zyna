// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct RoomTopicEditorView: View {
    @ObservedObject var model: RoomTopicEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            if model.snapshot != nil {
                Section {
                    TextField(String(localized: "Group description", table: "RoomProfile"),
                              text: $model.draft, axis: .vertical)
                        .lineLimit(5...14)
                        .focused($focused)
                        .disabled(model.isSaving || model.isLoading || model.snapshot?.canEdit != true)
                        .accessibilityIdentifier("room.description.editor")
                } footer: {
                    Text(String(localized: "Describe this group. Leave empty to remove the description.", table: "RoomProfile"))
                }
                if model.snapshot?.canEdit == false {
                    Text(String(localized: "You don't have permission to change this description.", table: "RoomProfile"))
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "Save")) { focused = false; model.save() }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("room.description.save")
            }
            if model.isLoading || model.isSaving { ProgressView().frame(maxWidth: .infinity) }
            if let error = model.error {
                Section {
                    Text(error)
                    if model.snapshot == nil || model.snapshot?.canEdit == false {
                        Button(String(localized: "Try Again")) { model.reload() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { model.start() }
    }
}
