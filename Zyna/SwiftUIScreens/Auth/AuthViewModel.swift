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
    @Published var isSigningIn = false
    @Published var errorMessage: String?
    @Published var serverSupportsPassword = true
    @Published var serverSupportsOAuth = false

    private let matrixService = MatrixClientService.shared
    private var oauthClient: Client?
    private var oauthAuthData: OAuthAuthorizationData?
    private var oauthWebSession: ASWebAuthenticationSession?
    private var oauthPresentationContext: OAuthPresentationContext?

    // MARK: - Password Login

    func login(username: String, password: String, homeserver: String = Brand.current.defaultHomeserver) {
        guard !isLoading else { return }

        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter username and password"
            return
        }

        isLoading = true
        isSigningIn = true
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
                    isSigningIn = false
                    onAuthenticated?()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    isSigningIn = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Registration (OAuth)

    func register(homeserver: String) {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let client = try await matrixService.buildUnauthenticatedClient(homeserver: homeserver)
                let details = await client.homeserverLoginDetails()

                guard details.supportsOauthLogin() else {
                    await MainActor.run {
                        isLoading = false
                        errorMessage = "This server does not support registration from the app"
                    }
                    return
                }

                let (loginURL, authData) = try await matrixService.startOAuthFlow(client: client)
                self.oauthClient = client
                self.oauthAuthData = authData

                await MainActor.run {
                    isLoading = false
                    presentOAuthSession(url: loginURL)
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - OAuth Login

    func loginWithOAuth(homeserver: String) {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let client = try await matrixService.buildUnauthenticatedClient(homeserver: homeserver)
                let (loginURL, authData) = try await matrixService.startOAuthFlow(client: client)
                self.oauthClient = client
                self.oauthAuthData = authData

                await MainActor.run {
                    isLoading = false
                    presentOAuthSession(url: loginURL)
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
                    serverSupportsOAuth = details.supportsOauthLogin()
                }
            } catch {
                await MainActor.run {
                    serverSupportsPassword = true
                    serverSupportsOAuth = false
                }
            }
        }
    }

    // MARK: - OAuth Browser Session

    private func presentOAuthSession(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "zyna"
        ) { [weak self] callbackURL, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    self.abortOAuthSessionIfNeeded()
                    // User cancelled -- not an error
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
                    guard let client = self.oauthClient else { return }
                    try await self.matrixService.completeOAuthFlow(
                        client: client,
                        callbackURL: callbackURL.absoluteString
                    )
                    await MainActor.run {
                        self.isLoading = false
                        self.clearOAuthSessionState()
                        self.onAuthenticated?()
                    }
                } catch {
                    self.abortOAuthSessionIfNeeded()
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }

        // Use the window as presentation context
        let contextProvider = OAuthPresentationContext(window: window)
        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        oauthWebSession = session
        oauthPresentationContext = contextProvider

        if !session.start() {
            abortOAuthSessionIfNeeded()
            errorMessage = "Unable to start browser authentication"
        }
    }

    private func abortOAuthSessionIfNeeded() {
        guard let client = oauthClient,
              let authData = oauthAuthData else {
            clearOAuthSessionState()
            return
        }

        clearOAuthSessionState()

        Task {
            await client.abortOauthAuth(authorizationData: authData)
        }
    }

    private func clearOAuthSessionState() {
        oauthClient = nil
        oauthAuthData = nil
        oauthWebSession = nil
        oauthPresentationContext = nil
    }
}

// MARK: - OAuth Presentation Context

private final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
