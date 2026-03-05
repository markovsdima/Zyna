//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine

final class AuthViewModel: ObservableObject {

    var onAuthenticated: (() -> Void)?

    @Published var isLoading = false
    @Published var errorMessage: String?

    private let matrixService = MatrixClientService.shared

    func login(username: String, password: String, homeserver: String = "matrix.org") {
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter username and password"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await matrixService.login(
                    username: username,
                    password: password,
                    homeserver: homeserver
                )
                await MainActor.run {
                    isLoading = false
                    onAuthenticated?()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func tryRestoreSession() {
        guard matrixService.hasStoredSession else { return }

        isLoading = true
        Task {
            do {
                try await matrixService.restoreSession()
                await MainActor.run {
                    isLoading = false
                    onAuthenticated?()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    // Session expired — show login form
                }
            }
        }
    }
}
