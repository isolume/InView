import AccessCore
import SwiftUI

/// The volunteer flow: scan the floor, save the AR map, review and save.
struct ScanView: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch controller.phase {
            case .unsupported:
                UnsupportedDeviceView(onClose: close)
            case .scanning, .processing, .savingWorldMap:
                captureScreen
            case .review:
                MapReviewView(controller: controller, onClose: close)
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private func close() {
        controller.stop()
        dismiss()
    }

    private var captureScreen: some View {
        ZStack {
            ViewContainer(view: controller.captureView).ignoresSafeArea()
            if controller.phase == .scanning {
                Crosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    CloseButton(action: close)
                    Spacer()
                    DetectionStatus(detector: controller.detector, section: controller.sectionCount + 1)
                }
                Spacer()
                switch controller.phase {
                case .processing:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Processing section…").font(.headline)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule())
                case .savingWorldMap:
                    worldMapPanel
                default:
                    scanControls
                }
            }
            .padding()
        }
    }

    private var worldMapPanel: some View {
        VStack(spacing: 12) {
            if let error = controller.errorMessage {
                Text(error).font(.subheadline).multilineTextAlignment(.center)
                Button("Try again", action: controller.saveWorldMap)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                ProgressView("Saving AR map…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mark what's in the middle of the screen")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(VisionDetection.Kind.allCases, id: \.self) { kind in
                    Button {
                        controller.detector.addManual(kind)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.symbolName).font(.title3.weight(.semibold))
                            Text(kind.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(kind.tint)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Mark \(kind.title.lowercased())")
                    .accessibilityHint("Marks the spot in the center of the screen")
                }
            }
            HStack(spacing: 10) {
                Button(action: controller.addSection) {
                    Label("Add section", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: controller.finish) {
                    Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// Small crosshair in the middle of the camera view, where the mark buttons pin things.
private struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 2).frame(width: 26, height: 26)
            Circle().fill(.white).frame(width: 4, height: 4)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DetectionStatus: View {
    @ObservedObject var detector: AccessibilityDetector
    let section: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(detector.lastError == nil && detector.isEnabled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(statusLine)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            ForEach(detector.sightings) { sighting in
                chip(sighting.name, count: sighting.count, symbol: sighting.kind.symbolName, tint: sighting.kind.tint)
            }
            ForEach(detector.stairs.filter(\.isConfirmed)) { stairs in
                chip(stairs.name, count: stairs.count, symbol: "figure.stairs", tint: Theme.stairs)
            }
        }
        .animation(.spring, value: detector.sightings.count + detector.stairs.filter(\.isConfirmed).count)
        .padding(10)
        .frame(maxWidth: 230, alignment: .trailing)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chip(_ name: String, count: Int, symbol: String, tint: Color) -> some View {
        Label(count > 1 ? "\(name) ×\(count)" : name, systemImage: symbol)
            .font(.caption.bold())
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
            .transition(.scale.combined(with: .opacity))
    }

    private var statusLine: String {
        if !detector.isEnabled {
            return AppConfig.visionProvider == .openai ? "Vision off: set OPENAI_API_KEY" : "Vision off: set GEMINI_API_KEY"
        }
        if let error = detector.lastError { return error }
        var line = "Section \(section) · \(detector.framesAnalyzed) frames checked"
        if detector.rejectedStairs > 0 {
            line += " · \(detector.rejectedStairs) false stairs ruled out by LiDAR"
        }
        return line
    }
}

struct MapReviewView: View {
    @ObservedObject var controller: ScanController
    let onClose: () -> Void
    @State private var pendingPoint: SIMD2<Float>?
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            List {
                if let draft = controller.draft {
                    Section {
                        MapPanel(map: draft, height: 320) { pendingPoint = $0 }
                            .padding(.vertical, 6)
                    } footer: {
                        Text("Tap the plan to add an elevator or ramp the camera missed.")
                    }
                    Section {
                        if draft.points.isEmpty {
                            Text("None yet").foregroundStyle(.secondary)
                        }
                        ForEach(draft.points) { point in
                            PointRow(point: point, name: name(for: point), needsStaff: needsStaff(for: point))
                        }
                        .onDelete(perform: controller.removePoints)
                    } header: {
                        Text("Accessible points")
                    } footer: {
                        Text("Names are read aloud, so make them easy to say. Turn on \u{201C}Needs staff\u{201D} for lifts or doors someone has to operate.")
                    }
                    Section("Accessibility report") {
                        if let report = controller.report {
                            HStack(spacing: 14) {
                                ScoreRing(report: report, size: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(report.verdict).font(.headline)
                                    Text(report.tally).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            ForEach(report.findings.prefix(3)) { FindingRow(finding: $0) }
                            NavigationLink("Full report") {
                                FullReportView(map: draft, report: report)
                            }
                        } else {
                            HStack {
                                ProgressView()
                                Text("Checking accessibility…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive, action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .confirmationDialog("Add accessible point", isPresented: isAddingPoint) {
                ForEach(AccessPoint.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) {
                        if let pendingPoint { controller.addPoint(kind, at: pendingPoint) }
                    }
                }
            }
            .alert("Couldn't save the map", isPresented: isShowingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        do {
            try controller.save()
            onClose()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func name(for point: AccessPoint) -> Binding<String> {
        Binding(get: { point.name }, set: { controller.rename(point.id, to: $0) })
    }

    private func needsStaff(for point: AccessPoint) -> Binding<Bool> {
        Binding(get: { point.requiresAssistance }, set: { controller.setRequiresAssistance(point.id, $0) })
    }

    private var isAddingPoint: Binding<Bool> {
        Binding(get: { pendingPoint != nil }, set: { if !$0 { pendingPoint = nil } })
    }

    private var isShowingSaveError: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }
}

private struct PointRow: View {
    let point: AccessPoint
    @Binding var name: String
    @Binding var needsStaff: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                TextField(point.kind.title, text: $name)
                    .font(.body.weight(.medium))
                    .submitLabel(.done)
                Text(details).font(.caption).foregroundStyle(point.isTooSteep ? .orange : .secondary)
                Toggle("Needs staff", isOn: $needsStaff)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        } icon: {
            Image(systemName: point.kind.symbolName).foregroundStyle(point.kind.tint)
        }
    }

    private var details: String {
        var parts = [point.source == .manual ? "Added by hand" : "Detected, \(Int(point.confidence * 100))% sure"]
        if let slope = point.slopeDegrees {
            parts.append(String(format: point.isTooSteep ? "%.1f° · too steep" : "%.1f° slope", slope))
        }
        return parts.joined(separator: " · ")
    }
}

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

private struct UnsupportedDeviceView: View {
    let onClose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("LiDAR required", systemImage: "camera.metering.unknown")
        } description: {
            Text("Mapping needs an iPhone Pro or iPad Pro with a LiDAR scanner.")
        } actions: {
            Button("Close", action: onClose)
        }
    }
}
