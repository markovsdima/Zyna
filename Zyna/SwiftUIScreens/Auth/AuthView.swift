//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import RxFlow
import RxRelay

struct AuthView: View {
    @ObservedObject var viewModel: AuthViewModel
    
    @State private var username: String = ""
    @State private var password: String = ""
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
                
                loginInput()
                passwordInput()
                
                Spacer().frame(height: 50)
                signInButton()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.light)
    }
    
    // MARK: - View Components
    
    private func logoView() -> some View {
        Group {
            Text("Zyna")
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            
            Text("Safe chats. Stunning vibes.") // Grace meets security
                .foregroundColor(.white).opacity(0.75)
        }
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
        }.padding(.horizontal)
    }
    
    @ViewBuilder private func passwordInput() -> some View {
        ZStack(alignment: .trailing) {
            Group {
                if showPassword {
                    TextField("", text: $password)
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
            viewModel.proceedToMainFlow()
        }) {
            Text("Sign In")
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 5)
        }
        .padding(.horizontal)
    }
}
