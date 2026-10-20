import ARKit
import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import InView

@MainActor
final class NavigationAcquisitionTests: XCTestCase {
    private func registeredSession() -> NavigationSessionAlignment {
        var alignment = NavigationSessionAlignment()
        XCTAssertFalse(alignment.start(startedAt: 10, needsOriginChange: true))
        XCTAssertEqual(alignment.next(timestamp: 11, trackingIsNormal: true), .changeOrigin)
        alignment.didChangeOrigin(at: 12)
        XCTAssertEqual(alignment.next(timestamp: 13, trackingIsNormal: true), .ready)
        return alignment
    }

    func testSameFloorResumeRetainsOriginAndAvoidsApplyingRegistrationTwice() {
        var alignment = registeredSession()

        XCTAssertTrue(alignment.start(startedAt: 20, needsOriginChange: true))
        XCTAssertFalse(alignment.isReady, "A resumed session must first deliver a current camera pose")
        XCTAssertEqual(alignment.next(timestamp: 21, trackingIsNormal: true), .ready,
                       "The saved registration is already applied to this session's origin")
        XCTAssertEqual(alignment.next(timestamp: 22, trackingIsNormal: true), .ready)
        XCTAssertTrue(alignment.isReady)
    }

    func testResumeRejectsStaleAndLimitedFramesBeforeRestoringPosition() {
        var alignment = registeredSession()
        XCTAssertTrue(alignment.start(startedAt: 20, needsOriginChange: true))

        for timestamp in [13.0, 19.9, 20.0] {
            XCTAssertEqual(alignment.next(timestamp: timestamp, trackingIsNormal: true), .wait)
        }
        XCTAssertEqual(alignment.next(timestamp: 21, trackingIsNormal: false), .wait)
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 22, trackingIsNormal: true), .ready)
    }

    func testExplicitRetryDiscardsReusableOriginAndWaitsForItsReplacement() {
        var alignment = registeredSession()

        XCTAssertFalse(alignment.start(startedAt: 20, needsOriginChange: true, forceReset: true))
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 13, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 21, trackingIsNormal: true), .changeOrigin)
        alignment.didChangeOrigin(at: 22)
        XCTAssertEqual(alignment.next(timestamp: 22, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 23, trackingIsNormal: true), .ready)
    }

    func testFloorChangeCannotReusePreviousFloorOrigin() {
        var alignment = registeredSession()
        alignment.invalidate()

        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 14, trackingIsNormal: true), .wait)
        XCTAssertFalse(alignment.start(startedAt: 20, needsOriginChange: true))
        XCTAssertEqual(alignment.next(timestamp: 21, trackingIsNormal: true), .changeOrigin)
        alignment.didChangeOrigin(at: 22)
        XCTAssertEqual(alignment.next(timestamp: 23, trackingIsNormal: true), .ready)
    }

    func testInterruptedOriginAdjustmentCannotBeReused() {
        for originWasApplied in [false, true] {
            var alignment = NavigationSessionAlignment()
            XCTAssertFalse(alignment.start(startedAt: 10, needsOriginChange: true))
            XCTAssertEqual(alignment.next(timestamp: 11, trackingIsNormal: true), .changeOrigin)
            if originWasApplied { alignment.didChangeOrigin(at: 12) }

            XCTAssertFalse(alignment.start(startedAt: 20, needsOriginChange: true),
                           "Only a completed localization can be reused")
            XCTAssertEqual(alignment.next(timestamp: 21, trackingIsNormal: true), .changeOrigin)
            alignment.didChangeOrigin(at: 22)
            XCTAssertEqual(alignment.next(timestamp: 22, trackingIsNormal: true), .wait)
            XCTAssertEqual(alignment.next(timestamp: 23, trackingIsNormal: true), .ready)
        }
    }

    func testLocalMapWithoutRegistrationCanResumeItsEstablishedOrigin() {
        var alignment = NavigationSessionAlignment()
        XCTAssertFalse(alignment.start(startedAt: 10, needsOriginChange: false))
        XCTAssertEqual(alignment.next(timestamp: 11, trackingIsNormal: true), .ready)

        XCTAssertTrue(alignment.start(startedAt: 20, needsOriginChange: false))
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 20, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 21, trackingIsNormal: true), .ready)
    }

    func testAcquisitionConfigurationDefersNavigationSensors() {
        let configuration = NavigationController.configuration(isAcquiring: true)

        XCTAssertTrue(configuration.planeDetection.isEmpty)
        XCTAssertTrue(configuration.frameSemantics.isEmpty)
        XCTAssertTrue(configuration.sceneReconstruction.isEmpty)
        XCTAssertNil(configuration.initialWorldMap)
    }

    func testNavigationConfigurationRestoresFloorAndObstacleDepthWithoutMeshing() {
        let configuration = NavigationController.configuration(isAcquiring: false)

        XCTAssertEqual(configuration.planeDetection, [.horizontal])
        XCTAssertEqual(configuration.frameSemantics.contains(.sceneDepth),
                       ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
        XCTAssertFalse(configuration.frameSemantics.contains(.smoothedSceneDepth))
        XCTAssertTrue(configuration.sceneReconstruction.isEmpty)
    }

    func testCameraPreviewOrientsAndDownsamplesCopiedPixels() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)

        func fill(red: UInt8, blue: UInt8) throws {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
            base.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetDataSize(pixels))
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<480 {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<640 {
                    row[x * 4] = blue
                    row[x * 4 + 1] = 0
                    row[x * 4 + 2] = red
                    row[x * 4 + 3] = 255
                }
            }
        }

        func renderedColor(_ image: CGImage) throws -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4,
                    space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba
        }

        try fill(red: 255, blue: 0)
        let snapshot = try XCTUnwrap(FrameEncoder.snapshot(pixels))
        try fill(red: 0, blue: 255)

        let portrait = try XCTUnwrap(FrameEncoder.preview(from: snapshot, orientation: .right))
        let landscape = try XCTUnwrap(FrameEncoder.preview(from: snapshot, orientation: .up))
        XCTAssertEqual(portrait.width, 240)
        XCTAssertEqual(portrait.height, 320)
        XCTAssertEqual(landscape.width, 320)
        XCTAssertEqual(landscape.height, 240)
        XCTAssertEqual(try renderedColor(portrait), [255, 0, 0, 255],
                       "Rendering must use the snapshot after ARKit reuses the original buffer")
        XCTAssertEqual(try renderedColor(landscape), [255, 0, 0, 255])
        let changed = try XCTUnwrap(FrameEncoder.snapshot(pixels))
        let changedPreview = try XCTUnwrap(FrameEncoder.preview(from: changed, orientation: .up))
        XCTAssertEqual(try renderedColor(changedPreview), [0, 0, 255, 255])
    }
}
