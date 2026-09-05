import SwiftUI

struct SharedWorkPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PulseTelemetry.self) private var telemetry
    @Environment(PulseRuntimeLifecycle.self) private var runtimeLifecycle
    let work: InteractiveApp
    @State private var touchPoint = CGPoint(x: 0.5, y: 0.62)
    @State private var isRemixAuthenticationPresented = false
    @State private var shouldResumeRemix = false
    @State private var isSharePresented = false

    private var isRuntimeActive: Bool {
        PulseAccessibility.runtimeIsActive(
            isVisible: true,
            isApplicationActive: scenePhase == .active,
            isObscured: isRemixAuthenticationPresented || isSharePresented,
            isSystemRuntimeAvailable: runtimeLifecycle.allowsRuntime
        )
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Button {
                        model.clearSharedWork()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.bold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityLabel("Close shared work")

                    Spacer()
                    Text("Shared work")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(.horizontal, 20).padding(.top, 8)
                ZStack {
                    if let artifactURL = model.artifactURL(for: work) {
                        ArtifactPlayerView(
                            url: artifactURL,
                            isActive: isRuntimeActive,
                            title: work.title,
                            interactionSummary: work.theme,
                            accessibilityIdentifier: "shared.artifact.player",
                            telemetryScreen: "shared_work"
                        )
                    } else {
                        LivingCanvas(app: work, touchPoint: $touchPoint, isActive: isRuntimeActive)
                            .allowsHitTesting(isRuntimeActive)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                touchPoint = CGPoint(x: value.location.x / proxy.size.width, y: value.location.y / proxy.size.height)
                            })
                            .accessibilityIdentifier("shared.interactive.canvas")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                VStack(alignment: .leading, spacing: 8) {
                    Text(work.theme)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(work.accent)
                        .lineLimit(2)
                    Text(work.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text("by @\(work.creator)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                    if let ageRating = work.ageRating, work.contentReviewStatus == .approved {
                        Label("Reviewed for \(ageRating.rawValue)", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.pulseLime)
                            .accessibilityLabel("Content reviewed for ages \(ageRating.rawValue) and up")
                    }
                    HStack(spacing: 10) {
                        Button(action: requestRemix) {
                            Label("Remix", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.pulseLime)
                        .foregroundStyle(.black)
                        .accessibilityHint(work.allowRemix ? "Create a private Remix from this published work." : "The creator has disabled Remix.")
                        .disabled(!work.allowRemix)

                        Button {
                            telemetry.record(.shareInvoked, attributes: ["screen_id": "shared_work"])
                            isSharePresented = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(.black)
        .sheet(isPresented: $isRemixAuthenticationPresented) {
            AuthenticationRequiredView(
                title: "Sign in to Remix this work",
                detail: "Remix drafts belong to your account so you can return to them on another device."
            )
        }
        .sheet(isPresented: $isSharePresented) { ShareSheet(app: work) }
        .onChange(of: session.canResumeMemberActions) { _, canResume in
            guard canResume, shouldResumeRemix else { return }
            shouldResumeRemix = false
            isRemixAuthenticationPresented = false
            model.startRemix(work)
        }
        .onChange(of: isRemixAuthenticationPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented, !session.canPerformMemberActions {
                shouldResumeRemix = false
            }
        }
    }

    private func requestRemix() {
        guard work.allowRemix else { return }
        guard session.canPerformMemberActions else {
            shouldResumeRemix = true
            isRemixAuthenticationPresented = true
            return
        }
        model.startRemix(work)
    }
}
