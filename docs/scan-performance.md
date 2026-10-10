# Scan performance

Measured on 2026-10-10 with an iPhone 15 Pro Max running iOS 27.0.1,
using Debug builds and two 45-second user-operated scans of roughly the same area.
These are observations from short scans, not a controlled FPS benchmark or proof
that arbitrary building sizes are supported.

| InView measurement | Before | After |
| --- | ---: | ---: |
| Peak physical memory footprint | 1,121 MiB | 794 MiB |
| Mean physical memory footprint | 1,085 MiB | 775 MiB |
| Mean CPU utilization | 119% | 78% |
| Sampled main-thread CPU time | 30.36 s | 5.07 s |
| Main-thread mesh-copy CPU time | 27.15 s | 0 s |

CPU utilization can exceed 100% when multiple cores are active. Memory figures
are Instruments' physical footprint, including compressed memory. Sampled CPU
time is statistical; recording had a system-symbol overlap warning in the second
run. App symbols and activity measurements were available. App warm-up, scan
coverage and device thermals can affect the comparison.

## Changes

- Stop requesting and repeatedly copying a separate AR mesh alongside RoomPlan.
  Its measured surfaces and objects continue to supply navigation geometry.
- Retain at most six complete depth keyframes, with an 8 MiB retained-payload
  budget and a 2 MiB native-byte limit per frame. One background worker decodes
  immutable copies; it drops incoming samples while busy.
- Query nearby detection annotations through a spatial index. Project at most
  16 live tags, show three kind counts in the header, share evidence images, and
  retain a bounded slope history. Automatic raycast checks yield in small batches.
- Convert camera pixels once for the model and its evidence preview. Release
  copied sensor images before network round trips; cancel stale work on pause.
- Disable RoomPlan's live miniature model and built-in final presentation.
  Process section data with one cancellable RoomBuilder task and release the
  capture view before constructing the app's navigation scene.
- Build routing footprints off the main thread and deduplicate components by
  their RoomPlan identifiers, retaining each component's latest measurement.
- Archive originals once, separately from the compact navigation capture. Apply
  the 32 MiB limit only to server uploads; local maps can still process larger
  captures. Skip unused depth-point projection in local navigation scenes.
- Share entrance reachability searches across report destinations, preserving
  routing resolution, clearance selection and findings. Cancel obsolete audits
  instead of letting detached work continue after its screen is closed.
- Preserve completed sections after processing failures. Explain scene-size
  and thermal interruptions, offer shorter sections, and pause on critical heat
  or a memory warning. Keep the same AR coordinate space between sections.

## Verification

- 125 AccessCore tests pass, including long-scan depth budgets, nearby lookup with
  10,000 distant annotations, large local captures, cancellation and route parity.
- Physical iPhone and Simulator builds pass.
- The user verified Next section resumes scanning and Finish opens the 3D review
  on the installed iPhone build.
- A separate 40-second section/finish recording peaked at 1,064 MiB during the
  transition and ended at 717 MiB with the 3D review open. RoomPlan processing
  still has a substantial temporary memory cost; capture-budget limits do not
  cap the framework's own allocations.
- Synthetic camera encoding on the Mac averaged 10.57 ms before and 8.32 ms after
  over 30 encodes of a 1920 × 1440 YCbCr image; output size, color, pixel ownership
  and portrait-coordinate mapping were checked.
- A synthetic Debug report audit on the Mac, excluding unchanged grid creation,
  took 3.573 s versus 0.200 s for a 20 × 15 m floor with 50 destinations; a
  30 × 20 m floor with 80 destinations took 10.570 s versus 0.304 s. Medians of
  three warmed, alternating-order trials; reachability and clearances matched.

Very large room/building stress testing remains necessary. RoomPlan has scene-size
and thermal limits; Apple recommends short scans and describes MultiRoom as best
suited to residential, single-floor spaces with a total area around 186 m².
Sections preserve alignment but do not remove those tracking limits. The routing
grid still scales with the total floor bounds at its original 10 cm resolution.

Sources: [RoomPlan MultiRoom guidance](https://developer.apple.com/videos/play/wwdc2023/10192/),
[scan duration and thermal guidance](https://developer.apple.com/videos/play/wwdc2022/10127/),
[capture errors](https://developer.apple.com/documentation/roomplan/roomcapturesession/captureerror).
