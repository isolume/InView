# Open corridors and balconies

RoomPlan fits rooms, which can stall or omit geometry in a long corridor with an
open side. The app now saves each section automatically after its tracked span
reaches 7 m or its duration reaches 120 seconds, with at least 15 seconds to settle.
Processing briefly pauses capture; the next section retains the same AR session
and coordinate space. Manual Next section still works.

Alongside RoomPlan, the app samples nearby ARKit plane boundaries every 0.75 seconds
during normal, recent tracking. It retains exact horizontal floor outlines and
near-floor partial vertical planes at their measured height. Two consistent
observations at least 0.5 seconds apart are required. Classified floors can establish
an elevation; unclassified floors must agree with an established elevation. Tables,
ceilings, and lower floors visible across an atrium are rejected. No floor is
inferred by widening the camera's path or extending a destination marker.

Retention is limited to 64 floor planes and 1,024 floor vertices plus 128 low
barriers, with at most 128 vertices per plane. Floor extents up to 200 m and area
up to 5,000 m² allow long corridors without a 40 m capture plateau. Barriers are
0.35–1.6 m high and no more than 40 m long. Frames and mutable sensor buffers are
not retained for this supplement; full mesh copying remains disabled.

Recovered floors are compared by their actual coverage. Partial overlap no longer
discards a whole corridor extension. Saved maps and portable local/server scenes
retain floor polygon corners; floor unions preserve concave cutouts and separate
islands. New scans restrict routes to measured floor coverage, even if no floor
was captured. Older floorless maps retain their legacy behavior.

The provided map export had no floor surfaces and elevator pins about 4 m and
6 m beyond the nearest captured footprint. It contains no raw evidence from
which to reconstruct that missing portion. Rescan that area using the updated
app, keeping the floor in view as well as the wall or railing.

Small obstacles omitted by RoomPlan have a separate depth supplement. Every
1.5 seconds, one background worker samples at most 8,000 depth pixels using the
captured camera calibration and a frozen measured floor elevation. Returns must
have high confidence, nearby support, and visible sides 8–75 cm above the floor.
Smooth floor and ramp surfaces, isolated noise, objects within 75 cm horizontally
of the scanner, and returns beyond 4 m are excluded. Two consistent frames and
at least 6 cm of measured vertical variation are required.

The supplement retains at most 4,096 spatial cells and emits at most 128 clusters,
each no more than 2 m across. Confirmed evidence survives depth-keyframe eviction.
Known walls and furniture contain and suppress duplicate clusters. Confirmed
clutter uses the same measured bounds for generic 3D blocks, saved scenes, and
routing; it receives no invented furniture category or label. The visible sides
establish its bounds, so a top-only return never becomes an assumed solid volume.

Core regressions and iPhone/Simulator builds cover these changes. A physical
balcony scan is still needed: the Simulator cannot validate LiDAR capture.
Small objects need a slow pass with their sides and the nearby floor in view,
usually from about 1–2 m away. Thin, transparent, reflective, moving, or distant
items can still be missed; railings also depend on ARKit detecting a vertical plane.

Apple's [RoomPlan guidance](https://developer.apple.com/videos/play/wwdc2022/10127/)
describes room-oriented scanning constraints, and its
[plane detection guidance](https://developer.apple.com/documentation/arkit/tracking-and-visualizing-planes)
describes horizontal and vertical measured plane anchors.
