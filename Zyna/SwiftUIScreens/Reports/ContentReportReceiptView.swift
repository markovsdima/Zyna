// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// An immutable receipt replaces the form as soon as submission starts.
/// Each action keeps its own result, including during a partial retry.
struct ContentReportReceiptView: View {
    @ObservedObject var model: ContentReportViewModel
    let context: ContentReportContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var resultFocused: Bool

    private var primaryStep: ContentReportStep {
        if model.requested?.contains(.report) == true { return .report }
        return model.requested?.first ?? .block
    }
    private var primaryState: ContentReportStepState { model.state(of: primaryStep) }
    private var accepted: Bool { primaryState == .completed }
    private var additionalSteps: [ContentReportStep] {
        (model.requested ?? []).filter { $0 != primaryStep }
    }
    private var resultColor: Color {
        if accepted { return .appAccent }
        if case .failed = primaryState { return .appDestructive }
        return .secondary
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                if model.requested?.contains(.report) == true { document }
                if !additionalSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(additionalSteps, id: \.self) { step in actionResult(step) }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .onChange(of: model.isSubmitting) { _, submitting in
            if !submitting { resultFocused = true }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(resultColor.opacity(0.1))
                if accepted {
                    ReportReceiptCheckmark()
                } else if case .failed = primaryState {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 28, weight: .semibold))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .foregroundStyle(resultColor)
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)

            Text(title(primaryStep, state: primaryState))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($resultFocused)
            if accepted, primaryStep == .report {
                Text(String(localized: "The server \(context.recipient) accepted your report.", table: "Reports"))
                    .foregroundStyle(.secondary)
            } else if case .failed(let error) = primaryState {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: primaryState)
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(String(localized: "Your report", table: "Reports"), systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(model.submittedReason ?? "")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(.secondary.opacity(0.2))
                .frame(height: 1)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    recipient
                    Spacer(minLength: 8)
                    deliveryStamp
                }
                VStack(alignment: .leading, spacing: 14) {
                    recipient
                    deliveryStamp
                }
            }
        }
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityIdentifier("report.receipt")
    }

    private var recipient: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Recipient", table: "Reports"))
                .font(.caption).foregroundStyle(.secondary)
            Text(context.recipient).font(.subheadline.weight(.medium))
        }
    }

    private var deliveryStamp: some View {
        let sent = model.completed.contains(.report)
        let label: String
        switch model.state(of: .report) {
        case .completed: label = String(localized: "Sent", table: "Reports")
        case .failed: label = String(localized: "Not sent", table: "Reports")
        case .running: label = String(localized: "Sending…", table: "Reports")
        case .pending, .waitingForReport: label = String(localized: "Pending", table: "Reports")
        }
        return Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(sent ? Color.appAccent : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background((sent ? Color.appAccent : Color.secondary).opacity(0.08), in: Capsule())
            .overlay { Capsule().strokeBorder((sent ? Color.appAccent : Color.secondary).opacity(0.25), lineWidth: 1) }
            .fixedSize()
    }

    private func actionResult(_ step: ContentReportStep) -> some View {
        let state = model.state(of: step)
        return HStack(alignment: .top, spacing: 12) {
            Group {
                switch state {
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appAccent)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.appDestructive)
                case .running: ProgressView()
                case .pending, .waitingForReport: Image(systemName: "clock").foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title(step, state: state)).font(.subheadline.weight(.semibold))
                if case .failed(let error) = state {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else if state == .waitingForReport {
                    Text(String(localized: "You'll stay in the room until the report is sent.", table: "Reports"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if step == .block, let userID = context.blockUserID {
                    Text(userID).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if model.isSubmitting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.activeStep.map { title($0, state: .running) }
                         ?? String(localized: "Finishing…", table: "Reports"))
                }
                .font(.subheadline)
                .frame(minHeight: 48)
                Text(String(localized: "You can close this screen. The actions will continue.", table: "Reports"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !model.isComplete {
                Button { model.submit() } label: {
                    Text(retryTitle).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("report.retry")
            }
            Button { model.close() } label: {
                Text(String(localized: "Close"))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("report.close")
        }
        .controlSize(.large)
        .tint(.appAccent)
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
    }

    private var retryTitle: String {
        guard model.remainingSteps.count == 1, let step = model.remainingSteps.first else {
            return String(localized: "Retry unfinished actions", table: "Reports")
        }
        switch step {
        case .report: return String(localized: "Retry sending report", table: "Reports")
        case .block: return String(localized: "Retry blocking", table: "Reports")
        case .leave: return model.target.isInvitation ? String(localized: "Retry declining invitation", table: "Reports")
            : String(localized: "Retry leaving room", table: "Reports")
        }
    }

    private func title(_ step: ContentReportStep, state: ContentReportStepState) -> String {
        switch (step, state) {
        case (.report, .completed): return String(localized: "Report sent", table: "Reports")
        case (.block, .completed): return String(localized: "User blocked", table: "Reports")
        case (.leave, .completed): return model.target.isInvitation ? String(localized: "Invitation declined", table: "Reports")
            : String(localized: "You left the room", table: "Reports")
        case (.report, .failed): return String(localized: "Couldn't send report", table: "Reports")
        case (.block, .failed): return String(localized: "Couldn't block user", table: "Reports")
        case (.leave, .failed): return model.target.isInvitation ? String(localized: "Couldn't decline invitation", table: "Reports")
            : String(localized: "Couldn't leave room", table: "Reports")
        case (.report, .running): return String(localized: "Sending report…", table: "Reports")
        case (.block, .running): return String(localized: "Blocking user…", table: "Reports")
        case (.leave, .running): return model.target.isInvitation ? String(localized: "Declining invitation…", table: "Reports")
            : String(localized: "Leaving room…", table: "Reports")
        case (.report, _): return String(localized: "Preparing report…", table: "Reports")
        case (.block, _): return String(localized: "Blocking pending", table: "Reports")
        case (.leave, _): return model.target.isInvitation ? String(localized: "Decline pending", table: "Reports")
            : String(localized: "Leaving pending", table: "Reports")
        }
    }
}

private struct ReportReceiptCheckmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ReportCheckmarkShape()
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .frame(width: 28, height: 24)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { drawn = true }
            }
    }
}

private struct ReportCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}
