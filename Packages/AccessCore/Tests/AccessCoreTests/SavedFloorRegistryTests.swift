import Foundation
import Testing
@testable import AccessCore

@Test func initialFloorNamesSupportGroundBasementsAndNamedFloors() {
    #expect(ScanFloorIdentity(level: 0).name == "Ground floor")
    #expect(ScanFloorIdentity(level: -1).name == "Floor -1")
    #expect(ScanFloorIdentity(level: 3, name: "  Main lobby  ").name == "Main lobby")
    #expect(ScanFloorIdentity(level: 2, name: " \n ").name == "Floor 2")
}

@Test func savingAnotherFloorKeepsThePreviousFloorAndMatchingCaptures() throws {
    let buildingID = UUID()
    let downstairs = ScanFloorIdentity(buildingID: buildingID, level: 1)
    let upstairs = ScanFloorIdentity(buildingID: buildingID, level: 2)
    let firstStorage = UUID(), secondStorage = UUID()
    let firstCapture = UUID().uuidString, secondCapture = UUID().uuidString
    var registry = SavedFloorRegistry()
    try registry.record(downstairs, buildingName: "Library", storageID: firstStorage, captureID: firstCapture)
    try registry.record(upstairs, storageID: secondStorage, captureID: secondCapture)

    #expect(registry.buildings.count == 1)
    #expect(registry.selectedBuilding?.name == "Library")
    #expect(registry.selectedBuilding?.floors.map(\.level) == [1, 2])
    #expect(registry.selectedFloor?.captureID == secondCapture)
    try registry.select(buildingID: buildingID, floorID: downstairs.id)
    #expect(registry.selectedFloor?.storageID == firstStorage)
    #expect(registry.selectedFloor?.captureID == firstCapture)
}

@Test func explicitRescanRetainsImmutablePriorVersions() throws {
    let identity = ScanFloorIdentity(level: 2)
    let firstStorage = UUID(), secondStorage = UUID(), thirdStorage = UUID()
    let firstCapture = UUID().uuidString
    var registry = SavedFloorRegistry()
    try registry.record(identity, storageID: firstStorage, captureID: firstCapture)
    try registry.record(identity, storageID: secondStorage, captureID: nil)
    try registry.record(identity, storageID: thirdStorage, captureID: UUID().uuidString)

    let floor = try #require(registry.selectedFloor)
    #expect(registry.selectedBuilding?.floors.count == 1)
    #expect(floor.storageID == thirdStorage)
    #expect(floor.previousVersions.map(\.storageID) == [firstStorage, secondStorage])
    #expect(floor.previousVersions.first?.captureID == firstCapture)
}

@Test func failedRecordDoesNotReplaceSelectionOrExistingFloor() throws {
    let identity = ScanFloorIdentity(level: 1)
    let storageID = UUID()
    var registry = SavedFloorRegistry()
    try registry.record(identity, buildingName: "Original building", storageID: storageID, captureID: nil)
    let published = registry

    let accidentalDuplicate = ScanFloorIdentity(buildingID: identity.buildingID, level: identity.level)
    #expect(throws: SavedFloorStorageError.duplicateFloorLevel) {
        try registry.record(accidentalDuplicate, buildingName: "Changed", storageID: UUID(), captureID: nil)
    }
    #expect(registry == published)
    #expect(throws: SavedFloorStorageError.invalidCaptureID) {
        try registry.record(identity, storageID: UUID(), captureID: "../../another-scan")
    }
    #expect(registry == published)
    #expect(throws: SavedFloorStorageError.invalidCatalog) {
        try registry.record(identity, storageID: storageID, captureID: nil)
    }
    #expect(registry == published)
    #expect(throws: SavedFloorStorageError.missingFloor) {
        try registry.select(buildingID: identity.buildingID, floorID: UUID())
    }
    #expect(registry == published)
}

@Test func buildingsKeepIndependentFloorsAndSurviveRoundTrip() throws {
    let firstFloor = ScanFloorIdentity(level: 1), secondFloor = ScanFloorIdentity(level: 1)
    var registry = SavedFloorRegistry()
    try registry.record(firstFloor, buildingName: "Library", storageID: UUID(), captureID: UUID().uuidString)
    try registry.record(secondFloor, buildingName: "Museum", storageID: UUID(), captureID: UUID().uuidString)
    let data = try JSONEncoder().encode(registry)
    var restored = try JSONDecoder().decode(SavedFloorRegistry.self, from: data)
    try restored.validate()
    #expect(restored == registry)
    try restored.select(buildingID: firstFloor.buildingID, floorID: firstFloor.id)
    #expect(restored.selectedBuilding?.name == "Library")
    #expect(restored.selectedFloor?.identity == firstFloor)
    #expect(restored.buildings.last?.floors.first?.identity == secondFloor)
}

@Test func malformedSavedIdentitiesCannotEscapeStorageDirectories() throws {
    let identity = ScanFloorIdentity(level: 1)
    var registry = SavedFloorRegistry()
    try registry.record(identity, storageID: UUID(), captureID: nil)
    let data = try JSONEncoder().encode(registry)
    let json = try #require(String(data: data, encoding: .utf8))
    let malicious = json.replacingOccurrences(of: identity.id.uuidString, with: "../../other-building")
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SavedFloorRegistry.self, from: Data(malicious.utf8))
    }

    registry.buildings[0].floors[0].identity.buildingID = UUID()
    #expect(throws: SavedFloorStorageError.invalidCatalog) { try registry.validate() }
}

@Test func corruptedCatalogCannotPublishAnotherSelection() throws {
    let identity = ScanFloorIdentity(level: 1)
    var registry = SavedFloorRegistry()
    try registry.record(identity, storageID: UUID(), captureID: nil)
    registry.selection = SavedFloorSelection(buildingID: identity.buildingID, floorID: UUID())
    let corrupt = registry
    #expect(throws: SavedFloorStorageError.missingFloor) {
        try registry.select(buildingID: identity.buildingID, floorID: identity.id)
    }
    #expect(registry == corrupt)
}

@Test func removingTheSelectedFloorSelectsTheLowestRemainingFloorOfItsBuilding() throws {
    let buildingID = UUID()
    let ground = ScanFloorIdentity(buildingID: buildingID, level: 0)
    let first = ScanFloorIdentity(buildingID: buildingID, level: 1)
    let second = ScanFloorIdentity(buildingID: buildingID, level: 2)
    var registry = SavedFloorRegistry()
    try registry.record(second, buildingName: "Library", storageID: UUID(), captureID: nil)
    try registry.record(first, storageID: UUID(), captureID: nil)
    try registry.record(ground, storageID: UUID(), captureID: nil)
    try registry.record(second, storageID: UUID(), captureID: nil)
    #expect(registry.selectedFloor?.id == second.id)

    let removed = try registry.removeFloor(buildingID: buildingID, floorID: second.id)
    #expect(removed.allVersions.count == 2)
    #expect(registry.selectedFloor?.id == ground.id)
    #expect(registry.selectedBuilding?.floors.map(\.level).sorted() == [0, 1])
    try registry.validate()
}

@Test func removingAnUnselectedFloorKeepsTheSelectionAndTheLastFloorRemovesItsBuilding() throws {
    let library = ScanFloorIdentity(level: 1)
    let gym = ScanFloorIdentity(level: 1)
    var registry = SavedFloorRegistry()
    try registry.record(library, buildingName: "Library", storageID: UUID(), captureID: nil)
    try registry.record(gym, buildingName: "Gym", storageID: UUID(), captureID: nil)
    try registry.removeFloor(buildingID: library.buildingID, floorID: library.id)
    #expect(registry.buildings.map(\.name) == ["Gym"])
    #expect(registry.selectedFloor?.id == gym.id)
    try registry.removeFloor(buildingID: gym.buildingID, floorID: gym.id)
    #expect(registry.buildings.isEmpty)
    #expect(registry.selection == nil)
    try registry.validate()
    #expect(throws: SavedFloorStorageError.missingFloor) {
        try registry.removeFloor(buildingID: gym.buildingID, floorID: gym.id)
    }
}

@Test func removingABuildingRemovesEveryFloorAndClearsItsSelection() throws {
    let buildingID = UUID()
    var registry = SavedFloorRegistry()
    try registry.record(ScanFloorIdentity(buildingID: buildingID, level: 1), buildingName: "Library", storageID: UUID(), captureID: nil)
    try registry.record(ScanFloorIdentity(buildingID: buildingID, level: 2), storageID: UUID(), captureID: nil)
    let removed = try registry.removeBuilding(buildingID)
    #expect(removed.count == 2)
    #expect(registry.buildings.isEmpty && registry.selection == nil)
    try registry.validate()
}
