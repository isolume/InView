import AccessCore
import SwiftUI

/// The volunteer flow: scan the floor, save the AR map, review and save.
struct ScanView: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss
    @Namespace private var glass
    @State private var marks = 0

    var body: some View {
        Group {
            switch controller.phase {
            case .unsupported:
                UnsupportedDeviceView(onClose: close)
            case .scanning, .processing, .interrupted, .savingWorldMap, .processingScene:
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
            if let captureView = controller.captureView, controller.phase != .processingScene {
                ViewContainer(view: captureView).ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
            if controller.phase == .scanning {
                DetectionOverlay(detector: controller.detector, session: controller.session)
                    .ignoresSafeArea()
                Crosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            // One glass container, so the bottom controls morph into each phase's panel instead of cutting.
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        CloseButton(action: close)
                        Spacer()
                        DetectionStatus(detector: controller.detector, section: controller.sectionCount + 1)
                    }
                    Spacer()
                    if controller.suggestsNewSection, controller.phase == .scanning {
                        sectionSuggestion
                    }
                    switch controller.phase {
                    case .processing:
                        StatusPill(text: "Processing section…", isWorking: true)
                            .glassEffectID("status", in: glass)
                    case .interrupted:
                        interruptedPanel
                    case .savingWorldMap:
                        worldMapPanel
                    case .processingScene:
                        StatusPill(text: "Building map…", isWorking: true)
                            .glassEffectID("status", in: glass)
                    default:
                        scanControls
                    }
                }
                .padding()
            }
            .animation(.smooth, value: controller.phase)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: marks)
    }

    /// The volunteer walked through a doorway. RoomPlan keeps one room per section, so this is the moment to split.
    private var sectionSuggestion: some View {
        HStack(spacing: 10) {
            Image(systemName: Theme.Symbol.door).font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("New room?").font(.subheadline.weight(.semibold))
                Text("Add a section so the last one is kept as scanned.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Add section", action: controller.addSection)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            Button("Dismiss", systemImage: "xmark", action: controller.dismissSectionSuggestion)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        }
        .glassPanel(padding: 12)
        .glassEffectID("suggestion", in: glass)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// RoomPlan ended the section by itself; what it scanned is kept, and the volunteer decides what's next.
    private var interruptedPanel: some View {
        VStack(spacing: 12) {
            Label("Scanning stopped", systemImage: Theme.symbol(for: .warning))
                .font(.headline)
                .foregroundStyle(Theme.color(for: .warning))
            Text(controller.errorMessage ?? "The scanner ended this section, usually because it lost track of where it was.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text(controller.interruptionHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: controller.continueScanning) {
                    Label("Continue scanning", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button(action: controller.finish) {
                    Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(!controller.canFinishInterruptedScan)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .glassPanel()
        .glassEffectID("status", in: glass)
    }

    private var worldMapPanel: some View {
        VStack(spacing: 12) {
            if let error = controller.errorMessage {
                Text(error).font(.subheadline).multilineTextAlignment(.center)
                Button("Try again", systemImage: "arrow.clockwise", action: controller.saveWorldMap)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            } else {
                ProgressView("Saving AR map…")
            }
        }
        .frame(maxWidth: .infinity)
        .glassPanel()
        .glassEffectID("status", in: glass)
    }

    /// Separate glass pieces rather than one slab, like the Camera app's controls.
    private var scanControls: some View {
        VStack(spacing: 10) {
            StatusPill(text: "Mark what's in the middle of the screen", isCompact: true)
            HStack(spacing: 10) {
                ForEach(VisionDetection.Kind.allCases, id: \.self) { kind in
                    Button {
                        controller.detector.addManual(kind)
                        marks += 1
                    } label: {
                        VStack(spacing: 6) {
                            KindBadge(kind: kind, size: 30)
                            Text(kind.title).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.panel))
                    .glassEffectID("mark-\(kind.title)", in: glass)
                    .accessibilityLabel("Mark \(kind.title.lowercased())")
                    .accessibilityHint("Marks the spot in the center of the screen")
                }
            }
            HStack(spacing: 10) {
                Button(action: controller.addSection) {
                    Label("Next section", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(action: controller.finish) {
                    Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            Text(controller.scanNotice ?? "One room per section: add a section each time you go through a door.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error = controller.errorMessage {
                StatusPill(text: error, systemImage: Theme.symbol(for: .barrier), isCompact: true)
                    .foregroundStyle(Theme.color(for: .barrier))
            }
        }
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
        let counts = detector.sightings.reduce(into: [VisionDetection.Kind: Int]()) { counts, sighting in
            if sighting.isConfirmed { counts[sighting.kind, default: 0] += 1 }
        }
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color(for: detector.lastError == nil && detector.isEnabled ? .good : .warning))
                    .frame(width: 7, height: 7)
                Text(statusLine)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .contentTransition(.numericText())
            }
            ForEach(VisionDetection.Kind.allCases, id: \.self) { kind in
                if let count = counts[kind] {
                    chip(kind.title, count: count, symbol: kind.symbolName, tint: kind.tint)
                }
            }
            if detector.isWaitingForSteadyCamera {
                Label("Hold still a moment to look for features", systemImage: "hand.raised")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            }
        }
        .animation(.spring, value: confirmedCount)
        .animation(.smooth, value: detector.framesAnalyzed)
        .frame(maxWidth: 210, alignment: .trailing)
        .glassPanel(padding: 12)
        .sensoryFeedback(.success, trigger: confirmedCount) { old, new in new > old }
    }

    private var confirmedCount: Int { detector.sightings.filter(\.isConfirmed).count }

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
        if detector.rejectedClaims > 0 {
            line += " · \(detector.rejectedClaims) false finds ruled out by LiDAR"
        }
        return line
    }
}

/// The scan's processed scene is the main review, with the volunteer's evidence and report one tap away.
struct MapReviewView: View {
    @ObservedObject var controller: ScanController
    let onClose: () -> Void
    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        Group {
            if let scene = controller.scene {
                RoomMapExperience(scene: scene, map: controller.draft, title: "Review map", onClose: onClose,
                                  primaryTitle: isSaving ? "Saving…" : "Save map", primaryAction: save,
                                  secondaryTitle: "Review points",
                                  reviewDestination: AnyView(RoomReviewSheet(controller: controller, onSaved: onClose)),
                                  currentMapPosition: { controller.placementPosition },
                                  onPlaceBuilding: controller.setGeographicReference,
                                  error: $saveError)
            } else {
                MapReviewDetailsView(controller: controller, onClose: onClose)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await controller.save()
                onClose()
            } catch { saveError = error.localizedDescription }
            isSaving = false
        }
    }
}

private struct RoomReviewSheet: View {
    @ObservedObject var controller: ScanController
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MapReviewDetailsView(controller: controller, onClose: { dismiss() }, isDetailSheet: true, onSaved: onSaved)
    }
}

private struct MapReviewDetailsView: View {
    @ObservedObject var controller: ScanController
    let onClose: () -> Void
    var isDetailSheet = false
    var onSaved: (() -> Void)? = nil
    @State private var pendingPoint: SIMD2<Float>?
    @State private var pendingDestinationPoint: SIMD2<Float>?
    @State private var destinationName = ""
    @State private var isShowingSettings = false
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var shownEvidence: ShownEvidence?

    var body: some View {
        NavigationStack {
            List {
                if let draft = controller.draft {
                    if controller.isProcessingScene {
                        Section { ProgressView("Building map…") }
                    } else if let error = controller.sceneError {
                        Section {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            if controller.canUseLocalScene {
                                Button("Use local map", action: controller.useLocalScene)
                            }
                            HStack {
                                Button("Settings") { isShowingSettings = true }
                                Spacer()
                                if controller.canRetryScene { Button("Try again", action: controller.retryScene) }
                            }
                        }
                    }
                    Section {
                        MapPanel(map: draft, height: 320) { pendingPoint = $0 }
                            .padding(.vertical, 6)
                    } footer: {
                        Text("Tap the plan to name a destination or add an elevator or ramp the camera missed.")
                    }
                    if !controller.unconfirmed.isEmpty {
                        Section {
                            ForEach(controller.unconfirmed) { sighting in
                                UnconfirmedRow(
                                    sighting: sighting,
                                    thumbnail: { evidenceThumbnail(for: sighting.id, title: sighting.name) },
                                    onKeep: { controller.keep(sighting) },
                                    onDrop: { controller.drop(sighting) }
                                )
                            }
                        } header: {
                            Text("Unconfirmed \u{2013} keep?")
                        } footer: {
                            Text("The camera saw these only briefly, or LiDAR couldn't check them. Tap a photo to look, then keep the real ones.")
                        }
                    }
                    Section {
                        if draft.points.isEmpty {
                            Text("None yet").foregroundStyle(.secondary)
                        }
                        ForEach(draft.points) { point in
                            HStack(spacing: 12) {
                                evidenceThumbnail(for: point.id, title: point.name)
                                PointRow(point: point, name: name(for: point), needsStaff: needsStaff(for: point))
                            }
                        }
                        .onDelete(perform: controller.removePoints)
                    } header: {
                        Text("Destinations")
                    } footer: {
                        Text("Tap a photo to see what the camera saw. Names are read aloud, so make them easy to say. Turn on \u{201C}Needs staff\u{201D} for lifts or doors someone has to operate.")
                    }
                    let stairs = draft.footprints.filter { $0.kind == .stairs }
                    Section {
                        if stairs.isEmpty {
                            Text("None found").foregroundStyle(.secondary)
                        }
                        ForEach(Array(stairs.enumerated()), id: \.offset) { index, footprint in
                            HStack(spacing: 12) {
                                if let id = footprint.id {
                                    evidenceThumbnail(for: id, title: "Stairs \(index + 1)")
                                } else {
                                    KindBadge(kind: VisionDetection.Kind.stairs, size: 32)
                                        .frame(width: 48, height: 64)
                                        .background(Theme.stairs.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Stairs \(index + 1)").font(.body.weight(.medium))
                                    Text(footprint.id == nil ? "Measured by RoomPlan" : "Spotted by the camera, checked with LiDAR")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { stairs[$0] }.forEach(controller.removeStairs)
                        }
                    } header: {
                        Text("Stairs")
                    } footer: {
                        Text("Routes go around every stairs listed here. Swipe to delete any that aren't real.")
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
                    if isDetailSheet {
                        Button("Close", systemImage: "xmark", role: .close, action: onClose)
                    } else {
                        Button("Discard", role: .destructive, action: onClose)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save) {
                        if isSaving { ProgressView() } else { Label("Save", systemImage: "checkmark") }
                    }
                    .disabled(isSaving || controller.isProcessingScene || controller.canUseLocalScene)
                }
            }
            .confirmationDialog("Add destination", isPresented: isAddingPoint) {
                ForEach(AccessPoint.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) {
                        if let pendingPoint {
                            if kind == .destination {
                                pendingDestinationPoint = pendingPoint
                                destinationName = ""
                            } else {
                                controller.addPoint(kind, at: pendingPoint)
                            }
                        }
                    }
                }
            }
            .alert("Name destination", isPresented: Binding(
                get: { pendingDestinationPoint != nil },
                set: { if !$0 { pendingDestinationPoint = nil } }
            )) {
                TextField("Room or place name", text: $destinationName)
                Button("Cancel", role: .cancel) { pendingDestinationPoint = nil }
                Button("Add") {
                    if let point = pendingDestinationPoint {
                        controller.addPoint(.destination, at: point,
                                            name: destinationName.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    pendingDestinationPoint = nil
                }
                .disabled(destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("Couldn't save the map", isPresented: isShowingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
            .sheet(item: $shownEvidence) { shown in
                EvidenceSheet(title: shown.title, evidence: shown.evidence)
            }
            .sheet(isPresented: $isShowingSettings) { BackendSettingsView() }
        }
    }

    @ViewBuilder
    private func evidenceThumbnail(for id: UUID, title: String) -> some View {
        if let evidence = controller.detector.evidence(for: id) {
            Button {
                shownEvidence = ShownEvidence(title: title, evidence: evidence)
            } label: {
                EvidenceImage(evidence: evidence, markerSize: 12)
                    .frame(width: 48, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo of \(title)")
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await controller.save()
                onClose()
                onSaved?()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
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

/// A find that didn't confirm, with its photo and a Keep / Drop choice.
private struct UnconfirmedRow<Thumbnail: View>: View {
    let sighting: AccessibilityDetector.Sighting
    @ViewBuilder let thumbnail: () -> Thumbnail
    let onKeep: () -> Void
    let onDrop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail()
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("\(sighting.name)?").font(.body.weight(.medium))
                } icon: {
                    KindBadge(kind: sighting.kind, size: 26)
                }
                Text(reason).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Keep", action: onKeep)
                        .buttonStyle(.borderedProminent)
                        .tint(sighting.kind.tint)
                    Button("Drop", role: .destructive, action: onDrop)
                        .buttonStyle(.bordered)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var reason: String {
        var parts = ["Seen in \(sighting.frames) frame\(sighting.frames == 1 ? "" : "s")", "\(Int(sighting.confidence * 100))% sure"]
        if sighting.kind != .elevator, sighting.verifiedFrames == 0 {
            parts.append("LiDAR couldn't check it")
        }
        if let slope = sighting.slopeDegrees {
            parts.append(String(format: "%.1f° slope", slope))
        }
        return parts.joined(separator: " · ")
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
                Text(details).font(.caption).foregroundStyle(point.isTooSteep ? Theme.color(for: .warning) : .secondary)
                Toggle("Needs staff", isOn: $needsStaff)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        } icon: {
            KindBadge(kind: point.kind, size: 26)
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

private struct ShownEvidence: Identifiable {
    let id = UUID()
    let title: String
    let evidence: AccessibilityDetector.Evidence
}

/// The frame a find came from, with a ring where the model pointed.
private struct EvidenceImage: View {
    let evidence: AccessibilityDetector.Evidence
    var markerSize: CGFloat = 28

    var body: some View {
        Image(uiImage: evidence.image)
            .resizable()
            .aspectRatio(evidence.image.size, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Circle()
                        .stroke(.white, lineWidth: markerSize / 6)
                        .background(Circle().stroke(.black.opacity(0.5), lineWidth: markerSize / 3))
                        .frame(width: markerSize, height: markerSize)
                        .position(x: evidence.point.x * geometry.size.width, y: evidence.point.y * geometry.size.height)
                }
            }
    }
}

private struct EvidenceSheet: View {
    let title: String
    let evidence: AccessibilityDetector.Evidence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EvidenceImage(evidence: evidence)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .padding()
                .frame(maxHeight: .infinity)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}
