// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation

enum ContentReportStepState: Equatable {
    case pending, running, completed, waitingForReport
    case failed(String)
}

@MainActor
final class ContentReportViewModel: ObservableObject {
    let target: ContentReportTarget
    @Published var reason = ""
    @Published var shouldReport: Bool
    @Published var shouldBlock = false
    @Published var shouldLeave = false
    @Published private(set) var context: ContentReportContext?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var loadError: String?
    @Published private(set) var completed: Set<ContentReportStep> = []
    @Published private(set) var failures: [ContentReportStep: String] = [:]
    @Published private(set) var requested: [ContentReportStep]?
    @Published private(set) var submittedReason: String?
    @Published private(set) var activeStep: ContentReportStep?
    var onClose: ((Bool) -> Void)?
    var onSubmissionFinished: (() -> Void)?
    private let source: any ContentReportSource
    private let isCurrentSession: () -> Bool
    private var task: Task<Void, Never>?
    private var generation = 0
    private var stopped = false

    init(target: ContentReportTarget, source: any ContentReportSource, isCurrentSession: @escaping () -> Bool) {
        self.target = target; self.source = source; self.isCurrentSession = isCurrentSession
        shouldReport = !target.isInvitation
        shouldLeave = target.isInvitation
    }

    deinit { task?.cancel() }

    var isComplete: Bool { requested.map { !$0.isEmpty && Set($0).isSubset(of: completed) } ?? false }
    var remainingSteps: [ContentReportStep] { (requested ?? []).filter { !completed.contains($0) } }

    func state(of step: ContentReportStep) -> ContentReportStepState {
        if completed.contains(step) { return .completed }
        if let error = failures[step] { return .failed(error) }
        if activeStep == step { return .running }
        if step == .leave, !target.isInvitation, requested?.contains(.report) == true,
           failures[.report] != nil { return .waitingForReport }
        return .pending
    }

    var canSubmit: Bool {
        guard !stopped, isCurrentSession(), !isLoading, !isSubmitting, let context, !isComplete else { return false }
        if requested != nil { return true }
        guard !shouldReport || (context.canReport && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return false }
        return shouldReport || shouldLeave || (shouldBlock && context.blockUserID != nil && !context.isBlocked)
    }

    func load() {
        guard !stopped, !isSubmitting, requested == nil, isCurrentSession() else { return }
        task?.cancel(); generation += 1
        let version = generation
        isLoading = true; loadError = nil
        task = Task { [weak self, source] in
            do {
                let context = try await source.load()
                guard let self, self.accepts(version) else { return }
                self.context = context
                self.shouldBlock = false
                self.isLoading = false
            } catch {
                guard let self, self.accepts(version) else { return }
                self.isLoading = false; self.loadError = ContentReportFailure.message(for: error)
            }
        }
    }

    func submit() {
        guard canSubmit, let context else { return }
        if requested == nil {
            submittedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            var steps: [ContentReportStep] = []
            if target.isInvitation { steps.append(.leave) }
            if shouldReport { steps.append(.report) }
            if shouldBlock && !context.isBlocked && context.blockUserID != nil { steps.append(.block) }
            if shouldLeave && !target.isInvitation { steps.append(.leave) }
            requested = steps
        }
        guard let requested else { return }
        let reason = submittedReason ?? ""
        let version = generation
        isSubmitting = true; failures = [:]
        task = Task { [weak self, source] in
            for step in requested {
                guard let self, self.accepts(version) else { return }
                guard !self.completed.contains(step) else { continue }
                // Keep the room available until the requested report succeeds.
                // Blocking can still complete independently.
                if step == .leave, !self.target.isInvitation,
                   requested.contains(.report), !self.completed.contains(.report) { continue }
                self.activeStep = step
                do {
                    try await source.perform(step, reason: reason, userID: context.blockUserID)
                    guard self.accepts(version) else { return }
                    self.completed.insert(step)
                } catch {
                    guard self.accepts(version) else { return }
                    self.failures[step] = ContentReportFailure.message(for: error)
                }
            }
            guard let self, self.accepts(version) else { return }
            self.activeStep = nil
            self.isSubmitting = false
            self.onSubmissionFinished?()
        }
    }

    func close() { onClose?(completed.contains(.leave)) }
    func stop() { stopped = true; generation += 1; task?.cancel(); activeStep = nil; isSubmitting = false }
    #if DEBUG
    func waitForOperationForTesting() async { await task?.value }
    #endif

    private func accepts(_ version: Int) -> Bool {
        !stopped && !Task.isCancelled && generation == version && isCurrentSession()
    }
}
