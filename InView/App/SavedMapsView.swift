import AccessCore
import SwiftUI

/// The buildings and floors scanned on this device, to open or delete. With `building`, just that
/// building's details: its floors and what each one holds.
struct SavedMapsView: View {
    /// Shows one building's details instead of every saved map.
    var building: UUID? = nil
    let openFloorID: UUID?
    /// Returns to the map that comes with InView; nil while it's already showing.
    let onOpenBuiltIn: (() -> Void)?
    let onOpen: (SavedFloor) -> Void

    @State private var buildings = MapStore.savedBuildings()
    @State private var pendingDelete: PendingDelete?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    private enum PendingDelete: Identifiable {
        case floor(SavedBuilding, SavedFloor)
        case building(SavedBuilding)

        var id: UUID {
            switch self {
            case .floor(_, let floor): floor.id
            case .building(let building): building.id
            }
        }

        var title: String {
            switch self {
            case .floor(let building, let floor): "Delete \(floor.name) of \(building.name)?"
            case .building(let building): "Delete \(building.name) and all its floors?"
            }
        }
    }

    private var shown: [SavedBuilding] { building.map { id in buildings.filter { $0.id == id } } ?? buildings }

    var body: some View {
        NavigationStack {
            List {
                if building == nil, let onOpenBuiltIn {
                    Section {
                        Button { onOpenBuiltIn(); dismiss() } label: {
                            Label(StudentCenterCatalog.buildingName, systemImage: "building.2")
                        }
                    } footer: {
                        Text("The map that comes with InView.")
                    }
                }
                ForEach(shown) { building in
                    Section {
                        if self.building != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(building.name).font(.title2.bold())
                                Text("Scanned on this \(UIDevice.current.model) · \(building.floors.count) \(building.floors.count == 1 ? "floor" : "floors")")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        ForEach(building.floors.sorted { $0.level < $1.level }) { floor in
                            Button { onOpen(floor); dismiss() } label: {
                                SavedFloorRow(floor: floor, isOpen: floor.id == openFloorID)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = .floor(building, floor) }
                            }
                            .contextMenu {
                                Button("Delete \(floor.name)", systemImage: "trash", role: .destructive) { pendingDelete = .floor(building, floor) }
                            }
                        }
                        Button(role: .destructive) { pendingDelete = .building(building) } label: {
                            Label("Delete \(building.name)", systemImage: "trash")
                        }
                    } header: {
                        if self.building == nil { Text(building.name) }
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("No saved maps", systemImage: "map",
                        description: Text("Scans you save on this \(UIDevice.current.model) appear here."))
                }
            }
            .navigationTitle(building == nil ? "Saved maps" : "Building details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(pendingDelete?.title ?? "", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete) { item in
                Button("Delete", role: .destructive) { delete(item) }
            } message: { _ in
                Text("This removes the map, its places, 3D scan and live-location data from this \(UIDevice.current.model). It can’t be undone. Scan recordings waiting to upload are kept.")
            }
            .alert("Couldn’t delete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func delete(_ item: PendingDelete) {
        do {
            switch item {
            case .floor(let building, let floor): try MapStore.deleteFloor(buildingID: building.id, floorID: floor.id)
            case .building(let building): try MapStore.deleteBuilding(building.id)
            }
        } catch {
            failure = error.localizedDescription
        }
        buildings = MapStore.savedBuildings()
        if self.building != nil, shown.isEmpty { dismiss() }
    }
}

/// A floor's name, when it was scanned and what was found on it.
private struct SavedFloorRow: View {
    let floor: SavedFloor
    let isOpen: Bool
    @State private var contents: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(floor.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text("Scanned \(floor.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if let contents { Text(contents).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if isOpen {
                Text("Open").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: floor.storageID) {
            let floor = floor
            contents = await Task.detached(priority: .utility) { MapStore.map(for: floor)?.contentSummary }.value
        }
    }
}

extension VenueMap {
    /// "2 elevators · 1 ramp · 3 doors", from what the scan measured.
    var contentSummary: String {
        func counted(_ count: Int, _ singular: String) -> String? {
            count == 0 ? nil : "\(count) \(singular)\(count == 1 ? "" : "s")"
        }
        let parts = AccessPoint.Kind.allCases.compactMap { kind in
            counted(points.filter { $0.kind == kind }.count, kind.title.lowercased())
        } + [counted(footprints.filter { $0.kind == .door || $0.kind == .opening }.count, "door")].compactMap { $0 }
        return parts.isEmpty ? "No places marked yet" : parts.joined(separator: " · ")
    }
}
