import AccessCore
import ARKit
import MetalKit
import RoomPlan
import XCTest
@testable import InView

@MainActor
final class ScanPreviewRendererTests: XCTestCase {
    nonisolated private static func isMainThread() -> Bool {
        Thread.isMainThread
    }

    private func emptyRoom() throws -> CapturedRoom {
        let data = try JSONSerialization.data(withJSONObject: [
            "identifier": UUID().uuidString, "version": 3, "story": 0,
            "walls": [], "doors": [], "openings": [], "windows": [],
            "floors": [], "objects": [], "sections": []
        ])
        return try JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    func testMetalPipelinesCompileAndReleasingGeometryClearsTheBuffer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Compiles both camera and outline shaders on the actual Metal device.
        let renderer = try XCTUnwrap(ScanPreviewRenderer(device: device, pixelFormat: .bgra8Unorm))
        renderer.setLines([.init(start: [0, 0, -1], end: [1, 0, -1])])
        XCTAssertEqual(renderer.lineCount, 1)
        renderer.setLines([])
        XCTAssertEqual(renderer.lineCount, 0)
        renderer.setLines([.init(start: [0, 0, -1], end: [1, 0, -1])])
        renderer.clear()
        XCTAssertEqual(renderer.lineCount, 0)
    }

    func testMetalBufferHasAHardLimitEvenWithDenseInput() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(ScanPreviewRenderer(device: device, pixelFormat: .bgra8Unorm))
        renderer.setLines(Array(repeating: .init(start: [0, 0, -1], end: [1, 0, -1]), count: 10_000))
        XCTAssertEqual(renderer.lineCount, 1_536)
    }

    func testBackgroundSelectionBuildsAnImmutableBufferThatTheRendererCanPublish() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(ScanPreviewRenderer(device: device, pixelFormat: .bgra8Unorm))
        let first = ScanPreviewLine(start: [0, 0, -1], end: [1, 0, -1])
        let other = ScanPreviewLine(start: [100, 0, -1], end: [101, 0, -1])
        let (prepared, ranOnMainThread) = await Task.detached(priority: .utility) {
            var index = ScanPreviewIndex()
            index.replace(with: [.init(id: UUID(), lines: [first]), .init(id: UUID(), lines: [other])])
            return (ScanPreviewPreparedLines.make(from: index.nearbyLines(to: .zero), device: device),
                    Self.isMainThread())
        }.value
        XCTAssertFalse(ranOnMainThread)
        XCTAssertEqual(prepared.count, 1)
        let buffer = try XCTUnwrap(prepared.buffer)
        // Check the published world-space endpoints, including the SIMD padding used by Metal.
        XCTAssertEqual(buffer.length, MemoryLayout<SIMD4<Float>>.stride * 2)
        XCTAssertEqual(buffer.contents().load(as: SIMD4<Float>.self), SIMD4(first.start, 1))
        XCTAssertEqual(buffer.contents().advanced(by: MemoryLayout<SIMD4<Float>>.stride)
            .load(as: SIMD4<Float>.self), SIMD4(first.end, 1))
        renderer.setPreparedLines(prepared)
        XCTAssertEqual(renderer.lineCount, 1)
        renderer.clear()
        // Releasing the renderer's handle cannot invalidate a worker's immutable result.
        XCTAssertEqual(buffer.contents().load(as: SIMD4<Float>.self), SIMD4(first.start, 1))
    }

    func testClearingRoomRejectsOldWorkerResultsAndProcessesTheNewRoom() async throws {
        let session = ARSession()
        let view = ScanPreviewCameraView(session: session)
        let completed = expectation(description: "New room measurements published")
        var observations: [TimeInterval?] = []
        view.onMeasurementsReady = { measurements in
            observations.append(measurements.observedAt)
            XCTAssertEqual(measurements.observedAt, 200)
            completed.fulfill()
        }
        view.update(room: try emptyRoom(), observedAt: 100)
        // The main actor cannot accept the old result before this synchronous reset.
        view.clearRoom()
        view.update(room: try emptyRoom(), observedAt: 200)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(observations.count, 1)
        view.stop()
    }
}
