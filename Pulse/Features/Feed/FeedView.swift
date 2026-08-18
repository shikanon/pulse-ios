import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedApp: InteractiveApp?

    var body: some View {
        TabView {
            ForEach(model.feed) { app in
                FeedCard(app: app, onRemix: { selectedApp = app })
                    .tag(app.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .sheet(item: $selectedApp) { app in RemixSheet(original: app) }
    }
}

private struct FeedCard: View {
    @Environment(AppModel.self) private var model
    let app: InteractiveApp
    let onRemix: () -> Void
    @State private var touchPoint = CGPoint(x: 0.5, y: 0.62)
    @State private var isSharePresented = false
    @State private var isCommentsPresented = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LivingCanvas(app: app, touchPoint: touchPoint)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        touchPoint = CGPoint(x: value.location.x / proxy.size.width, y: value.location.y / proxy.size.height)
                    })
                LinearGradient(colors: [.black.opacity(0.72), .clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    FeedHeader()
                    Spacer()
                    HStack(alignment: .bottom, spacing: 12) {
                        AppDetails(app: app)
                        Spacer(minLength: 8)
                        ActionRail(app: app, comments: { isCommentsPresented = true }, remix: onRemix, share: { isSharePresented = true })
                    }
                    .padding(.bottom, 115)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $isSharePresented) { ShareSheet(app: app) }
        .sheet(isPresented: $isCommentsPresented) { CommentsSheet(app: app) }
    }
}

private struct FeedHeader: View {
    var body: some View {
        HStack {
            Text("Pulse").font(.system(size: 34, weight: .bold, design: .rounded))
            Spacer()
            Circle().fill(.white.opacity(0.16)).frame(width: 42, height: 42).overlay(Image(systemName: "magnifyingglass").font(.title3))
        }
        .padding(.top, 8)
    }
}

private struct AppDetails: View {
    let app: InteractiveApp
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(app.prompt).font(.subheadline.weight(.medium)).foregroundStyle(app.accent)
            Text(app.title).font(.system(size: 29, weight: .bold, design: .rounded)).lineLimit(2)
            Text("by @\(app.creator)").font(.subheadline).foregroundStyle(.white.opacity(0.72))
            Text(app.theme).font(.subheadline).foregroundStyle(.white.opacity(0.82)).lineLimit(2)
        }
    }
}

private struct ActionRail: View {
    @Environment(AppModel.self) private var model
    let app: InteractiveApp
    let comments: () -> Void
    let remix: () -> Void
    let share: () -> Void
    var body: some View {
        VStack(spacing: 19) {
            ActionButton(symbol: app.isLiked ? "heart.fill" : "heart", label: compact(app.likes), tint: app.isLiked ? .pulseCoral : .white) { model.like(app.id) }
            ActionButton(symbol: "bubble.right", label: compact(app.comments), tint: .white, action: comments)
            ActionButton(symbol: "arrow.triangle.2.circlepath", label: "Remix\n\(compact(app.remixes))", tint: app.accent, action: remix)
            ActionButton(symbol: "square.and.arrow.up", label: "Share", tint: .pulseViolet, action: share)
        }.frame(width: 71)
    }
    private func compact(_ number: Int) -> String { number > 999 ? String(format: "%.1fK", Double(number) / 1000) : "\(number)" }
}

private struct ActionButton: View {
    let symbol: String; let label: String; let tint: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title2.weight(.medium))
                Text(label).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
            }.foregroundStyle(tint)
        }.accessibilityLabel(label)
    }
}
