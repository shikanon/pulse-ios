import SwiftUI

struct MaterialDirectionCard: View {
    let asset: GenerationAsset
    @Binding var context: CreationContext
    let remove: () -> Void

    private var direction: Binding<CreationContext.Material> {
        Binding {
            context.selected(for: [asset]).materials[0]
        } set: { value in
            context.materials.removeAll { $0.id == asset.id }
            context.materials.append(value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: asset.iconName).foregroundStyle(Color.pulseViolet)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.displayName).font(.subheadline.weight(.semibold))
                    Text(asset.library == .public ? "Official public resource" : "Your private resource")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: remove) { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .tint(.secondary).accessibilityLabel("Remove \(asset.displayName)")
            }
            Picker("Use as", selection: direction.role) {
                ForEach(CreationContext.Role.choices(for: asset.kind), id: \.self) { role in
                    Text(LocalizedStringKey(role.title)).tag(role)
                }
            }
            .tint(.pulseLime)
            .accessibilityIdentifier("creation.material-role.\(asset.id.uuidString)")
            TextField("Where or when? For example: show this cat after clearing a line", text: direction.placement, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityLabel("Material placement and trigger")
                .accessibilityIdentifier("creation.material-placement.\(asset.id.uuidString)")
            if direction.wrappedValue.role == .reference {
                Text("Use for visual direction, not as an in-game image. Image understanding depends on the connected model; describe the details that matter.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if direction.wrappedValue.role == .reaction {
                Text("Describe the trigger, position and duration. Keep the board and controls clear.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Loads only this author's jobs. Never reads the source author's private
/// conversation when showing a Remix, even though source attribution is public.
struct CreationConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let work: InteractiveApp
    let currentJob: GenerationJob?
    let continueEditing: (() -> Void)?
    @State private var turns: [GenerationJob] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var total = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(work.title).font(.title2.bold())
                    Text("Your requests and generation results stay with this work. Continue editing from the current preview; previous versions remain in Profile.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isLoading { ProgressView("Loading conversation…") }
                    if failed {
                        Text("Some messages could not be loaded. Your work is still saved.").foregroundStyle(Color.pulseCoral)
                        Button("Try again") { Task { await load() } }
                    }
                    if total > 20 { Text("Showing the latest 20 requests.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(turns) { turn in
                        turnView(turn)
                    }
                    if !isLoading && !failed && turns.isEmpty {
                        Text("Your first request will appear here after you generate.").foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            .background(Color.black).foregroundStyle(.white)
            .safeAreaInset(edge: .bottom) {
                if let continueEditing {
                    Button("Ask for another change", action: continueEditing)
                        .fontWeight(.bold).frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                        .padding(16).background(Color.black)
                        .accessibilityIdentifier("creation.conversation.continue")
                }
            }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
    }

    private func turnView(_ turn: GenerationJob) -> some View {
        let brief = CreationContext.parse(turn.instruction)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("You").font(.caption.bold())
                Spacer()
                Text(turn.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Text(brief.message).textSelection(.enabled)
                .accessibilityIdentifier("creation.conversation.message")
            if let context = brief.context {
                if !context.preserve.isEmpty {
                    Text("Keep: \(context.preserve)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(context.materials) { material in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(material.name).font(.caption.bold())
                        Text(LocalizedStringKey(material.role.title)).font(.caption)
                        if !material.placement.isEmpty { Text(material.placement).font(.caption) }
                    }.foregroundStyle(Color.pulseViolet)
                }
            }
            Divider()
            Label(LocalizedStringKey(resultLabel(turn)), systemImage: turn.verificationGrade == .verified ? "checkmark.circle" : "bubble.left")
                .font(.subheadline).foregroundStyle(turn.verificationGrade == .verified ? Color.pulseLime : Color.pulseViolet)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    private func resultLabel(_ turn: GenerationJob) -> String {
        if !turn.stage.isTerminal { return "Creating this version…" }
        if turn.verificationGrade == .verified { return "Preview ready · checks passed" }
        if turn.verificationGrade == .degraded { return "Private preview · changes needed" }
        if turn.stage == .cancelled { return "Cancelled · nothing published" }
        return "This request needs another try · nothing published"
    }

    @MainActor private func load() async {
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            let versions = try await model.workVersions(for: work.id)
            total = versions.count
            var loaded: [GenerationJob] = []
            for version in versions.sorted(by: { $0.version > $1.version }).prefix(20) {
                try Task.checkCancellation()
                do {
                    let job = try await model.refreshGeneration(version.generationID)
                    if job.workID == work.id { loaded.append(job) }
                } catch is CancellationError { return }
                catch { failed = true }
            }
            if let currentJob, currentJob.workID == work.id, !loaded.contains(where: { $0.id == currentJob.id }) {
                loaded.append(currentJob)
            }
            guard !Task.isCancelled else { return }
            turns = loaded.sorted { $0.createdAt < $1.createdAt }
        } catch is CancellationError { return }
        catch { failed = true }
    }
}
