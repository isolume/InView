import AccessCore
import SwiftUI
import simd

struct FloorNavigationDestination: Identifiable, Equatable, Sendable {
    let level: Int
    let floorName: String
    let point: AccessPoint
    var savedFloor: SavedFloor? = nil
    var isRoutable = true
    var id: String { "\(savedFloor?.id.uuidString ?? String(level)):\(point.id)" }
    var title: String { "\(point.title) · \(floorName)" }
}

struct FloorNavigationSelection: Equatable, Sendable {
    var start: FloorNavigationDestination? = nil
    var destination: FloorNavigationDestination? = nil
    var swapped: Self { Self(start: destination, destination: start) }
}

struct FloorNavigationSection: Identifiable {
    let level: Int
    let name: String
    let places: [FloorNavigationDestination]
    var id: Int { level }
}

enum FloorNavigationCatalog {
    static func sections(for destinations: [FloorNavigationDestination]) -> [FloorNavigationSection] {
        Array(Set(destinations.map(\.level))).sorted().map { level in
            let places = destinations.filter { $0.level == level }
            return FloorNavigationSection(level: level,
                name: places.first?.floorName ?? ScanFloorIdentity.defaultName(for: level), places: places)
        }
    }
    static func destinations(level: Int, name: String? = nil, map: VenueMap?,
                             savedFloor: SavedFloor? = nil, includesModel: Bool = false) -> [FloorNavigationDestination] {
        let floorName = name ?? ScanFloorIdentity.defaultName(for: level)
        var result = (map?.points ?? []).map {
            FloorNavigationDestination(level: level, floorName: floorName, point: $0, savedFloor: savedFloor)
        }
        guard includesModel else { return result }
        let transform = map.flatMap { StudentCenterModelAlignment.transform(for: $0, floor: level) }
        for landmark in StudentCenterCatalog.modelLandmarks(for: level) {
            guard !result.contains(where: { $0.point.id == landmark.id }),
                  landmark.title != "Lifts" || !result.contains(where: { $0.point.kind == .elevator }) else { continue }
            let position: SIMD3<Float>
            if let transform {
                let registered = transform * SIMD4(landmark.position.x,
                    StudentCenterCatalog.modelFloorY(for: level) ?? 0, landmark.position.z, 1)
                position = SIMD3(registered.x, registered.y, registered.z)
            } else { position = landmark.position }
            result.append(FloorNavigationDestination(level: level, floorName: floorName,
                point: AccessPoint(id: landmark.id, kind: landmark.title == "Lifts" ? .elevator : .destination,
                    name: landmark.title, position: position, source: .manual, confidence: 0.5),
                isRoutable: level == 2 && map != nil && transform != nil))
        }
        return result
    }
}

/// Both endpoint menus use the same floor groups, including places without walking coverage.
struct FloorPlaceMenuSections: View {
    let destinations: [FloorNavigationDestination]
    let onSelect: (FloorNavigationDestination) -> Void

    var body: some View {
        ForEach(FloorNavigationCatalog.sections(for: destinations)) { floor in
            Menu(floor.name) {
                ForEach(floor.places) { place in
                    Button(place.point.title, systemImage: place.point.kind.symbolName) { onSelect(place) }
                }
            }
        }
    }
}

/// Uses the same destinations as the map's To field, including other floors.
struct FloorDestinationPicker: View {
    let destinations: [FloorNavigationDestination]
    let onSelect: (FloorNavigationDestination) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var matches: [FloorNavigationDestination] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return destinations.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(Set(matches.map(\.level))).sorted(), id: \.self) { level in
                    let places = matches.filter { $0.level == level }
                    Section(places.first?.floorName ?? "Floor \(level)") {
                        ForEach(places) { place in
                            Button {
                                dismiss()
                                onSelect(place)
                            } label: {
                                Label(place.point.title, systemImage: place.point.kind.symbolName)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Search all floors")
            .navigationTitle("Choose a destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
