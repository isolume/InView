# Continuous scanning with RoomPlan

Choose a floor, scan the space, and tap **Finish**. New scans use RoomPlan and
build their maps on the phone. Connected rooms share one AR session; confirmed
room transitions are handled internally. Saving and reviewing a local map work
without a server. **Find places** is an explicit optional processing request during
review; it does not replace the local geometry or resume an older stream.

## Room transitions

A room is finalized only after a confirmed crossing of a measured door or opening.
The detector requires stable portal measurements, reliable tracking, movement
through the clear passage, and sustained clearance on the other side. Walking
past a doorway, looking through it, measurement jitter, or briefly stepping over
and back must not trigger a handoff. Stale measurements, tracking loss, and
implausible jumps discard pending crossings. A spatial cooldown prevents repeated
handoffs at the same doorway, including when RoomPlan changes its identifier.

Room extent, distance walked, and elapsed time never finalize a room. The former
7 m and two-minute rollover is removed, so a long scan of one large room does not
split because it passes an app threshold. RoomPlan itself can still reach a size
or processing limit. Tracking interruptions, critical heat, storage pressure, and
floor travel can also pause capture. These are explicit pauses, not silent cuts
followed by another room capture. **Continue scanning** resumes where supported;
**Finish** retries a retained room whose saving or processing failed before
finishing the map. This is not an unlimited building-wide
LiDAR capture guarantee.

A confirmed handoff briefly processes the room before continuing RoomPlan in the
shared coordinate system. The app asks the mapper to hold position; bounded ARKit
floor observations and the recorded walk continue during this normal handoff.
Depth processing pauses to leave room for RoomBuilder. Floor travel, capture
errors and finalization stop these observations. Finish becomes available after pending room work completes. Floor changes keep
separate captures and saved maps; they do not merge different floors into one
room structure.

## Finishing the map

Each room's original `CapturedRoomData` is archived as a binary property list
before `RoomBuilder` processes it. This preserves sensor values that JSON cannot
represent. If the SDK cannot serialize its opaque input, room processing still
continues; its processed native result is archived instead, with an original-data
warning. Actual file-write failures pause with the input retained for retry. Only
an out-of-space error asks the user to free storage.

One completed room uses its native result directly. Multiple completed rooms
are assembled with Apple's `StructureBuilder`, and that structure supplies both
the portable scene and navigation geometry. An SDK merge failure is not replaced
by concatenated room geometry.

The finishing operation validates finite, rigid geometry and checks that the
assembled structure remains in the original shared coordinate envelope. Original
captures are saved before this operation. Processing or alignment failure keeps
them available and leaves the previously saved map selected.

Original RoomPlan capture data remains in the local archive. Preliminary
measurements discarded by native processing are not reinserted as walls or
furniture in the finished map.
Confirmed ARKit floor observations can add exact uncovered floor regions. Gaps
and missing coverage remain open rather than becoming an invented floor slab.
Connected measured patches are retried until no more coverage can be added, so
anchor order cannot discard the far end of an observed corridor. A disconnected
patch is not connected by invented geometry.

## Capture guidance and review

RoomPlan instructions provide short prompts about speed, light and wall distance.
The app also prompts for a downward view when neither RoomPlan nor ARKit has
measured floor under the phone. Doorway handoffs use a measured floor elevation.

**Check scan** compares the mapper's recorded walk with the finished measured
floor. Dashed segments mark missing coverage along that walk. The trace is bounded
to 4,096 samples and breaks across tracking loss, stale poses, implausible jumps
and explicit pauses. An incomplete assessment is labeled as partial. This check
cannot detect every unvisited room or certify complete building coverage, and
the walk never becomes routing geometry.

The review also flags missing floor outlines, doorway widths, ramp slopes and
destinations. Accessibility reports include measured openings as well as doors,
retain unknown measurements as unknown, and show findings instead of a letter
grade that could imply an incomplete scan is accessible.

`LocalSceneBuilder` retains the existing bundled furniture catalog. RoomPlan's
categories, measured dimensions, and placement select and position those models;
unsupported categories use neutral measured shapes. This preserves custom model
styling without requiring server furniture recognition. It does not identify an
exact furniture brand or reconstruct unseen object details.

Review and navigation derive a separate finished display with measured floor
polygons, clean wall cutaways, furniture, and place labels. Framing follows the
actual floor polygons and visible geometry; near walls keep a 50 cm cutaway in
3D. Preparation runs in the background and resets when the displayed floor
changes, keeping the original coordinate frame, routing coverage, obstacles, and
saved evidence intact.

Earlier depth-only scenes can still derive supported flat floor and upright wall
panels. Measured openings and missing coverage stay open, and small isolated
fragments are omitted. This is display preparation, not semantic room recognition
or photoreal reconstruction. It accepts up to 200,000 mesh triangles, 400,000
vertices, and 4,000 surfaces, objects, or supplied floor outlines each, with
additional bounded geometry work. Inputs above those display limits show **Map
unavailable** while saved originals remain available.

## Optional detail and place suggestions

**Scanning → Detailed scan** adds a bounded native mesh and photos to new captures.
It is off by default. Original RoomPlan inputs and the raw snapshot are secured
before optional mesh compaction or coloring. The structural map remains usable
when detail fails, and **Try detail again** retries from the same originals.
**Map appearance → Scan detail** selects the matching derived display without
changing floor coverage, destination positions or routing geometry. Classified
meshes are limited to 150,000 triangles and 200,000 vertices. Photo coloring shares
a fixed work budget and supports cancellation. Long-scan memory, battery and
finish latency still require testing on a LiDAR phone.

New captures retain up to six paired depth/photo keyframes within the existing
8 MiB selected-evidence budget, plus bounded movement and environment samples.
**Find places** sends an immutable package of those indexed photos, measurements,
location and reviewed semantics to the configured processing server. It does not
send the original native room archives or adopt the server's reconstructed map.
Suggestions preserve their measured positions and floor identity; each has an
individual **Keep** or **Drop** action. Saving refreshes the reviewed semantic
sidecar. Confirmed phone points retain their identity and edits.

## Originals and export

Local archives are under `Documents/Captures/<scan UUID>/`:

- `roomplan-source/*.plist`: each original room input, written before native room
  processing, including inputs whose processing failed. Use `PropertyListDecoder`
  to decode these inputs; earlier JSON originals remain supported by export.
- `roomplan-rooms/*.plist`: processed native room results retained when the SDK
  cannot serialize an original input.
- `roomplan.json`: completed native room results.
- `roomplan-structure.json`: the assembled native structure for a multi-room scan.
- `raw-snapshot.json`: bounded selected depth observations, supplemental live
  measurements and the optional recorded walk, separate from finished geometry.
- `capture.json` and `scene.json`: the portable projection and cached local scene.
- `package-manifest.json` and indexed depth/photo files: bounded processing evidence.
- `semantics.json`, `text-observations.json` and `camera-track.json`: reviewed points,
  text candidates and movement evidence in the same scan frame.
- `detail.json`: optional derived surface capture and scene, saved together;
  these never replace the canonical capture or structural scene.

Open **Scanning → Saved scans** to view a saved map or **Export original scan**.
The export includes available original room inputs, completed rooms, structure,
raw snapshot, and portable capture. Opening the list and exporting do not send
scan data to a server. A capture can appear with originals available even when no
finished map could be produced.

New RoomPlan scans retain a bounded depth archive, not every sensor frame or a
full RGB photo history. Selected accessibility evidence photos and the scan-start
reference photo remain separate. When configured, accessibility detection still
sends selected images to the chosen vision provider; that service is independent
of map construction.

Earlier stream archives and cached results are retained without deletion.
**Earlier scans → View scan data** opens their depth/color evidence offline, and
the evidence share action exports the original saved observations. Opening or
exporting old evidence does not resume uploads or replace a saved navigation map.
Those original streams retain their sensor-oriented photos, calibration, depth,
and camera poses for possible later processing. New RoomPlan captures do not
create another streaming photo archive.

## Validation

Run `swift test --package-path Packages/AccessCore` and build the iOS app. The
room-transition tests cover stable doors and openings, sustained clearance,
walking past, backing out, stale observations, tracking loss, implausible motion,
revisits, changed portal identifiers, and rotated coordinate frames. The
large-room test exercises extended movement without portals and verifies that
time, distance, and room extent never trigger a handoff. Map tests cover measured
polygons, openings, floor separation, source preservation, and resource limits.
Coverage tests include reversed and shuffled corridor patches, preserved gaps,
tracking breaks, missing intervals between recorded poses, and bounded review work.

For a Simulator-only UI fixture, launch with `--scan-review-preview`. It opens the
production scan-check views with two measured rooms and a missing corridor; it
does not start capture or modify saved maps.

Physical LiDAR validation remains necessary. Scan one large room beyond the old
7 m/two-minute limits, then enter adjoining rooms through doors and openings.
Check the original inputs, native merged structure, map and furniture, alignment
with saved points, interruption/resume, revisits, and floor changes. Synthetic
fixtures and passing detector tests do not establish RoomPlan quality, heat,
tracking, or seamless room handoffs on the device.

The Rust streaming backend is retained as separate developer research. Its
archived capture, transport, reconstruction, loop-closure, and recognition
protocols are documented in [backend/SCANS.md](../backend/SCANS.md); they are not
instructions for the current app scanning flow.
