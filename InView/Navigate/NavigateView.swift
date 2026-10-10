import AccessCore
import SwiftUI

/// The rider flow: relocalize in the saved map, then follow arrows to the nearest elevator or ramp.
struct NavigateView: View {
    @StateObject private var controller = NavigationController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if controller.phase == .noMap {
                ContentUnavailableView {
                    Label("No map yet", systemImage: "map")
                } description: {
                    Text("A volunteer needs to scan this floor first.")
                } actions: {
                    Button("Close") { dismiss() }
                }
            } else {
                ViewContainer(view: controller.arView).ignoresSafeArea()
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        CloseButton {
                            controller.stop()
                            dismiss()
                        }
                        Spacer()
                    }
                    if let caption = controller.caption {
                        Text(caption)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(.white)
                            .transition(.opacity)
                            .id(caption)
                            .accessibilityHidden(true)
                    }
                    Spacer()
                    panel
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .padding()
                .animation(.easeInOut(duration: 0.25), value: controller.caption)
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private var panel: some View {
        switch controller.phase {
        case .noMap:
            EmptyView()
        case .locating:
            LocatingPanel(
                startView: controller.startView,
                isSlow: controller.isRelocalizationSlow,
                onStartHere: controller.startFromScanOrigin
            )
        case .ready:
            PrimaryButton(title: "Take me to the nearest accessible point", systemImage: "figure.roll", action: controller.navigateToNearest)
        case .routing:
            ProgressView("Finding a step-free route…")
        case .navigating:
            if let route = controller.route {
                RouteCard(route: route, onEnd: controller.endNavigation)
            }
        case .arrived:
            VStack(spacing: 12) {
                Label("You've arrived", systemImage: "checkmark.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                if let route = controller.route {
                    Text(route.destination.name).font(.title3)
                    if route.destination.requiresAssistance {
                        Label("Needs a staff member to operate", systemImage: "person.fill.questionmark")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                Button("Done", action: controller.endNavigation)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        case .noRoute:
            VStack(spacing: 12) {
                Label("No step-free route from here", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Move to open floor space and try again.").font(.subheadline)
                PrimaryButton(title: "Try again", systemImage: "arrow.clockwise", action: controller.navigateToNearest)
            }
        }
    }
}

private struct LocatingPanel: View {
    let startView: UIImage?
    let isSlow: Bool
    let onStartHere: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let startView {
                Image(uiImage: startView)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Photo of where the scan started")
            }
            Text("Finding where you are").font(.title3.bold())
            Text("Go to where the scan started and slowly look around.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            ProgressView()
            if isSlow {
                Divider()
                Text("Still searching? Stand exactly where the scan started, facing the way the photo does, then start from there.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Start from here", action: onStartHere)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }
}

private struct RouteCard: View {
    let route: Route
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: route.destination.kind.symbolName)
                    .font(.system(size: 40))
                    .foregroundStyle(route.destination.kind.tint)
                VStack(alignment: .leading) {
                    Text(route.destination.name).font(.title2.bold())
                    Text(details).font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button("End", action: onEnd)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            if route.destination.isTooSteep {
                Label("Steeper than the ADA allows; it's the only reachable option", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if route.isNarrow {
                Label("Some passages on this route are narrow", systemImage: "arrow.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = ["\(Int(route.length.rounded())) m", "step-free"]
        if let slope = route.destination.slopeDegrees {
            parts.append(String(format: "%.1f° slope", slope))
        }
        return parts.joined(separator: " · ")
    }
}

private struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 20))
    }
}
