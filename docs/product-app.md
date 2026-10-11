# Student Center East app

The app opens on the Floor 2 model of Student Center East at Georgia State
University. Search, place details, directions and model placement use one bottom
sheet. The profile menu contains account access, contributions, submissions, saved
local maps and settings. The AR button stays visible and explains when positioning
is unavailable. Floor labels stay concise; **Building details** explains the model
estimates and available scan coverage.

## Map and model

Floors 2 and 3 use their own expanded walkthrough models as the primary visual
layer. The bundled USDZs and layout labels come from
`models/walkthrough-building/floors-2-3/`. They include estimated connecting areas
beyond the partial Floor 2 LiDAR scan; dimensions, spacing and connections remain
estimates. Floor 1 still has no bundled model or map and says so explicitly.

The bundled `student-center-east-floor-2.json` remains an unchanged copy of the
supplied `venue-map 3.json`, with partial measured floor coverage and two elevator
markers. Floor 3 can be explored visually but has no bundled measured routing map.
No verified floor links, geographic placement or AR localization data were supplied.

Both models share an approximate visual registration: the Floor 2 model's two
elevator doors are fitted to the scan's two elevator markers with translation,
horizontal rotation and a uniform scale of about **1.24672**. Floor 3 retains its
estimated relative elevation under that same transform. The fit does not establish
measured coverage elsewhere in either model.

Generated landmarks are searchable and clickable, with place details, but have no
directions yet. They remain display-only and never enter `VenueMap` or
`RoutePlanner`. **Floor scan** is offered only when the selected floor has its own
matching measured map. Choosing a route start or previewing a route automatically
shows that scan; generated geometry never supplies walkable coverage.

**Map appearance → Adjust placement** provides shared local position, rotation
and size controls for the two model floors, with reset to the elevator fit. These
settings affect the visual layer and its displayed landmarks. They do not change
the source scan, routing coordinates or AR registration.

Route previews use a chosen start and the measured floor geometry. **Step-free**
is the default and requires 45 cm obstacle clearance and measured eligible ramp
slopes. **Fastest** compares permitted paths at 30 cm clearance or wider and can
use measured ramps above the step-free slope limit. It never treats the shadow
of a staircase as a flat floor connection. Both choices respect measured coverage
and obstacles; neither falls back to the tighter audit-only clearance. They do not verify
real-world accessibility. Live AR guidance needs a matching local ARWorldMap and
reliable tracking; the supplied scan and server releases cannot provide it yet.

The route preference is saved on this device, without asking for a medical
profile. Changing it clears the previous route and recalculates from the same
start to the same destination. Live reroutes keep that choice.

**Between floors** uses explicit building connections from the configured InView
service. Step-free requires known step-free edges, at least 90 cm clear width,
and a maximum measured grade of 1:12; stairs and escalators are excluded before
search. Fastest clears those step-free requirements and compares total estimated
travel time, including connector waits. Either mode can use ramps or elevators;
Fastest uses stairs only when they produce the quicker available journey. Closed
or unknown connections are never used, and an unavailable step-free journey
does not fall back to stairs.

The current Student Center maps do not contain building connections, so that
screen reports directions unavailable until those connections are reviewed and
published. Worker-generated graphs remain private drafts and cannot directly
become public building directions.
The native client uses `/graphs/student-center-east` and requires matching
`metadata.venue_id`, rejecting demo graphs for the real building. Directions
preserve each floor's coordinate frame and show explicit transition steps. They
do not overlay unrelated scan coordinates or claim cross-floor AR guidance.

For a Simulator-only integration demo, launch with `--building-directions-preview`
and run an isolated backend at `127.0.0.1:18763`. Load `backend/examples/graph.json`
into `/graphs/demo-building` with `metadata.venue_id` set to `demo-building`.
The screen uses the real graph and route endpoints: Step-free takes the 34-second
elevator route, while Fastest takes the 12-second stairs route. The demo keeps its
preference in memory and does not change the user's saved choice.

## Scan review

The map is assembled on the phone from canonical RoomPlan geometry. During review,
**Find places** can send selected photos, depth, location and reviewed points to the
configured server. Suggestions need individual Keep or Drop decisions and retain
their measured floor and position. Saving exports the current reviewed points.

**Detailed scan** is off by default. When enabled, original capture data is saved
before surface compaction and photo coloring. **Scan detail** displays that separate
result alongside the measured structure; it does not supply routing coverage.
Detail failures can be retried from the original capture.

## Accounts and contributions

Set `INVIEW_BACKEND_URL` in the ignored `Config/Secrets.xcconfig`, then run
`xcodegen generate`. Use HTTPS for a remote service. Local loopback and `.local`
HTTP are accepted for development; xcconfig URLs use `http:/$()/host:port`.
Map browsing and the bundled model work without this service. Account and upload
screens explain when it is unconfigured.

Users register or sign in with email and password. Sessions are stored in Keychain
and bound to the configured service. Contributions select a building floor,
import a valid floor-map JSON or use a saved on-device scan, and affirm permission
to map the space. Failed submissions retain an account-bound queue for explicit
retry. Submissions show their review status; requested changes can be resubmitted.
Uploads currently contain the floor map and notes, not raw LiDAR, video, photos,
USDZ or ARWorldMap archives. Existing capture exports remain local.

## Admin review

Run the service using [backend setup](../backend/README.md#accounts-and-reviewed-maps).
Bootstrap an admin explicitly using `INVIEW_ADMIN_EMAIL` and
`INVIEW_ADMIN_PASSWORD`; registering in the app never grants admin access. Open
`/admin` on that service and sign in.

The workspace shows a submission queue, map geometry, original/draft comparison,
destination labels, types, staff assistance and pin placement, notes, change
requests and publication. Pin movement supports map clicks and arrow keys. A publish
requires the current saved revision and geometry, route and floor-link review
checks. Published versions are immutable and separate from the original capture.
The native app refreshes the public catalog, caches reviewed releases separately
from local scans, and uses the latest release for each floor.

The JSON snapshot store supports one server process. Email verification, password
recovery, raw capture storage and a full geometry editor remain future work. Processing and Studio endpoints use a dedicated service token, independently
of account sessions. Public map releases and reviewed building-route snapshots
remain available without that processing credential.

## Verification

The iOS Simulator build exercises bundled resources and the native map UI.
Backend product integration tests cover registration, ownership, idempotency,
revision conflicts, review and publication. Core routing tests cover strict
clearance, ramp eligibility and destination preservation during rerouting.
The native building-directions fixture was checked against the local routing
service: the same trip used a 34-second elevator route in Step-free and a
12-second stairs route in Fastest. Closing the elevator produced a no-route
message in Step-free, without falling back to stairs. The earlier Simulator and backend checks are supplemented by integration
regressions for processing authentication, persistence, immutable evidence,
reviewed routing snapshots, place identity, unknown terrain and ceiling budgets.
Simulator checks passed for the expanded Floor 2/3 models, floor-specific
landmarks, landmark search and place details, model/scan switching, local rotation and reset,
the missing Floor 1 state and AR availability explanation. A 9 m measured route
preview automatically selected the scan; switching to Floor 3 cleared its route,
starting point and destination. Floor 3 offered only its model layer.
Browser checks passed for editing, moving and publishing destination pins. Real
HTTP checks also passed using the native account and map-release types.
The final integration checks passed: 488 AccessCore tests, 165 Rust backend tests,
682 processing-worker tests and 9 Studio tests, together with the iOS Simulator
build. The PostgreSQL integration test requires a live database and was explicitly
ignored; five optional worker tests were skipped. Depth-capture tests now assert
the existing three-observation confirmation requirement.

Screenshot guide: [primary Floor 2 model](screenshots/map-model.png),
[Floor 3 model](screenshots/map-floor-3.png) and
[route preview](screenshots/route-preview.png) show the current app.
Earlier verified views:
[floor scan](screenshots/map-scan.png),
[placement](screenshots/model-placement.png),
[admin review](screenshots/admin-review.png).

Physical-device AR relocalization and building-wide coverage still need new
capture data and on-site verification.
