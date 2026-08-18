import SwiftUI

struct AppTabBar: View {
    @Binding var selectedTab: AppTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 22, weight: selectedTab == tab ? .bold : .medium))
                        Text(tab.label).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.pulseLime : .white)
                    .frame(maxWidth: .infinity).frame(height: 61)
                }
                .accessibilityLabel(tab.label)
            }
        }
        .padding(.horizontal, 8)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}
