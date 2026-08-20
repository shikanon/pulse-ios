import SwiftUI

struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let app: InteractiveApp
    @State private var isPublishing = false
    @State private var publishedWork: InteractiveApp?
    @State private var errorMessage: String?

    private var shareURL: URL? { publishedWork?.publicURL ?? app.publicURL }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Share to the web").font(.title.bold())
                Text("Anyone with this link can open and play \(app.title) in a browser. Pulse preserves the creator and Remix lineage.").foregroundStyle(.secondary)
                if let shareURL {
                    VStack(alignment: .leading, spacing: 8) { Text("PUBLIC LINK").font(.caption2.bold()).foregroundStyle(Color.pulseLime); Text(shareURL.absoluteString).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(2) }
                        .padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    ShareLink(item: shareURL) { Label("Share public link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                } else {
                    Button(action: publish) { HStack { if isPublishing { ProgressView().tint(.black) }; Text("Publish link").fontWeight(.bold) }.frame(maxWidth: .infinity).padding(.vertical, 12) }
                        .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black).disabled(isPublishing)
                }
                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.pulseCoral) }
                Spacer()
            }
            .padding(24).navigationTitle("Share")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func publish() {
        guard !isPublishing else { return }
        isPublishing = true
        Task {
            do { publishedWork = try await model.publish(app.id); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
            isPublishing = false
        }
    }
}
