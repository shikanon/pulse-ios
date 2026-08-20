import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 15) {
                        Circle().fill(Color.pulseViolet.gradient).frame(width: 68, height: 68).overlay(Text("Y").font(.title.bold()))
                        VStack(alignment: .leading, spacing: 4) { Text("@\(model.creatorName)").font(.title2.bold()); Text("Local Creator").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 0) {
                        ProfileMetric(value: model.myWorks.filter { $0.status == .published }.count, label: "Published")
                        ProfileMetric(value: model.myWorks.filter { $0.creationMode == .remix }.count, label: "Remixes")
                        ProfileMetric(value: model.myWorks.reduce(0) { $0 + $1.likes }, label: "Likes")
                    }.padding(.vertical, 15).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    HStack { Text("Your works").font(.title3.bold()); Spacer(); Text("\(model.myWorks.count)").foregroundStyle(.secondary) }
                    if model.myWorks.isEmpty {
                        ContentUnavailableView("No works yet", systemImage: "sparkles", description: Text("Use Create to generate your first interactive app."))
                            .frame(maxWidth: .infinity).padding(.vertical, 45)
                    } else {
                        LazyVStack(spacing: 11) { ForEach(model.myWorks) { work in WorkRow(work: work) } }
                    }
                    if let error = model.profileError { Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(Color.pulseCoral) }
                }.padding(22).padding(.bottom, 110)
            }
            .background(.black).foregroundStyle(.white).navigationTitle("Profile")
            .task { await model.loadMyWorks() }
            .refreshable { await model.loadMyWorks() }
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
    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 12).fill(work.accent.gradient).frame(width: 58, height: 58).overlay(Image(systemName: "hand.tap.fill").foregroundStyle(.black.opacity(0.7)))
            VStack(alignment: .leading, spacing: 5) { Text(work.title).font(.headline); Text(work.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1); Text("\(work.status.rawValue) · \(work.verificationGrade.rawValue)").font(.caption2.weight(.semibold)).foregroundStyle(work.verificationGrade == .fallback ? Color.pulseViolet : Color.pulseLime) }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(11).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
    }
}

struct InboxView: View {
    var body: some View {
        ContentUnavailableView("Inbox", systemImage: "bubble.left.and.bubble.right", description: Text("Generation updates and community notifications will appear here."))
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white)
    }
}
