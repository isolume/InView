import Foundation

/// The floor the person selected before starting a scan. Identity survives a rescan.
public struct ScanFloorIdentity: Codable, Identifiable, Equatable, Sendable {
    public var buildingID: UUID
    public var id: UUID
    public var level: Int
    public var name: String

    public init(buildingID: UUID = UUID(), id: UUID = UUID(), level: Int, name: String? = nil) {
        self.buildingID = buildingID
        self.id = id
        self.level = level
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? Self.defaultName(for: level) : trimmed
    }

    public static func defaultName(for level: Int) -> String {
        level == 0 ? "Ground floor" : "Floor \(level)"
    }
}

/// A complete, immutable save. Its UUID is also its storage directory name.
public struct SavedFloorVersion: Codable, Equatable, Sendable {
    public var storageID: UUID
    public var savedAt: Date
    public var captureID: String?

    public init(storageID: UUID, savedAt: Date, captureID: String?) {
        self.storageID = storageID
        self.savedAt = savedAt
        self.captureID = captureID
    }
}

public struct SavedFloor: Codable, Identifiable, Equatable, Sendable {
    public var identity: ScanFloorIdentity
    public var storageID: UUID
    public var savedAt: Date
    /// Matches the source capture and derived scene stored by the app.
    public var captureID: String?
    public var previousVersions: [SavedFloorVersion]

    public var id: UUID { identity.id }
    public var level: Int { identity.level }
    public var name: String { identity.name }

    public init(identity: ScanFloorIdentity, storageID: UUID, savedAt: Date,
                captureID: String?, previousVersions: [SavedFloorVersion] = []) {
        self.identity = identity
        self.storageID = storageID
        self.savedAt = savedAt
        self.captureID = captureID
        self.previousVersions = previousVersions
    }
}

public struct SavedBuilding: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var floors: [SavedFloor]

    public init(id: UUID, name: String, floors: [SavedFloor] = []) {
        self.id = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "Building" : trimmed
        self.floors = floors
    }
}

public struct SavedFloorSelection: Codable, Equatable, Sendable {
    public var buildingID: UUID
    public var floorID: UUID

    public init(buildingID: UUID, floorID: UUID) {
        self.buildingID = buildingID
        self.floorID = floorID
    }
}

public enum SavedFloorStorageError: Error, LocalizedError, Equatable {
    case invalidCatalog
    case invalidCaptureID
    case duplicateFloorLevel
    case missingFloor

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The saved building list could not be read."
        case .invalidCaptureID: "The saved scan could not be identified."
        case .duplicateFloorLevel: "This floor has already been saved. Choose that floor to scan it again."
        case .missingFloor: "That saved floor is no longer available."
        }
    }
}

/// One publication record for completed floor assets and the selected map.
/// The app writes this only after every file belonging to a save is ready.
public struct SavedFloorRegistry: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var buildings: [SavedBuilding]
    public var selection: SavedFloorSelection?

    public init(buildings: [SavedBuilding] = [], selection: SavedFloorSelection? = nil) {
        schemaVersion = 1
        self.buildings = buildings
        self.selection = selection
    }

    public var selectedBuilding: SavedBuilding? {
        guard let selection else { return nil }
        return buildings.first { $0.id == selection.buildingID }
    }

    public var selectedFloor: SavedFloor? {
        guard let selection else { return nil }
        return selectedBuilding?.floors.first { $0.id == selection.floorID }
    }

    public func validate() throws {
        guard schemaVersion == 1, Set(buildings.map(\.id)).count == buildings.count else {
            throw SavedFloorStorageError.invalidCatalog
        }
        var storageIDs = Set<UUID>()
        for building in buildings {
            guard !building.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(building.floors.map(\.id)).count == building.floors.count,
                  Set(building.floors.map(\.level)).count == building.floors.count else {
                throw SavedFloorStorageError.invalidCatalog
            }
            for floor in building.floors {
                guard floor.identity.buildingID == building.id,
                      !floor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SavedFloorStorageError.invalidCatalog
                }
                let versions = floor.previousVersions + [SavedFloorVersion(
                    storageID: floor.storageID, savedAt: floor.savedAt, captureID: floor.captureID)]
                for version in versions {
                    guard version.savedAt.timeIntervalSince1970.isFinite,
                          storageIDs.insert(version.storageID).inserted else {
                        throw SavedFloorStorageError.invalidCatalog
                    }
                    if let captureID = version.captureID, UUID(uuidString: captureID) == nil {
                        throw SavedFloorStorageError.invalidCaptureID
                    }
                }
            }
        }
        if selection != nil, selectedFloor == nil { throw SavedFloorStorageError.missingFloor }
    }

    /// Records a completed save. Using an existing floor identity is an explicit rescan;
    /// its previous assets remain in the history, and other floors keep their references.
    public mutating func record(_ identity: ScanFloorIdentity, buildingName: String? = nil,
                                storageID: UUID, captureID: String?, savedAt: Date = .now) throws {
        try validate()
        if let captureID, UUID(uuidString: captureID) == nil { throw SavedFloorStorageError.invalidCaptureID }
        var updated = self
        let buildingIndex: Int
        if let existing = updated.buildings.firstIndex(where: { $0.id == identity.buildingID }) {
            buildingIndex = existing
            if let buildingName {
                let trimmed = buildingName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { updated.buildings[existing].name = trimmed }
            }
        } else {
            updated.buildings.append(SavedBuilding(id: identity.buildingID, name: buildingName ?? "Building"))
            buildingIndex = updated.buildings.count - 1
        }
        var floors = updated.buildings[buildingIndex].floors
        guard !floors.contains(where: { $0.level == identity.level && $0.id != identity.id }) else {
            throw SavedFloorStorageError.duplicateFloorLevel
        }
        var previousVersions: [SavedFloorVersion] = []
        if let index = floors.firstIndex(where: { $0.id == identity.id }) {
            let previous = floors.remove(at: index)
            previousVersions = previous.previousVersions + [SavedFloorVersion(
                storageID: previous.storageID, savedAt: previous.savedAt, captureID: previous.captureID)]
        }
        floors.append(SavedFloor(identity: identity, storageID: storageID, savedAt: savedAt,
                                 captureID: captureID, previousVersions: previousVersions))
        updated.buildings[buildingIndex].floors = floors.sorted { $0.level < $1.level }
        updated.selection = SavedFloorSelection(buildingID: identity.buildingID, floorID: identity.id)
        try updated.validate()
        self = updated
    }

    public mutating func select(buildingID: UUID, floorID: UUID) throws {
        try validate()
        guard buildings.contains(where: { $0.id == buildingID && $0.floors.contains(where: { $0.id == floorID }) }) else {
            throw SavedFloorStorageError.missingFloor
        }
        selection = SavedFloorSelection(buildingID: buildingID, floorID: floorID)
    }
}
