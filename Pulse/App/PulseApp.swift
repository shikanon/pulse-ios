import SwiftUI
import UIKit

@main
struct PulseApp: App {
    @UIApplicationDelegateAdaptor(PulseApplicationDelegate.self) private var applicationDelegate
    @State private var appModel = AppModel()
    @State private var sessionModel = SessionModel()
    @State private var telemetry = PulseTelemetry()
    @State private var runtimeLifecycle = PulseRuntimeLifecycle()
    @AppStorage(PulseAppLanguage.storageKey) private var appLanguage = PulseAppLanguage.defaultLanguage.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(sessionModel)
                .environment(telemetry)
                .environment(runtimeLifecycle)
                .environment(\.locale, PulseAppLanguage(rawValue: appLanguage)?.locale ?? PulseAppLanguage.defaultLanguage.locale)
                .preferredColorScheme(.dark)
        }
    }
}

/// UIKit delivers this callback when the system finished background transfer
/// events while Pulse was not running. URLSession's completion handler must be
/// released only after the upload coordinator has durably recorded the task
/// result, otherwise iOS may not relaunch the app for later transfers.
final class PulseApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundAssetUploadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundAssetUploadCoordinator.shared.handleEvents(completionHandler: completionHandler)
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SessionModel.self) private var session
    @Environment(PulseTelemetry.self) private var telemetry
    @Environment(PulseRuntimeLifecycle.self) private var runtimeLifecycle
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var homeTabResetToken = UUID()
    @State private var profileTabResetToken = UUID()
    @State private var launchState: PulseLaunchState = .loading

    var body: some View {
        @Bindable var bindableSession = session
        @Bindable var bindableAppModel = appModel
        Group {
            if launchState.allowsAppContent {
                mainContent
            } else {
                LaunchGateView(state: launchState, retry: { Task { await bootstrap() } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task {
            queueUITestDeepLinkIfNeeded()
            telemetry.start()
            await bootstrap()
        }
        .onAppear { runtimeLifecycle.update(scenePhase: scenePhase) }
        .onChange(of: scenePhase) { _, nextScenePhase in
            runtimeLifecycle.update(scenePhase: nextScenePhase)
        }
        .onChange(of: appModel.pendingRemixSource?.id) { _, id in
            if id != nil { selectedTab = .create }
        }
        .onOpenURL { url in
            guard let deepLink = PulseDeepLink.parse(url) else {
                telemetry.record(.deepLinkFailed, attributes: ["entry_point": "universal_link", "error_category": "invalid_link"])
                return
            }
            appModel.queueDeepLink(deepLink)
            guard launchState.allowsAppContent, !appModel.isOfflineReadOnly else { return }
            Task { await openQueuedDeepLink() }
        }
        .fullScreenCover(item: $bindableAppModel.sharedWork) { work in
            SharedWorkPlayer(work: work)
                .environment(appModel)
                .environment(session)
        }
        .sheet(item: $bindableAppModel.reportTarget) { target in
            ReportComposerSheet(
                targetType: "work",
                targetID: target.id.uuidString.lowercased(),
                targetTitle: target.title
            )
            .environment(appModel)
            .environment(session)
        }
        .fullScreenCover(isPresented: $bindableSession.needsTermsAcceptance) {
            TermsAcceptanceView()
                .environment(session)
        }
        .fullScreenCover(isPresented: Binding(
            get: { session.needsProfileSetup && !session.needsTermsAcceptance },
            set: { _ in }
        )) {
            ProfileSetupView()
                .environment(session)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { viewport in
            ZStack(alignment: .bottom) {
                HomeTabRoot(
                    isSelected: selectedTab == .home,
                    resetToken: homeTabResetToken,
                    reconnect: { Task { await bootstrap() } }
                )
                .tabVisibility(selectedTab == .home)

                createTabContent(viewportHeight: viewport.size.height)
                    .padding(.bottom, 88)
                    .tabVisibility(selectedTab == .create)
                    .environment(\.creationSurfaceVisible, selectedTab == .create && appModel.sharedWork == nil && !session.needsTermsAcceptance)

                profileTabContent
                    .padding(.bottom, 88)
                    .tabVisibility(selectedTab == .profile)

                // Keep the system gesture area visually stable while the
                // paged Feed moves behind the floating navigation control.
                Color.black
                    .frame(height: 36)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)

                AppTabBar(selectedTab: $selectedTab, onReselect: resetTabToRoot)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let job = appModel.activeCreationJob, selectedTab == .home {
                    Button { selectedTab = .create } label: {
                        HStack {
                            if !job.stage.isTerminal { ProgressView().tint(.pulseLime) }
                            Text(job.stage == .succeeded ? "Your creation is ready to review" : job.stage.productTitle).font(.footnote.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(12).foregroundStyle(.white).background(Color.pulseViolet.opacity(0.22))
                    }.accessibilityIdentifier("app.creation-status")
                }
                if appModel.isOfflineReadOnly {
                    OfflineReadOnlyNotice(retry: { Task { await bootstrap() } })
                }
            }
        }
        .overlay {
            if let unavailable = appModel.deepLinkUnavailable {
                DeepLinkUnavailableView(
                    unavailable: unavailable,
                    retry: { Task { await openQueuedDeepLink() } },
                    returnHome: {
                        appModel.dismissUnavailableDeepLink()
                        selectedTab = .home
                    }
                )
                .transition(.opacity)
            }
        }
        .onChange(of: session.user) { _, user in
            guard let user else { return }
            appModel.creatorName = user.username
            Task { await appModel.loadMyWorks() }
        }
    }

    @ViewBuilder
    private func createTabContent(viewportHeight: CGFloat) -> some View {
        if appModel.isOfflineReadOnly {
            OfflineReadOnlySurface(
                title: "Creation needs a connection",
                detail: "Your saved Feed is available, but creating or resuming a generation needs the latest safety checks and a connection to Pulse.",
                retry: { Task { await bootstrap() } }
            )
        } else {
            VStack(spacing: 0) {
                CreateView(
                    parent: appModel.pendingRemixSource,
                    recoveryWork: appModel.pendingGenerationRecovery,
                    interactionViewportHeight: viewportHeight
                ) {
                    appModel.clearPendingRemix()
                    appModel.clearPendingGenerationRecovery()
                    selectedTab = .home
                }
                .id("\(appModel.pendingRemixSource?.id.uuidString ?? "original"):\(appModel.pendingGenerationRecovery?.id.uuidString ?? "new")")
            }
        }
    }

    @ViewBuilder
    private var profileTabContent: some View {
        if appModel.isOfflineReadOnly {
            OfflineReadOnlySurface(
                title: "Account tools need a connection",
                detail: "Connect to Pulse before changing your profile, managing safety controls, or accessing account data.",
                retry: { Task { await bootstrap() } }
            )
            .id(profileTabResetToken)
        } else {
            ProfileView(selectedTab: $selectedTab, resetToken: profileTabResetToken)
        }
    }

    private func resetTabToRoot(_ tab: AppTab) {
        switch tab {
        case .home:
            homeTabResetToken = UUID()
        case .create:
            break
        case .profile:
            profileTabResetToken = UUID()
        }
    }

    private func bootstrap() async {
        launchState = .loading
        appModel.isOfflineReadOnly = false

        let configuration: PulseClientConfiguration
        do {
            configuration = try await appModel.api.fetchClientConfiguration()
            appModel.cacheClientConfiguration(configuration)
        } catch {
            guard let cachedConfiguration = appModel.restoreCachedClientConfiguration() else {
                launchState = .unavailable("Pulse needs a connection to check service availability. Check your network and try again.")
                telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "unavailable"])
                return
            }
            appModel.clientConfiguration = cachedConfiguration
            session.configureTermsAcceptance(cachedConfiguration.termsPolicy)
            if cachedConfiguration.maintenance {
                launchState = .maintenance(cachedConfiguration)
                telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "maintenance"])
                return
            }
            if cachedConfiguration.requiresUpdate(for: .current) {
                launchState = .updateRequired(cachedConfiguration)
                telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "update_required"])
                return
            }
            guard appModel.restoreCachedFeed() else {
                launchState = .unavailable("Pulse needs a connection to check service availability. A saved Feed is not available on this device.")
                telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "unavailable"])
                return
            }
            appModel.isOfflineReadOnly = true
            appModel.feedError = "You’re offline. You can browse this saved Feed, but interactions need a connection."
            launchState = .ready
            telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "offline_cached_read_only"])
            return
        }

        appModel.clientConfiguration = configuration
        session.configureTermsAcceptance(configuration.termsPolicy)
        if configuration.maintenance {
            launchState = .maintenance(configuration)
            telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "maintenance"])
            return
        }
        if configuration.requiresUpdate(for: .current) {
            launchState = .updateRequired(configuration)
            telemetry.record(.launchGateDisplayed, attributes: ["screen_id": "launch", "outcome": "update_required"])
            return
        }
        await session.restore()
        if let user = session.user {
            appModel.creatorName = user.username
            await appModel.loadMyWorks()
        }
        appModel.restoreCachedFeed()
        await appModel.loadFeed()
        launchState = .ready
        await openQueuedDeepLink()
    }

    private func openQueuedDeepLink() async {
        let destination = await appModel.resolvePendingDeepLink()
        if case .some(.remix) = destination {
            selectedTab = .create
            telemetry.record(.deepLinkResolved, attributes: ["entry_point": "universal_link", "outcome": "remix"])
        } else if case .some(.publicWork) = destination {
            telemetry.record(.deepLinkResolved, attributes: ["entry_point": "universal_link", "outcome": "shared_work"])
        } else if case .some(.report) = destination {
            telemetry.record(.deepLinkResolved, attributes: ["entry_point": "universal_link", "outcome": "report"])
        } else if appModel.deepLinkUnavailable != nil {
            telemetry.record(.deepLinkFailed, attributes: ["entry_point": "universal_link", "error_category": "unavailable"])
        }
    }

    private func queueUITestDeepLinkIfNeeded() {
#if DEBUG
        guard let rawLink = ProcessInfo.processInfo.environment["PULSE_UI_TEST_DEEP_LINK"],
              let deepLink = PulseDeepLink.parse(URL(string: rawLink) ?? URL(fileURLWithPath: "/invalid"))
        else { return }
        appModel.queueDeepLink(deepLink)
#endif
    }
}

private struct DeepLinkUnavailableView: View {
    let unavailable: DeepLinkUnavailable
    let retry: () -> Void
    let returnHome: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.pulseCoral)
                .accessibilityHidden(true)
            Text(unavailable.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(unavailable.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(unavailable.retryTitle, action: retry)
                .buttonStyle(.borderedProminent)
                .tint(.pulseLime)
                .foregroundStyle(.black)
            Button("Back to Home", action: returnHome)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, ignoresSafeAreaEdges: .all)
        .accessibilityIdentifier(unavailable.accessibilityIdentifier)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(unavailable.title). \(unavailable.detail)")
    }

    private var symbol: String {
        switch unavailable {
        case .removed: "link.badge.plus"
        case .ageRestricted: "hand.raised.fill"
        case .incompatible: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .temporarilyUnavailable, .unavailable: "exclamationmark.triangle.fill"
        }
    }
}

private struct LaunchGateView: View {
    let state: PulseLaunchState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let actionURL {
                Link(actionTitle, destination: actionURL)
                    .buttonStyle(.borderedProminent)
                    .tint(.pulseLime)
                    .foregroundStyle(.black)
            }
            if case .maintenance = state {
                Button("Check again", action: retry)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            if case .unavailable = state {
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(.pulseLime)
                    .foregroundStyle(.black)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch state {
        case .loading: "Opening Pulse"
        case .maintenance: "Pulse is being updated"
        case .updateRequired: "Update Pulse to continue"
        case .unavailable: "Pulse is unavailable right now"
        case .ready: ""
        }
    }

    private var detail: String {
        switch state {
        case .loading: "Checking service availability…"
        case let .maintenance(configuration): configuration.maintenanceMessage ?? "Pulse is being updated. Please try again shortly."
        case .updateRequired: "A newer version includes important safety and compatibility updates."
        case let .unavailable(message): message
        case .ready: ""
        }
    }

    private var symbol: String {
        switch state {
        case .loading: "sparkles"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .updateRequired: "arrow.down.app.fill"
        case .unavailable: "wifi.exclamationmark"
        case .ready: ""
        }
    }

    private var tint: Color {
        switch state {
        case .maintenance, .updateRequired: .pulseViolet
        case .unavailable: .pulseCoral
        case .loading, .ready: .pulseLime
        }
    }

    private var actionTitle: String? {
        switch state {
        case .maintenance: "Contact support"
        case .updateRequired: "Update on the App Store"
        default: nil
        }
    }

    private var actionURL: URL? {
        switch state {
        case let .maintenance(configuration): configuration.resolvedSupportURL
        case let .updateRequired(configuration): configuration.resolvedAppStoreURL
        default: nil
        }
    }
}

private struct OfflineReadOnlyNotice: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "wifi.slash")
                .accessibilityHidden(true)
            Text("Offline — viewing a saved Feed")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Reconnect", action: retry)
                .buttonStyle(.bordered)
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.black.opacity(0.92))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Offline. Viewing a saved Feed. Reconnect to use account and interaction features.")
    }
}

private struct OfflineReadOnlySurface: View {
    let title: String
    let detail: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "wifi.slash",
            description: Text(detail)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Button("Reconnect", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(.pulseLime)
                .foregroundStyle(.black)
                .padding(.bottom, 130)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }
}

private struct TermsAcceptanceView: View {
    @Environment(SessionModel.self) private var session
    @State private var isAccepting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(Color.pulseLime)
                    Text("Review the Terms of Use")
                        .font(.title.weight(.bold))
                    Text("Before creating, interacting with, or updating your Pulse profile, please review and accept the current Terms of Use. You can still sign out or use safety and account-deletion controls without accepting.")
                        .foregroundStyle(.secondary)
                    if let policy = session.currentTermsPolicy {
                        Link(destination: policy.url) {
                            Label("Read Terms of Use", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityHint("Opens Pulse Terms of Use in your browser")
                        Text("Terms version \(policy.version)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseCoral)
                    }
                    Button(action: accept) {
                        HStack {
                            if isAccepting { ProgressView().tint(.black) }
                            Text("Accept and continue").fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pulseLime)
                    .foregroundStyle(.black)
                    .disabled(isAccepting || session.currentTermsPolicy == nil)
                    .accessibilityIdentifier("terms.accept")
                    Button("Not now", role: .cancel) {
                        Task { await session.signOut() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isAccepting)
                }
                .padding(24)
                .padding(.top, 34)
            }
            .background(.black)
            .foregroundStyle(.white)
        }
        .interactiveDismissDisabled()
    }

    private func accept() {
        isAccepting = true
        errorMessage = nil
        Task {
            do {
                try await session.acceptTerms()
            } catch {
                errorMessage = error.localizedDescription
            }
            isAccepting = false
        }
    }
}

private struct ProfileSetupView: View {
    @Environment(SessionModel.self) private var session
    @State private var username = ""
    @State private var displayName = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose how Pulse will credit you")
                        .font(.title.weight(.bold))
                    Text("Your handle appears on works and Remix attribution. You can change it later in account settings.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Handle").font(.headline)
                        TextField("your.handle", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(13).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("profile.setup.username")
                        Text("3 to 30 characters: letters, numbers, dots, underscores, or hyphens.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display name").font(.headline)
                        TextField("What should people call you?", text: $displayName)
                            .padding(13).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(Color.pulseCoral)
                    }
                    Button(action: save) {
                        HStack { if isSaving { ProgressView().tint(.black) }; Text("Continue to Pulse").fontWeight(.bold) }
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                    .disabled(normalizedUsername.count < 3 || isSaving)
                }
                .padding(24).padding(.top, 34)
            }
            .background(.black).foregroundStyle(.white)
            .onAppear {
                if username.isEmpty { username = session.user?.username ?? "" }
                if displayName.isEmpty { displayName = session.user?.displayName ?? "" }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await session.updateProfile(username: normalizedUsername, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

struct AuthenticationRequiredView: View {
    let title: String
    let detail: String
    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.pulseLime)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            AppleSignInButton()
                .frame(maxWidth: 340)
            if session.isSigningIn { ProgressView("Signing in…").tint(.white) }
            if let error = session.authenticationError {
                Text(error).font(.footnote).foregroundStyle(Color.pulseCoral).multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
    }
}

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, create, profile
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .create: "Create"
        case .profile: "Profile"
        }
    }
    var accessibilityLabel: LocalizedStringKey {
        self == .create ? "Create an original app from one sentence" : label
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .create: "plus"
        case .profile: "person"
        }
    }
}

private extension View {
    @ViewBuilder
    func tabVisibility(_ isVisible: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
