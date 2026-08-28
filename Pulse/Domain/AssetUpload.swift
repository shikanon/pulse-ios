import Foundation
import Security

enum AssetUploadPhase: Equatable, Sendable {
    case preparing
    case uploading(progress: Double)
    case verifying
    case completed
    case cancelled
    case failed
}

struct AssetUploadProgress: Equatable, Sendable {
    let assetID: UUID?
    let phase: AssetUploadPhase
}

/// Identifies the signed-in composer that owns a recoverable private upload.
/// The context is kept in the protected application container only; it never
/// contains a token, object key, or object-storage upload grant.
struct AssetUploadRecoveryContext: Codable, Equatable, Sendable {
    let ownerID: String
    let parentWorkID: UUID?
}

/// Persistent bookkeeping for an OSS transfer that iOS owns through a
/// background URLSession. The media stays in a file protected by the app
/// container so the system, rather than an in-memory Swift task, can continue
/// the upload after Pulse is suspended or relaunched.
struct BackgroundAssetUploadRecord: Codable, Equatable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case uploading
        case transferred
        case failed
    }

    let assetID: UUID
    let context: AssetUploadRecoveryContext
    let fileName: String
    let mediaType: String
    let localFileName: String
    var taskIdentifier: Int
    var state: State
    let createdAt: Date

    var id: UUID { assetID }
}

/// Stores only the local file reference and recovery context. Signed URLs,
/// request headers, Bearer tokens, and object keys deliberately remain in the
/// URL loading system or on the server; none are serialized here.
enum BackgroundAssetUploadStore {
    private static let directoryName = "PulsePrivateAssetUploads"
    private static let metadataFileName = "uploads.json"
    private static let lock = NSLock()

    static func records(for context: AssetUploadRecoveryContext) -> [BackgroundAssetUploadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsUnsafe().filter { $0.context == context }.sorted { $0.createdAt < $1.createdAt }
    }

    static func records(ownerID: String) -> [BackgroundAssetUploadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsUnsafe().filter { $0.context.ownerID == ownerID }.sorted { $0.createdAt < $1.createdAt }
    }

    static func record(assetID: UUID) -> BackgroundAssetUploadRecord? {
        lock.lock()
        defer { lock.unlock() }
        return recordsUnsafe().first { $0.assetID == assetID }
    }

    static func records(forTaskIdentifier taskIdentifier: Int) -> [BackgroundAssetUploadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsUnsafe().filter { $0.taskIdentifier == taskIdentifier }
    }

    static func create(
        data: Data,
        assetID: UUID,
        context: AssetUploadRecoveryContext,
        fileName: String,
        mediaType: String,
        taskIdentifier: Int
    ) throws -> BackgroundAssetUploadRecord {
        lock.lock()
        defer { lock.unlock() }
        let directory = try storageDirectoryUnsafe()
        let localFileName = "\(UUID().uuidString.lowercased()).material"
        let localURL = directory.appending(path: localFileName)
        try data.write(to: localURL, options: .atomic)
        try protect(localURL)
        let record = BackgroundAssetUploadRecord(
            assetID: assetID,
            context: context,
            fileName: fileName,
            mediaType: mediaType,
            localFileName: localFileName,
            taskIdentifier: taskIdentifier,
            state: .uploading,
            createdAt: Date()
        )
        do {
            var values = recordsUnsafe()
            values.removeAll { $0.assetID == assetID }
            values.append(record)
            try writeRecordsUnsafe(values)
            return record
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    static func markTransferred(assetID: UUID) {
        update(assetID: assetID, state: .transferred, removeLocalFile: true)
    }

    static func markFailed(assetID: UUID) {
        update(assetID: assetID, state: .failed, removeLocalFile: false)
    }

    static func setTaskIdentifier(_ taskIdentifier: Int, for assetID: UUID) throws -> BackgroundAssetUploadRecord {
        lock.lock()
        defer { lock.unlock() }
        var values = recordsUnsafe()
        guard let index = values.firstIndex(where: { $0.assetID == assetID }) else {
            throw PulseAPIError(message: "Secure upload recovery storage is unavailable.")
        }
        values[index].taskIdentifier = taskIdentifier
        try writeRecordsUnsafe(values)
        return values[index]
    }

    static func readPrivateData(for record: BackgroundAssetUploadRecord) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let url = try localFileURLUnsafe(for: record)
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func localFileURL(for record: BackgroundAssetUploadRecord) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try localFileURLUnsafe(for: record)
    }

    static func discard(assetID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var values = recordsUnsafe()
        guard let record = values.first(where: { $0.assetID == assetID }) else { return }
        values.removeAll { $0.assetID == assetID }
        try? FileManager.default.removeItem(at: try storageDirectoryUnsafe().appending(path: record.localFileName))
        try? writeRecordsUnsafe(values)
    }

    static func discardAll() {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = try? storageDirectoryUnsafe() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func update(assetID: UUID, state: BackgroundAssetUploadRecord.State, removeLocalFile: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var values = recordsUnsafe()
        guard let index = values.firstIndex(where: { $0.assetID == assetID }) else { return }
        values[index].state = state
        if removeLocalFile {
            try? FileManager.default.removeItem(at: try storageDirectoryUnsafe().appending(path: values[index].localFileName))
        }
        try? writeRecordsUnsafe(values)
    }

    private static func storageDirectoryUnsafe() throws -> URL {
        let fileManager = FileManager.default
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: directoryName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try protect(directory)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        return directory
    }

    private static func localFileURLUnsafe(for record: BackgroundAssetUploadRecord) throws -> URL {
        try storageDirectoryUnsafe().appending(path: record.localFileName)
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func recordsUnsafe() -> [BackgroundAssetUploadRecord] {
        guard let directory = try? storageDirectoryUnsafe() else { return [] }
        let metadataURL = directory.appending(path: metadataFileName)
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        return (try? JSONDecoder().decode([BackgroundAssetUploadRecord].self, from: data)) ?? []
    }

    private static func writeRecordsUnsafe(_ values: [BackgroundAssetUploadRecord]) throws {
        let metadataURL = try storageDirectoryUnsafe().appending(path: metadataFileName)
        try JSONEncoder().encode(values).write(to: metadataURL, options: .atomic)
        try protect(metadataURL)
    }
}

enum PrivateAssetUploadPolicy {
    static let maximumBytes = 20_000_000

    private static let supportedMediaTypes: Set<String> = [
        "image/gif", "image/heic", "image/heif", "image/jpeg", "image/png", "image/webp",
        "audio/aac", "audio/mp4", "audio/mpeg", "audio/ogg", "audio/wav", "audio/x-wav",
        "video/mp4", "video/quicktime", "video/webm"
    ]

    static func validationMessage(fileName: String, mediaType: String, sizeBytes: Int) -> String? {
        let normalizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = mediaType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty || normalizedName.utf8.count > 128 || normalizedName.contains("/") || normalizedName.contains("\\") || normalizedName.contains("\u{0000}") || normalizedName.contains("\r") || normalizedName.contains("\n") || normalizedName == "." || normalizedName == ".." {
            return "This file name can’t be uploaded. Choose the item again or rename the file."
        }
        if sizeBytes <= 0 || sizeBytes > maximumBytes {
            return "This material is larger than Pulse’s 20 MB upload limit."
        }
        if !supportedMediaTypes.contains(normalizedType) {
            return "Pulse supports JPEG, PNG, HEIC, WebP, GIF, common audio files, MP4, MOV, and WebM."
        }
        return nil
    }
}

// Keep an already-transferred private object only when the server explicitly
// says its content-safety dependency was temporarily unavailable. All other
// failed uploads retain the existing cancel/re-upload behavior, so a rejected
// or incomplete object is never accidentally reused as if it were ready.
enum AssetUploadRetryPolicy {
    static func preservesUploadedObject(for error: Error) -> Bool {
        guard let apiError = error as? PulseAPIError else { return false }
        return apiError.serverCode == "content_safety_unavailable"
    }
}

/// A server-side upload that already transferred successfully but could not
/// finish its content-safety check. The device keeps only enough information
/// to ask Pulse to retry that final check after a relaunch; it never retains
/// private bytes, an upload grant, an object key, or a session token.
struct PendingAssetSafetyRetry: Codable, Equatable, Sendable, Identifiable {
    let assetID: UUID
    let fileName: String
    let createdAt: Date

    var id: UUID { assetID }
}

/// Keeps a content-safety completion retry scoped to one signed-in creator and
/// one original/Remix composer. It deliberately lives separately from a
/// ComposerDraft so an otherwise empty composer can still recover the retry.
enum PendingAssetSafetyRetryStore {
    private static let service = "chat.lovetalk.pulse.asset-safety-retry"

    static func storageAccount(ownerID: String, parentWorkID: UUID?) -> String {
        ComposerDraft.storageAccount(ownerID: ownerID, parentWorkID: parentWorkID)
    }

    static func load(ownerID: String, parentWorkID: UUID?) -> PendingAssetSafetyRetry? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storageAccount(ownerID: ownerID, parentWorkID: parentWorkID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let retry = try? JSONDecoder().decode(PendingAssetSafetyRetry.self, from: data)
        else { return nil }
        return retry
    }

    static func save(_ retry: PendingAssetSafetyRetry, ownerID: String, parentWorkID: UUID?) throws {
        let data = try JSONEncoder().encode(retry)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storageAccount(ownerID: ownerID, parentWorkID: parentWorkID),
        ]
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PulseAPIError(message: "Secure upload recovery storage is unavailable.")
        }
        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else {
            throw PulseAPIError(message: "Secure upload recovery storage is unavailable.")
        }
    }

    static func clear(ownerID: String, parentWorkID: UUID?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storageAccount(ownerID: ownerID, parentWorkID: parentWorkID),
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class AssetUploadProgressObserver: NSObject, URLSessionTaskDelegate {
    private let report: @MainActor @Sendable (Double) -> Void

    init(report: @escaping @MainActor @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        Task { @MainActor in report(progress) }
    }
}

/// Owns the single process-wide background URLSession used for private
/// object-storage PUTs. URLSession retains the request (including the short
/// lived signed grant) across process termination; the app persists only a
/// protected source file and opaque server asset ID so it can finish Pulse's
/// authenticated content-safety check after launch.
final class BackgroundAssetUploadCoordinator: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.shikanon.pulse.private-asset-upload"
    static let shared = BackgroundAssetUploadCoordinator()

    private struct TransferObserver {
        let progress: @MainActor @Sendable (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var observers: [Int: TransferObserver] = [:]
    private var eventCompletionHandlers: [() -> Void] = []
    private var session: URLSession!

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func upload(
        data: Data,
        assetID: UUID,
        context: AssetUploadRecoveryContext,
        fileName: String,
        mediaType: String,
        request: URLRequest,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        // Persist the protected source file before the task starts. A process
        // kill can then leave at most an inert record, never an untracked
        // network transfer. The task identifier is written before `resume`.
        let stagedRecord = try BackgroundAssetUploadStore.create(
            data: data,
            assetID: assetID,
            context: context,
            fileName: fileName,
            mediaType: mediaType,
            taskIdentifier: 0
        )
        let task = session.uploadTask(with: request, fromFile: try protectedFileURL(for: stagedRecord))
        let record = try BackgroundAssetUploadStore.setTaskIdentifier(task.taskIdentifier, for: assetID)
        task.resume()
        try await awaitTransfer(task: task, record: record, progress: progress)
    }

    func resume(
        _ record: BackgroundAssetUploadRecord,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        switch record.state {
        case .transferred:
            return
        case .failed:
            throw PulseAPIError(message: "The background transfer stopped before Pulse received this material.")
        case .uploading:
            guard let task = await task(identifier: record.taskIdentifier) else {
                BackgroundAssetUploadStore.markFailed(assetID: record.assetID)
                throw PulseAPIError(message: "The background transfer stopped before Pulse received this material.")
            }
            try await awaitTransfer(task: task, record: record, progress: progress)
        }
    }

    func cancelAndDiscard(assetID: UUID) {
        Task {
            if let record = BackgroundAssetUploadStore.record(assetID: assetID),
               let task = await task(identifier: record.taskIdentifier) {
                task.cancel()
            }
            BackgroundAssetUploadStore.discard(assetID: assetID)
        }
    }

    func discard(assetID: UUID) {
        BackgroundAssetUploadStore.discard(assetID: assetID)
    }

    func cancelAndDiscardAll() {
        Task {
            let tasks = await allTasks()
            tasks.forEach { $0.cancel() }
            BackgroundAssetUploadStore.discardAll()
        }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        eventCompletionHandlers.append(completionHandler)
        lock.unlock()
        _ = session
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let value = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        lock.lock()
        let observer = observers[task.taskIdentifier]
        lock.unlock()
        if let observer {
            Task { @MainActor in observer.progress(value) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let assetID = BackgroundAssetUploadStore.records(forTaskIdentifier: task.taskIdentifier).first?.assetID
        let result: Result<Void, Error>
        if let error {
            if let assetID { BackgroundAssetUploadStore.markFailed(assetID: assetID) }
            result = .failure(error)
        } else if let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
            if let assetID { BackgroundAssetUploadStore.markTransferred(assetID: assetID) }
            result = .success(())
        } else {
            if let assetID { BackgroundAssetUploadStore.markFailed(assetID: assetID) }
            result = .failure(PulseAPIError(message: "The material could not be uploaded. Please try again."))
        }

        lock.lock()
        let observer = observers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let observer else { return }
        switch result {
        case .success:
            observer.continuation.resume()
        case .failure(let error):
            observer.continuation.resume(throwing: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handlers = eventCompletionHandlers
        eventCompletionHandlers.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            handlers.forEach { $0() }
        }
    }

    private func awaitTransfer(
        task: URLSessionTask,
        record: BackgroundAssetUploadRecord,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        if record.state == .transferred { return }
        guard task.state != .completed else {
            if BackgroundAssetUploadStore.record(assetID: record.assetID)?.state == .transferred { return }
            BackgroundAssetUploadStore.markFailed(assetID: record.assetID)
            throw PulseAPIError(message: "The background transfer stopped before Pulse received this material.")
        }
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if BackgroundAssetUploadStore.record(assetID: record.assetID)?.state == .transferred {
                lock.unlock()
                continuation.resume()
                return
            }
            observers[task.taskIdentifier] = TransferObserver(progress: progress, continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    private func task(identifier: Int) async -> URLSessionTask? {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.first { $0.taskIdentifier == identifier })
            }
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func protectedFileURL(for record: BackgroundAssetUploadRecord) throws -> URL {
        let url = try BackgroundAssetUploadStore.localFileURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PulseAPIError(message: "The protected upload file is no longer available on this device.")
        }
        return url
    }
}
