@preconcurrency import MetricKit
import Foundation
import Observation

// Pulse telemetry is intentionally a small, reviewed health contract rather
// than a generic analytics SDK. It never accepts free text, user identifiers,
// work IDs, material metadata, tokens, or raw MetricKit payloads.
enum PulseTelemetryEventName: String, Codable, Sendable, CaseIterable {
    case appOpened = "app_opened"
    case launchGateDisplayed = "launch_gate_displayed"
    case deepLinkResolved = "deep_link_resolved"
    case deepLinkFailed = "deep_link_failed"
    case feedLoaded = "feed_loaded"
    case feedLoadFailed = "feed_load_failed"
    case workImpression = "work_impression"
    case shareInvoked = "share_invoked"
    case assetUploadStarted = "asset_upload_started"
    case assetUploadCompleted = "asset_upload_completed"
    case assetUploadCancelled = "asset_upload_cancelled"
    case assetUploadFailed = "asset_upload_failed"
    case generationSubmitted = "generation_submitted"
    case generationSubmissionFailed = "generation_submission_failed"
    case generationBackgrounded = "generation_backgrounded"
    case generationCancelled = "generation_cancelled"
    case generationRetried = "generation_retried"
    case artifactLoadFailed = "artifact_load_failed"
    case metricKitPerformanceObserved = "metric_kit_performance_observed"
    case metricKitDiagnosticObserved = "metric_kit_diagnostic_observed"
    case diagnosticsPreferenceEnabled = "diagnostics_preference_enabled"
}

struct PulseTelemetryEvent: Codable, Sendable, Equatable {
    let eventVersion: Int
    let name: PulseTelemetryEventName
    let occurredAt: Date
    let sessionID: String
    let platform: String
    let appVersion: String
    let build: String
    let attributes: [String: String]

    enum CodingKeys: String, CodingKey {
        case eventVersion, name, occurredAt, platform, appVersion, build, attributes
        case sessionID = "sessionId"
    }
}

enum PulseTelemetryPolicy {
    static let schemaVersion = 1
    static let maximumBatchSize = 20

    private static let allowedAttributes: [PulseTelemetryEventName: Set<String>] = [
        .appOpened: ["screen_id"],
        .launchGateDisplayed: ["screen_id", "outcome"],
        .deepLinkResolved: ["entry_point", "outcome"],
        .deepLinkFailed: ["entry_point", "error_category"],
        .feedLoaded: ["screen_id", "source"],
        .feedLoadFailed: ["screen_id", "error_category"],
        .workImpression: ["screen_id"],
        .shareInvoked: ["screen_id"],
        .assetUploadStarted: ["screen_id"],
        .assetUploadCompleted: ["screen_id"],
        .assetUploadCancelled: ["screen_id"],
        .assetUploadFailed: ["screen_id", "error_category"],
        .generationSubmitted: ["screen_id", "creation_mode"],
        .generationSubmissionFailed: ["screen_id", "creation_mode", "error_category"],
        .generationBackgrounded: ["screen_id", "creation_mode"],
        .generationCancelled: ["screen_id", "creation_mode"],
        .generationRetried: ["screen_id", "creation_mode"],
        .artifactLoadFailed: ["screen_id", "error_category"],
        .metricKitPerformanceObserved: ["metric_type", "metric_value_bucket"],
        .metricKitDiagnosticObserved: ["diagnostic_type", "diagnostic_count_bucket"],
        .diagnosticsPreferenceEnabled: ["screen_id"]
    ]

    private static let samplingRates: [PulseTelemetryEventName: Double] = [
        .feedLoaded: 0.25,
        .workImpression: 0.25
    ]

    static func makeEvent(
        name: PulseTelemetryEventName,
        sessionID: UUID,
        attributes: [String: String],
        occurredAt: Date = .now,
        appVersion: String = currentAppVersion,
        build: String = currentBuild
    ) -> PulseTelemetryEvent? {
        guard allowedAttributes[name] == Set(attributes.keys),
              attributes.values.allSatisfy(isControlledDimension),
              isVersion(appVersion),
              isBuild(build)
        else { return nil }
        return PulseTelemetryEvent(
            eventVersion: schemaVersion,
            name: name,
            occurredAt: occurredAt,
            sessionID: sessionID.uuidString.lowercased(),
            platform: "ios",
            appVersion: appVersion,
            build: build,
            attributes: attributes
        )
    }

    static func shouldSample(_ name: PulseTelemetryEventName, seed: String) -> Bool {
        let rate = samplingRates[name] ?? 1
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }
        let threshold = UInt64(Double(UInt64.max) * rate)
        return stableHash(seed) <= threshold
    }

    private static func isControlledDimension(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), let first = value.utf8.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57)
        else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        guard (1...32).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
    }

    private static func isBuild(_ value: String) -> Bool {
        guard (1...16).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static let currentAppVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    private static let currentBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
}

@MainActor
@Observable
final class PulseTelemetry {
    private static let preferenceKey = "pulse.diagnostics-sharing.enabled"
    private let preferences: UserDefaults
    private let api: PulseAPIClient
    private let sessionID = UUID()
    private var sequence = 0
    private var pendingEvents: [PulseTelemetryEvent] = []
    private var isSending = false
    private var hasStarted = false
    private var scheduledFlush: Task<Void, Never>?
    private var metricKitObserver: PulseMetricKitObserver?

    private(set) var isDiagnosticsSharingEnabled: Bool

    init(api: PulseAPIClient = PulseAPIClient(), preferences: UserDefaults = .standard) {
        self.api = api
        self.preferences = preferences
        self.isDiagnosticsSharingEnabled = preferences.bool(forKey: Self.preferenceKey)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let observer = PulseMetricKitObserver(telemetry: self)
        metricKitObserver = observer
        MXMetricManager.shared.add(observer)
        record(.appOpened, attributes: ["screen_id": "launch"])
    }

    func setDiagnosticsSharingEnabled(_ enabled: Bool) {
        guard enabled != isDiagnosticsSharingEnabled else { return }
        isDiagnosticsSharingEnabled = enabled
        preferences.set(enabled, forKey: Self.preferenceKey)
        guard enabled else {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            pendingEvents.removeAll()
            return
        }
        record(.diagnosticsPreferenceEnabled, attributes: ["screen_id": "settings"])
    }

    func record(_ name: PulseTelemetryEventName, attributes: [String: String]) {
        guard isDiagnosticsSharingEnabled else { return }
        sequence += 1
        guard PulseTelemetryPolicy.shouldSample(name, seed: "\(sessionID.uuidString.lowercased()):\(sequence)"),
              let event = PulseTelemetryPolicy.makeEvent(name: name, sessionID: sessionID, attributes: attributes)
        else { return }
        pendingEvents.append(event)
        if pendingEvents.count >= 4 {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            Task { await flush() }
        } else {
            scheduleFlush()
        }
    }

    func flush() async {
        guard isDiagnosticsSharingEnabled, !isSending, !pendingEvents.isEmpty else { return }
        scheduledFlush?.cancel()
        scheduledFlush = nil
        isSending = true
        let batch = Array(pendingEvents.prefix(PulseTelemetryPolicy.maximumBatchSize))
        pendingEvents.removeFirst(batch.count)
        defer { isSending = false }
        do {
            try await api.recordClientTelemetry(events: batch)
        } catch {
            // Diagnostics must never block user work. Retain only a small,
            // in-memory retry window and discard it immediately when consent
            // is withdrawn.
            pendingEvents = Array((batch + pendingEvents).prefix(PulseTelemetryPolicy.maximumBatchSize))
        }
    }

    fileprivate func recordMetricKitPerformance(metricType: String, valueBucket: String) {
        record(.metricKitPerformanceObserved, attributes: ["metric_type": metricType, "metric_value_bucket": valueBucket])
    }

    fileprivate func recordMetricKitDiagnostic(diagnosticType: String, count: Int) {
        record(.metricKitDiagnosticObserved, attributes: ["diagnostic_type": diagnosticType, "diagnostic_count_bucket": countBucket(count)])
    }

    private func countBucket(_ count: Int) -> String {
        switch count {
        case 0: "zero"
        case 1: "one"
        case 2...4: "two_to_four"
        default: "five_or_more"
        }
    }

    private func scheduleFlush() {
        guard scheduledFlush == nil else { return }
        scheduledFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}

// MetricKit carries detailed diagnostics owned by the operating system. Pulse
// deliberately extracts only a reviewed type/count or a coarse duration
// bucket; raw MetricKit JSON and diagnostic messages never leave the device.
private final class PulseMetricKitObserver: NSObject, MXMetricManagerSubscriber {
    weak var telemetry: PulseTelemetry?

    init(telemetry: PulseTelemetry) {
        self.telemetry = telemetry
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let observations = payloads.flatMap(Self.performanceObservations)
        Task { @MainActor [weak telemetry] in
            for observation in observations {
                telemetry?.recordMetricKitPerformance(metricType: observation.type, valueBucket: observation.bucket)
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let diagnostics = payloads.flatMap(Self.diagnosticObservations)
        Task { @MainActor [weak telemetry] in
            for diagnostic in diagnostics {
                telemetry?.recordMetricKitDiagnostic(diagnosticType: diagnostic.type, count: diagnostic.count)
            }
        }
    }

    private static func performanceObservations(for payload: MXMetricPayload) -> [(type: String, bucket: String)] {
        var observations: [(type: String, bucket: String)] = []
        if let histogram = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw,
           let seconds = averageSeconds(in: histogram) {
            observations.append(("launch_first_draw", durationBucket(seconds)))
        }
        if let histogram = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime,
           let seconds = averageSeconds(in: histogram) {
            observations.append(("application_hang", durationBucket(seconds)))
        }
        return observations
    }

    private static func diagnosticObservations(for payload: MXDiagnosticPayload) -> [(type: String, count: Int)] {
        [
            ("crash", payload.crashDiagnostics?.count ?? 0),
            ("hang", payload.hangDiagnostics?.count ?? 0),
            ("cpu_exception", payload.cpuExceptionDiagnostics?.count ?? 0),
            ("disk_write_exception", payload.diskWriteExceptionDiagnostics?.count ?? 0)
        ].filter { $0.count > 0 }
    }

    private static func averageSeconds(in histogram: MXHistogram<UnitDuration>) -> Double? {
        let buckets = histogram.bucketEnumerator.allObjects
        var weightedSeconds = 0.0
        var totalCount = 0.0
        for case let bucket as MXHistogramBucket<UnitDuration> in buckets where bucket.bucketCount > 0 {
            let start = bucket.bucketStart.converted(to: UnitDuration.seconds).value
            let end = bucket.bucketEnd.converted(to: UnitDuration.seconds).value
            let count = Double(bucket.bucketCount)
            weightedSeconds += ((start + end) / 2) * count
            totalCount += count
        }
        guard totalCount > 0 else { return nil }
        return weightedSeconds / totalCount
    }

    private static func durationBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: "under_1s"
        case ..<3: "one_to_three_s"
        case ..<10: "three_to_ten_s"
        default: "ten_s_or_more"
        }
    }
}
