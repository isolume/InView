import AccessCore
import SwiftUI

/// The rider flow: find the check-in sign, then follow arrows to the nearest elevator or ramp.
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
                VStack {
                    HStack {
                        CloseButton {
                            controller.stop()
                            dismiss()
                        }
                        Spacer()
                    }
                    Spacer()
                    panel
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .padding()
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
            VStack(spacing: 12) {
                Image(systemName: "viewfinder").font(.largeTitle)
                Text("Point your camera at the check-in sign").font(.title3.bold()).multilineTextAlignment(.center)
                ProgressView(value: controller.markerProgress)
            }
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
                    Text(route.destination.kind.title).font(.title3)
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
                    Text(route.destination.kind.title).font(.title2.bold())
                    Text("\(Int(route.length.rounded())) m · step-free").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button("End", action: onEnd)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            if route.isNarrow {
                Label("Some passages on this route are narrow", systemImage: "arrow.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
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
