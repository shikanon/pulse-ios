import Foundation
import CoreFoundation
import Observation

struct PulseGrowthIdentity: Codable, Sendable {
    let platform: String
    let deviceId: String
    let consent: Bool
}
enum PulseGrowthPreferences {
    static let consentKey = "pulse.growth.consent.v1"
    static let deviceKey = "pulse.growth.device.v1"
    static var identity: PulseGrowthIdentity {
        let consent = UserDefaults.standard.bool(forKey: consentKey)
        guard consent else { return .init(platform: "ios", deviceId: "", consent: false) }
        let id = UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return .init(platform: "ios", deviceId: id, consent: true)
    }
}
struct PulsePlaySession: Codable, Sendable {
    let id: String
    let workId: String
    let artifactId: String
    let seed: UInt32
    var score: Int?
    var qualified: Bool
    var completed: Bool
    var challengeId: String?
}
struct PulseChallenge: Codable, Sendable, Identifiable {
    let id: String
    let workId: String
    let artifactId: String
    let seed: UInt32
    let score: Int
    let url: URL
    let expiresAt: Date
}
struct PulsePlayMessage: Equatable, Sendable {
    let name: String
    let score: Int?
    init?(body: Any) {
        guard let value = body as? [String: Any], value["type"] as? String == "pulse:play-v1",
              let name = value["name"] as? String,
              ["protocol", "interaction", "qualified", "complete"].contains(name) else { return nil }
        if name == "complete" {
            guard let number = value["score"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (0...1_000_000_000).contains(number.doubleValue) else { return nil }
            score = number.intValue
        } else { score = nil }
        self.name = name
    }
}

@MainActor @Observable
final class PulsePlayController {
    private(set) var session: PulsePlaySession?
    private(set) var challenge: PulseChallenge?
    private(set) var loading = true
    private(set) var error: String?
    private var generation = UUID()
    private var queue: Task<Void, Never>?

    func start(api: PulseAPIClient, work: InteractiveApp, challengeID: String?) async {
        let token = UUID(); generation = token; queue?.cancel()
        loading = true; session = nil; challenge = nil; error = nil
        defer { if generation == token { loading = false } }
        do {
            let result = try await api.startPlay(workID: work.id, challengeID: challengeID)
            guard generation == token, !Task.isCancelled else { return }
            session = result
        } catch {
            if generation == token { self.error = "Play tracking is unavailable. Try again to record a result." }
        }
    }
    func receive(_ message: PulsePlayMessage, api: PulseAPIClient) {
        guard let current = session else { return }
        let previous = queue; let token = generation
        queue = Task {
            await previous?.value
            guard !Task.isCancelled, generation == token else { return }
            do {
                let result = try await api.recordPlay(id: current.id, message: message)
                guard generation == token else { return }
                session = result; error = nil
                if result.completed, challenge == nil {
                    challenge = try await api.createChallenge(playID: current.id)
                }
            } catch { if generation == token { self.error = "Couldn’t save this result. Try sharing again." } }
        }
    }
    func retryChallenge(api: PulseAPIClient) async {
        guard let session, session.completed else { return }
        do { challenge = try await api.createChallenge(playID: session.id); error = nil }
        catch { self.error = "Couldn’t prepare the challenge link. Please try again." }
    }
}
