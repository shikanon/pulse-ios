import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct CreationSurfaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var creationSurfaceVisible: Bool {
        get { self[CreationSurfaceVisibleKey.self] }
        set { self[CreationSurfaceVisibleKey.self] = newValue }
    }
}

struct CreateView: View {
    let parent: InteractiveApp?
    let recoveryWork: InteractiveApp?
    let interactionViewportHeight: CGFloat?
    let onPublished: () -> Void

    init(
        parent: InteractiveApp? = nil,
        recoveryWork: InteractiveApp? = nil,
        interactionViewportHeight: CGFloat? = nil,
        onPublished: @escaping () -> Void
    ) {
        self.parent = parent
        self.recoveryWork = recoveryWork
        self.interactionViewportHeight = interactionViewportHeight
        self.onPublished = onPublished
    }

    private var isRemix: Bool { parent != nil || recoveryWork?.creationMode == .remix }

    var body: some View {
        GeometryReader { viewport in
            NavigationStack {
                ComposerFlow(
                    parent: parent,
                    initialPrompt: recoveryWork?.prompt ?? "",
                    resumeWork: recoveryWork,
                    interactionViewportHeight: max(interactionViewportHeight ?? 0, viewport.size.height)
                ) { _ in onPublished() }
                    .navigationTitle(isRemix ? "Remix" : "Create")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct PendingAssetUpload: Identifiable {
    let id = UUID()
    let fileName: String
    let mediaType: String
    let data: Data
}

private struct ComposerAssetUpload: Identifiable {
    let id: UUID
    let fileName: String
    var assetID: UUID?
    var phase: AssetUploadPhase
    var canRetryVerification = false
}

private struct ComposerFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    @Environment(PulseTelemetry.self) private var telemetry
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.creationSurfaceVisible) private var creationVisible
    @AppStorage(CreationPreferences.allowRemixByDefaultKey) private var allowsRemixByDefault = CreationPreferences.defaultAllowRemix
    let parent: InteractiveApp?
    let resumeWork: InteractiveApp?
    let interactionViewportHeight: CGFloat
    let onPublished: (InteractiveApp) -> Void
    @State private var isEditingVersion = false
    @State private var prompt: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var assets: [GenerationAsset] = []
    @State private var creationContext = CreationContext()
    @State private var isConversationPresented = false
    @State private var editingBaseJob: GenerationJob?
    @State private var work: InteractiveApp?
    @State private var job: GenerationJob?
    @State private var plan: GenerationPlan?
    @State private var verification: VerificationReport?
    @State private var isSubmitting = false
    @State private var isImporting = false
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var isPlanPresented = false
    @State private var isResourceLibraryPresented = false
    @State private var isBGMImporterPresented = false
    @State private var activeDraft: ComposerDraft?
    @State private var isRestoring = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var activeAssetUpload: ComposerAssetUpload?
    @State private var retryCandidate: PendingAssetUpload?
    @State private var retryCompletionAssetID: UUID?
    @State private var pendingBackgroundUpload: BackgroundAssetUploadRecord?
    @State private var isCancellingGeneration = false
    @State private var isRetryingGeneration = false
    @State private var isCancelGenerationConfirmationPresented = false
    @State private var requiresAuthentication = false
    @State private var pendingCreationIntent: PendingCreationIntent?
    @State private var promptFocusRequest = 0
    @State private var generationCapabilities: GenerationCapabilities?
    @State private var generationCapabilityCheckFailed = false

    init(
        parent: InteractiveApp?,
        initialPrompt: String,
        resumeWork: InteractiveApp? = nil,
        interactionViewportHeight: CGFloat,
        onPublished: @escaping (InteractiveApp) -> Void
    ) {
        self.parent = parent
        self.resumeWork = resumeWork
        self.interactionViewportHeight = interactionViewportHeight
        self.onPublished = onPublished
        _prompt = State(initialValue: initialPrompt)
        _work = State(initialValue: resumeWork)
        _isRestoring = State(initialValue: resumeWork?.generationJobID != nil)
    }

    private var draftOwnerID: String { session.user?.id ?? "local-development" }
    private var draftParentWorkID: UUID? { parent?.id ?? resumeWork?.parentID }
    private var assetUploadRecoveryContext: AssetUploadRecoveryContext {
        AssetUploadRecoveryContext(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
    }

    private var content: some View {
        Group {
            if isRestoring {
                ProgressView("Restoring your generation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let job, let work, !isEditingVersion {
                if job.stage.isTerminal {
                    TerminalSurface(
                        work: work, job: job, plan: plan, verification: verification, isPublishing: isPublishing,
                        publishingError: errorMessage, publish: publish,
                        showPlan: { isPlanPresented = true }, restart: restart,
                        retryGeneration: retryGeneration, isRetryingGeneration: isRetryingGeneration,
                        interactionViewportHeight: interactionViewportHeight
                    )
                }
                else {
                    ProgressSurface(
                        work: work,
                        job: job,
                        hasPlan: plan != nil,
                        statusNotice: errorMessage,
                        isCancelling: isCancellingGeneration,
                        showPlan: { isPlanPresented = true },
                        requestCancellation: { isCancelGenerationConfirmationPresented = true }
                    )
                }
            } else {
                inputSurface
            }
        }
    }

    private var conversationContinueAction: (() -> Void)? {
        guard (isEditingVersion || job?.stage.isTerminal == true) && !isPublishing else { return nil }
        return {
            isConversationPresented = false
            if !isEditingVersion { restart() }
            promptFocusRequest += 1
        }
    }

    private var previewReturnAction: (() -> Void)? {
        guard editingBaseJob != nil else { return nil }
        return { returnToPreview() }
    }

    private var inputSurface: some View {
                InputSurface(
                    parent: parent, isRemix: draftParentWorkID != nil, isEditingVersion: isEditingVersion, prompt: $prompt, pickerItems: $pickerItems, assets: assets,
                    creationContext: $creationContext, hasConversation: work != nil,
                    showConversation: { isConversationPresented = true },
                    returnToPreview: previewReturnAction,
                    isImporting: isImporting, isSubmitting: isSubmitting, activeUpload: activeAssetUpload, errorMessage: errorMessage,
                    promptFocusRequest: promptFocusRequest,
                    canAddPrivateAssets: session.canPerformMemberActions,
                    materialUploadsAvailable: generationCapabilities?.materialUploads == true,
                    generationAvailability: generationAvailability,
                    retryGenerationAvailability: { Task { await loadGenerationCapabilities() } },
                    browseLibrary: { requestAuthenticationForAssets { isResourceLibraryPresented = true } },
                    importBGM: { requestAuthenticationForAssets { isBGMImporterPresented = true } },
                    requestAuthentication: requestAuthenticationForCreation,
                    cancelUpload: cancelActiveUpload, retryUpload: retryLastAssetUpload,
                    removeAsset: { id in assets.removeAll { $0.id == id } }, submit: submit
                )
    }

    var body: some View {
        content
        .environment(\.creationSurfaceVisible, creationVisible && !isPlanPresented && !requiresAuthentication && !isResourceLibraryPresented)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .toolbar {
            if work != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Conversation", systemImage: "bubble.left.and.bubble.right") { isConversationPresented = true }
                        .accessibilityIdentifier("creation.conversation")
                }
            }
            if job?.stage.isTerminal == true, !isPublishing, !isEditingVersion {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New creation", systemImage: "plus", action: startNewCreation)
                        .accessibilityIdentifier("creation.new")
                }
            }
        }
        .onChange(of: job) { _, updated in model.activeCreationJob = updated }
        .onChange(of: pickerItems) { _, items in startPhotoImport(items) }
        .onChange(of: prompt) { _, _ in persistDraftIfNeeded() }
        .onChange(of: assets.map(\.id)) { _, _ in persistDraftIfNeeded() }
        .onChange(of: creationContext) { _, _ in persistDraftIfNeeded() }
        .onChange(of: session.user?.id) { oldUserID, newUserID in
            // A creation prompt must not be displayed after a member signs out
            // or changes accounts. The anonymous intent is kept only through
            // the authentication sheet that originated in this composer.
            guard oldUserID != newUserID, pendingCreationIntent == nil else { return }
            prompt = ""
            model.activeCreationJob = nil
            assets = []
            creationContext = CreationContext()
            editingBaseJob = nil
            isConversationPresented = false
            work = nil
            job = nil
            activeDraft = nil
            activeAssetUpload = nil
            retryCandidate = nil
            retryCompletionAssetID = nil
        }
        .onChange(of: session.canResumeMemberActions) { _, canResume in
            guard canResume else { return }
            if let intent = pendingCreationIntent, intent.parentWorkID == draftParentWorkID {
                prompt = intent.instruction
            }
            pendingCreationIntent = nil
            requiresAuthentication = false
        }
        .task(id: "\(draftOwnerID):\(draftParentWorkID?.uuidString ?? "original")") { await restoreDraftOrGeneration() }
        .task { await loadGenerationCapabilities() }
        .task(id: "\(job?.id.uuidString ?? "none"):\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await pollGeneration()
        }
        .onChange(of: scenePhase) { previousScenePhase, nextScenePhase in
            guard previousScenePhase == .active,
                  nextScenePhase != .active,
                  let job,
                  !job.stage.isTerminal
            else { return }
            telemetry.record(.generationBackgrounded, attributes: [
                "screen_id": "create",
                "creation_mode": draftParentWorkID == nil ? "original" : "remix"
            ])
        }
        .sheet(isPresented: $isPlanPresented) { if let plan { PlanSummaryView(plan: plan) } }
        .sheet(isPresented: $isConversationPresented) {
            if let work {
                CreationConversationSheet(
                    work: work, currentJob: job ?? editingBaseJob,
                    continueEditing: conversationContinueAction
                )
            }
        }
        .sheet(isPresented: $requiresAuthentication) {
            AuthenticationRequiredView(
                title: draftParentWorkID == nil ? "Sign in to create this app" : "Sign in to create this Remix",
                detail: "Your idea stays on this screen. After sign in, review it and choose Generate when you are ready."
            )
        }
        .sheet(isPresented: $isResourceLibraryPresented) { ResourceLibrarySheet(selectedAssets: $assets) }
        .fileImporter(isPresented: $isBGMImporterPresented, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            importBGM(result)
        }
        .confirmationDialog(
            "Cancel this generation?",
            isPresented: $isCancelGenerationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel generation", role: .destructive, action: cancelGeneration)
            Button("Keep generating", role: .cancel) {}
        } message: {
            Text("The current work stays private. Pulse will keep your instruction and selected materials, but this generation cannot be resumed after cancellation.")
        }
    }

    private func restoreDraftOrGeneration() async {
        guard session.canPerformMemberActions else { return }
        if let pendingRetry = PendingAssetSafetyRetryStore.load(ownerID: draftOwnerID, parentWorkID: draftParentWorkID) {
            activeAssetUpload = ComposerAssetUpload(
                id: pendingRetry.assetID,
                fileName: pendingRetry.fileName,
                assetID: pendingRetry.assetID,
                phase: .failed,
                canRetryVerification: true
            )
            retryCompletionAssetID = pendingRetry.assetID
        }
        if retryCompletionAssetID == nil,
           let backgroundUpload = BackgroundAssetUploadStore.records(for: assetUploadRecoveryContext).last {
            pendingBackgroundUpload = backgroundUpload
            activeAssetUpload = ComposerAssetUpload(
                id: backgroundUpload.assetID,
                fileName: backgroundUpload.fileName,
                assetID: backgroundUpload.assetID,
                phase: backgroundUpload.state == .transferred ? .verifying : (backgroundUpload.state == .uploading ? .uploading(progress: 0) : .failed),
                canRetryVerification: backgroundUpload.state == .transferred
            )
            if backgroundUpload.state == .transferred {
                retryCompletionAssetID = backgroundUpload.assetID
            } else if backgroundUpload.state == .uploading {
                resumePendingBackgroundAssetUpload(backgroundUpload)
            } else {
                errorMessage = "This material did not finish transferring. Keep Pulse open and try again when you have a connection."
            }
        }
        if let resumeWork, let generationID = resumeWork.generationJobID {
            let pendingDraft = ComposerDraftStore.load(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
            await restoreGeneration(generationID, failureMessage: "This generation could not be restored. Your existing work is still available in Profile.")
            if let draft = pendingDraft,
               draft.workID == resumeWork.id, draft.generationID == nil, job?.stage.isTerminal == true {
                activeDraft = draft
                prompt = draft.instruction
                creationContext = draft.creationContext ?? creationContext
                await restoreDraftAssets(draft)
                editingBaseJob = job?.artifactID == nil ? nil : job
                isEditingVersion = true
                job = nil
            }
            return
        }
        guard work == nil, job == nil,
              let draft = ComposerDraftStore.load(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
        else { return }
        activeDraft = draft
        prompt = draft.instruction
        creationContext = draft.creationContext ?? CreationContext()
        await restoreDraftAssets(draft)
        guard let workID = draft.workID else { return }
        guard let generationID = draft.generationID else {
            do {
                work = try await model.api.fetchWork(id: workID)
                isEditingVersion = work?.artifactID != nil
                if let generationID = work?.generationJobID {
                    editingBaseJob = try? await model.refreshGeneration(generationID)
                    if editingBaseJob?.artifactID == nil { editingBaseJob = nil }
                }
            } catch { errorMessage = "Your saved version could not be loaded. Try again when connected." }
            return
        }
        do {
            work = try await model.api.fetchWork(id: workID)
            isRestoring = true
            await restoreGeneration(generationID, failureMessage: "This generation could not be restored. Your saved instruction is ready to try again.")
        } catch {
            errorMessage = "This generation could not be restored. Your saved instruction is ready to try again."
            work = nil
            job = nil
        }
    }

    private func restoreDraftAssets(_ draft: ComposerDraft) async {
        assets = []
        guard !draft.assetIDs.isEmpty else { return }
        do {
            let available = try await model.api.fetchAssetLibrary()
            let assetsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
            assets = draft.assetIDs.compactMap { assetsByID[$0] }
            if assets.count != draft.assetIDs.count {
                errorMessage = "Some saved materials are no longer available, so they were removed from this draft."
            }
        } catch {
            errorMessage = "Your idea was restored, but materials could not be checked yet. Try again before generating."
        }
    }

    private func restoreGeneration(_ generationID: UUID, failureMessage: String) async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            let restored = try await model.refreshGeneration(generationID)
            job = restored
            if activeDraft == nil {
                creationContext = CreationContext.parse(restored.instruction).context ?? CreationContext()
                if !restored.assetIDs.isEmpty {
                    do {
                        let available = try await model.api.fetchAssetLibrary()
                        assets = available.filter { restored.assetIDs.contains($0.id) }
                    } catch {
                        errorMessage = "Your idea was restored, but materials could not be checked yet. Try again before generating."
                    }
                }
            }
            work = try await model.api.fetchWork(id: restored.workID)
            if restored.planID != nil { plan = try? await model.plan(for: generationID) }
            if let verificationID = restored.verificationID { verification = try? await model.verification(for: verificationID) }
        } catch {
            errorMessage = failureMessage
            work = nil
            job = nil
        }
    }

    @discardableResult
    private func persistDraft(resetOperation: Bool = false) -> ComposerDraft {
        var draft: ComposerDraft
        if resetOperation {
            draft = .fresh(ownerID: draftOwnerID, parentWorkID: draftParentWorkID, instruction: prompt, assetIDs: assets.map(\.id))
        } else if let activeDraft {
            draft = activeDraft
            draft.instruction = prompt
            draft.assetIDs = assets.map(\.id)
            draft.updatedAt = Date()
        } else {
            draft = .fresh(ownerID: draftOwnerID, parentWorkID: draftParentWorkID, instruction: prompt, assetIDs: assets.map(\.id))
        }
        draft.workID = work?.id ?? draft.workID
        draft.creationContext = creationContext.selected(for: assets)
        if isEditingVersion { draft.generationID = nil }
        activeDraft = draft
        do {
            try ComposerDraftStore.save(draft)
        } catch {
            errorMessage = "Pulse could not securely save this draft on this device. Keep this screen open while you generate."
        }
        return draft
    }

    private func persistDraftIfNeeded() {
        guard session.canPerformMemberActions else { return }
        guard !isRestoring, job == nil else { return }
        guard activeDraft != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assets.isEmpty else { return }
        _ = persistDraft()
    }

    private func clearDraft() {
        if let backgroundUpload = pendingBackgroundUpload {
            BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: backgroundUpload.assetID)
            Task { try? await model.api.cancelAssetUpload(id: backgroundUpload.assetID) }
            pendingBackgroundUpload = nil
        }
        if let pendingAssetID = retryCompletionAssetID {
            PendingAssetSafetyRetryStore.clear(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
            Task { try? await model.api.cancelAssetUpload(id: pendingAssetID) }
        }
        ComposerDraftStore.clear(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
        activeDraft = nil
    }

    private func submit() {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isSubmitting, !isImporting else { return }
        guard generationAvailability.canGenerate else {
            errorMessage = "AI generation is not available on this server. Ask the operator to connect the live model service, then try again."
            return
        }
        guard session.canPerformMemberActions else {
            pendingCreationIntent = PendingCreationIntent(parentWorkID: draftParentWorkID, instruction: instruction)
            requiresAuthentication = true
            return
        }
        guard assets.reduce(0, { $0 + $1.sizeBytes }) <= 4 * 1024 * 1024 else {
            errorMessage = "Selected media exceed the 4 MB game budget. Remove or compress a file before generating."
            return
        }
        isSubmitting = true
        errorMessage = nil
        let draft = persistDraft()
        Task {
            do {
                let result = try await model.beginGeneration(
                    existingWork: work,
                    instruction: instruction,
                    parent: parent,
                    parentWorkID: draftParentWorkID,
                    assets: assets,
                    generationInstruction: creationContext.selected(for: assets).instruction(for: instruction),
                    baseArtifactID: editingBaseJob?.verificationGrade == .fallback ? nil : editingBaseJob?.artifactID,
                    allowRemix: allowsRemixByDefault,
                    workIdempotencyKey: draft.workIdempotencyKey,
                    generationIdempotencyKey: draft.generationIdempotencyKey
                )
                work = result.0
                job = result.1
                isEditingVersion = false
                editingBaseJob = nil
                telemetry.record(.generationSubmitted, attributes: [
                    "screen_id": "create",
                    "creation_mode": draftParentWorkID == nil ? "original" : "remix"
                ])
                var recoveredDraft = draft
                recoveredDraft.workID = result.0.id
                recoveredDraft.generationID = result.1.id
                recoveredDraft.updatedAt = Date()
                activeDraft = recoveredDraft
                try? ComposerDraftStore.save(recoveredDraft)
            } catch {
                if let apiError = error as? PulseAPIError,
                   let validationMessage = apiError.validationMessage(for: ["instruction"]) {
                    errorMessage = validationMessage
                    promptFocusRequest += 1
                } else {
                    errorMessage = error.localizedDescription
                }
                telemetry.record(.generationSubmissionFailed, attributes: [
                    "screen_id": "create",
                    "creation_mode": draftParentWorkID == nil ? "original" : "remix",
                    "error_category": "network_or_server"
                ])
            }
            isSubmitting = false
        }
    }

    private var generationAvailability: GenerationAvailability {
        if let generationCapabilities {
            if generationCapabilities.usesLiveModel { return .live }
            return allowsLocalTestGeneration ? .localTest : .notConfigured
        }
        return generationCapabilityCheckFailed ? .unavailable : .checking
    }

    private var allowsLocalTestGeneration: Bool {
#if DEBUG
        model.api.isLocalDevelopmentServer && ProcessInfo.processInfo.environment["PULSE_ALLOW_DEMO_GENERATION"] == "1"
#else
        false
#endif
    }

    private func loadGenerationCapabilities() async {
        generationCapabilityCheckFailed = false
        do {
            generationCapabilities = try await model.api.fetchGenerationCapabilities()
        } catch {
            generationCapabilities = nil
            generationCapabilityCheckFailed = true
        }
    }

    private func startPhotoImport(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isImporting, !isSubmitting else { return }
        guard session.canPerformMemberActions else {
            pickerItems = []
            requestAuthenticationForCreation()
            return
        }
        isImporting = true
        errorMessage = nil
        activeAssetUpload = ComposerAssetUpload(id: UUID(), fileName: "Selected materials", assetID: nil, phase: .preparing)
        uploadTask = Task {
            defer {
                isImporting = false
                uploadTask = nil
                pickerItems = []
            }
            do {
                let candidates = try await photoCandidates(from: items)
                try await performAssetUploads(candidates)
            } catch is CancellationError {
                activeAssetUpload?.phase = .cancelled
                errorMessage = "Upload cancelled. You can try that material again."
            } catch {
                markAssetUploadFailure(error)
            }
        }
    }

    private func photoCandidates(from items: [PhotosPickerItem]) async throws -> [PendingAssetUpload] {
        var candidates: [PendingAssetUpload] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PulseAPIError(message: "One selected material could not be read. Choose it again and try uploading.")
            }
            let type = item.supportedContentTypes.first ?? .data
            let extensionName = type.preferredFilenameExtension ?? "bin"
            let candidate = PendingAssetUpload(
                fileName: "pulse-material-\(index + 1).\(extensionName)",
                mediaType: type.preferredMIMEType ?? "application/octet-stream",
                data: data
            )
            if let message = PrivateAssetUploadPolicy.validationMessage(fileName: candidate.fileName, mediaType: candidate.mediaType, sizeBytes: candidate.data.count) {
                throw PulseAPIError(message: message)
            }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else {
            throw PulseAPIError(message: "No usable materials were selected.")
        }
        return candidates
    }

    private func importBGM(_ result: Result<[URL], Error>) {
        guard session.canPerformMemberActions else {
            requestAuthenticationForCreation()
            return
        }
        do {
            guard let url = try result.get().first else {
                return
            }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey])
            let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .audio
            let mediaType = contentType.preferredMIMEType ?? "audio/mpeg"
            let data = try Data(contentsOf: url)
            let candidate = PendingAssetUpload(fileName: url.lastPathComponent, mediaType: mediaType, data: data)
            if let message = PrivateAssetUploadPolicy.validationMessage(fileName: candidate.fileName, mediaType: candidate.mediaType, sizeBytes: candidate.data.count) {
                throw PulseAPIError(message: message)
            }
            startAssetUpload([candidate])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startAssetUpload(_ candidates: [PendingAssetUpload]) {
        guard !candidates.isEmpty, !isImporting, !isSubmitting else { return }
        guard session.canPerformMemberActions else {
            requestAuthenticationForCreation()
            return
        }
        isImporting = true
        errorMessage = nil
        activeAssetUpload = ComposerAssetUpload(id: candidates[0].id, fileName: candidates[0].fileName, assetID: nil, phase: .preparing)
        uploadTask = Task {
            defer {
                isImporting = false
                uploadTask = nil
            }
            do {
                try await performAssetUploads(candidates)
            } catch is CancellationError {
                activeAssetUpload?.phase = .cancelled
                errorMessage = "Upload cancelled. You can try that material again."
            } catch {
                markAssetUploadFailure(error)
            }
        }
    }

    private func performAssetUploads(_ candidates: [PendingAssetUpload]) async throws {
        let remainingSlots = 8 - assets.count
        guard remainingSlots > 0 else {
            throw PulseAPIError(message: "You can add up to 8 materials to one creation. Remove a material before uploading another.")
        }
        guard candidates.count <= remainingSlots else {
            throw PulseAPIError(message: "You can add (remainingSlots) more material\(remainingSlots == 1 ? "" : "s") to this creation.")
        }

        for candidate in candidates {
            try Task.checkCancellation()
            retryCandidate = candidate
            activeAssetUpload = ComposerAssetUpload(id: candidate.id, fileName: candidate.fileName, assetID: nil, phase: .preparing)
            telemetry.record(.assetUploadStarted, attributes: ["screen_id": "create"])
            do {
                let asset = try await model.registerAssetWithProgress(
                    fileName: candidate.fileName,
                    mediaType: candidate.mediaType,
                    data: candidate.data,
                    recoveryContext: assetUploadRecoveryContext
                ) { progress in
                    guard activeAssetUpload?.id == candidate.id else { return }
                    activeAssetUpload?.assetID = progress.assetID ?? activeAssetUpload?.assetID
                    activeAssetUpload?.phase = progress.phase
                }
                mergeAssets([asset])
                telemetry.record(.assetUploadCompleted, attributes: ["screen_id": "create"])
                activeAssetUpload = nil
                retryCandidate = nil
            } catch is CancellationError {
                activeAssetUpload?.phase = .cancelled
                telemetry.record(.assetUploadCancelled, attributes: ["screen_id": "create"])
                throw CancellationError()
            } catch {
                activeAssetUpload?.phase = .failed
                activeAssetUpload?.canRetryVerification = AssetUploadRetryPolicy.preservesUploadedObject(for: error) && activeAssetUpload?.assetID != nil
                retryCompletionAssetID = activeAssetUpload?.canRetryVerification == true ? activeAssetUpload?.assetID : nil
                if let assetID = activeAssetUpload?.assetID,
                   let backgroundRecord = BackgroundAssetUploadStore.record(assetID: assetID) {
                    pendingBackgroundUpload = backgroundRecord
                }
                rememberPendingAssetSafetyRetryIfNeeded()
                telemetry.record(.assetUploadFailed, attributes: ["screen_id": "create", "error_category": "upload_failed"])
                throw error
            }
        }
    }

    private func cancelActiveUpload() {
        guard isImporting || activeAssetUpload?.assetID != nil else { return }
        if let assetID = activeAssetUpload?.assetID {
            BackgroundAssetUploadCoordinator.shared.cancelAndDiscard(assetID: assetID)
            Task { try? await model.api.cancelAssetUpload(id: assetID) }
        }
        uploadTask?.cancel()
    }

    private func retryLastAssetUpload() {
        guard !isImporting else { return }
        if let retryCompletionAssetID {
            retryAssetCompletion(id: retryCompletionAssetID)
            return
        }
        if let pendingBackgroundUpload {
            switch pendingBackgroundUpload.state {
            case .uploading:
                resumePendingBackgroundAssetUpload(pendingBackgroundUpload)
            case .transferred:
                retryAssetCompletion(id: pendingBackgroundUpload.assetID)
            case .failed:
                retryFailedBackgroundAssetUpload(pendingBackgroundUpload)
            }
            return
        }
        guard let retryCandidate else { return }
        activeAssetUpload = nil
        startAssetUpload([retryCandidate])
    }

    private func retryAssetCompletion(id: UUID) {
        guard !isImporting, var activeUpload = activeAssetUpload, activeUpload.assetID == id else { return }
        isImporting = true
        errorMessage = nil
        activeUpload.phase = .verifying
        activeUpload.canRetryVerification = false
        activeAssetUpload = activeUpload
        uploadTask = Task {
            defer {
                isImporting = false
                uploadTask = nil
            }
            do {
                let asset = try await model.completeAssetUpload(id: id) { progress in
                    guard activeAssetUpload?.assetID == id else { return }
                    activeAssetUpload?.phase = progress.phase
                    activeAssetUpload?.canRetryVerification = false
                }
                mergeAssets([asset])
                telemetry.record(.assetUploadCompleted, attributes: ["screen_id": "create"])
                activeAssetUpload = nil
                retryCandidate = nil
                retryCompletionAssetID = nil
                pendingBackgroundUpload = nil
                PendingAssetSafetyRetryStore.clear(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
            } catch is CancellationError {
                activeAssetUpload?.phase = .cancelled
                activeAssetUpload?.canRetryVerification = false
                retryCompletionAssetID = nil
                PendingAssetSafetyRetryStore.clear(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
                telemetry.record(.assetUploadCancelled, attributes: ["screen_id": "create"])
            } catch {
                activeAssetUpload?.phase = .failed
                activeAssetUpload?.canRetryVerification = AssetUploadRetryPolicy.preservesUploadedObject(for: error)
                retryCompletionAssetID = activeAssetUpload?.canRetryVerification == true ? id : nil
                rememberPendingAssetSafetyRetryIfNeeded()
                telemetry.record(.assetUploadFailed, attributes: ["screen_id": "create", "error_category": "upload_failed"])
                markAssetUploadFailure(error)
            }
        }
    }

    private func markAssetUploadFailure(_ error: Error) {
        if activeAssetUpload != nil {
            activeAssetUpload?.phase = .failed
            if activeAssetUpload?.canRetryVerification == true {
                errorMessage = "Pulse couldn’t finish checking \(activeAssetUpload?.fileName ?? "this material"). It is still uploaded—try checking it again without uploading it again."
            } else {
                errorMessage = "The transfer could not finish. Keep Pulse open, check your connection, and retry. Your selected file is still available."
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func rememberPendingAssetSafetyRetryIfNeeded() {
        guard let upload = activeAssetUpload,
              upload.canRetryVerification,
              let assetID = upload.assetID
        else { return }
        do {
            try PendingAssetSafetyRetryStore.save(
                PendingAssetSafetyRetry(assetID: assetID, fileName: upload.fileName, createdAt: Date()),
                ownerID: draftOwnerID,
                parentWorkID: draftParentWorkID
            )
            if let assetID = upload.assetID {
                BackgroundAssetUploadCoordinator.shared.discard(assetID: assetID)
                pendingBackgroundUpload = nil
            }
        } catch {
            // The current in-memory retry remains available. Do not persist
            // private bytes as a fallback if Keychain cannot be written.
        }
    }

    private func resumePendingBackgroundAssetUpload(_ record: BackgroundAssetUploadRecord) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        uploadTask = Task {
            defer {
                isImporting = false
                uploadTask = nil
            }
            do {
                let asset = try await model.resumeBackgroundAssetUpload(record) { progress in
                    guard activeAssetUpload?.assetID == record.assetID else { return }
                    activeAssetUpload?.phase = progress.phase
                }
                mergeAssets([asset])
                telemetry.record(.assetUploadCompleted, attributes: ["screen_id": "create"])
                activeAssetUpload = nil
                pendingBackgroundUpload = nil
                retryCompletionAssetID = nil
            } catch is CancellationError {
                // Leaving this composer must not cancel a system-owned
                // background upload. The explicit Cancel control handles that.
            } catch {
                activeAssetUpload?.phase = .failed
                activeAssetUpload?.canRetryVerification = AssetUploadRetryPolicy.preservesUploadedObject(for: error)
                retryCompletionAssetID = activeAssetUpload?.canRetryVerification == true ? record.assetID : nil
                rememberPendingAssetSafetyRetryIfNeeded()
                markAssetUploadFailure(error)
            }
        }
    }

    private func retryFailedBackgroundAssetUpload(_ record: BackgroundAssetUploadRecord) {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        activeAssetUpload?.phase = .verifying
        activeAssetUpload?.canRetryVerification = false
        uploadTask = Task {
            defer {
                isImporting = false
                uploadTask = nil
            }
            do {
                // A completion probe avoids duplicating a material when a
                // network error happened after OSS had already accepted it.
                let asset = try await model.completeAssetUpload(id: record.assetID) { progress in
                    guard activeAssetUpload?.assetID == record.assetID else { return }
                    activeAssetUpload?.phase = progress.phase
                }
                mergeAssets([asset])
                telemetry.record(.assetUploadCompleted, attributes: ["screen_id": "create"])
                activeAssetUpload = nil
                pendingBackgroundUpload = nil
                retryCompletionAssetID = nil
                return
            } catch let error as PulseAPIError where error.serverCode == "asset_upload_not_found" {
                do {
                    let data = try BackgroundAssetUploadStore.readPrivateData(for: record)
                    try? await model.api.cancelAssetUpload(id: record.assetID)
                    pendingBackgroundUpload = nil
                    activeAssetUpload = ComposerAssetUpload(id: UUID(), fileName: record.fileName, assetID: nil, phase: .preparing)
                    let asset = try await model.registerAssetWithProgress(
                        fileName: record.fileName,
                        mediaType: record.mediaType,
                        data: data,
                        recoveryContext: assetUploadRecoveryContext
                    ) { progress in
                        activeAssetUpload?.assetID = progress.assetID ?? activeAssetUpload?.assetID
                        activeAssetUpload?.phase = progress.phase
                    }
                    mergeAssets([asset])
                    telemetry.record(.assetUploadCompleted, attributes: ["screen_id": "create"])
                    activeAssetUpload = nil
                    retryCompletionAssetID = nil
                } catch {
                    activeAssetUpload?.phase = .failed
                    activeAssetUpload?.canRetryVerification = AssetUploadRetryPolicy.preservesUploadedObject(for: error)
                    retryCompletionAssetID = activeAssetUpload?.canRetryVerification == true ? record.assetID : nil
                    rememberPendingAssetSafetyRetryIfNeeded()
                    markAssetUploadFailure(error)
                }
            } catch {
                activeAssetUpload?.phase = .failed
                activeAssetUpload?.canRetryVerification = AssetUploadRetryPolicy.preservesUploadedObject(for: error)
                retryCompletionAssetID = activeAssetUpload?.canRetryVerification == true ? record.assetID : nil
                rememberPendingAssetSafetyRetryIfNeeded()
                markAssetUploadFailure(error)
            }
        }
    }

    private func mergeAssets(_ additions: [GenerationAsset]) {
        for asset in additions where !assets.contains(where: { $0.id == asset.id }) {
            assets.append(asset)
        }
        if let upload = activeAssetUpload, additions.contains(where: { $0.id == upload.assetID }) {
            activeAssetUpload = nil
            retryCompletionAssetID = nil
        }
    }

    private func requestAuthenticationForCreation() {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            pendingCreationIntent = PendingCreationIntent(parentWorkID: draftParentWorkID, instruction: instruction)
        }
        requiresAuthentication = true
    }

    private func requestAuthenticationForAssets(_ action: () -> Void) {
        guard session.canPerformMemberActions else {
            requestAuthenticationForCreation()
            return
        }
        action()
    }

    private func pollGeneration() async {
        guard let jobID = job?.id else { return }
        while !Task.isCancelled {
            do {
                let updated = try await model.refreshGeneration(jobID)
                job = updated
                if updated.planID != nil, plan == nil { plan = try? await model.plan(for: jobID) }
                if let verificationID = updated.verificationID, verification == nil { verification = try? await model.verification(for: verificationID) }
                if updated.stage.isTerminal {
                    work = try await model.api.fetchWork(id: updated.workID)
                    errorMessage = nil
                    return
                }
                errorMessage = nil
                try await Task.sleep(for: .milliseconds(450))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Reconnecting to generation status…"
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func publish(title: String, summary: String) {
        guard let work, !isPublishing else { return }
        isPublishing = true
        errorMessage = nil
        Task {
            do {
                let published = try await model.publish(work.id, title: title, summary: summary, artifactID: job?.artifactID)
                clearDraft()
                self.work = nil
                job = nil
                plan = nil
                verification = nil
                prompt = ""
                assets = []
                pickerItems = []
                isEditingVersion = false
                model.activeCreationJob = nil
                onPublished(published)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPublishing = false
        }
    }

    private func startNewCreation() {
        // The saved server work remains available from Profile. Only the
        // local composer slot is released for the next idea.
        clearDraft()
        prompt = ""
        assets = []
        creationContext = CreationContext()
        editingBaseJob = nil
        work = nil
        job = nil
        plan = nil
        verification = nil
        errorMessage = nil
        isEditingVersion = false
        model.activeCreationJob = nil
    }

    private func restart() {
        // Keep the Work and its last successful Artifact. A new request creates
        // a candidate for this same work rather than a disconnected work.
        if job?.verificationGrade == .fallback {
            prompt = CreationContext.parse(job?.instruction ?? prompt).message
            work = nil
        }
        let hasUnsentMessage = editingBaseJob?.id == job?.id
        editingBaseJob = job?.artifactID == nil ? nil : job
        isEditingVersion = work?.artifactID != nil
        if isEditingVersion && !hasUnsentMessage { prompt = "" }
        job = nil
        plan = nil
        verification = nil
        errorMessage = nil
        _ = persistDraft(resetOperation: true)
    }

    private func returnToPreview() {
        guard let editingBaseJob else { return }
        _ = persistDraft()
        job = editingBaseJob
        isEditingVersion = false
    }

    private func cancelGeneration() {
        guard let job, !job.stage.isTerminal, !isCancellingGeneration else { return }
        isCancellingGeneration = true
        errorMessage = nil
        Task {
            do {
                self.job = try await model.cancelGeneration(job.id)
                telemetry.record(.generationCancelled, attributes: [
                    "screen_id": "create",
                    "creation_mode": draftParentWorkID == nil ? "original" : "remix"
                ])
                if let work {
                    self.work = try? await model.api.fetchWork(id: work.id)
                }
            } catch {
                errorMessage = "Pulse couldn’t cancel this generation. It may still finish; check the status before leaving."
            }
            isCancellingGeneration = false
        }
    }

    private func retryGeneration() {
        guard let job, (job.stage == .cancelled || job.retryable), !isRetryingGeneration else { return }
        isRetryingGeneration = true
        errorMessage = nil
        Task {
            do {
                let retried = try await model.retryGeneration(job.id)
                self.job = retried
                telemetry.record(.generationRetried, attributes: [
                    "screen_id": "create",
                    "creation_mode": draftParentWorkID == nil ? "original" : "remix"
                ])
                self.plan = nil
                self.verification = nil
                if let work {
                    self.work = try? await model.api.fetchWork(id: work.id)
                }
                var draft = activeDraft ?? persistDraft()
                draft.workID = self.work?.id
                draft.generationID = retried.id
                draft.updatedAt = Date()
                activeDraft = draft
                try? ComposerDraftStore.save(draft)
            } catch {
                errorMessage = "Pulse couldn’t retry this generation. Your idea and materials are still saved."
            }
            isRetryingGeneration = false
        }
    }
}

private struct InputSurface: View {
    let parent: InteractiveApp?
    let isRemix: Bool
    let isEditingVersion: Bool
    @Binding var prompt: String
    @Binding var pickerItems: [PhotosPickerItem]
    let assets: [GenerationAsset]
    @Binding var creationContext: CreationContext
    let hasConversation: Bool
    let showConversation: () -> Void
    let returnToPreview: (() -> Void)?
    let isImporting: Bool
    let isSubmitting: Bool
    let activeUpload: ComposerAssetUpload?
    let errorMessage: String?
    let promptFocusRequest: Int
    let canAddPrivateAssets: Bool
    let materialUploadsAvailable: Bool
    let generationAvailability: GenerationAvailability
    let retryGenerationAvailability: () -> Void
    let browseLibrary: () -> Void
    let importBGM: () -> Void
    let requestAuthentication: () -> Void
    let cancelUpload: () -> Void
    let retryUpload: () -> Void
    let removeAsset: (UUID) -> Void
    let submit: () -> Void
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isEditingVersion {
                    Label("Refine this version", systemImage: "wand.and.stars")
                        .font(.title2.bold())
                    Text("Describe the changes. Your current game and its materials will be the starting point.")
                        .foregroundStyle(.secondary)
                } else if let parent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REMIX OF").font(.caption2.weight(.bold)).foregroundStyle(Color.pulseViolet)
                        Text(parent.title).font(.title2.bold())
                        Text("by @\(parent.creator) · original by @\(parent.originalCreator)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                } else if isRemix {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REMIX VERSION").font(.caption2.weight(.bold)).foregroundStyle(Color.pulseViolet)
                        Text("Continue this Remix with a new version").font(.title2.bold())
                        Text("Pulse will re-check that the original can still be remixed before creating anything.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Make something people can feel.").font(.largeTitle.weight(.bold))
                        Text("Start from one sentence. Images and videos are optional.").foregroundStyle(.secondary)
                    }
                }

                if hasConversation {
                    HStack {
                        Button("Review conversation", systemImage: "bubble.left.and.bubble.right", action: showConversation)
                        Spacer()
                        if let returnToPreview {
                            Button("Back to preview", action: returnToPreview)
                                .accessibilityIdentifier("creation.back-to-preview")
                        }
                    }.font(.subheadline).tint(.pulseLime)
                }
                Text("Create, play, then ask for another change. Each message creates a new version of this work.")
                    .font(.caption).foregroundStyle(.secondary)
                if isRemix || isEditingVersion {
                    Label("Existing game and embedded media are inherited. Add materials below only when you need something new.", systemImage: "square.on.square")
                        .font(.caption).foregroundStyle(Color.pulseViolet)
                        .accessibilityIdentifier("creation.inherited-materials")
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(isEditingVersion || isRemix ? "What should change?" : "Your idea").font(.headline)
                    ZStack(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(isEditingVersion || isRemix ? "For example: make the pace slower and the colors warmer" : "For example: make a tiny garden that reacts to each touch")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 17).padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $prompt)
                            .scrollContentBackground(.hidden).frame(height: 144).padding(12)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .focused($isPromptFocused)
                            .accessibilityLabel(isRemix ? "Describe what should change in this Remix" : "Describe the interactive app you want to create")
                            .accessibilityHint("A single sentence is enough. Images, video, and BGM are optional.")
                            .accessibilityIdentifier("creation.prompt")
                    }
                    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
                }

                if isRemix || isEditingVersion {
                    DisclosureGroup("What should stay the same?") {
                        TextField("For example: keep the controls, scoring and cat image", text: $creationContext.preserve, axis: .vertical)
                            .lineLimit(2...4)
                            .accessibilityIdentifier("creation.preserve")
                        Text("These instructions stay with the next rounds until you change them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tint(.pulseLime)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Resource library").font(.headline)
                        Spacer()
                        Text("\(assets.count)/8 · Added here").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 9) {
                        ResourceActionButton(title: "Library", symbol: "square.grid.2x2", prominent: true, action: browseLibrary)
                            .disabled(isImporting || isSubmitting)
                            .accessibilityLabel(canAddPrivateAssets ? "Browse public and private resources" : "Sign in to add resources")
                            .accessibilityIdentifier("creation.resource-library")

                        if canAddPrivateAssets {
                            PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                                VStack(spacing: 7) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.title3.weight(.semibold))
                                    Text(isImporting ? "Preparing" : "Media")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .foregroundStyle(Color.white.opacity(0.9))
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.16)))
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .disabled(isImporting || isSubmitting || assets.count >= 8 || !materialUploadsAvailable)
                            .accessibilityLabel(isImporting ? "Preparing resources" : "Upload private images or videos")
                            .accessibilityIdentifier("creation.upload-media")
                        } else {
                            ResourceActionButton(title: "Media", symbol: "person.crop.circle.badge.plus", action: requestAuthentication)
                                .disabled(isSubmitting)
                                .accessibilityLabel("Sign in to upload private images or videos")
                                .accessibilityIdentifier("creation.upload-media")
                        }

                        ResourceActionButton(
                            title: "BGM",
                            symbol: canAddPrivateAssets ? "music.note.list" : "person.crop.circle.badge.plus",
                            action: importBGM
                        )
                        .disabled(isImporting || isSubmitting || assets.count >= 8 || !materialUploadsAvailable)
                        .accessibilityLabel(canAddPrivateAssets ? "Upload private BGM" : "Sign in to upload private BGM")
                        .accessibilityIdentifier("creation.upload-bgm")
                    }
                    if !materialUploadsAvailable {
                        Text("Material uploads are unavailable. You can create with text while storage is being configured.")
                            .font(.caption).foregroundStyle(Color.pulseCoral)
                    }
                    if let activeUpload {
                        AssetUploadStatusView(upload: activeUpload, cancel: cancelUpload, retry: retryUpload)
                    }
                    if !assets.isEmpty {
                        Text("Media budget: \(ByteCountFormatter.string(fromByteCount: Int64(assets.reduce(0) { $0 + $1.sizeBytes }), countStyle: .file)) / 4 MB")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(assets) { asset in
                        MaterialDirectionCard(asset: asset, context: $creationContext, remove: { removeAsset(asset.id) })
                    }
                    if !assets.isEmpty {
                        Text("Choose how each file should appear. After generation, play the event you described to check the result.")
                            .font(.caption).foregroundStyle(.secondary)
                        if isEditingVersion || isRemix {
                            Text("Removing a file here stops attaching it again. To remove media already in the game, ask for that change in your message.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.pulseCoral) }
                if !canAddPrivateAssets {
                    Text("Your idea stays on this screen until you sign in. It will not start generating automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                GenerationAvailabilityRow(availability: generationAvailability, retry: retryGenerationAvailability)
                Button(action: submit) {
                    HStack {
                        if isSubmitting { ProgressView().tint(.black) }
                        Text(canAddPrivateAssets ? (isEditingVersion ? "Apply changes" : (isRemix ? "Create Remix with AI" : "Generate with AI")) : (isRemix ? "Sign in to create Remix" : "Sign in to generate"))
                            .fontWeight(.bold)
                    }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting || isImporting || !generationAvailability.canGenerate)
                .accessibilityIdentifier("creation.generate")
            }.padding(.horizontal,20).padding(.vertical,10).background(Color.black)
        }
        .onChange(of: promptFocusRequest) { _, _ in
            isPromptFocused = true
        }
    }
}

private enum GenerationAvailability: Equatable {
    case checking
    case live
    case localTest
    case notConfigured
    case unavailable

    var canGenerate: Bool { self == .live || self == .localTest }
}

private struct GenerationAvailabilityRow: View {
    let availability: GenerationAvailability
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch availability {
            case .checking:
                ProgressView().tint(Color.pulseViolet)
                Text("Checking AI generator…")
            case .live:
                Image(systemName: "sparkles").foregroundStyle(Color.pulseLime)
                Text("Live AI generation is ready")
            case .localTest:
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Color.pulseViolet)
                Text("Local test generator · automated testing only")
            case .notConfigured:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.pulseCoral)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI generation is not configured")
                        .fontWeight(.semibold)
                    Text("Connect the server to a live model before generating.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .unavailable:
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.pulseCoral)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Couldn’t check the AI generator")
                        .fontWeight(.semibold)
                    Button("Try again", action: retry)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.pulseViolet)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("creation.generation-availability")
    }
}

private struct ResourceActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ResourceActionLabel(title: title, symbol: symbol, prominent: prominent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct ResourceActionLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var prominent = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.9))
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(prominent ? Color.pulseViolet : Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(prominent ? Color.pulseViolet : Color.white.opacity(0.16)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct AssetUploadStatusView: View {
    let upload: ComposerAssetUpload
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(upload.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                phaseAction
            }
            switch upload.phase {
            case .uploading(let progress):
                ProgressView(value: progress)
                    .tint(Color.pulseViolet)
                    .accessibilityLabel("Upload progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                Text("Uploading \(Int((progress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .preparing:
                ProgressView("Preparing this material…")
                    .font(.caption)
                    .tint(Color.pulseViolet)
            case .verifying:
                ProgressView("Checking the uploaded material…")
                    .font(.caption)
                    .tint(Color.pulseViolet)
            case .cancelled:
                Text("Upload cancelled. This material was not added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Text(upload.canRetryVerification ? "Checking is temporarily unavailable. This upload is still here." : "Upload failed. This material was not added.")
                    .font(.caption)
                    .foregroundStyle(Color.pulseCoral)
            case .completed:
                Text("Added to this creation.")
                    .font(.caption)
                    .foregroundStyle(Color.pulseLime)
            }
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Upload \(upload.fileName)")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var phaseAction: some View {
        switch upload.phase {
        case .preparing, .uploading, .verifying:
            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
                .tint(Color.pulseCoral)
                .accessibilityLabel("Cancel upload of \(upload.fileName)")
        case .cancelled, .failed:
            Button(upload.canRetryVerification ? "Check again" : "Try again", action: retry)
                .buttonStyle(.bordered)
                .tint(Color.pulseViolet)
                .accessibilityLabel(upload.canRetryVerification ? "Check \(upload.fileName) again without uploading it again" : "Try uploading \(upload.fileName) again")
        case .completed:
            EmptyView()
        }
    }

    private var symbol: String {
        switch upload.phase {
        case .preparing, .uploading, .verifying: "arrow.up.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch upload.phase {
        case .preparing, .uploading, .verifying: .pulseViolet
        case .completed: .pulseLime
        case .cancelled, .failed: .pulseCoral
        }
    }

    private var accessibilityValue: String {
        switch upload.phase {
        case .preparing: "Preparing"
        case .uploading(let progress): "Uploading \(Int((progress * 100).rounded())) percent"
        case .verifying: "Checking uploaded material"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: upload.canRetryVerification ? "Checking temporarily unavailable; upload retained" : "Failed"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let work: InteractiveApp
    let job: GenerationJob
    let hasPlan: Bool
    let statusNotice: String?
    let isCancelling: Bool
    let showPlan: () -> Void
    let requestCancellation: () -> Void

    private let visibleStages: [GenerationJob.Stage] = [.processingAssets, .planning, .coding, .verifying, .repairing, .fallbackBuilding]

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Spacer(minLength: 30)
            Group {
                if reduceMotion {
                    progressIndicator(pulse: 0.5)
                } else {
                    TimelineView(.animation) { context in
                        progressIndicator(pulse: (sin(context.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2)
                    }
                }
            }
            .frame(height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Generation status")
            .accessibilityValue(job.stage.productTitle)
            .accessibilityHint(reduceMotion ? "Progress animation is paused because Reduce Motion is enabled." : "Visual progress indicator.")
            VStack(alignment: .leading, spacing: 8) {
                Text(job.stage.productTitle).font(.title.weight(.bold))
                TimelineView(.periodic(from: job.createdAt, by: 1)) { context in
                    Text("Elapsed: \(Int(context.date.timeIntervalSince(job.createdAt))) seconds").font(.caption).foregroundStyle(.secondary)
                }
                Text(CreationContext.parse(job.instruction).message).font(.subheadline).foregroundStyle(Color.pulseLime).lineLimit(2)
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
            if let statusNotice {
                Label(statusNotice, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseCoral)
            }
            Button(role: .destructive, action: requestCancellation) {
                HStack {
                    if isCancelling { ProgressView().tint(Color.pulseCoral) }
                    Text(isCancelling ? "Cancelling generation…" : "Cancel generation")
                }
            }
            .buttonStyle(.bordered)
            .tint(Color.pulseCoral)
            .disabled(isCancelling)
            .accessibilityHint("Pulse will keep your private instruction and selected materials so you can try again later.")
            Text("You can leave this screen. The job continues on the Go generation service and is refreshed when Pulse becomes active again; it can also be recovered from Profile.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(24)
    }

    private func progressIndicator(pulse: Double) -> some View {
        ZStack {
            Circle().stroke(Color.pulseViolet.opacity(0.22), lineWidth: 18).frame(width: 150, height: 150).scaleEffect(0.94 + pulse * 0.08)
            Circle().fill(Color.pulseLime).frame(width: 21, height: 21).shadow(color: Color.pulseLime, radius: 18)
        }
        .frame(maxWidth: .infinity)
    }

    private func state(for stage: GenerationJob.Stage) -> (symbol: String, color: Color) {
        let order = visibleStages.firstIndex(of: stage) ?? 0
        let current = visibleStages.firstIndex(of: job.stage) ?? order
        if order < current { return ("checkmark.circle.fill", .pulseLime) }
        if stage == job.stage { return ("circle.dotted", .pulseViolet) }
        return ("circle", .secondary)
    }
}

private struct TerminalSurface: View {
    let work: InteractiveApp
    let job: GenerationJob
    let plan: GenerationPlan?
    let verification: VerificationReport?
    let isPublishing: Bool
    let publishingError: String?
    let publish: (String, String) -> Void
    let showPlan: () -> Void
    let restart: () -> Void
    let retryGeneration: () -> Void
    let isRetryingGeneration: Bool
    let interactionViewportHeight: CGFloat

    var body: some View {
        switch job.stage {
        case .succeeded, .fallbackReady:
            PreviewSurface(
                work: work, job: job, plan: plan, verification: verification, isPublishing: isPublishing,
                publishingError: publishingError, publish: publish, showPlan: showPlan, edit: restart,
                interactionViewportHeight: interactionViewportHeight
            )
        case .failed, .cancelled:
            FailureSurface(
                job: job,
                errorMessage: publishingError,
                showPlan: showPlan,
                restart: restart,
                retryGeneration: retryGeneration,
                isRetryingGeneration: isRetryingGeneration
            )
        default:
            EmptyView()
        }
    }
}

private struct FailureSurface: View {
    let job: GenerationJob
    let errorMessage: String?
    let showPlan: () -> Void
    let restart: () -> Void
    let retryGeneration: () -> Void
    let isRetryingGeneration: Bool

    private var presentation: GenerationFailurePresentation {
        GenerationFailurePresentation(stage: job.stage, errorCategory: job.errorCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 34)
            Image(systemName: presentation.symbolName)
                .font(.largeTitle).foregroundStyle(job.stage == .cancelled ? .secondary : Color.pulseCoral)
            Text(presentation.title)
                .font(.title.weight(.bold))
            Text(presentation.detail)
                .foregroundStyle(.secondary)
            if job.retryable && presentation != .materialsUnavailable {
                Text("This issue may be temporary. Starting again creates a new generation with your saved idea.")
                    .font(.footnote).foregroundStyle(Color.pulseViolet)
            }
            if job.stage == .cancelled || (job.retryable && presentation != .materialsUnavailable) {
                Button(action: retryGeneration) {
                    HStack {
                        if isRetryingGeneration { ProgressView().tint(.black) }
                        Label(isRetryingGeneration ? "Starting again…" : "Try again with the same idea", systemImage: "arrow.clockwise")
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.pulseViolet)
                .disabled(isRetryingGeneration)
                .accessibilityHint("Creates one new private generation from this version’s saved instruction and materials.")
            }
            Button(action: restart) {
                Label("Edit and try again", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
            if job.stage != .cancelled {
                Button(action: showPlan) { Label("Review project plan", systemImage: "doc.text") }
                    .buttonStyle(.bordered).tint(.white)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.pulseCoral)
            }
            Spacer()
        }
        .padding(24)
    }
}

private struct PreviewSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PulseRuntimeLifecycle.self) private var runtimeLifecycle
    let work: InteractiveApp
    let job: GenerationJob
    let plan: GenerationPlan?
    let verification: VerificationReport?
    let isPublishing: Bool
    let publishingError: String?
    let publish: (String, String) -> Void
    let showPlan: () -> Void
    let edit: () -> Void
    @Environment(\.creationSurfaceVisible) private var isSurfaceVisible
    @State private var areChecksExpanded = false
    @State private var publicationTitle = ""
    @State private var publicationSummary = ""
    let interactionViewportHeight: CGFloat
    @State private var touch = CGPoint(x: 0.5, y: 0.55)

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(job.verificationGrade == .verified ? "Your interactive app is ready" : (job.verificationGrade == .fallback ? "Your app was not created" : "Your game is saved · changes needed"))
                        .font(.title2.bold())
                        .padding(.horizontal, 20)
                    if let artifactID = job.artifactID, job.verificationGrade != .fallback {
                        ArtifactPlayerView(
                            url: model.artifactURL(for: artifactID),
                            isActive: PulseAccessibility.runtimeIsActive(
                                isVisible: isSurfaceVisible,
                                isApplicationActive: scenePhase == .active,
                                isSystemRuntimeAvailable: runtimeLifecycle.allowsRuntime
                            ),
                            title: work.title,
                            interactionSummary: work.theme,
                            accessibilityIdentifier: "generation.artifact.player",
                            telemetryScreen: "generation_preview"
                        )
                        .frame(width: viewport.size.width,
                               height: min(InteractiveSurfaceLayout.interactionHeight(in: interactionViewportHeight),
                                           max(320, viewport.size.height - 172)))
                        .clipped()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label(job.verificationGrade == .verified ? "Ready to share" : (job.verificationGrade == .fallback ? "Recovery screen only · not your requested app" : "Play privately, then fix the failed checks"),
                              systemImage: job.verificationGrade == .verified ? "checkmark.circle.fill" : "wand.and.stars")
                            .foregroundStyle(Color.pulseLime)
                        if let context = CreationContext.parse(job.instruction).context, !context.materials.isEmpty {
                            DisclosureGroup("Check materials in your preview") {
                                Text("These are your requested uses, not a visual verification result. Play each trigger, then ask for changes if a material is missing or gets in the way.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(context.materials) { material in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(material.name).font(.subheadline.bold())
                                        Text(LocalizedStringKey(material.role.title)).font(.caption)
                                        if !material.placement.isEmpty { Text(material.placement).font(.caption) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }
                            }.tint(.pulseLime)
                        }
                        DisclosureGroup("Title and description") {
                            TextField("Title", text: $publicationTitle)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("generation.title")
                            TextField("How to play", text: $publicationSummary, axis: .vertical)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("generation.summary")
                            Text("Selected media will be included in the published app and available to permitted Remixes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Automatic check details", isExpanded: $areChecksExpanded) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verification?.summary ?? "Check details are temporarily unavailable.")
                                if let verification {
                                    ForEach(verification.checks.filter(\.hardGate)) { check in
                                        Label(check.summary, systemImage: check.status == "passed" ? "checkmark.circle" : "exclamationmark.triangle")
                                    }
                                }
                                if plan != nil {
                                    Button("Review plan and acceptance cases", action: showPlan)
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        }
                        if !canPublish { publishingGateNotice }
                        if let publishingError {
                            Label(publishingError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Color.pulseCoral)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }.padding(.top, 12)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Button(action: edit) {
                            Label(job.verificationGrade == .fallback ? "Revise idea and start again" : "Keep editing", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered).tint(.pulseViolet)
                        .disabled(isPublishing || (work.status != .draft && work.status != .published))
                        .accessibilityIdentifier("generation.edit")
                        if canPublish {
                            Button { publish(publicationTitle, publicationSummary) } label: {
                                HStack {
                                    if isPublishing { ProgressView().tint(.black) }
                                    Text("Publish to Pulse").fontWeight(.bold)
                                }.frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                            .disabled(isPublishing || publicationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || publicationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || publicationTitle.count > 120 || publicationSummary.count > 120)
                            .accessibilityIdentifier("generation.publish")
                        }
                    }
                    if canPublish {
                        Text("Publishes immediately. Content may be removed after review.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("generation.publish-moderation-notice")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black)
            }
        }
        .onAppear {
            if publicationTitle.isEmpty { publicationTitle = work.title }
            if publicationSummary.isEmpty { publicationSummary = work.theme }
        }
    }

    private var publishingGateNotice: some View {
        Label(publishingGateMessage, systemImage: "clock.badge.checkmark")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.pulseViolet)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pulseViolet.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel(publishingGateMessage)
    }

    private var canPublish: Bool {
        guard job.verificationGrade == .verified,
              job.artifactID != nil,
              work.status == .draft
        else { return false }
        switch work.contentReviewStatus {
        case .pending, nil:
            return true
        case .approved:
            return work.ageRating == .fourPlus
        case .rejected:
            return false
        }
    }

    private var publishingGateMessage: String {
        if work.status == .published { return "This version is live. Keep editing to prepare a new version while this one stays available." }
        if job.verificationGrade != .verified {
            return "This preview is not eligible for public release. Only independently verified builds can be published."
        }
        if work.status == .hidden || work.contentReviewStatus == .rejected {
            return "This work was taken down after publication. Only a Pulse administrator can restore it after the issue is resolved."
        }
        switch work.contentReviewStatus {
        case .pending, nil:
            return "This verified build is ready to publish."
        case .rejected:
            return "This work was taken down after review. Resolve the issue before asking Pulse Support about restoration."
        case .approved:
            return "This work is classified as \(work.ageRating?.rawValue ?? "a different age band"), which is outside the public 4+ catalog."
        }
    }
}

private struct PlanSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let plan: GenerationPlan
    var body: some View {
        NavigationStack {
            List {
                Section("Objective") { Text(CreationContext.parse(plan.objective).message) }
                if let context = CreationContext.parse(plan.objective).context, !context.materials.isEmpty {
                    Section("Material direction") {
                        ForEach(context.materials) { material in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(material.name).font(.headline)
                                Text(LocalizedStringKey(material.role.title))
                                if !material.placement.isEmpty { Text(material.placement).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section("Screens") { ForEach(plan.screens) { screen in VStack(alignment: .leading) { Text(screen.id.capitalized).font(.headline); Text(screen.purpose).foregroundStyle(.secondary) } } }
                Section("Core interactions") { ForEach(plan.interactions) { interaction in VStack(alignment: .leading) { Text(interaction.trigger.capitalized).font(.headline); Text(interaction.effect).foregroundStyle(.secondary) } } }
                DisclosureGroup("Technical acceptance details") {
                    ForEach(plan.acceptanceCases) { item in VStack(alignment: .leading) { Text("\(item.priority) · \(item.action)").font(.headline); Text(item.assert).foregroundStyle(.secondary) } }
                    ForEach(plan.constraints, id: \.self) { Label($0, systemImage: "lock.shield") }
                }
            }.navigationTitle(plan.title).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
