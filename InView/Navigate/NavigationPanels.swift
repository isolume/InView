import AccessCore
import SwiftUI
import UIKit

struct LocatingPanel: View {
    let startView: UIImage?
    let isSlow: Bool
    /// What would help right now, from the camera: "Move a little slower".
    var hint: String? = nil
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Finding where you are")
            } icon: {
                Image(systemName: "location.viewfinder").foregroundStyle(Theme.accent).symbolEffect(.pulse)
            }
            .font(.panelTitle)
            Text("Hold your \(UIDevice.current.model) up and slowly look around the room you scanned.").foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ProgressView()
                if let hint { Text(hint).font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent) }
            }
            if let startView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where your scan started").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Image(uiImage: startView).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 110).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .accessibilityLabel("Photo taken where the scan started")
                }
            }
            if isSlow {
                Text("Stand where the scan started, facing the way the photo does.").font(.footnote)
                Button("Try again", systemImage: "arrow.clockwise", action: onRetry).buttonStyle(.glass)
            }
        }
    }
}

/// The next turn in large type, like a turn-by-turn sign, with the last spoken line under it.
struct NextStepBanner: View {
    let route: Route
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 48)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(distance).font(.metric).contentTransition(.numericText())
                    Text(instruction).font(.title3.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            if let caption {
                Text(caption).font(.subheadline).opacity(0.85).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .glassEffect(.regular.tint(Theme.accent), in: .rect(cornerRadius: Theme.Radius.panel))
        .animation(.smooth, value: distance)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String { route.nextManeuver?.turn.symbolName ?? "arrow.up" }

    private var distance: String {
        let meters = route.nextManeuver?.distance ?? route.length
        return "\(max(1, Int(meters.rounded()))) m"
    }

    private var instruction: String {
        guard let turn = route.nextManeuver?.turn else { return "to \(route.destination.title)" }
        return turn.phrase.prefix(1).uppercased() + turn.phrase.dropFirst()
    }
}

extension Maneuver.Turn {
    var symbolName: String {
        switch self {
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .slightLeft: "arrow.up.left"
        case .slightRight: "arrow.up.right"
        }
    }
}

extension Route {
    /// Said whenever part of the way wasn't recorded as floor, since it may hide a step or a closed door.
    var unmappedWarning: String? {
        guard unmappedLength >= 1 else { return nil }
        return "About \(Int(unmappedLength.rounded())) m of this route crosses areas the scan didn’t map. Check the way is clear."
    }

    /// "≈2 min · 48 m · Step-free"
    var summary: String {
        let minutes = max(1, Int((estimatedSeconds / 60).rounded(.up)))
        return "≈\(minutes) min · \(Int(length.rounded())) m · \(preference.title)"
    }
}

/// Time to the destination in large type, when you'd arrive, the distance and the kind of route.
struct RouteSummaryCard: View {
    let route: Route

    private var minutes: Int { max(1, Int((route.estimatedSeconds / 60).rounded(.up))) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(minutes)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(minutes == 1 ? "min" : "min").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("\(Int(route.length.rounded())) m ·")
                    Text("Arrive \(Date.now.addingTimeInterval(route.estimatedSeconds), style: .time)")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(route.preference.title, systemImage: route.preference == .stepFree ? "figure.roll" : "hare.fill")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Theme.brandGradient, in: Capsule())
        }
        .padding(16)
        .background(LinearGradient(colors: [Theme.accent.opacity(0.14), Color.indigo.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .animation(.smooth, value: minutes)
        .accessibilityElement(children: .combine)
    }
}

/// Every turn on a route from start to arrival, like the step list in Maps.
struct RouteStepsList: View {
    let route: Route
    /// During live directions the first step is what to do now, so it stands out.
    var isLive = false

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let instruction: String
        /// Meters to the next step; nil on arrival.
        let meters: Float?
    }

    private var steps: [Step] {
        let turns = route.maneuvers
        var steps = [Step(id: 0, symbol: "location.north.fill", instruction: "Head toward \(route.destination.title)",
                          meters: turns.first?.distance ?? route.length)]
        for (index, turn) in turns.enumerated() {
            let next = index + 1 < turns.count ? turns[index + 1].distance : route.length
            let phrase = turn.turn.phrase
            steps.append(Step(id: index + 1, symbol: turn.turn.symbolName,
                              instruction: phrase.prefix(1).uppercased() + phrase.dropFirst(), meters: next - turn.distance))
        }
        steps.append(Step(id: steps.count, symbol: "mappin",
                          instruction: "Arrive at \(route.destination.title)", meters: nil))
        return steps
    }

    var body: some View {
        let steps = steps
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                let isFirst = step.id == steps.first?.id, isLast = step.id == steps.last?.id
                HStack(alignment: .top, spacing: 14) {
                    // A timeline: each step's icon, joined to the next by a line.
                    VStack(spacing: 0) {
                        Image(systemName: step.symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background((isFirst ? Theme.routeStart : isLast ? Theme.routeEnd : Theme.accent).gradient, in: Circle())
                        if !isLast {
                            Capsule().fill(Theme.accent.opacity(0.22)).frame(width: 3)
                                .frame(maxHeight: .infinity).padding(.vertical, 3)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.instruction).font(isLive && isFirst ? .title3.weight(.bold) : .body.weight(.medium))
                        if let meters = step.meters {
                            Text("\(max(1, Int(meters.rounded()))) m").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.top, 5).padding(.bottom, isLast ? 0 : 16)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: steps.count)
    }
}

/// The arrival message, with a bounce and a haptic when it appears.
struct ArrivedPanel: View {
    let destination: AccessPoint?
    let onDone: () -> Void
    @State private var bounce = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("You’ve arrived")
            } icon: {
                Image(systemName: Theme.symbol(for: .good))
                    .foregroundStyle(Theme.color(for: .good))
                    .symbolEffect(.bounce, value: bounce)
            }
            .font(.panelTitle)
            Text(destination?.title ?? "Destination").foregroundStyle(.secondary)
            if destination?.requiresAssistance == true {
                Label("Needs a staff member to operate", systemImage: Theme.Symbol.needsStaff)
                    .font(.subheadline).foregroundStyle(Theme.color(for: .warning))
            }
            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
        }
        .onAppear { bounce += 1 }
    }
}

struct RouteCard: View {
    let route: Route
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                KindBadge(point: route.destination, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.destination.title).font(.title3.bold())
                    Text(details).font(.subheadline).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("End", action: onEnd)
                    .buttonStyle(.glass)
                    .tint(.red)
                    .controlSize(.large)
            }
            Group {
                if route.destination.requiresAssistance {
                    Label("Needs a staff member to operate", systemImage: Theme.Symbol.needsStaff)
                }
                    if route.isNarrow {
                    Label("Some passages on this route are narrow", systemImage: Theme.Symbol.narrow)
                }
                if let warning = route.unmappedWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.color(for: .warning))
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let minutes = max(1, Int((route.estimatedSeconds / 60).rounded(.up)))
        var parts = ["≈\(minutes) min", "\(Int(route.length.rounded())) m", route.preference.title]
        if let slope = route.destination.slopeDegrees {
            parts.append(String(format: "%.1f° slope", slope))
        }
        return parts.joined(separator: " · ")
    }
}
