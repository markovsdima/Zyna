//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

@MainActor
final class PollComposerModel: ObservableObject {
    @Published var draft: PollDefinition
    @Published var isSaving = false
    @Published var error: String?
    @Published var confirmsDiscard = false
    let isEditing: Bool
    private let initial: PollDefinition
    private let save: (PollDefinition) async throws -> Void
    var dismiss: (() -> Void)?

    init(definition: PollDefinition?, save: @escaping (PollDefinition) async throws -> Void) {
        let initial = definition ?? .draft
        self.initial = initial
        draft = initial
        isEditing = definition != nil
        self.save = save
    }

    var canSave: Bool {
        !isSaving && draft.isValidForCreation && (!isEditing || draft.normalized != initial.normalized)
    }

    func close() {
        guard !isSaving else { return }
        if draft != initial { confirmsDiscard = true }
        else { dismiss?() }
    }

    func submit() {
        guard canSave else { return }
        isSaving = true
        let definition = draft.normalized
        Task {
            do {
                try await save(definition)
                dismiss?()
            } catch {
                self.error = error.localizedDescription
                isSaving = false
            }
        }
    }

    func removeAnswer(id: String) {
        guard draft.answers.count > 2 else { return }
        draft.answers.removeAll { $0.id == id }
        draft.maxSelections = min(draft.maxSelections, UInt64(draft.answers.count))
    }
}

struct PollComposerScreen: View {
    @ObservedObject var model: PollComposerModel
    @FocusState private var focusedField: String?

    var body: some View {
        Form {
            Section {
                TextField("Ask a question", text: $model.draft.question, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focusedField, equals: "question")
                    .onChange(of: model.draft.question) { _, value in
                        if value.count > 1024 { model.draft.question = String(value.prefix(1024)) }
                    }
            } header: { Text("Question") }

            Section {
                ForEach($model.draft.answers) { $answer in
                    HStack(alignment: .top) {
                        TextField("Answer option", text: $answer.text, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($focusedField, equals: answer.id)
                            .onChange(of: answer.text) { _, value in
                                if value.count > 240 { answer.text = String(value.prefix(240)) }
                            }
                        if model.draft.answers.count > 2 {
                            Button {
                                if focusedField == answer.id { focusedField = nil }
                                model.removeAnswer(id: answer.id)
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(localized: "Remove answer: \(answer.text)"))
                        }
                    }
                }
                if model.draft.answers.count < 20 {
                    Button {
                        let answer = PollDefinition.Answer()
                        model.draft.answers.append(answer)
                        focusedField = answer.id
                    } label: { Label("Add answer", systemImage: "plus.circle") }
                }
            } header: { Text("Answers") } footer: { Text("Add between 2 and 20 answers.") }

            Section {
                Toggle("Multiple answers", isOn: Binding(
                    get: { model.draft.maxSelections > 1 },
                    set: { model.draft.maxSelections = $0 ? UInt64(model.draft.answers.count) : 1 }
                ))
                if model.draft.maxSelections > 1 {
                    Stepper(value: $model.draft.maxSelections, in: 2...UInt64(model.draft.answers.count)) {
                        Text("Up to \(model.draft.maxSelections) answers")
                    }
                }
                Toggle("Show results only after ending", isOn: Binding(
                    get: { model.draft.kind == .undisclosed },
                    set: { model.draft.kind = $0 ? .undisclosed : .disclosed }
                ))
            } footer: {
                Text("Polls are not anonymous. Hiding results delays their display; it does not hide who voted from other clients.")
            }

            Section {
                Button(action: model.submit) {
                    HStack {
                        Spacer()
                        if model.isSaving { ProgressView() }
                        Text(model.isEditing ? String(localized: "Save poll") : String(localized: "Create poll"))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!model.canSave)
            }
        }
        .disabled(model.isSaving)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .appBG))
        .confirmationDialog("Discard changes?", isPresented: $model.confirmsDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.dismiss?() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Couldn't save poll", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
