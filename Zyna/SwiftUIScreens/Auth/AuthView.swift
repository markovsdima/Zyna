//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct AuthView: View {
    @ObservedObject var viewModel: AuthViewModel

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var homeserver: String = "matrix.org"
    @State private var showPassword = false

    var body: some View {
        ZStack {

            // MARK: - Background Layers

            Color.black.ignoresSafeArea(.all)

            Group {
                ParticlePatternView()
                InterstellarLinesView()
                    .opacity(0.10)
                RadialPatternView()
            }
            .edgesIgnoringSafeArea(.all)
            .onTapGesture {
                UIApplication.shared.endEditing()
            }

            // MARK: - Content

            VStack(spacing: 20) {
                Spacer()
                logoView()
                Spacer()

                homeserverInput()

                if viewModel.serverSupportsPassword {
                    loginInput()
                    passwordInput()
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Spacer().frame(height: 30)

                if viewModel.serverSupportsPassword {
                    signInButton()
                }

                if !viewModel.serverSupportsPassword && viewModel.serverSupportsOIDC {
                    oidcSignInButton()
                }

                createAccountButton()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!viewModel.isLoading)
        }
        .preferredColorScheme(.light)
        .onAppear {
            viewModel.tryRestoreSession()
        }
    }

    // MARK: - View Components

    private func logoView() -> some View {
        Group {
            Text("Zyna")
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

            Text("Safe chats. Stunning vibes.")
                .foregroundColor(.white).opacity(0.75)
        }
    }

    @ViewBuilder private func homeserverInput() -> some View {
        ZStack(alignment: .leading) {
            if homeserver.isEmpty {
                Text("Homeserver")
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal)
            }
            TextField("", text: $homeserver)
                .font(.system(size: 18))
                .padding()
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.05))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: homeserver) { newValue in
                    viewModel.checkServerCapabilities(homeserver: newValue)
                }
        }.padding(.horizontal)
    }

    @ViewBuilder private func loginInput() -> some View {
        ZStack(alignment: .leading) {
            if username.isEmpty {
                Text("Login")
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal)
            }
            TextField("", text: $username)
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
                .keyboardType(.asciiCapable)
        }.padding(.horizontal)
    }

    @ViewBuilder private func passwordInput() -> some View {
        ZStack(alignment: .trailing) {
            Group {
                if showPassword {
                    TextField("", text: $password)
                        .keyboardType(.asciiCapable)
                } else {
                    SecureField("", text: $password)
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
            .transition(.move(edge: .top).combined(with: .opacity))

            if password.isEmpty {
                HStack {
                    Text("Password")
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 32)
                    Spacer()
                }
            }

            Button(action: {
                showPassword.toggle()
            }) {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.trailing, 26)
            }
        }
    }

    private func signInButton() -> some View {
        Button(action: {
            viewModel.login(username: username, password: password, homeserver: homeserver)
        }) {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Sign In")
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

    private func oidcSignInButton() -> some View {
        Button(action: {
            viewModel.loginWithOIDC(homeserver: homeserver)
        }) {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Sign In with Browser")
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

    private func createAccountButton() -> some View {
        Button(action: {
            viewModel.register(homeserver: homeserver)
        }) {
            Text("Create Account")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
        .disabled(viewModel.isLoading)
        .padding(.bottom, 16)
    }
}
