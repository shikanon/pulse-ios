import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    @Binding var selectedTab: AppTab
    let resetToken: UUID
    @State private var navigationPath = NavigationPath()
    @State private var selectedWorkFilter: ProfileWorkFilter = .all
    @State private var workPendingPublicLinkRevocation: InteractiveApp?
    @State private var workShowingDetails: InteractiveApp?
    @State private var workShowingVersions: InteractiveApp?
    @State private var isRevokingPublicLink = false
    @State private var publicLinkNotice: String?
    @State private var publicLinkError: String?

    init(selectedTab: Binding<AppTab>, resetToken: UUID) {
        _selectedTab = selectedTab
        self.resetToken = resetToken
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !session.canPerformMemberActions {
                    AuthenticationRequiredView(title: "Keep your work in one place", detail: "Sign in only when you are ready to create, publish, or manage your Pulse account.")
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 15) {
                        Circle().fill(Color.pulseViolet.gradient).frame(width: 68, height: 68).overlay(Text(String((session.user?.displayName ?? model.creatorName).prefix(1)).uppercased()).font(.title.bold()))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("@\(session.user?.username ?? model.creatorName)").font(.title2.bold())
                            Text(session.user?.displayName ?? "Local development creator").foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 0) {
                        ProfileMetric(value: model.myWorks.filter { $0.status == .published }.count, label: "Published")
                        ProfileMetric(value: model.myWorks.filter { $0.creationMode == .remix }.count, label: "Remixes")
                        ProfileMetric(value: model.myWorks.reduce(0) { $0 + $1.likes }, label: "Likes")
                    }.padding(.vertical, 15).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    HStack {
                        Text("Your works").font(.title3.bold())
                        Spacer()
                        Text("\(filteredWorks.count)")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(filteredWorks.count) \(selectedWorkFilter.label.lowercased()) works")
                    }
                    WorkFilterBar(selection: $selectedWorkFilter, works: model.myWorks)
                    if let profileError = model.profileError, model.myWorks.isEmpty {
                        ContentUnavailableView {
                            Label("Your works are unavailable", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(profileError)
                        } actions: {
                            Button("Try again") { Task { await model.loadMyWorks() } }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 45)
                    } else if model.myWorks.isEmpty {
                        EmptyWorksView(filter: .all, create: openCreator)
                            .frame(maxWidth: .infinity).padding(.vertical, 45)
                    } else if filteredWorks.isEmpty {
                        EmptyWorksView(filter: selectedWorkFilter, create: openCreator)
                            .frame(maxWidth: .infinity).padding(.vertical, 45)
                    } else {
                        LazyVStack(spacing: 11) {
                            ForEach(filteredWorks) { work in
                                WorkRow(work: work) {
                                    model.recoverGeneration(for: work)
                                    selectedTab = .create
                                } requestPublicLinkRevocation: {
                                    workPendingPublicLinkRevocation = work
                                } showDetails: {
                                    workShowingDetails = work
                                } showVersions: {
                                    workShowingVersions = work
                                }
                            }
                        }
                    }
                    if isRevokingPublicLink {
                        ProgressView("Revoking public link…")
                            .font(.footnote)
                    }
                    if let publicLinkNotice {
                        Label(publicLinkNotice, systemImage: "checkmark.shield.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseLime)
                    }
                    if let publicLinkError {
                        Label(publicLinkError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseCoral)
                    }
                    if model.profileError != nil, !model.myWorks.isEmpty {
                        Label("Your list may be out of date. Pull to refresh or try again.", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(Color.pulseCoral)
                            .accessibilityLabel("Your work list may be out of date. Pull to refresh or try again.")
                    }
                }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
                }
                .background(.black).foregroundStyle(.white).navigationTitle("Profile")
                .toolbar {
                    if session.canPerformMemberActions {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink(value: ProfileDestination.settings) {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Profile and safety settings")
                            .accessibilityIdentifier("profile.settings")
                        }
                    }
                }
                .task { await model.loadMyWorks() }
                .refreshable { await model.loadMyWorks() }
                .alert("Revoke public link?", isPresented: Binding(
                    get: { workPendingPublicLinkRevocation != nil },
                    set: { if !$0 { workPendingPublicLinkRevocation = nil } }
                )) {
                    Button("Revoke link", role: .destructive) { revokePublicLink() }
                    Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The browser link for \(workPendingPublicLinkRevocation?.title ?? "this work") will stop working immediately. Your private draft and its review record stay available in Profile.")
                    }
                }
            }
            .navigationDestination(for: ProfileDestination.self) { destination in
                switch destination {
                case .settings:
                    ProfileSettingsView()
                }
            }
        }
        .onChange(of: resetToken) { _, _ in
            navigationPath = NavigationPath()
        }
        .sheet(item: $workShowingVersions) { work in
            WorkVersionsSheet(work: work)
                // A candidate row contains several status cues. Presenting
                // this management surface at the medium detent can hide the
                // first actionable item on compact phones.
                .presentationDetents([.large])
        }
        .sheet(item: $workShowingDetails) { work in
            WorkDetailsSheet(
                work: work,
                continueCreation: {
                    workShowingDetails = nil
                    model.recoverGeneration(for: work)
                    selectedTab = .create
                },
                showVersions: {
                    workShowingDetails = nil
                    // Dismissing before presenting prevents competing sheets
                    // from hiding the version list on compact devices.
                    DispatchQueue.main.async {
                        workShowingVersions = work
                    }
                },
                openPublishedWork: {
                    workShowingDetails = nil
                    DispatchQueue.main.async {
                        model.sharedWork = work
                    }
                },
                requestPublicLinkRevocation: {
                    workShowingDetails = nil
                    // Present the destructive confirmation only after the
                    // details sheet is gone; competing sheets can otherwise
                    // hide its explanation on compact phones.
                    DispatchQueue.main.async {
                        workPendingPublicLinkRevocation = work
                    }
                },
                updateRemixPermission: { workID, allowRemix in
                    let updated = try await model.updateRemixPermission(workID: workID, allowRemix: allowRemix)
                    workShowingDetails = updated
                    return updated
                },
                openOriginalWork: { original in
                    workShowingDetails = nil
                    DispatchQueue.main.async {
                        model.sharedWork = original
                    }
                }
            )
            .presentationDetents([.large])
        }
    }

    private func revokePublicLink() {
        guard let work = workPendingPublicLinkRevocation, !isRevokingPublicLink else { return }
        workPendingPublicLinkRevocation = nil
        isRevokingPublicLink = true
        publicLinkNotice = nil
        publicLinkError = nil
        Task {
            do {
                _ = try await model.unpublish(work.id)
                publicLinkNotice = "Public link revoked. The previous link is no longer available."
            } catch {
                publicLinkError = "Pulse couldn’t revoke this link. Check your connection and try again."
            }
            isRevokingPublicLink = false
        }
    }

    private var filteredWorks: [InteractiveApp] {
        model.myWorks.filter(selectedWorkFilter.includes)
    }

    private func openCreator() {
        selectedTab = .create
    }
}

private enum ProfileDestination: Hashable {
    case settings
}

private enum ProfileWorkFilter: String, CaseIterable, Identifiable {
    case all
    case published
    case remixes
    case drafts
    case creating
    case attention
    case revoked

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .published: "Live"
        case .remixes: "Remixes"
        case .drafts: "Drafts"
        case .creating: "Creating"
        case .attention: "Needs attention"
        case .revoked: "Revoked"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: "No works yet"
        case .published: "No live works"
        case .remixes: "No remixes"
        case .drafts: "No drafts"
        case .creating: "Nothing is generating"
        case .attention: "Nothing needs attention"
        case .revoked: "No revoked links"
        }
    }

    var emptyDescription: String {
        switch self {
        case .all: "Use Create to generate your first interactive app."
        case .published: "Publish a verified work when you are ready to share it."
        case .remixes: "Remixed works will appear here after you create them."
        case .drafts: "Saved drafts and verified candidates ready to publish appear here."
        case .creating: "Generating works stay here until their technical checks finish."
        case .attention: "Works that were taken down or need changes will appear here."
        case .revoked: "Links you intentionally withdrew will be kept here until the work is published again."
        }
    }

    func includes(_ work: InteractiveApp) -> Bool {
        switch self {
        case .all:
            true
        case .published:
            work.status == .published
        case .remixes:
            work.creationMode == .remix
        case .drafts:
            work.status == .draft && work.publicLinkRevokedAt == nil
        case .creating:
            work.status == .processing
        case .attention:
            work.status == .hidden ||
                work.status == .deleted ||
                work.contentReviewStatus == .rejected ||
                (work.status == .draft && work.generationJobID != nil)
        case .revoked:
            work.publicLinkRevokedAt != nil
        }
    }
}

private struct WorkFilterBar: View {
    @Binding var selection: ProfileWorkFilter
    let works: [InteractiveApp]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProfileWorkFilter.allCases) { filter in
                        let count = works.filter(filter.includes).count
                        Button {
                            selection = filter
                        } label: {
                            Text("\(filter.label) \(count)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selection == filter ? .black : .white)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .background(selection == filter ? Color.pulseLime : .white.opacity(0.08), in: Capsule())
                        }
                        .id(filter)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("profile.work-filter.\(filter.rawValue)")
                        .accessibilityLabel("\(filter.label), \(count) works")
                        .accessibilityValue(selection == filter ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selection == filter ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
                // Reserve room after the final chip so a selected rightmost
                // lifecycle can still be centered instead of being clipped.
                .padding(.trailing, 160)
            }
            .onChange(of: selection) { _, filter in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(filter, anchor: .center)
                }
            }
        }
        .accessibilityLabel("Filter your works")
    }
}

private struct EmptyWorksView: View {
    let filter: ProfileWorkFilter
    let create: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(filter.emptyTitle, systemImage: filter == .all ? "sparkles" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(filter.emptyDescription)
        } actions: {
            if filter == .all || filter == .drafts {
                Button("Create an interactive app", action: create)
                    .buttonStyle(.borderedProminent)
                    .tint(.pulseViolet)
            }
        }
    }
}

private struct ProfileMetric: View {
    let value: Int
    let label: String
    var body: some View { VStack(spacing: 4) { Text("\(value)").font(.title3.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
}

private struct WorkRow: View {
    let work: InteractiveApp
    let recover: () -> Void
    let requestPublicLinkRevocation: () -> Void
    let showDetails: () -> Void
    let showVersions: () -> Void

    private var recoveryLabel: String? {
        guard work.generationJobID != nil else { return nil }
        switch work.status {
        case .processing: return "Resume"
        case .draft: return "Review"
        case .published: return "Edit"
        default: return nil
        }
    }

    private var recoveryAccessibilityLabel: String {
        work.status == .processing ? "Resume generation for \(work.title)" : "Review draft \(work.title)"
    }

    private var lifecycleSummary: (title: String, color: Color) {
        if work.publicLinkRevokedAt != nil {
            return ("Public link revoked", .pulseCoral)
        }
        switch work.status {
        case .published:
            return ("Live", .pulseLime)
        case .processing:
            return ("Generating", .pulseViolet)
        case .draft:
            return ("Private draft", .secondary)
        case .hidden:
            return ("Unavailable", .pulseCoral)
        case .deleted:
            return ("Deleted", .secondary)
        }
    }

    private var reviewSummary: String? {
        guard let review = work.contentReviewStatus else { return nil }
        switch review {
        case .pending:
            return work.contentReviewRequestedAt == nil ? "Not submitted for review" : "In content review"
        case .approved:
            return "Content review approved"
        case .rejected:
            return "Content review needs changes"
        }
    }

    private var detailsAccessibilityLabel: String {
        var parts = ["Open details for \(work.title)", lifecycleSummary.title, work.verificationGrade.rawValue]
        parts.append(hasStaticPreview ? "Static preview available" : "No static preview yet")
        if let currentVersion = work.currentVersion {
            parts.append("Version \(currentVersion)")
        }
        if let updatedAt = work.updatedAt {
            parts.append("Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ". ") + "."
    }

    var body: some View {
        HStack(spacing: 13) {
            ArtifactPosterThumbnail(work: work, lifecycle: lifecycleSummary.title, color: lifecycleSummary.color)
            Button(action: showDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(work.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(work.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(lifecycleSummary.title) · \(work.verificationGrade.rawValue)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(lifecycleSummary.color)
                        .lineLimit(1)
                            .truncationMode(.tail)
                    if let currentVersion = work.currentVersion {
                        Text("Version \(currentVersion)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let reviewSummary {
                        Text("\(reviewSummary)\(work.ageRating.map { " · \($0.rawValue)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(work.contentReviewStatus == .rejected ? Color.pulseCoral : Color.secondary)
                            .lineLimit(1)
                    }
                    if let updatedAt = work.updatedAt {
                        Text("Updated \(updatedAt, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityIdentifier("profile.work-details.\(work.id.uuidString.lowercased())")
            .accessibilityLabel(detailsAccessibilityLabel)
            .accessibilityHint("Shows the current preview, review state, and version history.")
            VStack(spacing: 8) {
                if work.status == .published {
                    Menu {
                        Button("Revoke public link", systemImage: "link.badge.minus", role: .destructive, action: requestPublicLinkRevocation)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Manage public link for \(work.title)")
                } else if recoveryLabel != nil {
                    Button(action: recover) {
                        Image(systemName: work.status == .processing ? "arrow.clockwise" : "checklist")
                    }
                    .buttonStyle(.bordered)
                    .tint(.pulseViolet)
                    .accessibilityLabel(recoveryAccessibilityLabel)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                Button(action: showVersions) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .accessibilityLabel("View versions for \(work.title)")
            }
            .frame(width: 34)
        }
        .padding(11)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
    }

    private var hasStaticPreview: Bool {
        work.artifactPreviewURL != nil && (work.status == .draft || work.status == .published)
    }
}

private struct ArtifactPosterThumbnail: View {
    @Environment(AppModel.self) private var model
    let work: InteractiveApp
    let lifecycle: String
    let color: Color
    @State private var image: UIImage?

    private var fallbackSymbol: String {
        switch lifecycle {
        case "Generating": return "sparkles"
        case "Public link revoked", "Unavailable", "Deleted": return "eye.slash"
        default: return "rectangle.slash"
        }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: fallbackSymbol)
                        .font(.title3.weight(.semibold))
                    Text("No poster")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(color)
                .padding(6)
                .multilineTextAlignment(.center)
                .background(color.opacity(0.14))
            }
        }
        .frame(width: 66, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: work.artifactPreviewURL) {
            guard let data = try? await model.artifactPreviewData(for: work),
                  !Task.isCancelled,
                  let decoded = UIImage(data: data)
            else {
                image = nil
                return
            }
            image = decoded
        }
    }
}

private struct WorkDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PulseTelemetry.self) private var telemetry
    @Environment(PulseRuntimeLifecycle.self) private var runtimeLifecycle
    let work: InteractiveApp
    let continueCreation: () -> Void
    let showVersions: () -> Void
    let openPublishedWork: () -> Void
    let requestPublicLinkRevocation: () -> Void
    let updateRemixPermission: (UUID, Bool) async throws -> InteractiveApp
    let openOriginalWork: (InteractiveApp) -> Void
    @State private var isOpeningOriginal = false
    @State private var originalWorkError: String?
    @State private var isLoadingLineage = false
    @State private var lineage: [InteractiveApp]?
    @State private var lineageError: String?
    @State private var isSharePresented = false
    @State private var remixPermissionOverride: Bool?
    @State private var isUpdatingRemixPermission = false
    @State private var remixPermissionError: String?

    private var canRunCurrentPreview: Bool {
        work.status == .draft || work.status == .published
    }

    private var isRuntimeActive: Bool {
        PulseAccessibility.runtimeIsActive(
            isVisible: true,
            isApplicationActive: scenePhase == .active,
            isObscured: isSharePresented,
            isSystemRuntimeAvailable: runtimeLifecycle.allowsRuntime
        )
    }

    private var lifecycle: String {
        if work.publicLinkRevokedAt != nil { return "Public link revoked" }
        switch work.status {
        case .published: return "Live"
        case .processing: return "Generating"
        case .draft: return "Private draft"
        case .hidden: return "Unavailable"
        case .deleted: return "Deleted"
        }
    }

    private var verification: String {
        switch work.verificationGrade {
        case .pending: return "Checks pending"
        case .verified: return "Verified"
        case .degraded: return "Checked with limitations"
        case .fallback: return "Safe fallback"
        }
    }

    private var review: String? {
        guard let review = work.contentReviewStatus else { return nil }
        switch review {
        case .pending:
            return work.status == .published ? "Live · eligible for post-publication review" : "Not yet reviewed"
        case .approved:
            return "Post-publication review approved"
        case .rejected:
            return "Taken down after review"
        }
    }

    private var continuationTitle: String? {
        switch work.status {
        case .published: return "Edit a new version"
        case .processing: return "Resume generation"
        case .draft where work.generationJobID != nil:
            return work.artifactID == nil ? "Continue generation" : "Open ready version"
        default: return nil
        }
    }

    private var originSummary: String {
        switch work.creationMode {
        case .original:
            return "Original work"
        case .remix:
            return "Remix of @\(work.originalCreator)"
        }
    }

    private var canUpdateRemixPermission: Bool {
        work.status == .draft || work.status == .published
    }

    private var allowsRemix: Bool {
        remixPermissionOverride ?? work.allowRemix
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview

                    VStack(alignment: .leading, spacing: 8) {
                        Text(work.title)
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text(lifecycle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(lifecycle == "Live" ? Color.pulseLime : lifecycle == "Unavailable" || lifecycle == "Deleted" || lifecycle == "Public link revoked" ? Color.pulseCoral : Color.pulseViolet)
                        Text(verification)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let currentVersion = work.currentVersion {
                            Text("Current candidate · Version \(currentVersion)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if work.status == .published {
                                Text("Public version · Version \(currentVersion)")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.pulseLime)
                            }
                        }
                        if let review {
                            Text(review)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("profile.work-detail.lifecycle")
                    .accessibilityLabel("\(lifecycle). \(verification).\(review.map { " \($0)." } ?? "")")

                    if work.contentReviewStatus == .rejected {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("This version was taken down", systemImage: "lock.shield")
                                .font(.headline)
                                .foregroundStyle(Color.pulseCoral)
                            Text("You can create a new version with changes. Pulse does not show moderator identities or internal safety rules here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let supportURL = model.clientConfiguration?.resolvedSupportURL {
                                Link(destination: supportURL) {
                                    Label("Ask Pulse Support about this review", systemImage: "questionmark.circle")
                                }
                                .font(.footnote.weight(.semibold))
                                .accessibilityIdentifier("profile.work-detail.review-support")
                                .accessibilityHint("Opens Pulse Support in your browser without sharing this work automatically.")
                            } else {
                                Text("Support is not available in this build. You can still create a new private version.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(Color.pulseCoral.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("profile.work-detail.review-rejected")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Origin")
                            .font(.headline)
                        Text(originSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("profile.work-detail.origin")
                    .accessibilityLabel("Origin. \(originSummary).")

                    if canUpdateRemixPermission {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remix permission")
                                .font(.headline)
                            Toggle(isOn: Binding(
                                get: { allowsRemix },
                                set: { setRemixPermission($0) }
                            )) {
                                Label("Allow others to Remix this work", systemImage: "arrow.triangle.branch")
                            }
                            .disabled(isUpdatingRemixPermission)
                            .accessibilityIdentifier("profile.work-detail.allow-remix")
                            Text("This affects future Remix requests only. Existing Remix works are unchanged.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if isUpdatingRemixPermission {
                                ProgressView("Saving Remix permission…")
                                    .font(.footnote)
                            }
                            if let remixPermissionError {
                                Label(remixPermissionError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Color.pulseCoral)
                                    .accessibilityIdentifier("profile.work-detail.remix-permission-error")
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                    }

                    if work.creationMode == .remix {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(action: { Task { await showOriginalWork() } }) {
                                if isOpeningOriginal {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text("Opening original work…")
                                    }
                                } else {
                                    Label("Open original work", systemImage: "arrow.uturn.backward.circle")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isOpeningOriginal)
                            .accessibilityIdentifier("profile.work-detail.open-original")
                            .accessibilityHint("Opens the original published work if it is still available.")

                            if let originalWorkError {
                                Label(originalWorkError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Color.pulseCoral)
                                    .accessibilityIdentifier("profile.work-detail.original-unavailable")
                            }
                        }

                        remixLineage
                    }

                    HStack(spacing: 0) {
                        WorkDetailMetric(value: work.likes, label: "Likes")
                        WorkDetailMetric(value: work.comments, label: "Comments")
                        WorkDetailMetric(value: work.remixes, label: "Remixes")
                    }
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your prompt")
                            .font(.headline)
                        Text(work.prompt)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        if let continuationTitle {
                            Button(continuationTitle, action: continueCreation)
                                .buttonStyle(.borderedProminent)
                                .tint(.pulseViolet)
                        }
                        if work.status == .published {
                            Button {
                                telemetry.record(.shareInvoked, attributes: ["screen_id": "profile_work_detail"])
                                isSharePresented = true
                            } label: {
                                Label("Share public link", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pulseLime)
                            .foregroundStyle(.black)
                            .accessibilityIdentifier("profile.work-detail.share")
                            .accessibilityHint("Shares the current public version. Private and historical candidates are never shared.")
                            Button("Open live work", action: openPublishedWork)
                                .buttonStyle(.bordered)
                            Button("Revoke public link", role: .destructive, action: requestPublicLinkRevocation)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("profile.work-detail.revoke-link")
                                .accessibilityHint("Asks for confirmation before immediately withdrawing the current public link. Your private draft stays available.")
                        }
                        Button("Version history", action: showVersions)
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Version history is read-only. Eligible historical candidates can be previewed privately, but only the current verified candidate can be published.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(.black)
            .foregroundStyle(.white)
            .navigationTitle("Work details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isSharePresented) { ShareSheet(app: work) }
    }

    @ViewBuilder
    private var preview: some View {
        if canRunCurrentPreview, let artifactURL = model.artifactURL(for: work) {
            ArtifactPlayerView(
                url: artifactURL,
                isActive: isRuntimeActive,
                title: work.title,
                interactionSummary: work.theme,
                accessibilityIdentifier: "profile.work-detail.artifact",
                telemetryScreen: "profile_work_detail"
            )
            .frame(height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("profile.work-detail.preview")
        } else {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "rectangle.slash")
            } description: {
                Text(previewUnavailableDetail)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("profile.work-detail.preview-unavailable")
        }
    }

    private var previewUnavailableDetail: String {
        switch work.status {
        case .processing:
            return "A preview will be available after this generation completes its checks."
        case .hidden, .deleted:
            return "This work is unavailable. Pulse cannot show an interactive preview here."
        default:
            return "This work does not have a previewable current candidate yet."
        }
    }

    @ViewBuilder
    private var remixLineage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remix lineage")
                .font(.headline)

            if let lineage {
                Text("From the original to this Remix")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(lineage) { ancestor in
                    Button(action: { openOriginalWork(ancestor) }) {
                        HStack(spacing: 10) {
                            Image(systemName: ancestor.creationMode == .original ? "circle.inset.filled" : "arrow.triangle.branch")
                                .foregroundStyle(ancestor.creationMode == .original ? Color.pulseLime : Color.pulseViolet)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ancestor.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(ancestor.creationMode == .original ? "Original by @\(ancestor.creator)" : "Remix by @\(ancestor.creator)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 7)
                    .accessibilityIdentifier("profile.work-detail.open-lineage.\(ancestor.id.uuidString.lowercased())")
                    .accessibilityLabel("Open \(ancestor.creationMode == .original ? "original" : "Remix") work \(ancestor.title) by @\(ancestor.creator)")
                }
            } else {
                Button(action: { Task { await loadLineage() } }) {
                    if isLoadingLineage {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading Remix lineage…")
                        }
                    } else {
                        Label("Show Remix lineage", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingLineage)
                .accessibilityIdentifier("profile.work-detail.show-lineage")
                .accessibilityHint("Shows every currently available published ancestor of this Remix.")

                if let lineageError {
                    Label(lineageError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseCoral)
                        .accessibilityIdentifier("profile.work-detail.lineage-unavailable")
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private func showOriginalWork() async {
        guard !isOpeningOriginal else { return }
        isOpeningOriginal = true
        originalWorkError = nil
        defer { isOpeningOriginal = false }

        do {
            let original = try await model.originalWork(for: work)
            guard !Task.isCancelled else { return }
            openOriginalWork(original)
        } catch {
            // Both access denials and withdrawn originals are intentionally
            // indistinguishable. Surface a recovery action without exposing
            // the original's moderation, ownership, or publication state.
            originalWorkError = error is URLError
                ? "Couldn’t open the original work. Check your connection and try again."
                : "The original work is no longer available."
        }
    }

    private func setRemixPermission(_ allowRemix: Bool) {
        guard !isUpdatingRemixPermission, allowRemix != allowsRemix else { return }
        isUpdatingRemixPermission = true
        remixPermissionError = nil
        Task {
            do {
                let updated = try await updateRemixPermission(work.id, allowRemix)
                remixPermissionOverride = updated.allowRemix
            } catch {
                // Keep a failed remote preference from looking saved. The
                // binding resolves to the last server-confirmed value again.
                remixPermissionError = "Pulse couldn’t update Remix permission. Check your connection and try again."
            }
            isUpdatingRemixPermission = false
        }
    }

    private func loadLineage() async {
        guard !isLoadingLineage else { return }
        isLoadingLineage = true
        lineageError = nil
        defer { isLoadingLineage = false }

        do {
            let fetched = try await model.remixLineage(for: work)
            guard !Task.isCancelled else { return }
            lineage = fetched
        } catch {
            // A lineage is useful only when every disclosed relationship is
            // still public. Avoid telling the creator which ancestor changed.
            lineageError = error is URLError
                ? "Couldn’t load the Remix lineage. Check your connection and try again."
                : "The full Remix lineage is no longer available."
        }
    }
}

private struct WorkDetailMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.headline.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WorkVersionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let work: InteractiveApp
    @State private var versions: [WorkVersion] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var previewingVersion: WorkVersion?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && versions.isEmpty {
                    ProgressView("Loading versions…")
                } else if let loadError, versions.isEmpty {
                    ContentUnavailableView {
                        Label("Versions unavailable", systemImage: "clock.badge.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try again") { Task { await loadVersions() } }
                    }
                } else if versions.isEmpty {
                    ContentUnavailableView("No versions yet", systemImage: "clock.arrow.circlepath", description: Text("A version will appear here when Pulse starts creating this work."))
                } else {
                    List {
                        Section("Candidate history") {
                            ForEach(versions) { version in
                                WorkVersionRow(version: version) {
                                    previewingVersion = version
                                }
                            }
                        }
                        Section {
                            Text("Each entry is an immutable generation candidate. Ready historical candidates can be opened only by you as a private, read-only preview. They cannot replace or publish over the current candidate.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await loadVersions() }
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(work.title)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Versions for \(work.title)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: work.id) { await loadVersions() }
        .sheet(item: $previewingVersion) { version in
            if let artifactID = version.artifactID, version.isPrivateHistoricalPreviewable {
                HistoricalCandidatePreviewSheet(
                    workTitle: work.title,
                    workTheme: work.theme,
                    version: version,
                    artifactURL: model.artifactURL(for: artifactID)
                )
            }
        }
    }

    private func loadVersions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            versions = try await model.workVersions(for: work.id)
            loadError = nil
        } catch {
            // Keep server and networking diagnostics out of the creator's
            // history surface; this request has no user action to repair.
            loadError = "Pulse couldn’t load this version history right now. Check your connection and try again."
        }
    }
}

private struct WorkVersionRow: View {
    let version: WorkVersion
    let showPreview: () -> Void

    private var lifecycle: (title: String, color: Color) {
        switch version.stage {
        case .queued, .processingAssets, .planning, .coding, .verifying, .repairing, .fallbackBuilding:
            ("In progress", .pulseViolet)
        case .succeeded:
            ("Ready", .pulseLime)
        case .fallbackReady:
            ("Safe version ready", .pulseViolet)
        case .failed:
            ("Needs changes", .pulseCoral)
        case .cancelled:
            ("Cancelled", .secondary)
        }
    }

    private var verification: String {
        switch version.verificationGrade {
        case .pending: "Checks pending"
        case .verified: "Verified"
        case .degraded: "Checked with limitations"
        case .fallback: "Safe fallback"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(version.version)")
                    .font(.headline)
                Spacer()
                if version.isPublished {
                    VersionBadge(title: "Live now", color: .pulseLime)
                } else if version.isCurrent {
                    VersionBadge(title: "Current", color: .pulseViolet)
                }
            }
            HStack(spacing: 6) {
                Text(lifecycle.title)
                    .foregroundStyle(lifecycle.color)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(verification)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            if version.isPrivateHistoricalPreviewable {
                Button(action: showPreview) {
                    Label("Preview private candidate", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("profile.work-version.preview.\(version.version)")
                .accessibilityHint("Opens a read-only preview visible only to you. It cannot change the current or published version.")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.work-version.\(version.version)")
        .accessibilityLabel("Version \(version.version), \(lifecycle.title), \(verification)\(version.isPublished ? ", live now" : version.isCurrent ? ", current" : ""), created \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct HistoricalCandidatePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let workTitle: String
    let workTheme: String
    let version: WorkVersion
    let artifactURL: URL

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ArtifactPlayerView(
                    url: artifactURL,
                    isActive: true,
                    title: workTitle,
                    interactionSummary: workTheme,
                    accessibilityIdentifier: "profile.work-version.artifact.\(version.version)",
                    telemetryScreen: "profile_work_version_preview"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("profile.work-version.preview-player")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Private historical candidate · Version \(version.version)")
                        .font(.headline)
                    Text("This is a read-only preview visible only to you. It cannot replace or publish over the current candidate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Candidate preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension WorkVersion {
    // Only a terminal candidate with an immutable artifact is previewable.
    // Current work stays in Work Details, and every historical preview uses
    // the same authenticated artifact boundary as the author-only timeline.
    var isPrivateHistoricalPreviewable: Bool {
        guard artifactID != nil, !isCurrent else { return false }
        return stage == .succeeded || stage == .fallbackReady
    }
}

private struct VersionBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }
}
