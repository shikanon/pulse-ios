import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CreateView: View {
    let parent: InteractiveApp?
    let recoveryWork: InteractiveApp?
    let onPublished: () -> Void

    init(parent: InteractiveApp? = nil, recoveryWork: InteractiveApp? = nil, onPublished: @escaping () -> Void) {
        self.parent = parent
        self.recoveryWork = recoveryWork
        self.onPublished = onPublished
    }

    private var isRemix: Bool { parent != nil || recoveryWork?.creationMode == .remix }

    var body: some View {
        NavigationStack {
            ComposerFlow(
                parent: parent,
                initialPrompt: recoveryWork?.prompt ?? (parent == nil ? "" : "Make it softer, slower, and add a violet midnight glow."),
                resumeWork: recoveryWork
            ) { _ in onPublished() }
                .navigationTitle(isRemix ? "Remix" : "Create")
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
    @AppStorage(CreationPreferences.allowRemixByDefaultKey) private var allowsRemixByDefault = CreationPreferences.defaultAllowRemix
    let parent: InteractiveApp?
    let resumeWork: InteractiveApp?
    let onPublished: (InteractiveApp) -> Void
    @State private var prompt: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var assets: [GenerationAsset] = []
    @State private var work: InteractiveApp?
    @State private var job: GenerationJob?
    @State private var plan: GenerationPlan?
    @State private var verification: VerificationReport?
    @State private var isSubmitting = false
    @State private var isImporting = false
    @State private var isPublishing = false
    @State private var isRequestingContentReview = false
    @State private var isCheckingContentReview = false
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

    init(parent: InteractiveApp?, initialPrompt: String, resumeWork: InteractiveApp? = nil, onPublished: @escaping (InteractiveApp) -> Void) {
        self.parent = parent
        self.resumeWork = resumeWork
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

    var body: some View {
        Group {
            if isRestoring {
                ProgressView("Restoring your generation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let job, let work {
                if job.stage.isTerminal {
                    TerminalSurface(
                        work: work, job: job, plan: plan, verification: verification, isPublishing: isPublishing,
                        isRequestingContentReview: isRequestingContentReview, isCheckingContentReview: isCheckingContentReview,
                        publishingError: errorMessage, publish: publish, requestContentReview: requestContentReview,
                        checkContentReview: checkContentReview, showPlan: { isPlanPresented = true }, restart: restart,
                        retryGeneration: retryGeneration, isRetryingGeneration: isRetryingGeneration
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
                InputSurface(
                    parent: parent, isRemix: draftParentWorkID != nil, prompt: $prompt, pickerItems: $pickerItems, assets: assets,
                    isImporting: isImporting, isSubmitting: isSubmitting, activeUpload: activeAssetUpload, errorMessage: errorMessage,
                    promptFocusRequest: promptFocusRequest,
                    canAddPrivateAssets: session.canPerformMemberActions,
                    browseLibrary: { requestAuthenticationForAssets { isResourceLibraryPresented = true } },
                    importBGM: { requestAuthenticationForAssets { isBGMImporterPresented = true } },
                    requestAuthentication: requestAuthenticationForCreation,
                    cancelUpload: cancelActiveUpload, retryUpload: retryLastAssetUpload,
                    removeAsset: { id in assets.removeAll { $0.id == id } }, submit: submit
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .onChange(of: pickerItems) { _, items in startPhotoImport(items) }
        .onChange(of: prompt) { _, _ in persistDraftIfNeeded() }
        .onChange(of: assets.map(\.id)) { _, _ in persistDraftIfNeeded() }
        .onChange(of: session.user?.id) { oldUserID, newUserID in
            // A creation prompt must not be displayed after a member signs out
            // or changes accounts. The anonymous intent is kept only through
            // the authentication sheet that originated in this composer.
            guard oldUserID != newUserID, pendingCreationIntent == nil else { return }
            prompt = ""
            assets = []
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
            await restoreGeneration(generationID, failureMessage: "This generation could not be restored. Your existing work is still available in Profile.")
            return
        }
        guard work == nil, job == nil,
              let draft = ComposerDraftStore.load(ownerID: draftOwnerID, parentWorkID: draftParentWorkID)
        else { return }
        activeDraft = draft
        prompt = draft.instruction
        await restoreDraftAssets(draft)
        guard let workID = draft.workID, let generationID = draft.generationID else { return }
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
        guard session.canPerformMemberActions else {
            pendingCreationIntent = PendingCreationIntent(parentWorkID: draftParentWorkID, instruction: instruction)
            requiresAuthentication = true
            return
        }
        isSubmitting = true
        errorMessage = nil
        let draft = persistDraft()
        Task {
            do {
                let result = try await model.beginGeneration(
                    instruction: instruction,
                    parent: parent,
                    parentWorkID: draftParentWorkID,
                    assets: assets,
                    allowRemix: allowsRemixByDefault,
                    workIdempotencyKey: draft.workIdempotencyKey,
                    generationIdempotencyKey: draft.generationIdempotencyKey
                )
                work = result.0
                job = result.1
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
                errorMessage = "Couldn’t upload \(activeAssetUpload?.fileName ?? "this material"). Please check the file and try again."
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
                clearDraft()
                onPublished(published)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPublishing = false
        }
    }

    private func requestContentReview() {
        guard let work, !isRequestingContentReview else { return }
        isRequestingContentReview = true
        errorMessage = nil
        Task {
            do {
                self.work = try await model.requestContentReview(work.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isRequestingContentReview = false
        }
    }

    private func checkContentReview() {
        guard let work, !isCheckingContentReview else { return }
        isCheckingContentReview = true
        errorMessage = nil
        Task {
            do {
                self.work = try await model.api.fetchWork(id: work.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isCheckingContentReview = false
        }
    }

    private func restart() {
        work = nil
        job = nil
        plan = nil
        verification = nil
        errorMessage = nil
        _ = persistDraft(resetOperation: true)
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
    @Binding var prompt: String
    @Binding var pickerItems: [PhotosPickerItem]
    let assets: [GenerationAsset]
    let isImporting: Bool
    let isSubmitting: Bool
    let activeUpload: ComposerAssetUpload?
    let errorMessage: String?
    let promptFocusRequest: Int
    let canAddPrivateAssets: Bool
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
            VStack(alignment: .leading, spacing: 22) {
                if let parent {
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

                VStack(alignment: .leading, spacing: 9) {
                    Text(isRemix ? "What should change?" : "Your idea").font(.headline)
                    ZStack(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(isRemix ? "For example: make the pace slower and the colors warmer" : "For example: make a tiny garden that reacts to each touch")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 17).padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $prompt)
                            .scrollContentBackground(.hidden).frame(minHeight: 145).padding(12)
                            .focused($isPromptFocused)
                            .accessibilityLabel(isRemix ? "Describe what should change in this Remix" : "Describe the interactive app you want to create")
                            .accessibilityHint("A single sentence is enough. Images, video, and BGM are optional.")
                            .accessibilityIdentifier("creation.prompt")
                    }
                    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Resource library").font(.headline)
                        Spacer()
                        Text("\(assets.count)/8 · Optional").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(action: browseLibrary) {
                        Label(canAddPrivateAssets ? "Browse public and private resources" : "Sign in to add resources", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent).tint(.pulseViolet)
                    .disabled(isImporting || isSubmitting)
                    .accessibilityIdentifier("creation.resource-library")
                    if canAddPrivateAssets {
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .any(of: [.images, .videos])) {
                            Label(isImporting ? "Preparing resources…" : "Upload private images or videos", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                        }
                        .buttonStyle(.bordered).tint(.white).disabled(isImporting || isSubmitting || assets.count >= 8)
                    } else {
                        Button(action: requestAuthentication) {
                            Label("Sign in to upload private images or videos", systemImage: "person.crop.circle.badge.plus")
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                        }
                        .buttonStyle(.bordered).tint(.white).disabled(isSubmitting)
                    }
                    Button(action: importBGM) {
                        Label(canAddPrivateAssets ? "Upload private BGM" : "Sign in to upload private BGM", systemImage: canAddPrivateAssets ? "music.note.list" : "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.bordered).tint(.white).disabled(isImporting || isSubmitting || assets.count >= 8)
                    if let activeUpload {
                        AssetUploadStatusView(upload: activeUpload, cancel: cancelUpload, retry: retryUpload)
                    }
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
                if !canAddPrivateAssets {
                    Text("Your idea stays on this screen until you sign in. It will not start generating automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: submit) {
                    HStack {
                        if isSubmitting { ProgressView().tint(.black) }
                        Text(canAddPrivateAssets ? (isRemix ? "Create Remix" : "Generate interactive app") : (isRemix ? "Sign in to create Remix" : "Sign in to generate"))
                            .fontWeight(.bold)
                    }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting || isImporting)
                .accessibilityIdentifier("creation.generate")
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 120)
        }
        .onChange(of: promptFocusRequest) { _, _ in
            isPromptFocused = true
        }
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
    let isRequestingContentReview: Bool
    let isCheckingContentReview: Bool
    let publishingError: String?
    let publish: () -> Void
    let requestContentReview: () -> Void
    let checkContentReview: () -> Void
    let showPlan: () -> Void
    let restart: () -> Void
    let retryGeneration: () -> Void
    let isRetryingGeneration: Bool

    var body: some View {
        switch job.stage {
        case .succeeded, .fallbackReady:
            PreviewSurface(
                work: work, job: job, plan: plan, verification: verification, isPublishing: isPublishing,
                isRequestingContentReview: isRequestingContentReview, isCheckingContentReview: isCheckingContentReview,
                publishingError: publishingError, publish: publish, requestContentReview: requestContentReview,
                checkContentReview: checkContentReview, showPlan: showPlan
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
            if job.retryable {
                Text("This issue may be temporary. Starting again creates a new generation with your saved idea.")
                    .font(.footnote).foregroundStyle(Color.pulseViolet)
            }
            if job.stage == .cancelled || job.retryable {
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
    let isRequestingContentReview: Bool
    let isCheckingContentReview: Bool
    let publishingError: String?
    let publish: () -> Void
    let requestContentReview: () -> Void
    let checkContentReview: () -> Void
    let showPlan: () -> Void
    @State private var touch = CGPoint(x: 0.5, y: 0.55)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(job.verificationGrade == .fallback ? "A preview version is ready" : "Your interactive app is ready")
                    .font(.title.weight(.bold))
                GeometryReader { proxy in
                    if let artifactID = job.artifactID {
                        ArtifactPlayerView(
                            url: model.artifactURL(for: artifactID),
                            isActive: PulseAccessibility.runtimeIsActive(
                                isVisible: true,
                                isApplicationActive: scenePhase == .active,
                                isSystemRuntimeAvailable: runtimeLifecycle.allowsRuntime
                            ),
                            title: work.title,
                            interactionSummary: work.theme,
                            accessibilityIdentifier: "generation.artifact.player",
                            telemetryScreen: "generation_preview"
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        LivingCanvas(
                            app: work,
                            touchPoint: $touch,
                            isActive: PulseAccessibility.runtimeIsActive(
                                isVisible: true,
                                isApplicationActive: scenePhase == .active,
                                isSystemRuntimeAvailable: runtimeLifecycle.allowsRuntime
                            )
                        )
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in touch = CGPoint(x: value.location.x / proxy.size.width, y: value.location.y / proxy.size.height) })
                            .accessibilityIdentifier("generation.preview.canvas")
                            .accessibilityValue("touch-x-\(Int(touch.x * 100))-y-\(Int(touch.y * 100))")
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                }.frame(height: 360)
                HStack {
                    Label(job.verificationGrade.rawValue.capitalized, systemImage: job.verificationGrade == .fallback ? "shield.lefthalf.filled" : "checkmark.seal.fill")
                        .foregroundStyle(job.verificationGrade == .fallback ? Color.pulseViolet : Color.pulseLime)
                    Spacer()
                    if let verification { Text("Score \(Int(verification.score.rounded()))").font(.caption).foregroundStyle(.secondary) }
                    else { Text("Verification summary unavailable").font(.caption).foregroundStyle(Color.pulseCoral) }
                }
                Text(verification?.summary ?? (job.verificationGrade == .fallback ? "The standard version did not pass every gate. This simplified version is available for review." : "This version is ready for review. The detailed verification summary could not be loaded."))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let verification {
                    ForEach(verification.checks.filter(\.hardGate)) { check in
                        Label(check.summary, systemImage: check.status == "passed" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(check.status == "passed" ? Color.pulseLime : Color.pulseCoral)
                    }
                }
                if plan != nil { Button(action: showPlan) { Label("Review plan and acceptance cases", systemImage: "doc.text") }.buttonStyle(.bordered) }
                if canPublish {
                    Button(action: publish) {
                        HStack { if isPublishing { ProgressView().tint(.black) }; Text("Publish to Pulse").fontWeight(.bold) }
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                    }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black).disabled(isPublishing)
                        .accessibilityIdentifier("generation.publish")
                } else if canRequestContentReview {
                    contentReviewSubmission
                } else {
                    publishingGateNotice
                }
                if let publishingError {
                    Label(publishingError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.pulseCoral)
                        .accessibilityLabel(publishingError)
                }
            }.padding(22).padding(.bottom, 110)
        }
    }

    @ViewBuilder
    private var contentReviewSubmission: some View {
        if work.contentReviewRequestedAt == nil {
            Button(action: requestContentReview) {
                HStack {
                    if isRequestingContentReview { ProgressView().tint(.black) }
                    Text(isRequestingContentReview ? "Submitting for review…" : "Submit for 4+ content review").fontWeight(.bold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent).tint(.pulseViolet).foregroundStyle(.white).disabled(isRequestingContentReview)
            .accessibilityIdentifier("generation.request-content-review")
            reviewQueueNotice("Your verified build remains private until a reviewer approves it for the 4+ catalog.")
        } else {
            reviewQueueNotice("Your content-review request is queued. Your build remains private while a reviewer decides whether it meets the 4+ catalog policy.")
            Button(action: checkContentReview) {
                HStack {
                    if isCheckingContentReview { ProgressView() }
                    Text(isCheckingContentReview ? "Checking review status…" : "Check review status")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .buttonStyle(.bordered).tint(.white).disabled(isCheckingContentReview)
            .accessibilityIdentifier("generation.check-content-review")
        }
    }

    private func reviewQueueNotice(_ message: String) -> some View {
        Label(message, systemImage: "clock.badge.checkmark")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.pulseViolet)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pulseViolet.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel(message)
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
        job.verificationGrade == .verified && work.contentReviewStatus == .approved && work.ageRating == .fourPlus
    }

    private var canRequestContentReview: Bool {
        job.verificationGrade == .verified && work.contentReviewStatus == .pending
    }

    private var publishingGateMessage: String {
        if job.verificationGrade != .verified {
            return "This preview is not eligible for public release. Only independently verified builds can be published."
        }
        switch work.contentReviewStatus {
        case .pending, nil:
            return "Content review is required before public release. A reviewer must approve this work for the 4+ catalog."
        case .rejected:
            return "This work was not approved for public release. Review the feedback with your support contact before creating another version."
        case .approved:
            return "This work is approved for \(work.ageRating?.rawValue ?? "a different age band"), which is outside the 4+ launch catalog."
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
