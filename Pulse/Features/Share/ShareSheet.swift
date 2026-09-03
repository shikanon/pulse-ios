import SwiftUI

struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let app: InteractiveApp

    private var shareURL: URL? { app.publicURL }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Share to the web").font(.title.bold())
                Text(shareURL == nil ? "This version is private. Only a published version has a browser link." : "Anyone with this link can open and play \(app.title) in a browser. Pulse preserves the creator and Remix lineage.").foregroundStyle(.secondary)
                if let shareURL {
                    VStack(alignment: .leading, spacing: 8) { Text("PUBLIC LINK").font(.caption2.bold()).foregroundStyle(Color.pulseLime); Text(shareURL.absoluteString).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(2) }
                        .padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    ShareLink(item: shareURL) { Label("Share public link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                } else {
                    ContentUnavailableView("Public link unavailable", systemImage: "lock.shield", description: Text("This version is not publicly available. Its creator can publish a verified draft immediately; Pulse may take it down later if it violates the community guidelines."))
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            }
            .padding(24).navigationTitle("Share")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
