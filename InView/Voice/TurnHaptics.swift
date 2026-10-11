import AccessCore
import CoreHaptics
import UIKit

/// Turns you can feel with the phone in a pocket: two taps for left, three for right, softer for a bend,
/// a rising buzz on arrival and a sharp double tap when something's in the way.
@MainActor
final class TurnHaptics {
    enum Cue {
        case turn(Maneuver.Turn)
        case arrival
        case warning
    }

    private let engine: CHHapticEngine?

    init() {
        engine = CHHapticEngine.capabilitiesForHardware().supportsHaptics ? try? CHHapticEngine() : nil
        engine?.isAutoShutdownEnabled = true
    }

    func play(_ cue: Cue) {
        guard let engine else { fallback(cue); return }
        do {
            let (events, curves) = Self.pattern(for: cue)
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: events, parameterCurves: curves))
                .start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback(cue)
        }
    }

    private static func pattern(for cue: Cue) -> ([CHHapticEvent], [CHHapticParameterCurve]) {
        func tap(at time: TimeInterval, intensity: Float, sharpness: Float = 0.8) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time)
        }
        switch cue {
        case .turn(let turn):
            let isLeft = turn == .left || turn == .slightLeft
            let isSharp = turn == .left || turn == .right
            return ((0..<(isLeft ? 2 : 3)).map { tap(at: Double($0) * 0.16, intensity: isSharp ? 1 : 0.55) }, [])
        case .arrival:
            let buzz = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ], relativeTime: 0, duration: 0.55)
            let rising = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.15),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.55, value: 1),
            ], relativeTime: 0)
            return ([buzz, tap(at: 0.62, intensity: 1, sharpness: 1)], [rising])
        case .warning:
            return ([tap(at: 0, intensity: 1, sharpness: 1), tap(at: 0.09, intensity: 1, sharpness: 1)], [])
        }
    }

    /// Devices without Core Haptics still get a distinct, if simpler, cue.
    private func fallback(_ cue: Cue) {
        switch cue {
        case .turn: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .arrival: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
