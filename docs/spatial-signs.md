# On-device OCR and spatial signs

The Mogo sign-recognition approach is integrated into InView's existing calibrated capture pipeline, rather than starting a second AR session or replacing RoomPlan's delegate. No API key or backend is needed for live OCR.

## What appears while scanning

Readable room numbers/room labels, direction signs, exits, elevators/lifts, stairs and restrooms produce mint-bordered camera labels **only when matched LiDAR depth supports a position**. Labels include measured local `x`, `y`, `z` in meters and height above the reference floor when available. The overlay projects fixed map positions through the current camera pose; it does not pin labels to their original screen pixels. It culls behind-camera/off-screen points and limits the display to ten nearby deduplicated labels.

Rules recognize English keywords, room-number patterns, explicit direction words, and arrow characters returned by Vision. Pictograms and arrows that Vision does not transcribe are not detected. A directional exit sign is the position of the *sign*, not the door it points toward. Signs never automatically become verified destinations, routing portals, or evacuation instructions.

## Reusable components

- `Packages/AccessCore/Sources/AccessCore/SpatialSigns.swift`: public `SignMeaning.classify` and `SignLocalizer.locate`, portable classification/localization independent of camera hardware and Vision.
- `InView/Detection/TextRecognizer.swift`: Apple Vision OCR, accepts upright JPEGs or sensor-native JPEGs plus optional `Calibration`. Language correction is disabled to preserve room identifiers.
- `CaptureTextObservation.spatial`: additive optional metric result; old schema-1 documents still decode.

To reuse: recognize a line into `CaptureTextObservation`, then pass the exact matching `CaptureDepthFrame`, optional floor datum, environment sample, and geographic map reference to `SignLocalizer.locate`. Never pair an older OCR image with the latest camera pose.

## Capture and export

The existing bounded depth worker now recognizes each retained color keyframe. It copies pixels/depth before background work, allows one worker at a time, and budgets live OCR to 0.8 seconds per image (at most 32 lines). Depth keyframe selection remains pose-based, at least two seconds apart, or ten seconds when stationary. This is live sampled recognition, not per-video-frame inference.

Observations remain paired with retained evidence frames and are evicted with them. They are included in `raw-snapshot.json`, and `text-observations.json` is saved when capture finishes—even without **Find places**. **Find places** can run the existing bounded high-resolution pass. **Save** refreshes geographic placement without changing local positions or discarding that pass. Exported capture packages already include the text sidecar.

`text-observations.json` retains schema version 1 and the existing backend-compatible OCR fields. New fields are additive. A localized observation has this shape (illustrative values):

```json
{
  "schema_version": 1,
  "engine": "apple_vision",
  "capture_id": "capture-uuid",
  "observations": [{
    "frame_id": "frame-uuid",
    "image_asset": "frame-uuid.color.jpg",
    "image_size_px": [960, 1280],
    "image_orientation": "upright_rotated_right_from_sensor",
    "bbox_norm": [0.3, 0.3, 0.4, 0.4],
    "bbox_sensor_norm": [0.3, 0.3, 0.4, 0.4],
    "text": "ROOM 204 →",
    "confidence": 0.95,
    "languages": ["en"],
    "spatial": {
      "meaning": {"kind": "room", "directions": ["right"]},
      "x": 10, "y": 3, "z": 18,
      "floor_id": "floor-uuid",
      "floor_elevation_m": 1,
      "height_above_floor_m": 2,
      "timestamp_seconds": 100,
      "depth_m": 2,
      "depth_sample_count": 9,
      "depth_spread_m": 0.02,
      "position_source": "lidar_depth_median",
      "coordinate_frame": "capture_map_meters_y_up",
      "destination_verified": false
    }
  }]
}
```

### Position and elevation datums

- `x/y/z`: metric AR map coordinates; **y is up**, not GPS altitude. The capture ID identifies the coordinate frame. Separate captures require alignment before their coordinates can be combined.
- `floor_id`: the floor selected by the mapper, not a floor inferred from the sign's text.
- `floor_elevation_m`: measured reference floor y (near the capturing camera during live capture; reviewed map floor during finish-time recognition).
- `height_above_floor_m`: sign y minus that reference floor. Across an atrium/stairwell this is not necessarily the floor immediately below the sign.
- `latitude/longitude`: populated only using a valid explicitly placed `BuildingMapReference`. Camera GPS coordinates are **not** silently used as sign coordinates. Map reference heading rotates the arbitrary AR map axes into the geographic frame.
- `altitude_msl_m`: when valid GPS vertical data exists, camera GPS altitude plus the sign-camera local y difference. GPS altitude can be inaccurate indoors and is independent of the user-placed horizontal map reference.
- `horizontal_accuracy_m` and `vertical_accuracy_m`: source sensor/reference accuracy, **not** a bound on total sign-position error.
- `environment`: optional camera GPS, heading, pressure and relative barometric altitude at capture time. Location/heading older than five seconds are omitted. Barometric relative altitude is camera movement relative to that active sensing interval, not sign altitude or a building floor number.
- `timestamp_seconds`: AR monotonic uptime; `environment.recorded_at_unix_seconds` is wall-clock time.
- `meaning.directions`: relative to the printed text; never a world-space route vector.

Unavailable fields are omitted, not replaced by zero. Unlocalized text remains in the sidecar without `spatial`.

## Measurement safeguards and limits

Localization uses sensor-native bounding boxes, camera intrinsics, and the matching frame's column-major map-from-camera transform. It requires confidence >= 0.65, at least three medium/high-confidence depth pixels inside the text box, range 0.15–8 m, and low depth spread. It uses a median depth, not an assumed plane or guessed room depth. Missing confidence/depth or a depth discontinuity yields no 3D label.

These are measured estimates, not survey-grade “hard” ground truth. Tracking drift, sign reflections, OCR errors, thin lettering, and depth sampling can still be wrong. Hidden object extents are not measured. Existing backend processing continues to independently localize/review OCR evidence; it does not trust the new client position as verified routing geometry.

## Validation

- AccessCore tests cover semantics/directions, translated and rotated XYZ, distinct elevation datums, rejection of invalid/noisy depth, geographic placement/removal, and backward-compatible JSON.
- iOS integration test renders `ROOM 204`, runs real Apple Vision OCR, pairs it with synthetic calibrated depth, checks XYZ, and verifies local sidecar saving and later geographic placement.
- Physical-device scanning, low-light signage, and geographic accuracy still need field testing.

Use the Xcode toolchain for package tests: `cd Packages/AccessCore && xcrun swift test`.
