import SwiftUI

struct AppTabBar: View {
    @Binding var selectedTab: AppTab
    let onReselect: (AppTab) -> Void
    @ScaledMetric(relativeTo: .caption) private var tabHeight = 61.0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    if selectedTab == tab {
                        onReselect(tab)
                    } else {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: tab == .create ? 24 : 22, weight: selectedTab == tab ? .bold : .medium))
                            .frame(minWidth: 44, minHeight: 36)
                            .background(tab == .create ? Color.pulseLime : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(tab == .create ? .black : (selectedTab == tab ? Color.pulseLime : .white))
                        Text(tab.label).font(.caption2.weight(.medium)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(selectedTab == tab ? Color.pulseLime : .white)
                    .frame(maxWidth: .infinity, minHeight: tabHeight)
                }
                .accessibilityLabel(Text(tab.accessibilityLabel))
                .accessibilityValue(selectedTab == tab ? "Selected" : "")
                .accessibilityHint(selectedTab == tab ? "Returns to the selected tab root" : "Switches tabs")
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("app.tab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 8)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}
