import Foundation
import SwiftUI
import UIKit

struct FeedView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    @Environment(PulseTelemetry.self) private var telemetry
    @Environment(PulseRuntimeLifecycle.self) private var runtimeLifecycle
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingRemix: InteractiveApp?
    @State private var isRemixAuthenticationPresented = false
    @State private var activeAppID: UUID?
    @State private var offlineActionMessage: String?
    let isTabSelected: Bool
    let resetToken: UUID
    let reconnect: () -> Void

    init(isTabSelected: Bool, resetToken: UUID, reconnect: @escaping () -> Void) {
        self.isTabSelected = isTabSelected
        self.resetToken = resetToken
        self.reconnect = reconnect
    }

    var body: some View {
        ZStack(alignment: .top) {
            if model.feed.isEmpty, !model.isLoadingFeed {
                ContentUnavailableView("The feed is empty", systemImage: "sparkles", description: Text("Create the first interactive app or try loading again."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else {
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.feed) { app in
                                FeedCard(
                                    app: app,
                                    isActive: activeAppID == app.id,
                                    isApplicationActive: scenePhase == .active && isTabSelected,
                                    isSystemRuntimeAvailable: runtimeLifecycle.allowsRuntime,
                                    isRemixPresented: isRemixAuthenticationPresented || offlineActionMessage != nil,
                                    onRemix: { requestRemix(app) }
                                )
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .id(app.id)
                            }
                            if model.isLoadingMoreFeed {
                                ProgressView("Loading more Pulse…")
                                    .frame(width: viewport.size.width, height: viewport.size.height)
                                    .background(.black)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $activeAppID, anchor: .top)
                    .refreshable {
                        await model.refreshFeed()
                    }
                }
            }
            if model.isLoadingFeed {
                ProgressView("Loading Pulse…").padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.top, 58)
            } else if let error = model.feedError {
                FeedStatusNotice(
                    message: error,
                    usesCachedFeed: model.feedDataSource.cachedAt != nil,
                    retry: {
                        if model.isOfflineReadOnly {
                            reconnect()
                        } else {
                            Task { await model.loadFeed() }
                        }
                    }
                )
                .padding(.top, 58)
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .sheet(isPresented: $isRemixAuthenticationPresented) {
            AuthenticationRequiredView(
                title: "Sign in to Remix this work",
                detail: "Remix drafts belong to your account so you can return to them on another device."
            )
        }
        .alert("Connection needed", isPresented: Binding(get: { offlineActionMessage != nil }, set: { if !$0 { offlineActionMessage = nil } })) {
            Button("OK", role: .cancel) { offlineActionMessage = nil }
        } message: {
            Text(offlineActionMessage ?? "Reconnect to Pulse and try again.")
        }
        .onChange(of: model.feed) { _, feed in
            if activeAppID == nil || !feed.contains(where: { $0.id == activeAppID }) {
                activeAppID = feed.first?.id
            }
            if !feed.isEmpty {
                telemetry.record(.feedLoaded, attributes: [
                    "screen_id": "feed",
                    "source": model.feedDataSource.cachedAt == nil ? "live" : "cached"
                ])
            }
        }
        .onChange(of: model.feedError) { _, error in
            if error != nil {
                telemetry.record(.feedLoadFailed, attributes: ["screen_id": "feed", "error_category": "network_or_server"])
            }
        }
        .onChange(of: activeAppID) { _, appID in
            if appID != nil {
                telemetry.record(.workImpression, attributes: ["screen_id": "feed"])
            }
            guard !model.isOfflineReadOnly,
                  let appID,
                  let index = model.feed.firstIndex(where: { $0.id == appID }),
                  index >= max(0, model.feed.count - 3)
            else { return }
            Task { await model.loadMoreFeed() }
        }
        .task(id: activeAppID) {
            guard let activeAppID else { return }
            await model.prefetchFeedStaticPreviews(after: activeAppID)
        }
        .onChange(of: model.feedFocusID) { _, id in
            guard let id, model.feed.contains(where: { $0.id == id }) else { return }
            activeAppID = id
            model.feedFocusID = nil
        }
        .onChange(of: resetToken) { _, _ in
            activeAppID = model.feed.first?.id
        }
        .onChange(of: session.canResumeMemberActions) { _, canResume in
            guard canResume, let app = pendingRemix else { return }
            pendingRemix = nil
            isRemixAuthenticationPresented = false
            model.startRemix(app)
        }
        .onChange(of: isRemixAuthenticationPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented, !session.canPerformMemberActions {
                pendingRemix = nil
            }
        }
        .onAppear { activeAppID = model.feed.first?.id }
    }

    private func requestRemix(_ app: InteractiveApp) {
        guard app.allowRemix else { return }
        guard !model.isOfflineReadOnly else {
            offlineActionMessage = "Reconnect to Pulse before starting a Remix. Saved Feed cards are read-only while you’re offline."
            return
        }
        guard session.canPerformMemberActions else {
            pendingRemix = app
            isRemixAuthenticationPresented = true
            return
        }
        model.startRemix(app)
    }
}

struct HomeTabRoot: View {
    let isSelected: Bool
    let resetToken: UUID
    let reconnect: () -> Void

    var body: some View {
        NavigationStack {
            FeedView(isTabSelected: isSelected, resetToken: resetToken, reconnect: reconnect)
        }
    }
}

private struct FeedStatusNotice: View {
    let message: String
    let usesCachedFeed: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: usesCachedFeed ? "clock.arrow.circlepath" : "wifi.exclamationmark")
                .accessibilityHidden(true)
            Text(message)
                .lineLimit(2)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .tint(.pulseLime)
                .foregroundStyle(.black)
        }
        .font(.footnote)
        .padding(10)
        .background(.black.opacity(0.90), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(usesCachedFeed ? "Offline Feed" : "Feed unavailable")
    }
}

private struct FeedCard: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    @Environment(PulseTelemetry.self) private var telemetry
    let app: InteractiveApp
    let isActive: Bool
    let isApplicationActive: Bool
    let isSystemRuntimeAvailable: Bool
    let isRemixPresented: Bool
    let onRemix: () -> Void
    @State private var touchPoint = CGPoint(x: 0.5, y: 0.62)
    @State private var isSharePresented = false
    @State private var isCommentsPresented = false
    @State private var isDetailsPresented = false
    @State private var isReportPresented = false
    @State private var isCommunityGuidelinesPresented = false
    @State private var isLikeAuthenticationPresented = false
    @State private var shouldResumeLike = false
    @State private var isBlockConfirmationPresented = false
    @State private var isBlockAuthenticationPresented = false
    @State private var shouldResumeBlock = false
    @State private var blockError: String?
    @State private var offlineActionMessage: String?

    private var isRuntimeActive: Bool {
        PulseAccessibility.runtimeIsActive(
            isVisible: isActive,
            isApplicationActive: isApplicationActive,
            isObscured: isDetailsPresented || model.isOfflineReadOnly || isRemixPresented || isCommentsPresented || isSharePresented || isReportPresented || isCommunityGuidelinesPresented || isLikeAuthenticationPresented || isBlockConfirmationPresented || isBlockAuthenticationPresented || blockError != nil || offlineActionMessage != nil,
            isSystemRuntimeAvailable: isSystemRuntimeAvailable
        )
    }

    private var artifactURL: URL? {
#if DEBUG
        // The test fixture reaches a closed local port through the same
        // ArtifactRuntimeSource and URLSession path used in production. It is
        // unavailable in Release and never changes a production Feed item.
        if ProcessInfo.processInfo.environment["PULSE_UI_TEST_ARTIFACT_FAILURE"] == "1" {
            return URL(string: "http://127.0.0.1:1/v1/artifacts/00000000-0000-4000-8000-000000000000/files/index.html")
        }
#endif
        return model.artifactURL(for: app)
    }

    var body: some View {
        GeometryReader { proxy in
            let detailsHeight = InteractiveSurfaceLayout.homeSummaryHeight
            let tabBarClearance = InteractiveSurfaceLayout.homeTabBarClearance
            let interactionHeight = InteractiveSurfaceLayout.interactionHeight(in: proxy.size.height)

            VStack(spacing: 0) {
                ZStack {
                    if !model.isOfflineReadOnly, let artifactURL, isActive {
                        ArtifactPlayerView(
                            url: artifactURL,
                            isActive: isRuntimeActive,
                            title: app.title,
                            interactionSummary: app.theme,
                            accessibilityIdentifier: "published.artifact.player",
                            telemetryScreen: "feed"
                        )
                        .frame(width: proxy.size.width, height: interactionHeight)
                        .clipped()
                        .background(.black)
                    } else {
                        if !isActive {
                            FeedStaticPreview(app: app, touchPoint: $touchPoint)
                                .accessibilityIdentifier("published.static-preview")
                        } else {
                            LivingCanvas(app: app, touchPoint: $touchPoint, isActive: isRuntimeActive)
                                .allowsHitTesting(isRuntimeActive)
                                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                                    touchPoint = CGPoint(
                                        x: value.location.x / proxy.size.width,
                                        y: value.location.y / interactionHeight
                                    )
                                })
                                .accessibilityIdentifier("published.interactive.canvas")
                                .accessibilityValue("touch-x-\(Int(touchPoint.x * 100))-y-\(Int(touchPoint.y * 100))")
                            }
                    }

#if DEBUG
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(.white.opacity(0.001))
                            .frame(height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Interaction layout boundary")
                            .accessibilityIdentifier("feed.interaction-boundary")
                    }
                    .allowsHitTesting(false)
#endif
                }
                .frame(width: proxy.size.width, height: interactionHeight)
                .clipped()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("feed.interaction-surface")

                WorkSummaryPanel(
                    app: app,
                    details: { isDetailsPresented = true },
                    like: requestLike,
                    comments: requestComments,
                    remix: onRemix,
                    share: {
                        telemetry.record(.shareInvoked, attributes: ["screen_id": "feed"])
                        isSharePresented = true
                    },
                    report: requestReport,
                    block: requestBlock,
                    guidelines: { isCommunityGuidelinesPresented = true }
                )
                .frame(height: detailsHeight)

                Color.black
                    .frame(height: tabBarClearance)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(.black)
        }
        .sheet(isPresented: $isSharePresented) { ShareSheet(app: app) }
        .sheet(isPresented: $isCommentsPresented) { CommentsSheet(app: app) }
        .sheet(isPresented: $isDetailsPresented) { WorkDetailsSheet(app: app) }
        .sheet(isPresented: $isReportPresented) {
            ReportComposerSheet(targetType: "work", targetID: app.id.uuidString.lowercased(), targetTitle: app.title)
        }
        .sheet(isPresented: $isCommunityGuidelinesPresented) {
            CommunityGuidelinesSheet()
        }
        .sheet(isPresented: $isLikeAuthenticationPresented) {
            AuthenticationRequiredView(title: "Sign in to like this work", detail: "Likes are saved to your account and stay in sync across devices.")
        }
        .confirmationDialog("Block @\(app.creator)?", isPresented: $isBlockConfirmationPresented, titleVisibility: .visible) {
            Button("Block @\(app.creator)", role: .destructive) {
                Task {
                    do { try await model.block(username: app.creator) }
                    catch { blockError = error.localizedDescription }
                }
            }
        } message: {
            Text("Their works and comments will be removed from your Pulse surfaces. You can manage blocked users in account settings once that feature is available.")
        }
        .alert("Couldn’t block this creator", isPresented: Binding(get: { blockError != nil }, set: { if !$0 { blockError = nil } })) {
            Button("OK", role: .cancel) { blockError = nil }
        } message: {
            Text(blockError ?? "Please try again.")
        }
        .sheet(isPresented: $isBlockAuthenticationPresented) {
            AuthenticationRequiredView(title: "Sign in to block a creator", detail: "Blocking is personal to your account, so it can follow you across devices.")
        }
        .alert("Connection needed", isPresented: Binding(get: { offlineActionMessage != nil }, set: { if !$0 { offlineActionMessage = nil } })) {
            Button("OK", role: .cancel) { offlineActionMessage = nil }
        } message: {
            Text(offlineActionMessage ?? "Reconnect to Pulse and try again.")
        }
        .onChange(of: session.canResumeMemberActions) { _, canResume in
            guard canResume else { return }
            if shouldResumeLike {
                shouldResumeLike = false
                isLikeAuthenticationPresented = false
                Task { await model.toggleLike(app.id) }
            }
            if shouldResumeBlock {
                shouldResumeBlock = false
                isBlockAuthenticationPresented = false
                isBlockConfirmationPresented = true
            }
        }
        .onChange(of: isLikeAuthenticationPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented, !session.canPerformMemberActions {
                shouldResumeLike = false
            }
        }
        .onChange(of: isBlockAuthenticationPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented, !session.canPerformMemberActions {
                shouldResumeBlock = false
            }
        }
    }

    private func requestLike() {
        guard !model.isOfflineReadOnly else {
            offlineActionMessage = "Reconnect to Pulse before liking a work. Saved Feed cards are read-only while you’re offline."
            return
        }
        guard session.canPerformMemberActions else {
            shouldResumeLike = true
            isLikeAuthenticationPresented = true
            return
        }
        Task { await model.toggleLike(app.id) }
    }

    private func requestBlock() {
        guard !model.isOfflineReadOnly else {
            offlineActionMessage = "Reconnect to Pulse before blocking a creator. Saved Feed cards are read-only while you’re offline."
            return
        }
        guard session.canPerformMemberActions else {
            shouldResumeBlock = true
            isBlockAuthenticationPresented = true
            return
        }
        isBlockConfirmationPresented = true
    }

    private func requestComments() {
        guard !model.isOfflineReadOnly else {
            offlineActionMessage = "Reconnect to Pulse before viewing or posting comments. Saved Feed cards are read-only while you’re offline."
            return
        }
        isCommentsPresented = true
    }

    private func requestReport() {
        guard !model.isOfflineReadOnly else {
            offlineActionMessage = "Reconnect to Pulse before submitting a report. Saved Feed cards are read-only while you’re offline."
            return
        }
        isReportPresented = true
    }
}

private struct FeedStaticPreview: View {
    @Environment(AppModel.self) private var model
    let app: InteractiveApp
    @Binding var touchPoint: CGPoint
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PulseAccessibility.interactiveSummary(title: app.title, theme: app.theme))
                    .accessibilityValue("Static preview")
                    .accessibilityHint("Open this work to interact.")
            } else {
                LivingCanvas(app: app, touchPoint: $touchPoint, isActive: false)
            }
        }
        .clipped()
        .task(id: "\(app.artifactID?.uuidString ?? "no-artifact")-\(app.artifactPreviewURL ?? "no-preview")-\(model.feedPreviewRevision)") {
            // Do not retain a previous poster when this Feed card is refreshed
            // without a server-authorized preview URL.
            image = nil
            guard let data = await model.cachedFeedPreviewData(for: app),
                  !Task.isCancelled,
                  let decoded = UIImage(data: data)
            else { return }
            image = decoded
        }
    }
}

private struct WorkSummaryPanel: View {
    let app: InteractiveApp
    let details: () -> Void
    let like: () -> Void
    let comments: () -> Void
    let remix: () -> Void
    let share: () -> Void
    let report: () -> Void
    let block: () -> Void
    let guidelines: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text("@\(app.creator)")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: details) {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.86))
                .accessibilityIdentifier("feed.work-details")
                Menu {
                    Button("Report this work", systemImage: "flag") { report() }
                    Button("Block @\(app.creator)", systemImage: "hand.raised", role: .destructive) { block() }
                    Button("Community guidelines", systemImage: "checklist") { guidelines() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Safety options for \(app.title)")
                .accessibilityIdentifier("feed.work-safety")
            }

            Text(app.theme)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)

            HStack(spacing: 0) {
                FeedBottomAction(
                    symbol: app.isLiked ? "heart.fill" : "heart",
                    count: compactFeedCount(app.likes),
                    accessibilityLabel: app.isLiked ? "Unlike this work" : "Like this work",
                    accessibilityValue: "\(app.likes) likes",
                    tint: app.isLiked ? .pulseCoral : .white,
                    action: like
                )
                FeedBottomAction(
                    symbol: "bubble.right",
                    count: compactFeedCount(app.comments),
                    accessibilityLabel: "Comments",
                    accessibilityValue: "\(app.comments) comments",
                    tint: .white,
                    action: comments
                )
                FeedBottomAction(
                    symbol: "arrow.triangle.2.circlepath",
                    count: app.allowRemix ? "Remix" : "Closed",
                    accessibilityLabel: app.allowRemix ? "Remix this work" : "Remix disabled by creator",
                    accessibilityValue: "\(app.remixes) remixes",
                    tint: app.accent,
                    action: remix
                )
                .disabled(!app.allowRemix)
                .opacity(app.allowRemix ? 1 : 0.45)
                FeedBottomAction(
                    symbol: "square.and.arrow.up",
                    count: nil,
                    accessibilityLabel: "Share this work",
                    accessibilityValue: "Public link status: \(app.publicURL == nil ? "not available" : "available")",
                    tint: .pulseViolet,
                    action: share
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background(.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.summary-panel")
    }
}

private struct FeedBottomAction: View {
    let symbol: String
    let count: String?
    let accessibilityLabel: String
    let accessibilityValue: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                if let count {
                    Text(count)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}

private struct WorkDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let app: InteractiveApp

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("@\(app.creator)")
                        .font(.largeTitle.weight(.bold))
                    Text(app.theme)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.86))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Creator note")
                            .font(.headline)
                        Text(app.prompt)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    if let ageRating = app.ageRating, app.contentReviewStatus == .approved {
                        Label("Reviewed for \(ageRating.rawValue)", systemImage: "checkmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.pulseLime)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(.black)
            .navigationTitle("Work details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private func compactFeedCount(_ number: Int) -> String {
    number > 999 ? String(format: "%.1fK", Double(number) / 1000) : "\(number)"
}
