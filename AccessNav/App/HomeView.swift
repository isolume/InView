import AccessCore
import SwiftUI

struct HomeView: View {
    private enum Mode: String, Identifiable {
        case scan
        case navigate

        var id: String { rawValue }
    }

    @State private var savedMap = MapStore.load()
    @State private var report = MapStore.loadReport()
    @State private var mode: Mode?
    @StateObject private var liveStatus = LiveStatus()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ModeCard(
                        title: "Navigate",
                        subtitle: "Find the nearest elevator or ramp",
                        systemImage: "figure.roll",
                        tint: .blue
                    ) { mode = .navigate }
                    .disabled(savedMap == nil)

                    ModeCard(
                        title: "Map a space",
                        subtitle: "Volunteers: scan a floor and tag elevators and ramps",
                        systemImage: "viewfinder",
                        tint: .indigo
                    ) { mode = .scan }

                    if let savedMap {
                        OutageList(map: savedMap, status: liveStatus)
                        SavedMapCard(map: savedMap, report: report, outOfService: liveStatus.outOfService)
                    } else {
                        Text("No map saved yet. A volunteer scans the floor first, then anyone can navigate it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding()
            }
            .navigationTitle("AccessNav")
        }
        .onAppear { liveStatus.start() }
        .onChange(of: mode) { _, mode in
            // Navigation polls on its own while it's open.
            if mode == nil { liveStatus.start() } else { liveStatus.stop() }
        }
        .fullScreenCover(item: $mode, onDismiss: reload) { mode in
            switch mode {
            case .scan: ScanView()
            case .navigate: NavigateView()
            }
        }
    }

    private func reload() {
        savedMap = MapStore.load()
        report = MapStore.loadReport()
    }
}

/// What the crew has reported broken, newest first.
private struct OutageList: View {
    let map: VenueMap
    @ObservedObject var status: LiveStatus

    var body: some View {
        let outages = status.statuses.values
            .filter { $0.state == .outOfService }
            .sorted { $0.reportedAt > $1.reportedAt }
            .compactMap { status in map.points.first { $0.id == status.pointId }.map { (point: $0, status: status) } }
        if !outages.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Reported by the crew", systemImage: "exclamationmark.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(outages, id: \.point.id) { outage in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(outage.point.name) is out of service").font(.subheadline.weight(.semibold))
                        Text(detail(for: outage.status)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func detail(for status: PointStatus) -> String {
        var parts = [status.reportedAt.formatted(.relative(presentation: .named))]
        if status.photoVerified { parts.append("photo verified") }
        if let note = status.note, !note.isEmpty { parts.append("\u{201C}\(note)\u{201D}") }
        return parts.joined(separator: " · ")
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
    let report: AccessibilityReport?
    let outOfService: Set<UUID>
    @State private var syncState: SyncState = .idle

    private enum SyncState: Equatable {
        case idle
        case syncing
        case synced
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved map").font(.headline)
                Spacer()
                if AppConfig.serverURL != nil {
                    syncButton
                }
                ShareLink(item: MapStore.mapURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export map")
            }
            MapPreviewView(map: map, outOfService: outOfService).frame(height: 240)
            Text(summary).font(.footnote).foregroundStyle(.secondary)
            if let report {
                Divider()
                ReportView(report: report, limit: 3)
                if report.findings.count > 3 {
                    NavigationLink("Full report") {
                        ScrollView { ReportView(report: report).padding() }
                            .navigationTitle("Accessibility report")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            if case .failed(let message) = syncState {
                Text("Sync failed: \(message)").font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var syncButton: some View {
        Button {
            guard let report else { return }
            syncState = .syncing
            Task {
                let failure = await MapStore.sync(map, report: report)
                syncState = failure.map(SyncState.failed) ?? .synced
            }
        } label: {
            switch syncState {
            case .syncing: ProgressView()
            case .synced: Label("Synced", systemImage: "checkmark.icloud")
            default: Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
        }
        .font(.subheadline)
        .disabled(report == nil || syncState == .syncing)
    }

    private var summary: String {
        let counts = AccessPoint.Kind.allCases.map { kind in
            "\(map.points.filter { $0.kind == kind }.count) \(kind.title.lowercased())"
        }
        return counts.joined(separator: " · ") + " · scanned " + map.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
