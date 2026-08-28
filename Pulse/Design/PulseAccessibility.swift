import Foundation

enum PulseRuntimeMotionState: Equatable {
    case active
    case pausedForInactiveSurface
    case pausedForReducedMotion
}

enum PulseAccessibility {
    static func runtimeIsActive(
        isVisible: Bool,
        isApplicationActive: Bool,
        isObscured: Bool = false,
        isSystemRuntimeAvailable: Bool = true
    ) -> Bool {
        isVisible && isApplicationActive && !isObscured && isSystemRuntimeAvailable
    }

    static func runtimeMotionState(isActive: Bool, reduceMotion: Bool) -> PulseRuntimeMotionState {
        if reduceMotion { return .pausedForReducedMotion }
        return isActive ? .active : .pausedForInactiveSurface
    }

    static func runtimeScript(for state: PulseRuntimeMotionState) -> String {
        switch state {
        case .active:
            """
            window.__pulseReduceMotion = false;
            document.getElementById('pulse-reduced-motion-style')?.remove();
            window.dispatchEvent(new CustomEvent('pulse:motion-preference', {detail: {reduceMotion: false}}));
            window.dispatchEvent(new Event('pulse:resume'));
            """
        case .pausedForInactiveSurface:
            """
            window.dispatchEvent(new CustomEvent('pulse:motion-preference', {detail: {reduceMotion: false}}));
            window.dispatchEvent(new Event('pulse:pause'));
            document.querySelectorAll('video,audio').forEach((element) => element.pause?.());
            """
        case .pausedForReducedMotion:
            """
            window.__pulseReduceMotion = true;
            if (!document.getElementById('pulse-reduced-motion-style')) {
              const style = document.createElement('style');
              style.id = 'pulse-reduced-motion-style';
              style.textContent = '*,*::before,*::after{animation-duration:0.001ms!important;animation-iteration-count:1!important;scroll-behavior:auto!important;transition-duration:0.001ms!important;}';
              document.head.appendChild(style);
            }
            window.dispatchEvent(new CustomEvent('pulse:motion-preference', {detail: {reduceMotion: true}}));
            window.dispatchEvent(new Event('pulse:pause'));
            document.querySelectorAll('video,audio').forEach((element) => element.pause?.());
            """
        }
    }

    static func interactiveSummary(title: String, theme: String) -> String {
        let normalizedTheme = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTheme.isEmpty ? "Interactive app \(title)." : "Interactive app \(title). \(normalizedTheme)"
    }
}
