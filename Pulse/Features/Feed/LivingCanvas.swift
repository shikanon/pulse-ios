import SwiftUI

struct LivingCanvas: View {
    let app: InteractiveApp
    @Binding var touchPoint: CGPoint
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || !isActive {
                canvas(at: 0)
            } else {
                TimelineView(.animation) { timeline in
                    canvas(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .background(.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PulseAccessibility.interactiveSummary(title: app.title, theme: app.theme))
        .accessibilityValue(reduceMotion || !isActive ? "Motion paused" : "Motion active")
        .accessibilityHint(reduceMotion || !isActive ? "Motion is paused. Swipe up or down to move the visual focus without animation." : "Drag across the artwork to move the visual focus. Swipe up or down with VoiceOver to move it without dragging.")
        .accessibilityAdjustableAction { direction in
            var next = touchPoint
            switch direction {
            case .increment: next.x = min(1, next.x + 0.1)
            case .decrement: next.x = max(0, next.x - 0.1)
            @unknown default: return
            }
            touchPoint = next
        }
    }

    private func canvas(at time: TimeInterval) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            for i in 0..<22 {
                let wave = sin(time * 1.3 + Double(i)) * 20
                let y = size.height * (0.22 + CGFloat(i) * 0.034) + wave
                var path = Path()
                path.move(to: CGPoint(x: -20, y: y))
                path.addCurve(to: CGPoint(x: size.width + 20, y: y + sin(time + Double(i)) * 70), control1: CGPoint(x: size.width * 0.3, y: y - 55), control2: CGPoint(x: size.width * 0.7, y: y + 55))
                context.stroke(path, with: .color(app.accent.opacity(0.17)), lineWidth: 1)
            }
            for i in 0..<18 {
                let p = bubblePosition(index: i, size: size, time: time)
                let radius = CGFloat(12 + (i % 5) * 10)
                context.addFilter(.blur(radius: 5))
                context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .radialGradient(Gradient(colors: [app.accent.opacity(0.8), .clear]), center: p, startRadius: 1, endRadius: radius))
                context.addFilter(.blur(radius: 0))
            }
            let focus = CGPoint(x: touchPoint.x * size.width, y: touchPoint.y * size.height)
            for ring in stride(from: 110.0, through: 22.0, by: -22.0) {
                let radius = CGFloat(ring + sin(time * 3) * 6)
                context.stroke(Path(ellipseIn: CGRect(x: focus.x - radius, y: focus.y - radius, width: radius * 2, height: radius * 2)), with: .color(app.accent.opacity(0.35)), lineWidth: 1.4)
            }
            context.fill(Path(ellipseIn: CGRect(x: focus.x - 15, y: focus.y - 15, width: 30, height: 30)), with: .color(app.accent))
        }
    }

    private func bubblePosition(index: Int, size: CGSize, time: TimeInterval) -> CGPoint {
        let n = Double(index)
        return CGPoint(x: size.width * CGFloat(0.08 + (sin(n * 9.3 + time * 0.13) + 1) * 0.42), y: size.height * CGFloat(0.18 + (cos(n * 4.7 + time * 0.19) + 1) * 0.31))
    }
}
