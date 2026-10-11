import AccessCore
import SwiftUI

/// The volunteer flow: scan the floor, save the AR map, review and save.
struct ScanView: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var glass
    @State private var marks = 0

    var body: some View {
        Group {
            switch controller.phase {
            case .unsupported:
                UnsupportedDeviceView(onClose: close)
            case .choosingFloor:
                ScanFloorPicker(onCancel: close, onSelect: controller.startScanning)
            case .scanning, .processing, .interrupted, .savingWorldMap, .processingScene, .switchingFloor:
                captureScreen
            case .review:
                if let nextFloor = controller.nextFloorName {
                    VStack(spacing: 16) {
                        Text(controller.errorMessage ?? "Save this floor before continuing.")
                            .multilineTextAlignment(.center)
                        if let error = controller.sceneError {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            if controller.canUseLocalScene { Button("Use local map", action: controller.useLocalScene) }
                        }
                        Button(controller.scene == nil ? "Try again" : "Continue to \(nextFloor)", action: controller.retryFloorSwitch)
                            .buttonStyle(.borderedProminent)
                        Button("Close", role: .close, action: close).buttonStyle(.bordered)
                    }.padding()
                } else {
                    MapReviewView(controller: controller, onClose: close)
                }
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            controller.setAppIsActive(phase == .active)
        }
        .sheet(isPresented: Binding(
            get: { controller.proposedFloorLevel != nil },
            set: { if !$0, controller.proposedFloorLevel != nil { controller.cancelFloorChange() } }
        )) {
            ScanFloorPicker(currentFloor: controller.currentFloor,
                            suggestedLevel: controller.proposedFloorLevel,
                            isDetectedChange: controller.isChangingFloors,
                            onCancel: controller.cancelFloorChange) { floor, _ in
                controller.confirmFloorChange(to: floor)
            }
            .presentationDetents([.medium, .large])
        }
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
                        if let floor = controller.currentFloor {
                            Button(action: controller.requestFloorChange) {
                                Label(floor.name, systemImage: "building.2")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                            .disabled(controller.phase != .scanning && controller.phase != .interrupted)
                            .accessibilityLabel("\(floor.name). Change floor")
                        }
                        Spacer()
                        if controller.phase == .scanning {
                            DetectionStatus(detector: controller.detector)
                        }
                    }
                    Spacer()
                    switch controller.phase {
                    case .processing:
                        StatusPill(text: "Hold here while the room is saved…", isWorking: true)
                            .glassEffectID("status", in: glass)
                    case .interrupted:
                        if controller.isChangingFloors { floorTransitionPanel }
                        else { interruptedPanel }
                    case .savingWorldMap:
                        worldMapPanel
                    case .processingScene:
                        ScanSceneProgress(controller: controller)
                            .padding(20)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: Theme.Radius.panel))
                    case .switchingFloor:
                        StatusPill(text: "Saving \(controller.currentFloor?.name ?? "floor")…", isWorking: true)
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

    private var floorTransitionPanel: some View {
        VStack(spacing: 12) {
            Label("Changing floors…", systemImage: "arrow.up.arrow.down")
                .font(.headline)
            Text("Scanning is paused. Confirm your floor when you arrive.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Choose floor", action: controller.requestFloorChange)
                    .buttonStyle(.glassProminent)
                Button("Stay on this floor", action: controller.cancelFloorChange)
                    .buttonStyle(.glass)
            }
            if let error = controller.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .glassPanel()
        .glassEffectID("status", in: glass)
    }

    /// An interruption keeps the scan available for recovery or review.
    private var interruptedPanel: some View {
        VStack(spacing: 12) {
            Label("Scanning paused", systemImage: Theme.symbol(for: .warning))
                .font(.headline)
                .foregroundStyle(Theme.color(for: .warning))
            Text(controller.errorMessage ?? "The scanner paused. Move somewhere with more detail in view before continuing.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text(controller.interruptionHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: controller.continueScanning) {
                    Label("Resume", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
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
                ProgressView("Saving map…")
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
            Button(action: controller.finish) {
                Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Text(controller.trackingNotice ?? controller.scanGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if controller.automaticFloorDetectionUnavailable {
                Text("Use the floor button when you move to another floor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                StatusPill(text: error, systemImage: Theme.symbol(for: .barrier), isCompact: true)
                    .foregroundStyle(Theme.color(for: .barrier))
            }
            if let warning = controller.originalScanWarning {
                StatusPill(text: warning, systemImage: Theme.symbol(for: .warning), isCompact: true)
                    .foregroundStyle(Theme.color(for: .warning))
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
            return "Mark accessibility features below"
        }
        if detector.lastError != nil { return "Feature detection unavailable" }
        return "Looking for accessibility features"
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
                                  secondaryTitle: "Check scan",
                                  reviewDestination: AnyView(RoomReviewSheet(controller: controller, onSaved: onClose)),
                                  currentMapPosition: { controller.placementPosition },
                                  onPlaceBuilding: controller.setGeographicReference,
                                  error: $saveError, detailScene: controller.detailScene)
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

private struct ScanSceneProgress: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        ProgressView(controller.sceneStatusLine)
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
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var shownEvidence: ShownEvidence?
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let warning = controller.originalScanWarning {
                    Section { Text(warning).foregroundStyle(.secondary) }
                }
                if let draft = controller.draft {
                    if controller.isProcessingScene {
                        Section { ScanSceneProgress(controller: controller) }
                    } else if let error = controller.sceneError {
                        Section {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            if controller.canUseLocalScene {
                                Button("Use local map", action: controller.useLocalScene)
                            }
                            if controller.canRetryScene { Button("Try again", action: controller.retryScene) }
                        }
                    }
                    Section {
                        MapPanel(map: draft, height: 320, onTap: controller.canPlaceReviewPoints ? { pendingPoint = $0 } : nil)
                            .padding(.vertical, 6)
                    } footer: {
                        Text(controller.canPlaceReviewPoints
                             ? "Tap the plan to name a destination or add an elevator or ramp the camera missed."
                             : "Finish preparing the map before adding destinations.")
                    }
                    ScanReviewSections(map: draft, trace: controller.walkTrace, coverage: controller.walkCoverage)
                    Section {
                        if controller.isPreparingDetail {
                            ProgressView("Preparing detail…")
                        } else if let error = controller.detailError {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            if controller.canRetryDetail { Button("Retry detail", action: controller.retryDetail) }
                        }
                        if controller.isFindingPlaces {
                            ProgressView(controller.analysisStatus ?? "Finding places…")
                        } else {
                            Button("Find places", systemImage: "text.viewfinder", action: controller.findPlaces)
                            if let status = controller.analysisStatus {
                                Text(status).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if let error = controller.analysisError {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(controller.analysisCandidates, id: \.id) { place in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(place.localizedName()).font(.body.weight(.medium))
                                Text(place.category.title).font(.caption).foregroundStyle(.secondary)
                                if !controller.canKeepAnalysisPlace(place) {
                                    Text("Its position on this floor needs checking. Add it by tapping the plan.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Keep") { controller.keepAnalysisPlace(place) }
                                        .disabled(!controller.canKeepAnalysisPlace(place))
                                    Button("Drop", role: .destructive) { controller.dropAnalysisPlace(place) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        Button("Scan settings", systemImage: "gearshape") { showsSettings = true }
                    } header: {
                        Text("Place suggestions")
                    } footer: {
                        Text("Find places sends this scan's photos, measurements and location to your scan server. Suggestions stay here until you keep them.")
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
            .sheet(isPresented: $showsSettings) { BackendSettingsView() }
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
                    .disabled(isSaving || controller.isProcessingScene || controller.scene == nil)
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
