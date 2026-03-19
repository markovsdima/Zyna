//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import MatrixRustSDK

struct SessionVerificationView: View {
    @ObservedObject var viewModel: SessionVerificationViewModel

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
    }

    // MARK: - Content

    @ViewBuilder
    private func contentForStep() -> some View {
        switch viewModel.step {
        case .initial:
            initialView()
        case .requestingVerification, .waitingForAcceptance:
            waitingView()
        case .showingEmojis:
            emojisView()
        case .verified:
            verifiedView()
        case .cancelled, .failed:
            failedView()
        }
    }

    // MARK: - Initial

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

    // MARK: - Waiting

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

    // MARK: - Emojis

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

    // MARK: - Verified

    private func verifiedView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)

            Text("Device Verified!")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Text("Your device is now verified. Messages will be trusted by other sessions.")
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Failed

    private func failedView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.shield")
                .font(.system(size: 56))
                .foregroundColor(.red.opacity(0.8))

            Text("Verification Failed")
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
        switch viewModel.step {
        case .initial:
            VStack(spacing: 12) {
                primaryButton("Start Verification") { viewModel.startVerification() }
                textButton("Skip for now") { viewModel.skip() }
            }

        case .requestingVerification, .waitingForAcceptance:
            textButton("Cancel") { viewModel.skip() }

        case .showingEmojis:
            VStack(spacing: 12) {
                primaryButton("They Match") { viewModel.confirmEmojis() }
                textButton("They Don't Match") { viewModel.denyEmojis() }
            }

        case .verified:
            primaryButton("Continue") { viewModel.continueToApp() }

        case .cancelled, .failed:
            VStack(spacing: 12) {
                primaryButton("Try Again") { viewModel.startVerification() }
                textButton("Skip for now") { viewModel.skip() }
            }
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
