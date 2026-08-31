//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

/// Scaffolding: final chrome and entry point, placeholder rows. Exists
/// to exercise `GlassHostingController` until the real list lands.
struct BlockedUsersView: View {

    private let placeholderCount = 30

    var body: some View {
        List {
            Section {
                ForEach(1...placeholderCount, id: \.self) { index in
                    placeholderRow(index: index)
                }
            } header: {
                Text("Placeholder rows — scroll to check the glass bar")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }

    private func placeholderRow(index: Int) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appAccent.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Text("\(index)")
                        .font(.footnote)
                        .foregroundStyle(Color.appAccent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Placeholder \(index)")
                Text("@user\(index):example.org")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    BlockedUsersView()
}
