//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

#if DEBUG
struct RoomPollsView: View {
    @ObservedObject var viewModel: RoomPollsViewModel
    let isActive: Bool
    let openPoll: @MainActor (String) async throws -> PreparedPollNavigation

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.openingEventId != nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading poll in chat…")
                    Spacer()
                    Button(String(localized: "Cancel")) { viewModel.cancelOpening() }
                }
                .font(.footnote)
                .padding()
            } else if let eventId = viewModel.failedOpeningEventId {
                HStack {
                    Text("Couldn't open poll in chat.")
                    Spacer()
                    Button(String(localized: "Try Again")) { viewModel.openPoll(eventId, prepare: openPoll) }
                }
                .font(.footnote)
                .padding()
            }
            if viewModel.pendingDecryptionCount > 0 {
                HStack {
                    Text("\(viewModel.pendingDecryptionCount) messages are waiting for keys")
                    Spacer()
                    Button(String(localized: "Retry")) { viewModel.retryDecryption() }
                }
                .font(.footnote)
                .padding()
            }
            if viewModel.items.isEmpty, viewModel.state == .exhausted,
               viewModel.pendingDecryptionCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 36))
                    Text("No polls yet.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.items) { item in
                            Button { viewModel.openPoll(item.eventId, prepare: openPoll) } label: { row(item) }
                                .buttonStyle(.plain)
                                .disabled(viewModel.openingEventId != nil)
                                #if DEBUG
                                .onAppear { viewModel.traceRowAppearance(item) }
                                #endif
                            Divider().padding(.leading, 16)
                        }
                        footer
                    }
                }
            }
        }
        .onAppear { if isActive { viewModel.activate() } }
        .onChange(of: isActive) { _, active in
            if active { viewModel.activate() } else { viewModel.deactivate() }
        }
    }

    private func row(_ item: RoomPollItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: item.snapshot.definition.question)
                .font(.body.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.senderName ?? item.senderId).lineLimit(1)
                Spacer(minLength: 8)
                Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.day().month().year())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text(item.snapshot.hasEnded ? String(localized: "Poll ended") : String(localized: "Poll active"))
                Spacer(minLength: 8)
                if item.snapshot.showsResults {
                    Text("\(item.snapshot.totalVoters) voters")
                } else {
                    Text("Results after the poll ends")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Open poll in chat"))
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 12) {
            switch viewModel.state {
            case .loading: ProgressView()
            case .more:
                Button(String(localized: "Load More")) { viewModel.loadMore() }
            case .failed:
                Text("Couldn't load polls.").foregroundStyle(.secondary)
                Button(String(localized: "Try Again")) { viewModel.loadMore() }
            case .idle, .exhausted: EmptyView()
            }
            Color.clear.frame(height: 1)
                .onAppear { viewModel.reachedBottom() }
                .onDisappear { viewModel.leftBottom() }
        }
        .padding()
    }
}
#endif
