import ARKit
import AccessCore
import SwiftUI

/// The live sign-reading layer over an AR camera: brackets that lock onto the sign in 3D, what it
/// says, which door and room it will label, and one tap to put it on the map.
struct SignReaderOverlay: View {
    @ObservedObject var reader: SignReader
    let session: ARSession
    /// The place the current sign would become on the map, door link included; nil when there's no map yet.
    let preview: (SignReader.Sighting) -> AccessPoint?
    /// Adds the place. Returns a message for the toast, or nil when it couldn't be saved.
    let onAdd: (AccessPoint) async -> String?
    var onShowOnMap: ((AccessPoint) -> Void)? = nil
    /// While scanning there's no finished map yet: says how the sign will be linked instead.
    var pendingLink: String? = nil
    var onClose: () -> Void

    @State private var isAdding = false
    @State private var added: (point: AccessPoint, message: String)?
    @State private var addError: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                    brackets(in: geometry.size)
                }
                .allowsHitTesting(false)
                VStack(spacing: 10) {
                    statusPill.padding(.top, geometry.safeAreaInsets.top + 70)
                    Spacer()
                    if let added {
                        addedToast(added.point, message: added.message).transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if reader.isLocked, let focus = reader.focus {
                        card(for: focus).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    controls
                }
                .padding(.horizontal, 16)
                .padding(.bottom, max(16, geometry.safeAreaInsets.bottom + 8))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: reader.isLocked)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: added?.point.id)
        }
        .onAppear { reader.start() }
        .onDisappear { reader.stop() }
        .sensoryFeedback(.success, trigger: added?.point.id) { _, new in new != nil }
    }

    // MARK: Brackets

    @ViewBuilder private func brackets(in size: CGSize) -> some View {
        if let focus = reader.focus, let point = project(focus.position, in: size) {
            let tint = focus.reading.category.tint
            // The upright camera image fills the screen by height (3:4 image on a taller screen).
            let width = max(110, min(size.width * 0.9, focus.box.width * size.height * 0.75 * 1.25))
            let height = max(70, min(size.height * 0.5, focus.box.height * size.height * 1.4))
            ZStack {
                CornerBrackets()
                    .stroke(tint, style: StrokeStyle(lineWidth: reader.isLocked ? 4 : 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: tint.opacity(0.8), radius: reader.isLocked ? 8 : 3)
                if reader.isLocked {
                    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.14))
                } else {
                    ScanLine(tint: tint)
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                Label(focus.reading.title, systemImage: focus.reading.category.symbolName)
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(tint, in: Capsule())
                    .fixedSize()
                    .offset(y: -30)
            }
            .scaleEffect(reader.isLocked ? 1 : 1.12)
            .opacity(reader.isLocked ? 1 : 0.85)
            .position(point)
        }
    }

    private func project(_ position: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        guard size.width > 0, let camera = session.currentFrame?.camera,
              (camera.transform.inverse * SIMD4(position, 1)).z < -0.1 else { return nil }
        let point = camera.projectPoint(position, orientation: .portrait, viewportSize: size)
        guard point.x.isFinite, point.y.isFinite,
              CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40).contains(point) else { return nil }
        return point
    }

    // MARK: Status

    private var statusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: reader.isLocked ? "checkmark.seal.fill" : "text.viewfinder")
                .symbolEffect(.pulse, isActive: !reader.isLocked)
                .foregroundStyle(reader.isLocked ? Color.green : .white)
            Text(statusText).lineLimit(2)
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.black.opacity(0.55), in: Capsule())
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: statusText)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if reader.isAskingAI { return "Asking AI what this sign is…" }
        if let hint = reader.hint { return hint }
        if reader.isLocked, let focus = reader.focus { return "Read “\(focus.reading.title)”" }
        if let focus = reader.focus { return "Reading “\(focus.reading.title)”… hold steady" }
        return "Point at a room number, exit or restroom sign"
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Label("Done", systemImage: "xmark").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).frame(height: 46)
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            Spacer()
            if reader.canAskAI, !reader.isLocked {
                Button(action: reader.askAI) {
                    Label(reader.isAskingAI ? "Asking…" : "No text? Ask AI", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(height: 46)
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
                .disabled(reader.isAskingAI)
                .accessibilityHint("Sends the middle of the camera view to an AI model to identify a sign without text")
            }
        }
    }

    // MARK: Card

    private func card(for focus: SignReader.Sighting) -> some View {
        let place = preview(focus)
        let tint = focus.reading.category.tint
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                KindBadge(symbol: focus.reading.category.symbolName, tint: tint, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.reading.title).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    if let detail = focus.reading.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    Text("\(focus.reading.category.title) sign · read “\(focus.text)”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { reader.reset() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 32, height: 32)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Not this sign")
            }
            VStack(alignment: .leading, spacing: 6) {
                linkRow(place, reading: focus.reading)
                aiRow(focus.check)
            }
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            Button {
                guard let place else { return }
                add(place)
            } label: {
                HStack {
                    if isAdding { ProgressView().tint(.white) }
                    Text(pendingLink != nil ? "Save this sign" : place?.sign?.door != nil ? "Tag this door on the map" : "Add to the map")
                }
                .font(.headline).frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.borderedProminent).tint(tint)
            .disabled(place == nil || isAdding)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1.5))
    }

    @ViewBuilder private func linkRow(_ place: AccessPoint?, reading: SignReading) -> some View {
        if let pendingLink, !reading.isDirectional {
            Label(pendingLink, systemImage: "door.left.hand.open").font(.footnote.weight(.medium))
        } else if place == nil {
            Label("Waiting for the map to load", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
        } else if reading.isDirectional {
            Label("Points \(reading.directions.joined(separator: " / ")) · pinned at the sign, not a door",
                  systemImage: "arrow.turn.up.right").font(.footnote)
        } else if let door = place?.sign?.door {
            Label {
                Text("Linked to the door beside it · \(String(format: "%.2f", door.width)) m wide\(place?.sign?.room != nil ? " · room behind it mapped" : "")")
            } icon: {
                Image(systemName: "door.left.hand.open").foregroundStyle(.green)
            }
            .font(.footnote.weight(.medium))
        } else {
            Label("No door nearby · pinned in front of the sign", systemImage: "mappin").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func aiRow(_ check: SignReader.Sighting.Check) -> some View {
        switch check {
        case .none: EmptyView()
        case .checking:
            Label("Checking with AI…", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
                .symbolEffect(.pulse)
        case .confirmed:
            Label("Confirmed by AI", systemImage: "sparkles").font(.footnote.weight(.medium)).foregroundStyle(.purple)
        case .corrected(let from):
            Label("AI corrected “\(from)”", systemImage: "sparkles").font(.footnote.weight(.medium)).foregroundStyle(.purple)
        case .failed:
            Label("On-device reading only", systemImage: "iphone").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func addedToast(_ point: AccessPoint, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title).font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let onShowOnMap {
                Button("View") { onShowOnMap(point) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    private func add(_ place: AccessPoint) {
        isAdding = true
        addError = nil
        Task {
            let message = await onAdd(place)
            isAdding = false
            guard let message else { addError = "Couldn’t save it to this map."; return }
            reader.markHandled()
            added = (place, message)
            try? await Task.sleep(for: .seconds(3))
            if added?.point.id == place.id { added = nil }
        }
    }
}

/// Four corner strokes, like a camera focus frame.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.28
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// A soft line sweeping down the brackets while the sign is still being read.
private struct ScanLine: View {
    let tint: Color
    @State private var down = false

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [tint.opacity(0), tint.opacity(0.55), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
                .offset(y: down ? geometry.size.height - 18 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { down = true } }
    }
}

extension AccessPoint {
    /// Records whether a vision model checked the reading, for review and the server.
    func withReader(_ check: SignReader.Sighting.Check) -> AccessPoint {
        var point = self
        switch check {
        case .confirmed, .corrected: point.sign?.reader = "ai"
        default: break
        }
        return point
    }
}

#if DEBUG && targetEnvironment(simulator)
/// The locked-sign card over a stand-in camera, bound to the navigation demo's doors.
struct SignReaderPreview: View {
    @StateObject private var reader = SignReader(session: ARSession())

    var body: some View {
        SignReaderOverlay(reader: reader, session: ARSession(), preview: { sighting in
            NavigationDemo.map.map { map in
                SignPlaceBinder.place(for: sighting.reading, text: sighting.text, sign: sighting.position,
                                      viewer: sighting.viewer, in: map)
            }
        }, onAdd: { _ in "Door tagged · searchable and routable now" }, onClose: {})
        .background(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
        .onAppear {
            reader.preview(SignReader.Sighting(
                reading: SignReading(category: .room, title: "Room 204", detail: "Meeting Room", roomNumber: "204"),
                text: "204 MEETING ROOM", position: SIMD3(2.55, 1.5, -8.45), viewer: SIMD3(1.75, 1.4, -6.8),
                box: CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.12), hits: 3, lastSeen: .distantFuture,
                crop: nil, check: .corrected(from: "Room 2O4 · Meeting Room")))
        }
    }
}
#endif
