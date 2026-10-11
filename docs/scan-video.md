# Video with LiDAR

Enable **Record video** before starting a new scan, either on the floor picker or
in Scanning settings. The app records the shared RoomPlan ARSession's camera
images, targeting 10 frames/second at a maximum 1280-pixel long edge, without
microphone audio. It writes H.264 MP4 segments and synchronized depth to the
capture's existing `Documents/Captures/<scan-id>/` directory. Nothing is uploaded
automatically. **Find places** retains its existing bounded photo/depth request.

Scanning continues through doorways. Walking out through a door saves the room
behind you and starts the next one while video keeps recording; finishing,
changing floors, or a scanner/resource interruption ends the current capture.

In **Scanning → Saved scans**, choose **Export video + LiDAR**, then **Share
video + LiDAR**. The resulting `.inviewvideo.tar` includes the MP4s, their frame
indexes and depth/confidence bytes, `video-manifest.json`, `capture.json`, native
RoomPlan geometry and available alignment/semantic support files. It is a local
reconstruction handoff, separate from the server's 256 MiB recognition package.
Files are also available through iOS Files or Finder file sharing.

Native RoomPlan originals use JSON when serializable, with a binary `.plist`
fallback that preserves values JSON cannot represent. Both formats are included
in local exports when present. Unavailable opaque SDK source data is reported
separately from the validated room map; genuine storage or alignment failures
keep the scan in review with a retry action.

## Alignment contract

Each successfully appended video frame has a record copied from that **same
ARFrame**: ARKit capture time, movie presentation time, `map_from_camera`, sensor
intrinsics, scaled video intrinsics, world-mapping state and, when available,
native scene-depth and confidence bytes. The recording accepts fresh, normally
tracked camera frames even during depth gaps. It never infers video poses from
the separately sampled/decimated movement track. ARKit's estimated tracking
accuracy and depth uncertainty still apply;
recorded coordinates are not ground-truth positions.

`video-manifest.json` schema 2 identifies the capture, map and floor, declares
`shared_arkit_session`, meters, Y up and a right-handed coordinate frame, and
records `arkit_uptime_seconds` with a Unix-time offset. Its ordered segments name
`video-NNNN.mp4`, `video-NNNN.frames.json` and `video-NNNN.depth.bin`, with exact
byte lengths, frame counts and first/last capture times. Only successfully
finalized segments enter the manifest. Recording state, skipped samples and any
stop reason are explicit.

The app restores scene depth after RoomPlan starts on the shared ARSession,
preserving its current configuration without resetting tracking or anchors.
RoomPlan can remove requested depth semantics during startup; this matches a
[developer reproduction](https://developer.apple.com/forums/thread/763400).
Camera video still records through unavailable depth, keeping its pose and
calibration. The app shows **Recording** only after a frame reaches the encoder,
and reports unavailable depth separately. Even a zero-frame recording leaves a
manifest with its stop reason; review and Saved scans show that no video was saved.

The frame index uses column-major 4×4 transforms, matching `capture.json` and
RoomPlan. `presentation_time_seconds` is the actual movie timestamp, rounded to
one microsecond, relative to the first accepted frame in its segment. Use these
timestamps to match decoded images; do not infer capture time from frame index
or the nominal rate. Pauses, encoder backpressure and tracking loss can create
gaps. Segment times remain on the original ARKit clock throughout a floor scan;
a new floor creates a new scan/session and its own coordinate frame.

Encoded video pixels remain in sensor-native landscape orientation. The MP4
track supplies a 90° clockwise playback transform. `video_camera` intrinsics
apply to the encoded pixels **before** that display rotation; `sensor_camera`
describes the original image. A decoder which applies the track transform must
undo it before projecting sensor/video pixels. For upright normalized pixels
`(x, y)`, the sensor-normalized point is `(y, 1-x)`. No scan overlay is recorded.

For each frame, `raw_depth` identifies dimensions, pixel format, native row
stride, offset and length in that segment's depth file. Depth is little-endian
float32 meters, retaining native padding and invalid/NaN values. Optional
confidence is uint8 (ARKit levels 0, 1, 2), immediately after that frame's depth,
with its own row stride, offset and length. Nothing is quantized or resampled.
Scale the sensor intrinsics to the depth dimensions before unprojection. The
ARKit camera looks along local -Z; for a depth pixel `(u,v)` and measured depth
`d`, camera position is `[(u-cx)*d/fx, -(v-cy)*d/fy, -d, 1]`. Multiply by
`map_from_camera` to place it in the scan. Reject invalid depths and use
confidence to filter uncertain measurements.

Schema 2 frame indexes omit `raw_depth` when that exact frame has no valid depth
sample. Such frames retain real camera poses and intrinsics; do not infer or
interpolate a depth measurement for them. An all-camera segment has an empty
depth file with a declared size of zero. Schema 1 recordings remain readable and
continue to require measured depth for every frame.

## Resource and recovery limits

At most one copied RGB/depth sample is processed at a time. An actor owns encoding
and disk I/O; it keeps at most 100 frame records per segment. Segments rotate at
100 frames, 10 seconds or 32 MiB of native depth. Video stops near 2 GiB of recorded
evidence or when less than 512 MiB of free storage remains, preserving completed
segments and leaving room scanning available. The limits are checked periodically;
encoder buffering and the final segment index can add a small overhead.
Raw depth at 10 Hz can use roughly 140 MiB/minute on a device delivering 256×192
depth plus confidence, before movie/index overhead. Actual resolution, strides,
sampling and storage vary. Export needs space for a second copy of the evidence.

Recording pauses with interruptions, floor transitions, resource pauses and app
inactivity. It continues through doorways on the same floor. Finish
waits for accepted samples and seals the final segment before map assembly.
Closing early produces a partial recording. An unfinished segment after a crash
is not advertised as usable; earlier finalized files stay on the phone.

## Reconstruction use

Use video with a vision model to identify surfaces, objects, materials and signs;
use the paired depth, camera calibration and RoomPlan geometry to constrain size,
pose and scale in the original scan frame. A video-only LLM output does not provide
metric placement. Geometry fitting, texturing and a check against the measured
scan remain downstream reconstruction work; this change provides the aligned
capture/export, not an automatic model generator.

The implementation follows Apple's [ARFrame capture data](https://developer.apple.com/documentation/arkit/arframe),
[camera intrinsics](https://developer.apple.com/documentation/arkit/arcamera/intrinsics)
and [scene depth](https://developer.apple.com/documentation/arkit/arframe/scenedepth)
APIs. Automated checks exercise manifest/export validation and synthetic movie
encoding. A physical LiDAR iPhone must still verify video/depth projection,
tracking recovery, floor changes, long scans and thermal/battery performance.
