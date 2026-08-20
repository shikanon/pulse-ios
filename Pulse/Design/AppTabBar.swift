import SwiftUI

struct AppTabBar: View {
    @Binding var selectedTab: AppTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: tab == .create ? 24 : 22, weight: selectedTab == tab ? .bold : .medium))
                            .frame(width: tab == .create ? 46 : 28, height: tab == .create ? 32 : 28)
                            .background(tab == .create ? Color.pulseLime : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(tab == .create ? .black : (selectedTab == tab ? Color.pulseLime : .white))
                        Text(tab.label).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.pulseLime : .white)
                    .frame(maxWidth: .infinity).frame(height: 61)
                }
                .accessibilityLabel(tab.accessibilityLabel)
            }
        }
        .padding(.horizontal, 8)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}
