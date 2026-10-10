import AccessCore
import SwiftUI

struct HomeView: View {
    private enum Mode: String, Identifiable {
        case scan
        case navigate
        case demo

        var id: String { rawValue }
    }

    @State private var savedMap = MapStore.load()
    @State private var mode: Mode?
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ModeCard(
                        title: "Navigate",
                        subtitle: "Find your way through the building",
                        systemImage: "figure.roll",
                        tint: .blue
                    ) { mode = .navigate }
                    .disabled(savedMap == nil)

                    ModeCard(
                        title: "Map a building",
                        subtitle: "Scan connected rooms and add destinations",
                        systemImage: "viewfinder",
                        tint: .indigo
                    ) { mode = .scan }

                    if let savedMap {
                        SavedMapCard(map: savedMap)
                    } else {
                        Text("No map saved yet. A volunteer scans the floor first, then anyone can navigate it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }

                    Button("Try navigation demo") { mode = .demo }
                        .font(.subheadline)
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("AccessNav")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Scan processing settings")
                }
            }
        }
        .fullScreenCover(item: $mode, onDismiss: { savedMap = MapStore.load() }) { mode in
            switch mode {
            case .scan: ScanView()
            case .navigate: NavigateView()
            case .demo: NavigateView(isDemo: true)
            }
        }
        .sheet(isPresented: $isShowingSettings) { BackendSettingsView() }
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.subheadline).opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.headline)
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

private struct SavedMapCard: View {
    let map: VenueMap

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved map").font(.headline)
                Spacer()
                ShareLink(item: MapStore.mapURL) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .font(.subheadline)
            }
            if let captureURL = CaptureStore.savedBundleURL {
                ShareLink(item: captureURL) {
                    Label("Export scan", systemImage: "cube.transparent")
                }
                .font(.subheadline)
            }
            MapPreviewView(map: map).frame(height: 240)
            Text(summary).font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var summary: String {
        let counts = AccessPoint.Kind.allCases.map { kind in
            "\(map.points.filter { $0.kind == kind }.count) \(kind.title.lowercased())"
        }
        return counts.joined(separator: " · ") + " · scanned " + map.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
