# Two-car CPU BVH images

Revision 11 adds a separate [one-bounce geometric mask](vehicle-reflection-mask.md).
The identity/depth and normal modes documented here remain unchanged.

These are geometry diagnostics, **not reflections, material shading, native RT
integration or performance claims for the live renderer**. The four-ray test,
hit markers and revision 9's 64x40 ID/depth baseline succeeded in-game. The new
revision 10 normal close-ups also completed in-game: 24576 pixels, 3328/3292
primary hits on A/B, four matching direct controls and about 22.9 seconds for the
whole job. This does not certify winding, opacity or reflected-ray behavior.

## New: tighter isolated normal close-ups

Keep the two parked cars and physics paused, then run in **GE Lua**:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startNormalImageTest(); print(tostring(ok)..': '..tostring(why))
```

This needs a fresh capture because previous completed image jobs released their
BVH and source buffers. The normal variant renders two **128x96** panels in one
256x96 image, A on the left and B on the right. Each panel fits its own captured
car's world-space bounds, so the gap no longer consumes image resolution. A
slightly elevated three-quarter direction reveals more than the baseline view.
The shared progress panel/status command and 120-second display timer still apply:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getImageStatus()))
```

`profile="normals"`, `width=256`, `height=96`, `panelWidth=128` and
`pixelsRendered=24576` identify the new result. Completion requires both cars
to receive pixels, plus the same four full-scene reference comparisons.

RGB encodes signed WORLD-space geometric face normal XYZ as `0.5*(normal+1)`.
Normals come from the cross product of each nearest triangle's transformed
positions, including prop placement. **No native normal/color stream is read.**
The direction is not face-forwarded, smoothed, normal-mapped or corrected to hide
bad winding. `frontFacePixels`/`backFacePixels` count the geometric dot-sign only;
they are not an opacity decision. `windingVerified` and `authoredNormalsCaptured`
remain false. Facets or sudden color changes are diagnostic evidence, not paint.

Each panel excludes the OTHER car from that panel's CPU rays to inspect the
target in isolation. The four reference controls still use the full pair and
their explicit excluded-B control before rendering. Thus these panels **do not
test inter-car occlusion or reflections**. The gameplay camera is not used.

The saved bitmap has the prefix `/settings/beamrtVehicleRayImage-normals-`.
It contains actual 256x96 sampled pixels, not an enlarged 64x40 ID image. Old
bitmaps are preserved. Source/BVH limits, cooperative work budget, timeout and
invalidation/cleanup rules below are unchanged.

Offline additions test unit/signed normals from transformed vertices, rotated
props, reversed viewing direction without automatic normal flips, curved face
colors, panel identity, framing across different gaps, true output dimensions,
and absence of optional native stream lookups in normal mode.

## Baseline 64x40 ID/depth run (still available)

Keep exactly two parked cars, side-by-side a few metres apart, enter one and
pause physics with J. Leave the exporter/other mesh-readback tools idle. A fresh
capture is necessary: the previous completed four-ray scan released its buffers.
In **GE Lua**, run once:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startImageTest(); print(tostring(ok)..': '..tostring(why))
```

A small ImGui progress window appears during acquisition/build/reference checks.
Keep physics paused; camera movement alone is fine. On completion, it displays
a 64x40 image scaled up, then hides after 120 seconds. Progress/status is also
available without restarting the job:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getImageStatus()))
```

The stage moves through `acquiring`, `building`, `reference-controls`,
`checking-bvh`, `rendering`, and `complete`. `acceleratorMatchesReference=true`
means the BVH matched all four brute-force controls' nearest vehicle/primitive
and distance, including both miss/exclusion controls. This is not a proof for
all possible rays. Build/trace counts and the UI error reason are reported.
Completion also requires at least one hit pixel for each car. A blank/one-car
image is rejected rather than accepted; keep the pair close enough for 64x40.

To reopen/hide the completed panel or cancel all pair data:

```lua
extensions.beamrt_vehiclePairProbe.showImage(120)
extensions.beamrt_vehiclePairProbe.hideImage()
extensions.beamrt_vehiclePairProbe.stop()
```

`hideImage` hides only the panel; an unfinished job continues. `stop` cancels the
job and drops its retained arrays. Pose/prop/identity/material changes, resumed
physics, vehicle reset/removal, mission changes or unload invalidate both image
and results. A UI drawing error hides the panel but preserves the finished bitmap
and status rather than restarting acquisition.

## What the pixels mean

The view is fixed orthographic, looking across the pair from a slightly elevated
direction perpendicular to their horizontal separation. It fits the BVH's actual
world-space geometry bounds, not the gameplay camera or a screen/depth buffer.
It can face either end of the parked vehicles; it is not a mirrored view.

- Cyan: nearest captured triangle belongs to A (the controlled car at start).
- Magenta: nearest captured triangle belongs to B.
- Dark: no captured vehicle triangle intersected the diagnostic segment.
- Brightness: geometric depth only; there are no material textures or light samples.

Glass and cutouts remain triangle geometry with **unknown opacity**. A miss is
not whole-world visibility: roads, buildings and other objects are absent. The
fixed view and screen-independent rays do not establish off-screen reflections.

One small 24-bit BMP is written under BeamNG's user folder:
`/settings/beamrtVehicleRayImage-<run>.bmp`. `getImageStatus().file` gives its exact
VFS path. This is the pixel image only; raw proprietary vertex/index arrays are
not exported. Older images and capture files are not deleted. BMP write/close
failures cancel the result; a partial newly generated file may remain.

## Acquisition and acceleration boundaries

The proven geometry-only provider profile is unchanged: positions, indices and
primitive identity only. A is copied/freed before requesting B. The native handles
are both released **before** BVH construction begins. Existing per-car readback
count/budget/FFI checks and append-only boundary journal remain active.

The BVH copies every captured primitive triangle reference into independent
double-precision world-space arrays, using the same point conversion as the
brute-force control. There is no decimation, camera culling, quantization or raw
native-pointer retention. Split fallback and a depth limit handle repeated or
degenerate centroid data without losing triangle references. Boxes are conservative;
nearest triangle tests use the original segment's endpoint tolerance, not a
shortened nearest-hit segment. Equal-distance ties retain original reference order.

The separate BVH budget is 500000 references **total across both cars**, at most
128 MiB for bulk destinations, with worst-case capacity 212 bytes/reference
(about 101 MiB at the triangle cap). This is additional to source CPU records and
small Lua metadata/pixels, not a total-process or native-engine memory bound.
There is no truncation if a budget is exceeded.

Build/trace work yields every 16384 counted operations; the independent reference
scan retains its 8192-triangle/update budget. These are count limits, not guaranteed
millisecond frame budgets. The image job has a 180-real-second timeout. Source
CPU arrays are released after BVH/control comparison, and BVH arrays after image
completion; the finished result retains only 2560 pixels and small control/frame
metadata. Cancellation discards the coroutine and its retained buffers.

Offline tests compare randomized BVH rays with full scans, exact primitive identity,
prop matrices, ties/flat centroids, parallel rays and endpoint rules. They cover
FFI ownership/types/ranges, incremental cancellation, mismatches before pixel
publication, BMP headers/row order/pixels, UI Begin/End pairing and sequential
pair cleanup/export failures. The rendered validation fixture uses synthetic boxes,
not live BeamNG vehicles. Passing it does not validate the game DLL or certify
the untested live image result.
