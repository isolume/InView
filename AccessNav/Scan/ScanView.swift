import AccessCore
import SwiftUI

/// The volunteer flow: scan the floor, check in at the marker, review and save.
struct ScanView: View {
    @StateObject private var controller = ScanController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch controller.phase {
            case .unsupported:
                UnsupportedDeviceView(onClose: close)
            case .scanning, .processing:
                captureScreen
            case .checkIn:
                checkInScreen
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
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    CloseButton(action: close)
                    Spacer()
                    DetectionStatus(detector: controller.detector, section: controller.sectionCount + 1)
                }
                Spacer()
                if controller.phase == .processing {
                    Label("Processing section…", systemImage: "hourglass")
                        .font(.headline)
                        .padding()
                        .background(.regularMaterial, in: Capsule())
                } else {
                    scanControls
                }
            }
            .padding()
        }
    }

    private var scanControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(AccessPoint.Kind.allCases, id: \.self) { kind in
                    Button {
                        controller.detector.addManual(kind)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Label("Pin \(kind.title.lowercased())", systemImage: kind.symbolName)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Marks the spot in the center of the screen")
                }
            }
            HStack(spacing: 12) {
                Button("Add section", action: controller.addSection)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Finish", action: controller.finish)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var checkInScreen: some View {
        ZStack {
            ViewContainer(view: controller.checkInView).ignoresSafeArea()
            VStack {
                HStack {
                    CloseButton(action: close)
                    Spacer()
                }
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder").font(.largeTitle)
                    Text("Check in at the marker").font(.title3.bold())
                    Text("Walk back to the printed check-in sign and point the camera at it. This pins the map to the building.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    ProgressView(value: controller.markerProgress)
                    if let error = controller.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding()
        }
    }
}

private struct DetectionStatus: View {
    @ObservedObject var detector: AccessibilityDetector
    let section: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(statusLine)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            ForEach(detector.sightings) { sighting in
                Label("\(sighting.kind.title) ×\(sighting.count)", systemImage: sighting.kind.symbolName)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(sighting.kind.tint, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring, value: detector.sightings.count)
        .padding(10)
        .frame(maxWidth: 220, alignment: .trailing)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusLine: String {
        if !detector.isEnabled { return "Vision off: set OPENAI_API_KEY" }
        if let error = detector.lastError { return error }
        return "Section \(section) · \(detector.framesAnalyzed) frames checked"
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
                        MapPreviewView(map: draft) { pendingPoint = $0 }
                            .frame(height: 320)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("Tap the map to add an elevator or ramp the camera missed. Green doors are wide enough for a wheelchair; orange ones are not.")
                    }
                    Section("Accessible points") {
                        if draft.points.isEmpty {
                            Text("None yet").foregroundStyle(.secondary)
                        }
                        ForEach(draft.points) { point in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(point.kind.title)
                                    Text(point.source == .manual ? "Added by hand" : "Detected, \(Int(point.confidence * 100))% sure")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: point.kind.symbolName).foregroundStyle(point.kind.tint)
                            }
                        }
                        .onDelete(perform: controller.removePoints)
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
                    Button("Save") {
                        do {
                            try controller.save()
                            onClose()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
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

    private var isAddingPoint: Binding<Bool> {
        Binding(get: { pendingPoint != nil }, set: { if !$0 { pendingPoint = nil } })
    }

    private var isShowingSaveError: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
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
