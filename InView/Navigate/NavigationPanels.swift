import AccessCore
import SwiftUI
import UIKit

struct LocatingPanel: View {
    let startView: UIImage?
    let isSlow: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Finding where you are")
            } icon: {
                Image(systemName: "location.viewfinder").foregroundStyle(Theme.accent).symbolEffect(.pulse)
            }
            .font(.panelTitle)
            Text("Go to where the scan started and slowly look around.").foregroundStyle(.secondary)
            ProgressView()
            if let startView {
                Image(uiImage: startView).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 150).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .accessibilityLabel("Photo of where the scan started")
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

    private var symbol: String {
        switch route.nextManeuver?.turn {
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .slightLeft: "arrow.up.left"
        case .slightRight: "arrow.up.right"
        case nil: "arrow.up"
        }
    }

    private var distance: String {
        let meters = route.nextManeuver?.distance ?? route.length
        return "\(max(1, Int(meters.rounded()))) m"
    }

    private var instruction: String {
        guard let turn = route.nextManeuver?.turn else { return "to \(route.destination.title)" }
        return turn.phrase.prefix(1).uppercased() + turn.phrase.dropFirst()
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
                KindBadge(kind: route.destination.kind, size: 44)
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
