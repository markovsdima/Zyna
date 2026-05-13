//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

final class SoftLogoutViewModel: ObservableObject {
    let credentials: SoftLogoutCredentials?
    var onAuthenticated: (() -> Void)?
    var onClearData: (() -> Void)?

    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    init(credentials: SoftLogoutCredentials?) {
        self.credentials = credentials
    }

    func signIn() {
        guard !isLoading else { return }
        guard !password.isEmpty else {
            errorMessage = String(localized: "Enter your password")
            return
        }

        isLoading = true
        errorMessage = nil
        let password = password

        Task {
            do {
                try await MatrixClientService.shared.loginAfterSoftLogout(password: password)
                await MainActor.run {
                    self.isLoading = false
                    self.password = ""
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

    func clearData() {
        guard !isLoading else { return }
        onClearData?()
    }
}

struct SoftLogoutView: View {
    @StateObject private var viewModel: SoftLogoutViewModel
    @State private var showPassword = false
    @State private var showClearDataConfirmation = false

    init(viewModel: SoftLogoutViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.all)

            Group {
                ParticlePatternView()
                InterstellarLinesView()
                    .opacity(0.10)
                RadialPatternView()
            }
            .edgesIgnoringSafeArea(.all)
            .allowsHitTesting(false)

            VStack(spacing: 20) {
                Spacer()

                Text("Session expired")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)

                Text("Sign in again to keep your encrypted message keys on this device.")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                accountSummary()
                    .padding(.top, 12)

                passwordInput()

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                signInButton()

                Button(role: .destructive) {
                    showClearDataConfirmation = true
                } label: {
                    Text("Remove account from this device")
                        .font(.subheadline)
                        .foregroundColor(.red.opacity(0.9))
                }
                .disabled(viewModel.isLoading)

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!viewModel.isLoading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.endEditing()
        }
        .alert("Remove account from this device?", isPresented: $showClearDataConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                viewModel.clearData()
            }
        } message: {
            Text("Local data for this session, including message encryption keys stored on this device, will be removed.\n\nIf any message keys are only on this device, some recent encrypted messages that depend on them may be lost permanently after the data is removed. Entering your recovery key later only restores keys that were already saved to the encrypted backup on your homeserver.\n\nRemove this data only if server key backup has finished, another verified session already has the needed message keys, or you accept losing access to some recent encrypted messages.")
        }
        .preferredColorScheme(.light)
    }

    private func accountSummary() -> some View {
        VStack(spacing: 6) {
            Text(viewModel.credentials?.userId ?? String(localized: "Current account"))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)

            if let credentials = viewModel.credentials {
                Text(credentials.homeserverUrl)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal)
    }

    private func passwordInput() -> some View {
        ZStack(alignment: .trailing) {
            Group {
                if showPassword {
                    TextField("", text: $viewModel.password)
                        .keyboardType(.asciiCapable)
                } else {
                    SecureField("", text: $viewModel.password)
                }
            }
            .font(.system(size: 18))
            .padding()
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.05))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .padding(.horizontal)

            if viewModel.password.isEmpty {
                HStack {
                    Text("Password")
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 32)
                    Spacer()
                }
            }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.trailing, 26)
            }
        }
    }

    private func signInButton() -> some View {
        Button {
            viewModel.signIn()
        } label: {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Continue")
                        .font(.headline)
                }
            }
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.black, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 5)
        }
        .disabled(viewModel.isLoading)
        .padding(.horizontal)
    }
}
