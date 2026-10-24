# Frozen main-camera bounce mask - revision 12

This adds camera-aligned primary rays to the CPU ideal-mirror geometry test.
It is **not** material shading, live GPU RT, a whole-world visibility result or
the completed off-screen reflection acceptance test. The fixed-view revision 11
mask remains available through `startReflectionMaskTest()`.

Revision 13 adds a separate [reflected material-factor preview](vehicle-material-reflection-preview.md)
while preserving this mask as a baseline.

Revision 14 additionally checks [whole captured sources outside the frozen
frustum](vehicle-offscreen-geometry.md) in both camera modes. Its separate
`offscreenGeometryControlsPassed` field does not enable shaded/GPU reflections.

## Run

Keep the two cars parked and physics paused with J. Position the free/orbit camera
OUTSIDE the receiver, looking at an inward-facing door/side panel which could
reflect the other car. The other car need not be visible in the primary view.
Stop moving the camera before opening the **GE Lua** console and running once:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startCameraReflectionMaskTest(); print(tostring(ok)..': '..tostring(why))
```

This needs a fresh capture. **Keep the camera STILL for this version**, as well
as the cars/physics, until the image and screenshot are collected. Camera pose,
projection or viewport changes invalidate the snapshot and stop it. Close the
console to see the progress panel without moving the camera. Status:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getImageStatus()))
```

The image samples the entire frozen main viewport, not an automatic vehicle crop.
It is 128 samples wide; panel height follows viewport aspect (32..96). The full
output has TWO vertically stacked panels, at most 24576 pixels:

- Top: camera primary rays hit the nearer of BOTH captured cars, then reflect
  into the full pair. No receiver-isolation trick is used on primary rays.
- Bottom: same primary hits and reflected rays, excluding the OTHER car from
  each pixel's secondary query. A-primary pixels exclude B; B-primary pixels
  exclude A. The primary scene itself is not changed.

Green=other-car secondary hit, orange=receiver self-hit, slate=reflected miss,
dark=primary miss. Buildings, road, terrain and other vehicles are absent, so
the apparent primary visibility is only within this two-car CPU scene.

Use `showImage(120)`/`hideImage()` to reopen/hide the panel without recapturing,
or `stop()` to cancel/drop data. Saved BMPs have prefix
`/settings/beamrtVehicleRayImage-camera-bounce-`; old images are preserved. An
invalidated image remains a historical file, not a current-view result.

## Camera contract checked against installed BeamNG

Read-only source evidence from this installed version:

- `core/camera.lua`: `getPosition`, `getRight`, `getForward`, `getUp` read the
  main context's final camera state; axes are native rotated +X/+Y/+Z. No guessed
  Torque quaternion multiplication is used.
- `editor/objectScreenSizeViz.lua`: camera-space projection uses right/forward/up
  dot products with the vertical FOV and aspect convention.
- `editor/vehicleEditor/staticEditor/veStaticRenderView.lua`: maps viewport-local
  XY through `RenderView:getUnprojectedRayPosDir(x,y)`.
- Editor frustum drawing uses `getNearLeft/Right/Top/Bottom`, `getNearDist`; render
  screenshot helpers use `getFarDist`. Main `viewPort.extent` supplies dimensions.

Before requesting ANY native mesh readback, the diagnostic copies the main
frustum bounds, near/far, viewport extent and core-camera pose/basis into detached
Lua values. Nine viewport samples compare generated perspective directions and
ray-line origins against native unprojection. Mismatch rejects preflight rather
than silently guessing a different FOV or quaternion convention.

This supports one landscape perspective main view (4:3 through 4:1). VR and
ANY active split-screen/multiseat mode (including one player) are rejected.
Optional extension modules are inspected only through raw loaded-table/global
entries; a missing module is not loaded merely to check its state.
Ordinary orthographic/native camera
mismatches fail the unprojection check; no orthographic fallback is fabricated.
The snapshot reports `nativeRayChecks=9` and `maxNativeDirectionError`, with a
0.001 direction-vector tolerance and 0.01m lateral ray-origin tolerance.

Pixels start on the captured near plane and use the captured asymmetric frustum,
so TAA/off-axis shifts are represented rather than replaced with a symmetric
FOV guess. The existing segment kernel adds its 0.08m near/end exclusion; primary
length is capped at 1000m. This is not claimed to be pixel-perfect native depth.
Small projection jitter up to two native viewport pixels is tolerated during
snapshot freshness checks; real motion (2mm position / 0.0001 basis components),
projection changes or viewport resizing require recapture.

## Validation and interpretation

The unchanged four direct full-scene controls still run. Up to two actual-camera
primary hits per receiver are additionally compared with linear full scans,
followed by the bounded reflected full/excluded comparisons. There is no BVH box
or order use in those linear reference scans.

Expected fields include `profile="camera-bounce"`, `gameplayCameraUsed=true`,
`cameraProjectionValidated=true`, `primaryFullPair=true`,
`primaryReceiverIsolated=false`, `cameraPrimaryMatched=true` and
`reflectedReferenceMatched=true`. `frozenCamera` records source view, viewport,
frustum, position and native validation error. It contains no native view handle.

A primary view may contain only ONE receiver; a camera is not forced to see both.
`bothDirectionsRequired=false` makes that distinction explicit. The camera's
`oneBounceGeometricControlsPassed` / `cameraBounceGeometricControlsPassed` require
at least one inter-car hit, its source-exclusion control, and matching sampled
primary/reflected references. A legitimate no-inter-car-hit image may complete
with those pass fields false. A view with no sampled car is rejected.

`reflectedHitPointsOutsideFrustum` counts secondary HIT POINTS outside the frozen
main frustum. This point count alone does **not** prove the entire source vehicle
is off-screen. Starting with revision 14, a separate whole-captured-triangle
bounding-box certificate can establish `wholeSourceOutsideFrustumVerified=true`
when reflected rays hit a wholly offscreen captured source and the required
geometry controls pass. See the linked geometry-control document for its scope
and conservative rules. `offscreenReflectionTestPassed=false` remains intentional.
Opacity, actual material
reflectivity, BRDF/light/radiance, scene completeness and GPU execution are still
unverified. The source-exclusion control does not move/hide/delete anything in
the actual game, and receiver self-hits remain present.

Native geometry profiles, sequential A-free-before-B ownership, byte/triangle
budgets, cooperative CPU work, 180-second deadline and release-on-cancel remain
unchanged. No camera, viewport, renderer or material setting is written.

Offline tests cover native-ray mismatch rejection before GPUMesh requests,
perspective projection round trips, roll/asymmetric frustums, camera freshness,
unsupported views, both-car primary occlusion, behind-camera secondary geometry,
bounded samples and pending/completed cleanup.

## Optional-module autoload incident - October 23

The first live revision 12 run computed/saved a camera mask, with projection,
primary and bounce comparison fields true. However, the console also showed an
unexpected `render_splitScreen` extension load and `multiseat` route transition;
the game displayed a disconnected-device overlay and a different active view.
This run is not accepted as a clean actual-view/camera result.

Cause: the initial optional-state check fell back to
`extensions.render_splitScreen` / `extensions.render_openxr`. Installed
`lua/common/extensions.lua` implements a missing-key `__index` by calling
`tbl.load(key)`. Loading `render_splitScreen` calls its `enable()` lifecycle hook.
That lookup was not read-only, contrary to the original intention.

The check now uses `rawget` on `_G` and the already-loaded extension registry,
without invoking either metatable. It also rejects ANY active multiseat state:
a one-player multiseat view need not be the normal `main` camera context. Tests
install tripwire autoloading metatables and ensure capture/freshness checks do
not touch them; active one-player mode refuses before any GPUMesh request.

No engine feature is automatically unloaded by the diagnostic. If the unintended
mode is still active, the user can stop the probe and unload only that feature:

```lua
extensions.beamrt_vehiclePairProbe.stop()
extensions.unload('render_splitScreen')
```

Its installed unload hook disables its views/route/quality overrides. Do not
automatically unload unrelated user features or change saved player/device
assignments. If the user has already returned to normal Freeroam/reloaded, do
not assume the disconnected overlay is still present. Restore the parked pair
if needed, reload the probe and retry the corrected camera test. A clean live
camera-mode result was subsequently completed cleanly after this repair: the
initial corrected image had 5 inter-car hits, all removed by exclusion, with
115 self-hits unchanged. Two closer/gap views then produced 17 and 58 inter-car
hits, each reduced to zero by exclusion, with 45 and 146 self-hits unchanged.
These are geometric mask results, not shaded or off-screen acceptance results.
