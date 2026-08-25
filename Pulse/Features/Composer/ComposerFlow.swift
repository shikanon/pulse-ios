import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
    let onPublished: () -> Void

    var body: some View {
        NavigationStack {
            ComposerFlow(parent: nil, initialPrompt: "A miniature world that responds to thumb movement") { _ in onPublished() }
                .navigationTitle("Create")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RemixSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: InteractiveApp

    var body: some View {
        NavigationStack {
            ComposerFlow(parent: original, initialPrompt: "Make it softer, slower, and add a violet midnight glow.") { _ in dismiss() }
                .navigationTitle("Remix")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ComposerFlow: View {
    @Environment(AppModel.self) private var model
    let parent: InteractiveApp?
    let onPublished: (InteractiveApp) -> Void
    @State private var prompt: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var assets: [GenerationAsset] = []
    @State private var work: InteractiveApp?
    @State private var job: GenerationJob?
    @State private var plan: GenerationPlan?
    @State private var isSubmitting = false
    @State private var isImporting = false
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var isPlanPresented = false
    @State private var isResourceLibraryPresented = false
    @State private var isBGMImporterPresented = false

    init(parent: InteractiveApp?, initialPrompt: String, onPublished: @escaping (InteractiveApp) -> Void) {
        self.parent = parent
        self.onPublished = onPublished
        _prompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        Group {
            if let job, let work {
                if job.stage.isTerminal { PreviewSurface(work: work, job: job, plan: plan, isPublishing: isPublishing, publish: publish, showPlan: { isPlanPresented = true }) }
                else { ProgressSurface(work: work, job: job, hasPlan: plan != nil, showPlan: { isPlanPresented = true }) }
            } else {
                InputSurface(
                    parent: parent, prompt: $prompt, pickerItems: $pickerItems, assets: assets,
                    isImporting: isImporting, isSubmitting: isSubmitting, errorMessage: errorMessage,
                    browseLibrary: { isResourceLibraryPresented = true },
                    importBGM: { isBGMImporterPresented = true },
                    removeAsset: { id in assets.removeAll { $0.id == id } }, submit: submit
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .onChange(of: pickerItems) { _, items in Task { await importAssets(items) } }
        .task(id: job?.id) { await pollGeneration() }
        .sheet(isPresented: $isPlanPresented) { if let plan { PlanSummaryView(plan: plan) } }
        .sheet(isPresented: $isResourceLibraryPresented) { ResourceLibrarySheet(selectedAssets: $assets) }
        .fileImporter(isPresented: $isBGMImporterPresented, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            Task { await importBGM(result) }
        }
    }

    private func submit() {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isSubmitting, !isImporting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                let result = try await model.beginGeneration(instruction: instruction, parent: parent, assets: assets)
                work = result.0
                job = result.1
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    private func importAssets(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isImporting = true
        errorMessage = nil
        var imported: [GenerationAsset] = []
        do {
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .data
                let extensionName = type.preferredFilenameExtension ?? "bin"
                let asset = try await model.registerAsset(fileName: "pulse-material-\(index + 1).\(extensionName)", mediaType: type.preferredMIMEType ?? "application/octet-stream", data: data)
                imported.append(asset)
            }
            mergeAssets(imported)
            pickerItems = []
        } catch {
            errorMessage = "One selected material could not be prepared: \(error.localizedDescription)"
        }
        isImporting = false
    }

    private func importBGM(_ result: Result<[URL], Error>) async {
        isImporting = true
        errorMessage = nil
        do {
            guard let url = try result.get().first else {
                isImporting = false
                return
            }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey])
            let mediaType = values.contentType?.preferredMIMEType ?? "audio/mpeg"
            guard mediaType.hasPrefix("audio/") else {
                throw PulseAPIError(message: "Please choose an audio file for BGM.")
            }
            let data = try Data(contentsOf: url)
            let asset = try await model.registerAsset(fileName: url.lastPathComponent, mediaType: mediaType, data: data)
            mergeAssets([asset])
        } catch {
            errorMessage = "The selected BGM could not be prepared: \(error.localizedDescription)"
        }
        isImporting = false
    }

    private func mergeAssets(_ additions: [GenerationAsset]) {
        for asset in additions where !assets.contains(where: { $0.id == asset.id }) {
            assets.append(asset)
        }
    }

    private func pollGeneration() async {
        guard let jobID = job?.id else { return }
        while !Task.isCancelled {
            do {
                let updated = try await model.refreshGeneration(jobID)
                job = updated
                if updated.planID != nil, plan == nil { plan = try? await model.plan(for: jobID) }
                if updated.stage.isTerminal { return }
                try await Task.sleep(for: .milliseconds(450))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Reconnecting to generation status…"
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func publish() {
        guard let work, !isPublishing else { return }
        isPublishing = true
        Task {
            do {
                let published = try await model.publish(work.id)
                onPublished(published)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPublishing = false
        }
    }
}

private struct InputSurface: View {
    let parent: InteractiveApp?
    @Binding var prompt: String
    @Binding var pickerItems: [PhotosPickerItem]
    let assets: [GenerationAsset]
    let isImporting: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let browseLibrary: () -> Void
    let importBGM: () -> Void
    let removeAsset: (UUID) -> Void
    let submit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let parent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REMIX OF").font(.caption2.weight(.bold)).foregroundStyle(Color.pulseViolet)
                        Text(parent.title).font(.title2.bold())
                        Text("by @\(parent.creator) · original by @\(parent.originalCreator)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Make something people can feel.").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Start from one sentence. Images and videos are optional.").foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(parent == nil ? "Your idea" : "What should change?").font(.headline)
                    TextEditor(text: $prompt)
                        .scrollContentBackground(.hidden).frame(minHeight: 145).padding(12)
                        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
                        .accessibilityIdentifier("creation.prompt")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Resource library").font(.headline); Spacer(); Text("Optional").font(.caption).foregroundStyle(.secondary) }
                    Button(action: browseLibrary) {
                        Label("Browse public and private resources", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent).tint(.pulseViolet)
                    .disabled(isImporting || isSubmitting)
                    .accessibilityIdentifier("creation.resource-library")
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                        Label(isImporting ? "Preparing resources…" : "Upload private images or videos", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.bordered).tint(.white).disabled(isImporting || isSubmitting)
                    Button(action: importBGM) {
                        Label("Upload private BGM", systemImage: "music.note.list")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.bordered).tint(.white).disabled(isImporting || isSubmitting)
                    ForEach(assets) { asset in
                        HStack(spacing: 12) {
                            Image(systemName: asset.iconName).foregroundStyle(Color.pulseViolet)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.displayName).font(.subheadline.weight(.semibold))
                                Text(asset.library == .public ? "Official public resource" : "Your private resource").font(.caption2).foregroundStyle(asset.library == .public ? Color.pulseLime : .secondary)
                                Text(asset.summary ?? "Ready for generation").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button { removeAsset(asset.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(.secondary).accessibilityLabel("Remove \(asset.displayName)")
                        }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.pulseCoral) }
                Button(action: submit) {
                    HStack { if isSubmitting { ProgressView().tint(.black) }; Text(parent == nil ? "Generate interactive app" : "Create Remix").fontWeight(.bold) }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting || isImporting)
                .accessibilityIdentifier("creation.generate")
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 120)
        }
    }
}

private struct ResourceLibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedAssets: [GenerationAsset]
    @State private var selectedLibrary: GenerationAsset.Library = .public

    private var resources: [GenerationAsset] {
        selectedLibrary == .public ? model.publicAssets : model.privateAssets
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Resource library", selection: $selectedLibrary) {
                    Text("Public").tag(GenerationAsset.Library.public)
                    Text("Private").tag(GenerationAsset.Library.private)
                }
                .pickerStyle(.segmented)
                .padding()
                .accessibilityIdentifier("resource-library.scope")

                if model.isLoadingAssetLibrary, resources.isEmpty {
                    Spacer()
                    ProgressView("Loading resources…")
                    Spacer()
                } else if let error = model.assetLibraryError, resources.isEmpty {
                    ContentUnavailableView {
                        Label("Resource library unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await model.loadAssetLibrary() } }
                    }
                } else if resources.isEmpty {
                    ContentUnavailableView(
                        "No private resources yet", systemImage: "tray",
                        description: Text("Upload an image or BGM from the creation screen and it will appear here.")
                    )
                } else {
                    List(resources) { asset in
                        Button { toggle(asset) } label: {
                            HStack(spacing: 13) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(asset.kind == .audio ? Color.pulseViolet.opacity(0.24) : Color.pulseLime.opacity(0.18))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: asset.iconName).foregroundStyle(asset.kind == .audio ? Color.pulseViolet : Color.pulseLime))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(asset.displayName).font(.headline).foregroundStyle(.primary)
                                    Text(asset.kind == .audio ? "BGM" : asset.kind.rawValue.capitalized)
                                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                                    Text(asset.summary ?? "Ready for generation").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if let license = asset.license { Text(license).font(.caption2).foregroundStyle(Color.pulseLime).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: isSelected(asset) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(isSelected(asset) ? Color.pulseLime : .secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(!isSelected(asset) && selectedAssets.count >= 8)
                        .accessibilityLabel("\(isSelected(asset) ? "Remove" : "Select") \(asset.displayName)")
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Resource Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task { await model.loadAssetLibrary() }
    }

    private func isSelected(_ asset: GenerationAsset) -> Bool {
        selectedAssets.contains { $0.id == asset.id }
    }

    private func toggle(_ asset: GenerationAsset) {
        if isSelected(asset) {
            selectedAssets.removeAll { $0.id == asset.id }
        } else if selectedAssets.count < 8 {
            selectedAssets.append(asset)
        }
    }
}

private struct ProgressSurface: View {
    let work: InteractiveApp
    let job: GenerationJob
    let hasPlan: Bool
    let showPlan: () -> Void

    private let visibleStages: [GenerationJob.Stage] = [.processingAssets, .planning, .coding, .verifying, .repairing, .fallbackBuilding]

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Spacer(minLength: 30)
            TimelineView(.animation) { context in
                let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
                ZStack {
                    Circle().stroke(Color.pulseViolet.opacity(0.22), lineWidth: 18).frame(width: 150, height: 150).scaleEffect(0.94 + pulse * 0.08)
                    Circle().fill(Color.pulseLime).frame(width: 21, height: 21).shadow(color: Color.pulseLime, radius: 18)
                }.frame(maxWidth: .infinity)
            }.frame(height: 180)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.stage.productTitle).font(.system(size: 29, weight: .bold, design: .rounded))
                Text(job.statusMessage).foregroundStyle(.secondary)
                Text(work.prompt).font(.subheadline).foregroundStyle(Color.pulseLime).lineLimit(2)
            }
            VStack(spacing: 0) {
                ForEach(visibleStages, id: \.self) { stage in
                    HStack(spacing: 12) {
                        Image(systemName: state(for: stage).symbol).foregroundStyle(state(for: stage).color)
                        Text(stage.productTitle).font(.subheadline)
                        Spacer()
                    }.padding(.vertical, 10)
                }
            }
            if hasPlan { Button(action: showPlan) { Label("View project plan", systemImage: "doc.text.magnifyingglass") }.buttonStyle(.bordered).tint(.pulseViolet) }
            Text("You can leave this screen. The job continues on the Go generation service and can be recovered from Profile.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(24)
    }

    private func state(for stage: GenerationJob.Stage) -> (symbol: String, color: Color) {
        let order = visibleStages.firstIndex(of: stage) ?? 0
        let current = visibleStages.firstIndex(of: job.stage) ?? order
        if order < current { return ("checkmark.circle.fill", .pulseLime) }
        if stage == job.stage { return ("circle.dotted", .pulseViolet) }
        return ("circle", .secondary)
    }
}

private struct PreviewSurface: View {
    @Environment(AppModel.self) private var model
    let work: InteractiveApp
    let job: GenerationJob
    let plan: GenerationPlan?
    let isPublishing: Bool
    let publish: () -> Void
    let showPlan: () -> Void
    @State private var touch = CGPoint(x: 0.5, y: 0.55)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(job.verificationGrade == .fallback ? "A safe version is ready" : "Your interactive app is ready")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                GeometryReader { proxy in
                    if let artifactID = job.artifactID {
                        ArtifactPlayerView(
                            url: model.artifactURL(for: artifactID),
                            accessibilityIdentifier: "generation.artifact.player"
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        LivingCanvas(app: work, touchPoint: touch)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in touch = CGPoint(x: value.location.x / proxy.size.width, y: value.location.y / proxy.size.height) })
                            .accessibilityIdentifier("generation.preview.canvas")
                            .accessibilityValue("touch-x-\(Int(touch.x * 100))-y-\(Int(touch.y * 100))")
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                }.frame(height: 360)
                HStack { Label(job.verificationGrade.rawValue.capitalized, systemImage: job.verificationGrade == .fallback ? "shield.lefthalf.filled" : "checkmark.seal.fill").foregroundStyle(job.verificationGrade == .fallback ? Color.pulseViolet : Color.pulseLime); Spacer(); Text("Score 92").font(.caption).foregroundStyle(.secondary) }
                Text(job.verificationGrade == .fallback ? "The standard version did not pass every gate. This simplified version passed build, loading, interaction and safety checks." : "Build, browser loading, the primary interaction, accessibility and local resource checks passed.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if plan != nil { Button(action: showPlan) { Label("Review plan and acceptance cases", systemImage: "doc.text") }.buttonStyle(.bordered) }
                Button(action: publish) {
                    HStack { if isPublishing { ProgressView().tint(.black) }; Text(job.verificationGrade == .fallback ? "Confirm and publish safe version" : "Publish to Pulse").fontWeight(.bold) }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black).disabled(isPublishing)
                    .accessibilityIdentifier("generation.publish")
            }.padding(22).padding(.bottom, 110)
        }
    }
}

private struct PlanSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let plan: GenerationPlan
    var body: some View {
        NavigationStack {
            List {
                Section("Objective") { Text(plan.objective) }
                Section("Screens") { ForEach(plan.screens) { screen in VStack(alignment: .leading) { Text(screen.id.capitalized).font(.headline); Text(screen.purpose).foregroundStyle(.secondary) } } }
                Section("Core interactions") { ForEach(plan.interactions) { interaction in VStack(alignment: .leading) { Text(interaction.trigger.capitalized).font(.headline); Text(interaction.effect).foregroundStyle(.secondary) } } }
                Section("Acceptance") { ForEach(plan.acceptanceCases) { item in VStack(alignment: .leading) { Text("\(item.priority) · \(item.action)").font(.headline); Text(item.assert).foregroundStyle(.secondary) } } }
                Section("Constraints") { ForEach(plan.constraints, id: \.self) { Label($0, systemImage: "lock.shield") } }
            }.navigationTitle(plan.title).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
