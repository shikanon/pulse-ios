import AuthenticationServices
import CryptoKit
import Security
import SwiftUI
import UniformTypeIdentifiers

struct ProfileSettingsView: View {
	@Environment(AppModel.self) private var appModel
    @Environment(SessionModel.self) private var session
    @Environment(PulseTelemetry.self) private var telemetry
    @AppStorage(CreationPreferences.allowRemixByDefaultKey) private var allowsRemixByDefault = CreationPreferences.defaultAllowRemix
    @AppStorage(PulseAppLanguage.storageKey) private var appLanguage = PulseAppLanguage.defaultLanguage.rawValue
    @State private var blockedUsers: [String] = []
    @State private var isLoadingBlockedUsers = true
    @State private var errorMessage: String?
    @State private var isSigningOut = false
    @State private var isExporting = false
    @State private var exportDocument: AccountExportDocument?
    @State private var isExportingFile = false
    @State private var isAccountDeletionPresented = false

    var body: some View {
        List {
            Section("Language") {
                Picker("App language", selection: $appLanguage) {
                    Text("English").tag(PulseAppLanguage.english.rawValue)
                    Text("简体中文").tag(PulseAppLanguage.simplifiedChinese.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.language")
                Text("Language changes apply immediately. Content created by people stays in its original language.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                NavigationLink("Edit profile", destination: EditProfileView())
                Button(role: .destructive) {
                    isSigningOut = true
                    Task {
                        await session.signOut()
                        isSigningOut = false
                    }
                } label: {
                    if isSigningOut { Label("Signing out…", systemImage: "hourglass") }
                    else { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                }
                .disabled(isSigningOut)
            }

            Section("Creation defaults") {
                Toggle(isOn: $allowsRemixByDefault) {
                    Label("Allow Remix for new works", systemImage: "arrow.triangle.branch")
                }
                .accessibilityIdentifier("settings.creation.allow-remix")
                Text("Choose whether people can Remix works you create from now on. This does not change works that already exist or are already public.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Safety") {
                if isLoadingBlockedUsers {
                    HStack { ProgressView(); Text("Loading blocked users…") }
                } else if blockedUsers.isEmpty {
                    Text("You have not blocked anyone.").foregroundStyle(.secondary)
                } else {
                    ForEach(blockedUsers, id: \.self) { username in
                        HStack {
                            Label("@\(username)", systemImage: "hand.raised.fill")
                            Spacer()
                            Button("Unblock") { Task { await unblock(username) } }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Unblock @\(username)")
                        }
                    }
                }
                NavigationLink {
                    CommunityGuidelinesView()
                } label: {
                    Label("Community guidelines", systemImage: "checklist")
                }
                NavigationLink {
                    ReportHistoryView()
                } label: {
                    Label("Your reports", systemImage: "flag.checkered")
                }
                .accessibilityHint("See the review status of reports you submitted")
            }

            if let supportURL = appModel.clientConfiguration?.resolvedSupportURL {
                Section("Support") {
                    Link(destination: supportURL) {
                        Label("Get help", systemImage: "questionmark.circle")
                    }
                    .accessibilityHint("Opens Pulse support in your browser")
                }
            }

            Section("Data controls") {
                Button {
                    Task { await exportData() }
                } label: {
                    if isExporting { Label("Preparing data export…", systemImage: "hourglass") }
                    else { Label("Download your data", systemImage: "square.and.arrow.down") }
                }
                .disabled(isExporting)
                Button(role: .destructive) {
                    isAccountDeletionPresented = true
                } label: {
                    Label("Delete account", systemImage: "trash")
                }
                Text("Deletion withdraws your works, removes private data access, deletes your comments and revokes your Apple authorization. Existing works by other creators keep an anonymized Remix attribution.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle(isOn: Binding(
                    get: { telemetry.isDiagnosticsSharingEnabled },
                    set: { telemetry.setDiagnosticsSharingEnabled($0) }
                )) {
                    Label("Share anonymous diagnostics", systemImage: "chart.line.uptrend.xyaxis")
                }
                Text("Optional diagnostics help us find crashes, slow launches and broken flows. They contain only limited event categories and app version, never your account identity, prompts, comments, plans, materials, tokens or raw crash reports.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
				if let privacyPolicyURL = appModel.clientConfiguration?.resolvedPrivacyPolicyURL {
					Link(destination: privacyPolicyURL) {
						Label("Privacy policy", systemImage: "hand.raised")
					}
                    .accessibilityHint("Opens Pulse's privacy policy in your browser")
                }
            }

            if let policy = appModel.clientConfiguration?.termsPolicy {
                Section("Legal") {
                    Link(destination: policy.url) {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                    .accessibilityHint("Opens Pulse Terms of Use in your browser")
                    if let acceptance = session.user?.termsAcceptance, acceptance.matches(policy) {
                        LabeledContent("Current terms") {
                            Text("Accepted \(acceptance.version)")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Current Terms of Use version \(acceptance.version) accepted")
                    }
                }
            }

            Section("About") {
                HStack {
                    Label("Pulse version", systemImage: "info.circle")
                    Spacer()
                    Text(PulseAppVersion.current.displayLabel)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("settings.app-version")
                .accessibilityLabel("Pulse \(PulseAppVersion.current.displayLabel)")
                .accessibilityHint("Installed app version and build number")
            }
        }
        // Navigation titles are cached by UINavigationItem and do not always
        // re-resolve a LocalizedStringKey when the app locale changes in
        // place. Supplying the selected bundle's resolved value keeps the
        // currently presented screen in sync with the language picker.
        .navigationTitle(selectedLanguage.localizedString("Settings"))
        .task { await loadBlockedUsers() }
        .fileExporter(isPresented: $isExportingFile, document: exportDocument, contentType: .json, defaultFilename: "pulse-account-export") { result in
            if case let .failure(error) = result { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $isAccountDeletionPresented) {
            AccountDeletionView()
        }
        .alert("Couldn’t update safety settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var selectedLanguage: PulseAppLanguage {
        PulseAppLanguage(rawValue: appLanguage) ?? .defaultLanguage
    }

    private func loadBlockedUsers() async {
        isLoadingBlockedUsers = true
        defer { isLoadingBlockedUsers = false }
        do {
            blockedUsers = try await session.api.blockedUsers()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unblock(_ username: String) async {
        do {
            try await session.api.unblock(username: username)
            blockedUsers.removeAll { $0 == username }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportData() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let export = try await session.api.exportAccountData()
            exportDocument = try AccountExportDocument(export: export)
            isExportingFile = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReportHistoryView: View {
    @Environment(SessionModel.self) private var session
    @State private var reports: [ReporterReport] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("Loading your reports…") }
            } else if reports.isEmpty, let errorMessage {
                ContentUnavailableView {
                    Label("Your reports are unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try again") { Task { await load(reset: true) } }
                }
            } else if reports.isEmpty {
                ContentUnavailableView {
                    Label("No reports yet", systemImage: "flag")
                } description: {
                    Text("Reports you submit from a work or comment menu will appear here.")
                }
            } else {
                Section {
                    ForEach(reports) { report in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(report.statusTitle, systemImage: statusSymbol(for: report.status))
                                    .font(.headline)
                                Spacer()
                                Text(report.updatedAt, format: .dateTime.month(.abbreviated).day().year())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Report about a \(report.targetType)")
                                .font(.subheadline)
                            Text(report.reason)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(report.statusDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(report.statusTitle). \(report.reason). \(report.statusDetail)")
                    }
                } footer: {
                    Text("To protect everyone’s privacy, Pulse shows your report status but not moderator notes or actions taken on another account.")
                }
                if nextCursor != nil {
                    Section {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if isLoadingMore { HStack { ProgressView(); Text("Loading older reports…") } }
                            else { Text("Load older reports") }
                        }
                        .disabled(isLoadingMore)
                    }
                }
            }
        }
        .navigationTitle("Your reports")
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(reset: true) } }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh report status")
            }
        }
    }

    private func load(reset: Bool) async {
        guard !reset || !isLoadingMore else { return }
        if reset { isLoading = true }
        defer { if reset { isLoading = false } }
        do {
            let page = try await session.api.fetchMyReportsPage(cursor: reset ? nil : nextCursor)
            if reset { reports = page.data } else { reports.append(contentsOf: page.data) }
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard nextCursor != nil, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await load(reset: false)
    }

    private func statusSymbol(for status: String) -> String {
        switch status {
        case "open": "checkmark.shield"
        case "investigating": "magnifyingglass"
        case "actioned", "dismissed": "checkmark.shield.fill"
        default: "flag"
        }
    }
}

private struct AccountDeletionView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var authorization: AppleDeletionAuthorization?
    @State private var deletionIdempotencyKey = UUID().uuidString
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var expectedConfirmation: String { "DELETE \(session.user?.username ?? "")" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Before you delete") {
                    Text("This cannot be undone. Your published and draft works will be withdrawn, your private assets become inaccessible, and your comments are deleted. Existing Remix works owned by other people remain available with anonymized original-creator attribution.")
                    Text("You will authenticate with Apple again so Pulse can revoke that authorization before deleting the account.")
                }
                Section("Confirm deletion") {
                    TextField(expectedConfirmation, text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Type \(expectedConfirmation) to confirm account deletion")
                    if authorization == nil {
                        AppleDeletionAuthorizationButton { value in
                            authorization = value
                            errorMessage = nil
                        }
                    } else {
                        Label("Apple authentication ready", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                }
                Section {
                    Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
                        .disabled(isDeleting || confirmation != expectedConfirmation || authorization == nil)
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isDeleting) } }
            .alert("Couldn’t delete account", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please try again.") }
        }
    }

    private func deleteAccount() async {
        guard let authorization else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await session.api.deleteAccount(
                confirmation: confirmation,
                authorization: authorization,
                idempotencyKey: deletionIdempotencyKey
            )
            session.completeAccountDeletion()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AppleDeletionAuthorizationButton: View {
    @State private var nonce = ""
    let onAuthorized: (AppleDeletionAuthorization) -> Void

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            let rawNonce = makeNonce()
            nonce = SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
            request.nonce = nonce
        } onCompletion: { result in
            guard case let .success(authorization) = result,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  let authorizationCodeData = credential.authorizationCode,
                  let authorizationCode = String(data: authorizationCodeData, encoding: .utf8)
            else { return }
            onAuthorized(AppleDeletionAuthorization(identityToken: identityToken, nonce: nonce, authorizationCode: authorizationCode))
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 44)
        .accessibilityLabel("Authenticate with Apple to delete your account")
    }

    private func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString }
        return Data(bytes).base64EncodedString()
    }
}

private struct AccountExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    private let data: Data

    init(export: AccountDataExport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        data = try encoder.encode(export)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct EditProfileView: View {
    private enum ProfileField: Hashable { case username, displayName }

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var displayName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: ProfileField?

    var body: some View {
        Form {
            Section("Public profile") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                TextField("Display name", text: $displayName)
                    .focused($focusedField, equals: .displayName)
            }
            Section {
                Text("Your username credits your works and Remix attribution. It uses 3–30 letters, numbers, dots, underscores or hyphens.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit profile")
        .task {
            username = session.user?.username ?? ""
            displayName = session.user?.displayName ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(isSaving || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Couldn’t save profile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await session.updateProfile(username: username.trimmingCharacters(in: .whitespacesAndNewlines), displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            if let apiError = error as? PulseAPIError,
               let validationMessage = apiError.validationMessage(for: ["username", "displayName"]) {
                errorMessage = validationMessage
                if apiError.hasValidationIssue(for: "username") {
                    focusedField = .username
                } else if apiError.hasValidationIssue(for: "displayName") {
                    focusedField = .displayName
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct CommunityGuidelinesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let supportURL = appModel.clientConfiguration?.resolvedSupportURL {
                Section("Need help?") {
                    Button {
                        openURL(supportURL)
                    } label: {
                        Label("Contact Pulse support", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("community-guidelines.contact-support")
                    .accessibilityHint("Opens Pulse support in your browser")
                }
            }
            Section("Keep Pulse safe") {
                Text("Do not post harassment, hate, sexual content involving minors, threats, private information, impersonation, copyright infringement or malicious interactive code.")
                Text("Use Report from a work or comment menu when something needs review. Blocking removes that person’s works and comments from your Pulse surfaces.")
            }
        }
        .navigationTitle("Community guidelines")
    }
}

struct CommunityGuidelinesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CommunityGuidelinesView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
