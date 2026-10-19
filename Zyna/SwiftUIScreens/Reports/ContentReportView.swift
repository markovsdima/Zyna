// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct ContentReportView: View {
    @ObservedObject var model: ContentReportViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var reasonFocused: Bool

    var body: some View {
        Group {
            if model.requested != nil, let context = model.context {
                ContentReportReceiptView(model: model, context: context)
                    .transition(.opacity)
            } else {
                form.transition(.opacity)
            }
        }
        .background(Color.appBackground)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.requested != nil)
        .sensoryFeedback(.success, trigger: model.completed.contains(.report) || model.isComplete) { _, succeeded in succeeded }
    }

    private var form: some View {
        Form {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = model.loadError {
                Section {
                    Text(error)
                    Button(String(localized: "Try Again")) { model.load() }
                }
            } else if let context = model.context {
                Section {
                    if model.target.isInvitation {
                        Toggle(String(localized: "Also report this room", table: "Reports"), isOn: $model.shouldReport)
                            .disabled(!context.canReport)
                    }
                    if model.shouldReport && context.canReport {
                        TextField(String(localized: "Describe the problem", table: "Reports"), text: $model.reason, axis: .vertical)
                            .lineLimit(4...10)
                            .focused($reasonFocused)
                            .onChange(of: model.reason) { _, value in
                                if value.count > 2000 { model.reason = String(value.prefix(2000)) }
                            }
                    }
                    if !context.canReport {
                        Text(String(localized: "Your server does not support this report.", table: "Reports"))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if model.shouldReport && context.canReport {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Reports go to the administrator of your server: \(context.recipient).", table: "Reports"))
                            if context.isEncrypted {
                                Text(String(localized: "The administrator cannot read encrypted messages. Describe the problem in your own words. Message contents and encryption keys are not attached.", table: "Reports"))
                            }
                        }
                    }
                }
                if context.blockUserID != nil || !model.target.isMessage {
                    Section {
                        if context.blockUserID != nil {
                            if context.isBlocked {
                                Text(String(localized: "This user is already blocked.", table: "Reports"))
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle(String(localized: "Block user", table: "Reports"), isOn: $model.shouldBlock)
                                    Text(String(localized: "Blocking hides this person's past and future messages from you in all chats, including shared groups. You won't receive invitations from them."))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if !model.target.isMessage && !model.target.isInvitation {
                            Toggle(String(localized: "Leave room", table: "Reports"), isOn: $model.shouldLeave)
                        }
                    } footer: {
                        if let userID = context.blockUserID { Text(userID) }
                    }
                }
                Section {
                    Button(submitTitle) {
                        reasonFocused = false
                        model.submit()
                    }
                    .disabled(!model.canSubmit)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .scrollDismissesKeyboard(.interactively)
    }

    private var submitTitle: String {
        model.target.isInvitation ? String(localized: "Decline invitation", table: "Reports")
            : String(localized: "Send report", table: "Reports")
    }
}
