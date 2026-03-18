//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import AuthenticationServices
import MatrixRustSDK

final class AuthViewModel: ObservableObject {

    var onAuthenticated: (() -> Void)?

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var serverSupportsPassword = true
    @Published var serverSupportsOIDC = false

    private let matrixService = MatrixClientService.shared
    private var oidcClient: Client?
    private var oidcAuthData: OAuthAuthorizationData?

    // MARK: - Password Login

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

    // MARK: - Registration (OIDC)

    func register(homeserver: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let client = try await matrixService.buildUnauthenticatedClient(homeserver: homeserver)
                let details = await client.homeserverLoginDetails()

                guard details.supportsOidcLogin() else {
                    await MainActor.run {
                        isLoading = false
                        errorMessage = "This server does not support registration from the app"
                    }
                    return
                }

                let (loginURL, authData) = try await matrixService.startOIDCFlow(client: client)
                self.oidcClient = client
                self.oidcAuthData = authData

                await MainActor.run {
                    isLoading = false
                    presentOIDCSession(url: loginURL)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - OIDC Login (for servers that only support OIDC)

    func loginWithOIDC(homeserver: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let client = try await matrixService.buildUnauthenticatedClient(homeserver: homeserver)
                let (loginURL, authData) = try await matrixService.startOIDCFlow(client: client)
                self.oidcClient = client
                self.oidcAuthData = authData

                await MainActor.run {
                    isLoading = false
                    presentOIDCSession(url: loginURL)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Server Capabilities Check

    func checkServerCapabilities(homeserver: String) {
        let trimmed = homeserver.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                let client = try await matrixService.buildUnauthenticatedClient(homeserver: trimmed)
                let details = await client.homeserverLoginDetails()

                await MainActor.run {
                    serverSupportsPassword = details.supportsPasswordLogin()
                    serverSupportsOIDC = details.supportsOidcLogin()
                }
            } catch {
                await MainActor.run {
                    serverSupportsPassword = true
                    serverSupportsOIDC = false
                }
            }
        }
    }

    // MARK: - Session Restore

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
                }
            }
        }
    }

    // MARK: - OIDC Browser Session

    private func presentOIDCSession(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "zyna"
        ) { [weak self] callbackURL, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    // User cancelled — not an error
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    self.errorMessage = error.localizedDescription
                }
                return
            }

            guard let callbackURL else { return }

            self.isLoading = true
            Task {
                do {
                    guard let client = self.oidcClient else { return }
                    try await self.matrixService.completeOIDCFlow(
                        client: client,
                        callbackURL: callbackURL.absoluteString
                    )
                    await MainActor.run {
                        self.isLoading = false
                        self.oidcClient = nil
                        self.oidcAuthData = nil
                        self.onAuthenticated?()
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }

        // Use the window as presentation context
        let contextProvider = OIDCPresentationContext(window: window)
        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }
}

// MARK: - OIDC Presentation Context

private final class OIDCPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
