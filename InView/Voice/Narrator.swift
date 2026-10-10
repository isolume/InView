import AccessCore
import Foundation
import simd

/// Decides what to say as a route evolves: where we're heading, upcoming turns, reroutes and arrival.
/// It only produces phrases; VoiceGuide speaks them.
@MainActor
final class Narrator {
    /// Why the route changed, which decides how the change is announced.
    enum Reason {
        case started
        case obstacle
        case update
    }

    struct Line {
        let text: String
        let isUrgent: Bool
    }

    /// Announce a turn once it is this close.
    private static let announceTurnWithin: Float = 4
    /// A turn within this distance of one already announced is the same turn.
    private static let sameTurnDistance: Float = 1.5

    private var destination: AccessPoint?
    private var announcedTurns: [SIMD2<Float>] = []

    func reset() {
        destination = nil
        announcedTurns = []
    }

    /// Lines to speak for a freshly computed route.
    func lines(for route: Route, reason: Reason) -> [Line] {
        var lines: [Line] = []
        let changedDestination = destination?.id != route.destination.id
        destination = route.destination

        switch reason {
        case .obstacle:
            announcedTurns = []
            lines.append(Line(text: "Something's in the way. Finding a way around.", isUrgent: true))
        case .started:
            announcedTurns = []
            lines.append(Line(text: "Heading to \(heading(for: route))", isUrgent: true))
        case .update:
            if changedDestination {
                announcedTurns = []
                lines.append(Line(text: "Rerouting to \(heading(for: route))", isUrgent: true))
            }
        }

        if changedDestination, route.destination.requiresAssistance {
            lines.append(Line(text: "\(route.destination.name) needs a staff member to operate it.", isUrgent: false))
        }

        if let maneuver = route.nextManeuver,
           maneuver.distance <= Self.announceTurnWithin,
           !announcedTurns.contains(where: { simd_distance($0, maneuver.position) < Self.sameTurnDistance }) {
            announcedTurns.append(maneuver.position)
            let meters = max(1, Int(maneuver.distance.rounded()))
            let phrase = maneuver.distance < 1.5
                ? "\(maneuver.turn.phrase.capitalizedFirst) now."
                : "In \(meters) \(meters == 1 ? "meter" : "meters"), \(maneuver.turn.phrase)."
            lines.append(Line(text: phrase, isUrgent: false))
        }
        return lines
    }

    func arrival(at point: AccessPoint) -> Line {
        var text = "You've arrived at \(point.name)."
        if point.requiresAssistance {
            text += " It needs a staff member to operate it."
        }
        return Line(text: text, isUrgent: true)
    }

    /// "the lobby elevator, 14 meters." plus what's worth knowing about getting there.
    private func heading(for route: Route) -> String {
        let point = route.destination
        let meters = max(1, Int(route.length.rounded()))
        var text = "\(point.name), \(meters) meters."
        if let slope = point.slopeDegrees {
            text += point.isTooSteep
                ? String(format: " Heads up, this ramp is steep, %.1f degrees.", slope)
                : String(format: " It's a gentle %.1f degree slope.", slope)
        }
        if route.isNarrow {
            text += " Some passages are tight."
        }
        return text
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
