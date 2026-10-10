import AccessCore
import Testing

@Test func longCorridorSavesBeforeRoomFitStopsGrowing() {
    var policy = ScanSectionPolicy()
    let save5 = policy.shouldSave(position: [0, 0], timestamp: 10)
    #expect(!save5)
    let save6 = policy.shouldSave(position: [0, 6], timestamp: 30)
    #expect(!save6)
    let save7 = policy.shouldSave(position: [0, 7.1], timestamp: 40)
    #expect(save7)
    policy.reset()
    let save9 = policy.shouldSave(position: [0, 7.1], timestamp: 41)
    #expect(!save9)
    let save10 = policy.shouldSave(position: [0, 8], timestamp: 60)
    #expect(!save10)
}

@Test func sectionPolicyUsesObservedSpanInsteadOfTravelDistance() {
    var policy = ScanSectionPolicy()
    for second in 0..<100 {
        let save16 = policy.shouldSave(position: [Float(second % 2), 0], timestamp: Double(second))
        #expect(!save16)
    }
    let save18 = policy.shouldSave(position: [0, 0], timestamp: 120)
    #expect(save18)
}

@Test func sectionPolicyRejectsInvalidTrackingAndSettlingMovement() {
    var policy = ScanSectionPolicy()
    let save23 = policy.shouldSave(position: [.nan, 0], timestamp: 0)
    #expect(!save23)
    let save24 = policy.shouldSave(position: [0, 0], timestamp: .infinity)
    #expect(!save24)
    let save25 = policy.shouldSave(position: [0, 0], timestamp: 100)
    #expect(!save25)
    let save26 = policy.shouldSave(position: [0, 20], timestamp: 99)
    #expect(!save26)
    let save27 = policy.shouldSave(position: [0, 8], timestamp: 110)
    #expect(!save27)
    let save28 = policy.shouldSave(position: [0, 8], timestamp: 115)
    #expect(save28)
}

@Test func recoveredFloorExtensionIsKeptDespiteOverlap() {
    let room = Footprint(floor: [[0, 0], [5, 0], [5, 5], [0, 5]], bottom: 0)
    let corridor = Footprint(floor: [[3, 3], [5, 3], [5, 25], [3, 25]], bottom: 0)
    #expect(MeasuredFootprintRecovery.shouldKeep(corridor, alongside: [room]))
    #expect(!MeasuredFootprintRecovery.shouldKeep(room, alongside: [room, corridor]))
}

@Test func recoveredFloorInsideConcaveBoundingBoxIsKept() {
    let room = Footprint(floor: [[0, 0], [5, 0], [5, 2], [2, 2], [2, 5], [0, 5]], bottom: 0)
    let extensionFloor = Footprint(floor: [[2, 2], [4, 2], [4, 4], [2, 4]], bottom: 0)
    #expect(MeasuredFootprintRecovery.shouldKeep(extensionFloor, alongside: [room]))
}

@Test func recoveredWallExtensionAndOtherFloorAreKept() {
    let wall = Footprint(kind: .wall, center: [0, 0], size: [4, 0.15], yaw: 0, bottom: 0)
    let extensionWall = Footprint(kind: .wall, center: [3, 0], size: [4, 0.15], yaw: 0, bottom: 0)
    #expect(MeasuredFootprintRecovery.shouldKeep(extensionWall, alongside: [wall]))
    #expect(!MeasuredFootprintRecovery.shouldKeep(wall, alongside: [wall]))
    let floor = Footprint(floor: [[0, 0], [5, 0], [5, 5], [0, 5]], bottom: 0)
    var upstairs = floor; upstairs.bottom = 3
    #expect(MeasuredFootprintRecovery.shouldKeep(upstairs, alongside: [floor]))
}

@Test func depthClutterInsideKnownWallOrFurnitureIsNotDuplicated() {
    let bag = Footprint(kind: .obstacle, center: [0, 0], size: [0.2, 0.1], yaw: 0, bottom: 0.2, height: 0.2)
    let wall = Footprint(kind: .wall, center: [0, 0], size: [4, 0.15], yaw: 0, bottom: 0, height: 2.5)
    let table = Footprint(kind: .obstacle, center: [0, 0], size: [1, 1], yaw: 0, bottom: 0, height: 0.7)
    #expect(!MeasuredFootprintRecovery.shouldKeep(bag, alongside: [wall]))
    #expect(!MeasuredFootprintRecovery.shouldKeep(bag, alongside: [table]))
    var adjacent = bag; adjacent.center.y = 0.6
    #expect(MeasuredFootprintRecovery.shouldKeep(adjacent, alongside: [wall, table]))
    var above = bag; above.bottom = 3
    #expect(MeasuredFootprintRecovery.shouldKeep(above, alongside: [table]))
}
