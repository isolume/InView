import AccessCore
import SwiftUI

/// The sensor can suggest a level; the volunteer supplies the building's floor name.
struct ScanFloorPicker: View {
    let currentFloor: ScanFloorIdentity?
    let isDetectedChange: Bool
    let onCancel: () -> Void
    let onSelect: (ScanFloorIdentity, String) -> Void

    @State private var buildings: [SavedBuilding]
    @State private var buildingID: UUID?
    @State private var buildingName: String
    @State private var level: Int
    @State private var floorName: String
    @AppStorage("recordScanVideo") private var recordScanVideo = false

    init(currentFloor: ScanFloorIdentity? = nil, suggestedLevel: Int? = nil,
         isDetectedChange: Bool = false, onCancel: @escaping () -> Void,
         onSelect: @escaping (ScanFloorIdentity, String) -> Void) {
        self.currentFloor = currentFloor
        self.isDetectedChange = isDetectedChange
        self.onCancel = onCancel
        self.onSelect = onSelect
        let saved = MapStore.savedBuildings()
        let selectedBuilding = currentFloor?.buildingID ?? MapStore.currentBuilding?.id
        let initialLevel = suggestedLevel ?? MapStore.currentFloor?.level ?? 1
        _buildings = State(initialValue: saved)
        _buildingID = State(initialValue: selectedBuilding)
        _buildingName = State(initialValue: saved.first { $0.id == selectedBuilding }?.name ?? "Building")
        _level = State(initialValue: initialLevel)
        _floorName = State(initialValue: saved.first { $0.id == selectedBuilding }?.floors.first { $0.level == initialLevel }?.name
                           ?? ScanFloorIdentity.defaultName(for: initialLevel))
    }

    var body: some View {
        NavigationStack {
            Form {
                if currentFloor == nil {
                    Section {
                        if !buildings.isEmpty {
                            Picker("Building", selection: $buildingID) {
                                ForEach(buildings) { building in Text(building.name).tag(Optional(building.id)) }
                                Text("New building").tag(Optional<UUID>.none)
                            }
                        }
                        if buildingID == nil { TextField("Building name", text: $buildingName) }
                    }
                } else if isDetectedChange {
                    Section { Text("Confirm the floor you've reached.").foregroundStyle(.secondary) }
                }
                Section {
                    Stepper("Floor \(level)", value: $level, in: -20...300)
                    TextField("Floor name", text: $floorName)
                        .textInputAutocapitalization(.words)
                }
                if currentFloor == nil {
                    Section {
                        Toggle("Record video", isOn: $recordScanVideo)
                    } footer: {
                        Text("Keeps video and matching LiDAR data on this phone for 3D modeling. No audio.")
                    }
                }
                Section {
                    Button(currentFloor == nil ? "Start scanning" : "Switch floor", role: .confirm, action: select)
                        .frame(maxWidth: .infinity)
                        .disabled(trimmedName.isEmpty || (currentFloor != nil && level == currentFloor?.level))
                }
            }
            .navigationTitle(currentFloor == nil ? "Which floor are you on?" : (isDetectedChange ? "New floor detected" : "Change floor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(currentFloor == nil ? "Close" : "Stay on this floor", action: onCancel)
                }
            }
            .onChange(of: level) { _, newLevel in
                floorName = buildings.first { $0.id == buildingID }?.floors.first { $0.level == newLevel }?.name
                    ?? ScanFloorIdentity.defaultName(for: newLevel)
            }
            .onChange(of: buildingID) { _, newID in
                buildingName = buildings.first { $0.id == newID }?.name ?? "Building"
                floorName = buildings.first { $0.id == newID }?.floors.first { $0.level == level }?.name
                    ?? ScanFloorIdentity.defaultName(for: level)
            }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled()
    }

    private var trimmedName: String { floorName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func select() {
        let id = buildingID ?? currentFloor?.buildingID ?? UUID()
        let existing = buildings.first { $0.id == id }?.floors.first { $0.level == level }
        let floor = ScanFloorIdentity(buildingID: id, id: existing?.id ?? UUID(), level: level, name: trimmedName)
        let name = buildingName.trimmingCharacters(in: .whitespacesAndNewlines)
        onSelect(floor, name.isEmpty ? "Building" : name)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Exercises the real forms on a Simulator without pretending to perform a LiDAR scan.
struct ScanFloorPickerPreview: View {
    let isSwitch: Bool
    @State private var selection: String?

    var body: some View {
        if let selection {
            ContentUnavailableView(selection, systemImage: "building.2")
        } else {
            ScanFloorPicker(currentFloor: isSwitch ? ScanFloorIdentity(level: 1) : nil,
                            suggestedLevel: isSwitch ? 2 : 1,
                            isDetectedChange: isSwitch,
                            onCancel: { selection = "Selection canceled" }) { floor, _ in
                selection = "Selected \(floor.name)"
            }
        }
    }
}
#endif
