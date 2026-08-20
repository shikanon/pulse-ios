import SwiftUI

@main
struct PulseApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .preferredColorScheme(.dark)
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedTab: AppTab = .home

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .home: FeedView()
                case .create: CreateView { selectedTab = .home }
                case .inbox: InboxView()
                case .profile: ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AppTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
        .ignoresSafeArea(edges: .bottom)
        .task { await appModel.loadFeed() }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, create, inbox, profile
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var accessibilityLabel: String { self == .create ? "Create an original app from one sentence" : label }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .create: "plus"
        case .inbox: "bubble.left.and.bubble.right"
        case .profile: "person"
        }
    }
}
