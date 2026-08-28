import AVFAudio
import Foundation
import Observation
import SwiftUI
import UIKit

/// Owns the process-wide conditions under which an interactive artifact may run.
///
/// Views still decide whether their own surface is visible or covered. This model
/// adds the OS-level reasons that must pause every active runtime, without making
/// an interrupted audio session resume playback on its own.
@MainActor
@Observable
final class PulseRuntimeLifecycle {
    private(set) var scenePhase: ScenePhase = .active
    private(set) var isAudioInterrupted = false
    private(set) var requiresForegroundRecoveryAfterMemoryWarning = false

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        observesSystemNotifications: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        guard observesSystemNotifications else { return }

        notificationTokens.append(notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let interruptionRawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(rawValue: interruptionRawValue)
            }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.noteMemoryWarning()
            }
        })
    }

    var allowsRuntime: Bool {
        scenePhase == .active && !isAudioInterrupted && !requiresForegroundRecoveryAfterMemoryWarning
    }

    func update(scenePhase nextScenePhase: ScenePhase) {
        let becomesActive = scenePhase != .active && nextScenePhase == .active
        scenePhase = nextScenePhase
        if becomesActive {
            requiresForegroundRecoveryAfterMemoryWarning = false
        }
    }

    func noteAudioInterruptionBegan() {
        isAudioInterrupted = true
    }

    func noteAudioInterruptionEnded() {
        isAudioInterrupted = false
    }

    func noteMemoryWarning() {
        // Keep the current bundle stopped until the app has completed a real
        // inactive/background-to-active lifecycle round trip. In particular, a
        // memory warning must never silently recreate an active Web runtime.
        requiresForegroundRecoveryAfterMemoryWarning = true
    }

    private func handleAudioInterruption(rawValue: UInt?) {
        guard let rawValue,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: rawValue)
        else { return }
        switch interruptionType {
        case .began:
            noteAudioInterruptionBegan()
        case .ended:
            noteAudioInterruptionEnded()
        @unknown default:
            break
        }
    }
}
