//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import MatrixRustSDK

struct SessionVerificationView: View {
    @ObservedObject var viewModel: SessionVerificationViewModel
    @State private var showSavedConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.all)

            ParticlePatternView()
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 24) {
                Spacer()
                contentForStep()
                Spacer()
                bottomButtons()
            }
            .padding()
        }
        .preferredColorScheme(.light)
        .onAppear { viewModel.detectMode() }
        .alert("Saved your recovery key?", isPresented: $showSavedConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("I've saved it") { viewModel.confirmRecoveryKeySaved() }
        } message: {
            Text("Without this key you'll lose access to encrypted messages if you sign in on another device.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentForStep() -> some View {
        switch viewModel.mode {
        case .checking:
            checkingView()
        case .firstDevice:
            firstDeviceContent()
        case .otherDevice:
            otherDeviceContent()
        case .responder:
            responderContent()
        }
    }

    // MARK: - Checking

    private func checkingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("Checking account…")
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: - First-Device (Recovery) Content

    @ViewBuilder
    private func firstDeviceContent() -> some View {
        switch viewModel.step {
        case .initial:
            recoveryIntroView()
        case .generatingRecoveryKey:
            generatingKeyView()
        case .showingRecoveryKey(let key):
            recoveryKeyView(key)
        case .enteringRecoveryKey:
            enterRecoveryKeyView()
        case .restoringFromRecoveryKey:
            restoringView()
        case .verified:
            verifiedView()
        case .failed, .cancelled:
            failedView()
        default:
            EmptyView()
        }
    }

    private func recoveryIntroView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.85))

            Text("Set Up Recovery")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Generate a recovery key to back up your encrypted messages, or enter an existing key if you already have one.")
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func generatingKeyView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("Generating recovery key…")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func recoveryKeyView(_ key: String) -> some View {
        VStack(spacing: 20) {
            Text("Your Recovery Key")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Save this key in a password manager or somewhere safe. You'll need it to restore encrypted messages on other devices.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(key)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = key
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                ShareLink(item: key) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Other-Device (Emoji or Recovery Key) Content

    @ViewBuilder
    private func otherDeviceContent() -> some View {
        switch viewModel.step {
        case .initial:
            initialView()
        case .requestingVerification, .waitingForAcceptance:
            waitingView()
        case .showingEmojis:
            emojisView()
        case .enteringRecoveryKey:
            enterRecoveryKeyView()
        case .restoringFromRecoveryKey:
            restoringView()
        case .generatingRecoveryKey:
            generatingKeyView()
        case .showingRecoveryKey(let key):
            recoveryKeyView(key)
        case .verified:
            verifiedView()
        case .cancelled, .failed:
            failedView()
        default:
            EmptyView()
        }
    }

    private func enterRecoveryKeyView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.85))

            Text("Enter Recovery Key")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Paste the recovery key you saved when setting up the account.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            TextField("", text: $viewModel.recoveryKeyInput, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(3...5)
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.horizontal)
        }
    }

    private func restoringView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("Restoring from recovery key…")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func initialView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.85))

            Text("Verify This Device")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Confirm your identity by verifying this device with another session, like Element on your phone or computer.")
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func waitingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Text("Waiting for Approval")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Accept the verification request on your other device.")
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func emojisView() -> some View {
        VStack(spacing: 20) {
            Text("Compare Emojis")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Confirm the emojis below match those shown on your other device.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            emojiGrid()
        }
    }

    private func emojiGrid() -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 16
        ) {
            ForEach(Array(viewModel.emojis.enumerated()), id: \.offset) { _, emoji in
                VStack(spacing: 4) {
                    Text(emoji.symbol())
                        .font(.system(size: 36))
                    Text(emoji.description())
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: - Responder Content (incoming request from another device)

    @ViewBuilder
    private func responderContent() -> some View {
        switch viewModel.step {
        case .initial:
            incomingRequestView()
        case .acceptingRequest, .waitingForAcceptance:
            waitingView()
        case .showingEmojis:
            emojisView()
        case .verified:
            verifiedView()
        case .cancelled, .failed:
            failedView()
        default:
            EmptyView()
        }
    }

    private func incomingRequestView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.85))

            Text("Verification Request")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            if let request = viewModel.incomingRequest {
                Text("Another device wants to verify this session.")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    if let name = request.deviceDisplayName {
                        detailRow("Device", name)
                    }
                    detailRow("Device ID", request.deviceId)
                }
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    // MARK: - Shared (verified / failed)

    private func verifiedView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)

            Text("All Set!")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text(viewModel.mode == .firstDevice
                 ? "Recovery key saved. You're ready to chat."
                 : "Your device is now verified. Messages will be trusted by other sessions.")
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func failedView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.shield")
                .font(.system(size: 56))
                .foregroundColor(.red.opacity(0.8))

            Text(viewModel.mode == .firstDevice ? "Setup Failed" : "Verification Failed")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Bottom Buttons

    @ViewBuilder
    private func bottomButtons() -> some View {
        switch viewModel.mode {
        case .checking:
            EmptyView()
        case .firstDevice:
            firstDeviceButtons()
        case .otherDevice:
            otherDeviceButtons()
        case .responder:
            responderButtons()
        }
    }

    @ViewBuilder
    private func firstDeviceButtons() -> some View {
        switch viewModel.step {
        case .initial:
            VStack(spacing: 12) {
                primaryButton("Generate Recovery Key") { viewModel.setupRecovery() }
                textButton("I have a recovery key") { viewModel.useRecoveryKey() }
                textButton("Skip for now") { viewModel.skip() }
            }
        case .generatingRecoveryKey:
            EmptyView()
        case .showingRecoveryKey:
            primaryButton("Done") { showSavedConfirmation = true }
        case .enteringRecoveryKey:
            VStack(spacing: 12) {
                primaryButton("Restore") { viewModel.restoreFromRecoveryKey() }
                textButton("Cancel") { viewModel.skip() }
            }
        case .restoringFromRecoveryKey:
            EmptyView()
        case .verified:
            primaryButton("Continue") { viewModel.continueToApp() }
        case .failed, .cancelled:
            VStack(spacing: 12) {
                primaryButton("Try Again") { viewModel.setupRecovery() }
                textButton("I have a recovery key") { viewModel.useRecoveryKey() }
                textButton("Skip for now") { viewModel.skip() }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func otherDeviceButtons() -> some View {
        switch viewModel.step {
        case .initial:
            VStack(spacing: 12) {
                primaryButton("Start Verification") { viewModel.startVerification() }
                textButton("I have a recovery key") { viewModel.useRecoveryKey() }
                textButton("Generate new recovery key") { viewModel.setupRecovery() }
                textButton("Skip for now") { viewModel.skip() }
            }
        case .requestingVerification, .waitingForAcceptance:
            textButton("Cancel") { viewModel.skip() }
        case .showingEmojis:
            VStack(spacing: 12) {
                primaryButton("They Match") { viewModel.confirmEmojis() }
                textButton("They Don't Match") { viewModel.denyEmojis() }
            }
        case .enteringRecoveryKey:
            VStack(spacing: 12) {
                primaryButton("Restore") { viewModel.restoreFromRecoveryKey() }
                textButton("Cancel") { viewModel.skip() }
            }
        case .restoringFromRecoveryKey:
            EmptyView()
        case .generatingRecoveryKey:
            EmptyView()
        case .showingRecoveryKey:
            primaryButton("Done") { showSavedConfirmation = true }
        case .verified:
            primaryButton("Continue") { viewModel.continueToApp() }
        case .cancelled, .failed:
            VStack(spacing: 12) {
                primaryButton("Try Again") { viewModel.startVerification() }
                textButton("I have a recovery key") { viewModel.useRecoveryKey() }
                textButton("Generate new recovery key") { viewModel.setupRecovery() }
                textButton("Skip for now") { viewModel.skip() }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func responderButtons() -> some View {
        switch viewModel.step {
        case .initial:
            VStack(spacing: 12) {
                primaryButton("Accept") { viewModel.acceptIncomingRequest() }
                textButton("Ignore") { viewModel.ignoreIncomingRequest() }
            }
        case .acceptingRequest, .waitingForAcceptance:
            EmptyView()
        case .showingEmojis:
            VStack(spacing: 12) {
                primaryButton("They Match") { viewModel.confirmEmojis() }
                textButton("They Don't Match") { viewModel.denyEmojis() }
            }
        case .verified:
            primaryButton("Done") { viewModel.continueToApp() }
        case .cancelled, .failed:
            VStack(spacing: 12) {
                primaryButton("Done") { viewModel.skip() }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Button Styles

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 5)
        }
        .padding(.horizontal)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}
