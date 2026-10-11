import AccessCore
import SwiftUI

/// One set of directions across the measured areas of a displayed floor. A connector is
/// its own instruction, and only the final destination receives an arrival instruction.
struct ElevatedFloorRouteSummary: View {
    let route: ElevatedFloorRoute
    let destinationName: String

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let instruction: String
        let detail: String?
    }

    private var steps: [Step] {
        var result: [Step] = []
        func append(_ instruction: String, symbol: String, meters: Float? = nil, detail: String? = nil) {
            result.append(Step(id: result.count, symbol: symbol, instruction: instruction,
                detail: detail ?? meters.map { "\(max(1, Int($0.rounded()))) m" }))
        }
        for (index, segment) in route.segments.enumerated() {
            switch segment {
            case .surface(let surface):
                guard surface.route.length > 0.05 else { continue }
                let turns = surface.route.maneuvers
                let target: String
                if index + 1 < route.segments.count, case .transition(let next) = route.segments[index + 1] {
                    switch next.kind {
                    case .elevator: target = "the elevator"
                    case .stairs: target = "the steps"
                    case .ramp: target = "the sloped corridor"
                    }
                } else {
                    target = destinationName
                }
                let opening = result.isEmpty ? "Head toward" : "Continue toward"
                let firstDistance = turns.first?.distance ?? surface.route.length
                if firstDistance > 0.05 {
                    append("\(opening) \(target)", symbol: "arrow.up", meters: firstDistance)
                }
                for (turnIndex, turn) in turns.enumerated() {
                    let nextDistance = turnIndex + 1 < turns.count ? turns[turnIndex + 1].distance : surface.route.length
                    let phrase = turn.turn.phrase
                    append(phrase.prefix(1).uppercased() + phrase.dropFirst(), symbol: turn.turn.symbolName,
                           meters: nextDistance - turn.distance)
                }
            case .transition(let transition):
                switch transition.kind {
                case .elevator:
                    append("Take the elevator", symbol: AccessPoint.Kind.elevator.symbolName)
                case .stairs:
                    append("Take the steps", symbol: "figure.stairs")
                case .ramp:
                    append("Follow the sloped corridor", symbol: "arrow.up.right", meters: transition.rampLength)
                }
            }
        }
        append("Arrive at \(destinationName)", symbol: "mappin.circle.fill")
        return result
    }

    var body: some View {
        let steps = steps
        VStack(alignment: .leading, spacing: 12) {
            Label(summary, systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.headline).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(step.id + 1)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color(.tertiarySystemFill), in: Circle())
                        Image(systemName: step.symbol)
                            .font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.instruction).font(.body.weight(.medium))
                            if let detail = step.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if step.id != steps.last?.id { Divider().padding(.leading, 72) }
                }
            }
        }
    }

    private var summary: String {
        let minutes = max(1, Int((route.estimatedSeconds / 60).rounded(.up)))
        return "≈\(minutes) min · \(Int(route.walkingLength.rounded())) m · \(route.preference.title)"
    }
}
