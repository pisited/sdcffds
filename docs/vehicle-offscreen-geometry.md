# Whole-source offscreen geometry controls - revision 14

The target is geometry-based reflections which can include an object outside the
main camera view. The current implementation is a **paused two-car CPU reference
experiment**, not a live reflection renderer. It uses copied vehicle triangles,
not the main camera's depth/color buffers. SSR, whole-scene lighting, hardware
DXR integration and material-texture evaluation are not implemented by this mode.

Revision 14 checks whether ALL captured triangle references of a reflected source
are outside the frozen main frustum. It applies automatically to both existing
`startCameraReflectionMaskTest()` and `startMaterialReflectionTest()`.

Revision 15 adds a separate [isolated GPU ray comparison](vehicle-gpu-ray-probe.md)
which uploads all captured references for a bounded hardware query batch. It
does not replace this CPU image with GPU-rendered reflections.

## Live setup

Keep the two cars parked and physics paused with J. Put the free camera in the
gap, outside the car bodies, and point toward one car's inward-facing door.
The other car should be entirely behind the camera or outside its edges. A view
with part of both cars visible is not the intended acceptance setup. The cars
must still be positioned so the visible car's surface directions reflect toward
the other car. No software step guarantees a positive hit for an arbitrary view.

Stop moving the camera. In GE Lua, start the existing material preview:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startMaterialReflectionTest(); print(tostring(ok)..': '..tostring(why))
```

Keep the camera, FOV, viewport, cars and physics unchanged until completion.
Close the console to watch the panel. When complete, get the shorter report:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getOffscreenStatus()))
```

Expected `offscreenGeometryControlsPassed=true` requires positive secondary hits
on a conservatively certified offscreen source, source exclusion, matching
sampled linear primary/secondary references and the original BVH/direct controls.
The completed UI reports the offscreen-hit count and both source-bound states.
`not certified outside` means the conservative test cannot establish that source
is wholly outside; it does not mean every triangle is visible. A legitimate
zero-hit run can finish with the control false. It must not fabricate a pass.

## Certificate

The CPU BVH build already computes per-car world AABBs from **every vertex of
every copied primitive triangle reference**, including transformed props. The
certificate uses those bounds, not sampled preview triangles, spawn OOBBs,
vehicle centers, rounded screen rectangles or low-resolution primary-hit counts.

For each of the six perspective frustum planes, it evaluates all eight AABB
corners against that SAME normalized world-space plane. The whole AABB is
certified outside only if every corner is strictly outside one plane with more
than 0.01 m separation. Convexity then guarantees all enclosed copied triangles
are outside that plane. No-corner-inside alone is not sufficient: a large box
may surround/intersect the view while all corners project outside.

The lateral frustum is expanded by two native viewport pixels (and at least
0.00001 m at the near plane), matching the projection-jitter allowance in camera
freshness. Snapshot near/far distances and rolled/asymmetric camera axes come
from the existing native-unprojection-validated BeamNG camera contract. The
1000 m CPU primary-ray cap is NOT a frustum plane and cannot certify offscreen
geometry. All distances, planes and evidence refer to the **frozen snapshot**;
this does not certify an independently moving camera or every future jitter.

Per-source results record `vehicleId`, `outside`, separating `plane`, normalized
`minimumSeparationMetres`, guard sizes and scope. A true certificate must also
agree with zero primary hits on that source; a contradiction rejects publication.
An inter-car reflected hit attributed to such a source must project outside the
frozen frustum too. Each retained receiver self-hit stays in both secondary scenes.

`offscreenSourceHitsA` counts rays from receiver A hitting wholly offscreen B;
`offscreenSourceHitsB` counts the reverse. These are subsets of the ordinary
inter-car-hit counts. `wholeSourceOutsideFrustumVerified` becomes true only when
at least one such secondary hit exists; the per-source certificate can still
report an outside source in an all-miss setup. The word "whole" refers only to
the captured primitive-reference geometry, not VFX, lights, omitted native passes
or a claim that the capture is a complete engine scene.

The image/status certificate is detached: callers cannot mutate internal evidence.
Completed/cancelled data follows the existing pause, camera, identity, pose, prop
and cleanup guards. There are no new native readbacks, native mesh streams, camera
settings, vehicle positions or renderer changes. Certificate work is constant:
six planes times eight corners for each of two cars.

## Limits

`offscreenReflectionTestPassed=false`, `materialShadingVerified=false` and
`gpuExecutionVerified=false` remain intentional. A successful new control proves
offscreen **geometry queries** in this CPU scene. It does not prove a shaded
reflection in the native frame, frame-rate suitability, material opacity,
roughness, texture/paint colors, world completeness or independence from all
possible temporal reflection inputs. Moving/deforming geometry and live GPU
publication still require separate implementation and validation.

The first corrected material-factor run (revision 13 color-format revision 2)
had 74 inter-car hits, 186 unchanged self-hits and zero purple fallback pixels
across its 260 full-pair reflected-surface pixels. It did not certify a wholly
offscreen source; parts of both cars were visible.

## Live offscreen geometry result - October 24

Revision 14 capture `20261024T145704Z-2510.8870812-1` completed and saved its
256x136 material preview. The live compact report and UI showed
`offscreenGeometryControlsPassed=true`: captured source A was outside the near
plane, source B was not certified outside, and B-to-A reflected rays produced
127 whole-source-offscreen hits. A received zero primary samples; B received
4121. The displayed separating-plane clearance for A was about 0.0932 m, using
the 0.01 m margin and two-pixel lateral guard. This certifies being outside the
frozen view frustum, not that every point is behind the camera's eye position.

Independent saved-BMP counts found 127 green full-pair pixels and zero green
excluded pixels. Both rows contained 520 receiver self-hits, with all 520
corresponding factor-preview RGB values identical. There were zero purple
fallback pixels in either factor-preview row. The journal ended with the
matching run's `cpuImageComplete` marker. The compact live report also showed
camera-primary/reference and reflected-reference matches plus source-exclusion
success. Its GPU, full shaded-reflection and material-shading acceptance fields
remained false. This is the successful paused offscreen geometry milestone;
live shaded/GPU reflection rendering remains pending.

Offline tests cover all six separating planes, whole-bound enclosure traps,
partial visibility, margins, the primary distance cap, roll/asymmetric frustums,
invalid bounds, behind-camera secondary hits with linear/exclusion controls,
no-hit refusal, detached reports and cancellation. They use synthetic geometry.
