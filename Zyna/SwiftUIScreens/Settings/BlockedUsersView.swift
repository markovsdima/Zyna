//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct BlockedUsersView: View {

    @ObservedObject var viewModel: BlockedUsersViewModel

    var body: some View {
        content
            .background(Color.appBackground)
            .alert(
                "Unblock user?",
                isPresented: unblockConfirmation,
                presenting: viewModel.pendingUnblock
            ) { entry in
                Button("Cancel", role: .cancel) { viewModel.cancelUnblock() }
                Button("Unblock", role: .destructive) { viewModel.confirmUnblock(entry) }
            } message: { entry in
                Text("\(entry.title) will be able to message you again.")
            }
            .alert(
                "Something went wrong",
                isPresented: errorAlert,
                presenting: viewModel.errorMessage
            ) { _ in
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = viewModel.loadError {
            failureState(loadError)
        } else if viewModel.entries.isEmpty {
            Text("You haven't blocked anyone.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Couldn't load your blocked users.")
                .foregroundStyle(.primary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { viewModel.retry() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(viewModel.entries) { entry in
                    row(entry)
                }
            } footer: {
                Text("Blocked users can't send you direct messages, and their messages stay hidden in rooms you share.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: BlockedUsersViewModel.Entry) -> some View {
        Button {
            viewModel.requestUnblock(entry)
        } label: {
            HStack(spacing: 12) {
                initialsCircle(for: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .foregroundStyle(.primary)
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if viewModel.processingUserId == entry.userId {
                    ProgressView()
                }
            }
        }
        .disabled(viewModel.processingUserId != nil)
    }

    /// Generated initials avoid loading remote avatar media for blocked users.
    private func initialsCircle(for entry: BlockedUsersViewModel.Entry) -> some View {
        let avatar = AvatarViewModel(
            userId: entry.userId,
            displayName: entry.displayName,
            mxcAvatarURL: nil
        )
        return Image(uiImage: avatar.circleImage(diameter: 36, fontSize: 14))
    }

    private var unblockConfirmation: Binding<Bool> {
        Binding(
            get: { viewModel.pendingUnblock != nil },
            set: { if !$0 { viewModel.cancelUnblock() } }
        )
    }

    private var errorAlert: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
