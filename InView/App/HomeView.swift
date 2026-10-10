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
    @State private var report = MapStore.loadReport()
    @State private var mode: Mode?
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Step-free routes inside buildings, mapped by volunteers.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ActionCard(
                        title: "Navigate",
                        subtitle: savedMap == nil ? "Map this floor first" : "Nearest elevator or ramp, step-free",
                        systemImage: "figure.roll",
                        style: .primary
                    ) { mode = .navigate }
                    .disabled(savedMap == nil)

                    ActionCard(
                        title: "Map a space",
                        subtitle: "Scan a floor; InView finds elevators, ramps and stairs",
                        systemImage: "viewfinder",
                        style: .secondary
                    ) { mode = .scan }

                    if let savedMap {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("This floor").sectionHeading()
                                Spacer()
                                ShareLink(item: MapStore.mapURL) {
                                    Label("Export", systemImage: "square.and.arrow.up").font(.footnote.weight(.semibold))
                                }
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                // The scan and navigate covers each run their own AR view; the 3D model must not stay alive under them.
                                MapPanel(map: savedMap, height: 260, isModelAllowed: mode == nil)
                                Text(summary(of: savedMap)).font(.footnote).foregroundStyle(.secondary)
                            }
                            .card()
                        }
                        if let report {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Accessibility").sectionHeading()
                                ReportSummaryCard(map: savedMap, report: report)
                            }
                        }
                    } else {
                        EmptyFloorCard()
                    }
                    Button("Try navigation demo") { mode = .demo }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("InView")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Scan processing settings", systemImage: "gearshape") { showsSettings = true }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .tint(Theme.accent)
        .fullScreenCover(item: $mode, onDismiss: reload) { mode in
            switch mode {
            case .scan: ScanView()
            case .navigate: NavigateView()
            case .demo: NavigateView(isDemo: true)
            }
        }
        .sheet(isPresented: $showsSettings) { BackendSettingsView() }
    }

    private func reload() {
        savedMap = MapStore.load()
        report = MapStore.loadReport()
    }

    private func summary(of map: VenueMap) -> String {
        let elevators = map.points.filter { $0.kind == .elevator }.count
        let ramps = map.points.filter { $0.kind == .ramp }.count
        let stairs = map.footprints.filter { $0.kind == .stairs }.count
        let counts = ["\(elevators) elevator\(elevators == 1 ? "" : "s")", "\(ramps) ramp\(ramps == 1 ? "" : "s")", "\(stairs) stairs"]
        return counts.joined(separator: " · ") + " · scanned " + map.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ActionCard: View {
    enum Style {
        case primary
        case secondary
    }

    let title: String
    let subtitle: String
    let systemImage: String
    let style: Style
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text(subtitle).font(.subheadline).opacity(0.8)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.headline).opacity(0.6)
            }
            .foregroundStyle(style == .primary ? Color.white : Color.primary)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressableStyle())
    }

    private var background: AnyShapeStyle {
        style == .primary ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
    }

    private var iconBackground: AnyShapeStyle {
        style == .primary ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(Theme.accent.opacity(0.12))
    }
}

private struct EmptyFloorCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No floor mapped yet", systemImage: "map").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Start at the entrance and tap Map a space.")
                step(2, "Walk the floor. InView pins elevators, ramps and stairs as it sees them.")
                step(3, "Review, save, and anyone can navigate it.")
            }
        }
        .card()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
