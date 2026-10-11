import AccessCore
import UIKit
import Vision
import XCTest
@testable import InView

final class SignReaderTests: XCTestCase {
    /// Real Apple Vision OCR on a rendered door plate: two lines become one sign, measured with depth.
    func testReadsAPlateAsOneMeasuredSign() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor(white: 0.85, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.white.setFill(); context.fill(CGRect(x: 150, y: 300, width: 300, height: 200))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 80, weight: .bold), .foregroundColor: UIColor.black]
            ("204" as NSString).draw(at: CGPoint(x: 230, y: 320), withAttributes: attributes)
            ("MEETING ROOM" as NSString).draw(at: CGPoint(x: 175, y: 430), withAttributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.black])
            ("Free pizza Friday at noon" as NSString).draw(at: CGPoint(x: 40, y: 720), withAttributes: [
                .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        // Sensor-native intrinsics are landscape; the upright test image is portrait.
        let frame = CaptureDepthFrame(id: "live", timestampSeconds: 1,
            mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1.4, 0, 1],
            camera: CaptureCameraCalibration(imageWidth: 800, imageHeight: 600, fx: 600, fy: 600, cx: 400, cy: 300),
            depth: CaptureDepthImage(width: 256, height: 192, valuesM: Array(repeating: 1.5, count: 256 * 192),
                                     confidence: Array(repeating: 2, count: 256 * 192)))
        var cropped: CGRect?
        let plate = try XCTUnwrap(SignReader.read(handler: VNImageRequestHandler(cgImage: cgImage, orientation: .up),
                                                  depthFrame: { frame }, crop: { cropped = $0; return Data([1]) }))
        XCTAssertEqual(plate.reading.category, .room)
        XCTAssertEqual(plate.reading.title, "Room 204")
        XCTAssertEqual(plate.reading.detail, "Meeting Room")
        let position = try XCTUnwrap(plate.position)
        XCTAssertEqual(position.z, -1.5, accuracy: 0.001)
        // The plate sits near the middle of the image, so near the optical axis.
        XCTAssertLessThan(abs(position.x), 0.3)
        XCTAssertLessThan(abs(position.y - 1.4), 0.3)
        let crop = try XCTUnwrap(cropped)
        XCTAssertTrue(crop.contains(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(plate.box.midX, 0.5, accuracy: 0.1)
    }
}
