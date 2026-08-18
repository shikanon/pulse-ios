import SwiftUI

struct RemixSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let original: InteractiveApp
    @State private var prompt = "Make it softer, slower, and add a violet midnight glow."
    @State private var remix: InteractiveApp?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("Remix \(original.title)").font(.title2.bold())
                Text("Start with the original interaction, then describe what should change. The original creator stays credited.").foregroundStyle(.secondary)
                TextEditor(text: $prompt).font(.body).frame(height: 155).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                if let remix { Label("Draft saved: \(remix.title)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button { remix = model.remix(original) } label: { Text("Create remix").frame(maxWidth: .infinity).padding(.vertical, 15) }
                    .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
            }
            .padding(24).navigationTitle("Remix").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct CreateView: View {
    @State private var prompt = "A miniature world that responds to thumb movement"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make something people can feel.").font(.system(size: 35, weight: .bold, design: .rounded))
            Text("Describe an interaction. Pulse turns the idea into an editable app, ready for the feed or the web.").foregroundStyle(.secondary)
            TextEditor(text: $prompt).frame(height: 180).padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            Button("Generate interactive app") {}.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
            Spacer()
        }.padding(.horizontal, 24).padding(.top, 80).background(.black).foregroundStyle(.white)
    }
}

struct InboxView: View { var body: some View { ContentPlaceholder(title: "Inbox", message: "Remixes, replies, and collaboration invitations will gather here.", symbol: "bubble.left.and.bubble.right") } }
struct ProfileView: View { var body: some View { ContentPlaceholder(title: "@you", message: "Your works, remixes, and public share links live here.", symbol: "person.crop.circle") } }
struct ContentPlaceholder: View { let title: String; let message: String; let symbol: String; var body: some View { VStack(spacing: 16) { Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(.pulseViolet); Text(title).font(.largeTitle.bold()); Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary) }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white) } }
