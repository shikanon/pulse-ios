import SwiftUI

struct ReportComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session

    let targetType: String
    let targetID: String
    let targetTitle: String

    @State private var reason = "Harassment or bullying"
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?
    @State private var requiresAuthentication = false
    @State private var pendingReportIntent: PendingReportIntent?
    @State private var isReviewingRestoredReport = false
    @FocusState private var isDetailsFocused: Bool

    private let detailCharacterLimit = 1_000

    private let reasons = [
        "Harassment or bullying",
        "Hate or discrimination",
        "Sexual or violent content",
        "Privacy or impersonation",
        "Copyright or ownership",
        "Unsafe interactive behavior",
        "Something else"
    ]

    var body: some View {
        NavigationStack {
            Group {
                if submitted {
                    VStack(spacing: 18) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Color.pulseLime)
                        Text("Report received").font(.title2.bold())
                        Text("Our safety team will review it. Blocking the creator also removes their work and comments from your Pulse feed.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(.pulseLime)
                            .foregroundStyle(.black)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Section("Reporting") {
                            LabeledContent("Content") { Text(targetTitle).lineLimit(1) }
                            Picker("Reason", selection: $reason) {
                                ForEach(reasons, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Section("What happened?") {
                            TextField("Add details that will help a reviewer. Do not include passwords or private contact information.", text: $details, axis: .vertical)
                                .lineLimit(4...8)
                                .focused($isDetailsFocused)
                            Text("Optional, up to \(detailCharacterLimit) characters. Do not include passwords or private contact information.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            Button(action: submit) {
                                HStack {
                                    if isSubmitting { ProgressView().tint(.black) }
                                    Text(session.canPerformMemberActions ? "Submit report" : "Sign in to submit report").fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pulseLime)
                            .foregroundStyle(.black)
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("community.report.submit")
                        }
                        if !session.canPerformMemberActions {
                            Section {
                                Text("Your report stays only on this screen until you sign in. After signing in, review it and choose Submit report; Pulse will not send it automatically.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if isReviewingRestoredReport {
                            Section {
                                Label("Signed in. Review the report and choose Submit report when you are ready.", systemImage: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(Color.pulseLime)
                            }
                        }
                        if let errorMessage {
                            Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.pulseCoral) }
                        }
                    }
                }
            }
            .navigationTitle("Report content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $requiresAuthentication) {
                AuthenticationRequiredView(
                    title: "Sign in to submit a report",
                    detail: "Reports are tied to an account so Pulse can prevent duplicates and keep you informed about safety actions."
                )
            }
            .onChange(of: details) { _, updatedDetails in
                if updatedDetails.count > detailCharacterLimit {
                    details = String(updatedDetails.prefix(detailCharacterLimit))
                }
            }
            .onChange(of: session.user?.id) { oldUserID, newUserID in
                // A report written while signed in must not remain in a new
                // account's sheet. The only allowed cross-state handoff is
                // this sheet's anonymous, not-yet-submitted report intent.
                guard oldUserID != newUserID, pendingReportIntent == nil else { return }
                reason = reasons[0]
                details = ""
                isReviewingRestoredReport = false
            }
            .onChange(of: session.canResumeMemberActions) { _, canResume in
                guard canResume, let intent = pendingReportIntent,
                      intent.targetType == targetType, intent.targetID == targetID
                else { return }
                reason = intent.reason
                details = intent.details
                pendingReportIntent = nil
                requiresAuthentication = false
                isReviewingRestoredReport = true
            }
            .onChange(of: requiresAuthentication) { wasPresented, isPresented in
                if wasPresented, !isPresented, !session.canPerformMemberActions {
                    pendingReportIntent = nil
                    reason = reasons[0]
                    details = ""
                    isReviewingRestoredReport = false
                }
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.canPerformMemberActions else {
            pendingReportIntent = PendingReportIntent(
                targetType: targetType,
                targetID: targetID,
                targetTitle: targetTitle,
                reason: reason,
                details: trimmedDetails
            )
            requiresAuthentication = true
            return
        }
        isSubmitting = true
        errorMessage = nil
        isReviewingRestoredReport = false
        Task {
            do {
                _ = try await model.report(targetType: targetType, targetID: targetID, reason: reason, details: trimmedDetails)
                submitted = true
            } catch {
                if let apiError = error as? PulseAPIError,
                   let validationMessage = apiError.validationMessage(for: ["details", "reason"]) {
                    errorMessage = validationMessage
                    if apiError.hasValidationIssue(for: "details") { isDetailsFocused = true }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isSubmitting = false
        }
    }
}
