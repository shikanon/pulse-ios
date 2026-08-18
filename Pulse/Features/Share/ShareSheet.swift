import SwiftUI

struct ShareSheet: View {
    let app: InteractiveApp
    @State private var isPublishing = false
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Share to the web").font(.title.bold())
                Text("Anyone with this link can open and play \(app.title) in a browser. Pulse credits @\(app.creator) and preserves its remix lineage.").foregroundStyle(.secondary)
                if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareURL.host ?? "link")", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent) }
                else { Button { publish() } label: { isPublishing ? AnyView(ProgressView()) : AnyView(Text("Publish link").frame(maxWidth: .infinity)) }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black) }
                Spacer()
            }.padding(24).navigationTitle("Share")
        }
    }
    private func publish() { isPublishing = true; Task { try? await Task.sleep(for: .milliseconds(500)); await MainActor.run { shareURL = URL(string: "https://pulse.example/a/\(app.id.uuidString.prefix(8))")!; isPublishing = false } } }
}
