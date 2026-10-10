import ARKit
import AccessCore
import ImageIO

/// The printed check-in sign. Scanning and navigation both find it, which puts them in one shared venue frame.
enum Marker {
    static let name = "check-in-marker"
    /// Printed width in meters. Must match print/check-in-marker.pdf at 100% scale.
    static let physicalWidth: CGFloat = 0.18

    static let referenceImage: ARReferenceImage? = {
        guard let url = Bundle.main.url(forResource: "marker", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: physicalWidth)
        reference.name = name
        return reference
    }()
}

/// Collects tracked sightings of the marker and averages them into a venue frame.
struct MarkerSampler {
    static let requiredSamples = 15

    private var transforms: [simd_float4x4] = []

    var progress: Double { min(1, Double(transforms.count) / Double(Self.requiredSamples)) }

    var venueFrame: VenueFrame? {
        transforms.count >= Self.requiredSamples ? VenueFrame(markerTransforms: transforms) : nil
    }

    mutating func add(_ frame: ARFrame) {
        let anchor = frame.anchors.lazy
            .compactMap { $0 as? ARImageAnchor }
            .first { $0.referenceImage.name == Marker.name && $0.isTracked }
        if let anchor { transforms.append(anchor.transform) }
    }
}
