/// Chooses which of ARKit's floor planes is the floor the person is on.
///
/// ARKit keeps plane anchors from every level it has seen, so across stairs, an elevator or an open
/// atrium the lowest plane is often another storey. Only a plane a plausible phone height below the
/// camera can be the surface underfoot: hand-held at 0.9...1.9 m, a wheelchair lap mount lower still.
public enum FloorPlaneSelection {
    /// How far below the camera the walking surface can be.
    public static let phoneHeightAboveFloor: ClosedRange<Float> = 0.5...2.4

    /// The lowest plausible floor plane (so a platform or ramp lip never becomes the reference), or nil
    /// when none is a believable distance below the camera.
    public static func floorHeight(cameraY: Float, planeHeights: [Float]) -> Float? {
        planeHeights.filter { phoneHeightAboveFloor.contains(cameraY - $0) }.min()
    }
}
