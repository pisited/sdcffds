# Two-car off-screen reflection test

Current continuation: revision 14 adds [whole-source offscreen geometry
controls](vehicle-offscreen-geometry.md) to the frozen-camera preview. The
older revision 8 workflow below remains a baseline. Geometry-based offscreen
queries are the target of this stage; live shaded reflections remain pending.

Revision 9's [CPU BVH ID/depth image](vehicle-ray-image.md) completed in-game,
including all 338768 references and four matching brute-force controls.
Revision 10 adds isolated higher-resolution signed-normal close-ups; that new
variant is offline-tested only. The four-control and point-overlay workflows
below remain available.

## Current experiment: revision 8 geometry-only CPU controls

Following a successful live single-car geometry-only copy/validation/free and
explicit user approval, revision 8 reopens the opt-in pair acquisition. Optional
colors, normals, tangents and UVs remain excluded. This is not a proven native
crash repair and does not enable reflections or GPU rendering.

Keep exactly two parked cars a few metres apart side-by-side, enter one of them,
and pause physics with J. Do not run the exporter or other mesh captures at the
same time. In **GE Lua**, run once:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startHitTest(); print(tostring(ok)..': '..tostring(why))
```

Without arguments the controlled car is A, and the only other car is B. More or
fewer cars, or a walking character rather than a controlled car, refuse automatic
selection. Use `listVehicles()` and `startHitTest(ID_A,ID_B)` for explicit selection.
After several seconds, keep physics paused and run:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getHitTestStatus()))
```

Both native readbacks are sequential: request/copy/free A before requesting B.
The controller requires the instrumented geometry-only provider API and never
replaces a stale package instance to force a retry. Native calls and preparation
phases append flushed/closed metadata records to
`/settings/beamrtVehiclePairStages.jsonl`, including vehicle ID and role. A failed
journal blocks further acquisition; already-owned handles still receive one
cleanup attempt. These writes improve process-crash diagnostics, not guaranteed
disk durability. CPU completion is also journaled once. No geometry is exported.

Expected success is `phase="complete"` and `geometricControlsPassed=true`.
Failure/miss controls are still useful evidence; do not equate completion alone
with correct transforms or a reflection. The four controls and remaining limits
are explained below. The live revision 8 CPU control result is recorded below;
this is not an off-screen reflection acceptance result.

## Ray-hit overlay on the completed CPU result

Leave physics paused and both cars unchanged after the completed control. Load
the separate drawing extension, **without reloading the pair probe**:

```lua
extensions.load('beamrt_vehicleRayHitPreview'); local ok,why=extensions.beamrt_vehicleRayHitPreview.show(90); print(tostring(ok)..': '..tostring(why))
```

Close the console and move only the camera to see the markers. A-to-B is cyan,
B-to-A is magenta, and exact CPU hit points are yellow spheres/crosses. The dim
line continues to the original segment endpoint beyond a hit. By default only
the two reciprocal hit controls draw. To inspect an overlapping line on its own:

```lua
extensions.beamrt_vehicleRayHitPreview.show(90,1) -- A to B; use 2 for B to A
```

Use `show(90,'all')` for all four controls, including the green above-cars miss
and orange excluded-B ray, or select control number 3/4. Failed geometric controls
draw red rather than being presented as success. The exclusion changes CPU test
data only; B remains visible in the game. Hide immediately with:

```lua
extensions.beamrt_vehicleRayHitPreview.hide()
```

The overlay uses only the four completed endpoint/hit records, never CPU mesh
buffers. It makes no readback or ray-job request and requires no new capture for
an existing revision 8 result. Current code offers a compact guarded report;
older already-loaded instances use their original `getStatus()` guard, so do not
reload a good live result just to attach the overlay. Drawing stops on expiry
(1..120 seconds), physics/pose/prop invalidation, controller replacement, a new
pair run, mission/reset/removal or unload. No material or renderer settings change.

The installed BeamNG vehicle-editor light debugger's native line/sphere APIs are
used with depth testing disabled. **Markers can be seen through car bodies**;
this is diagnostic visibility, not verified opacity, material coverage, alignment
certification or reflection shading. At most four rays, fourteen lines and six
spheres draw per frame. No automatic activation occurs on load.

## Live CPU control result - October 23

The saved pair run `20261024T020723Z-1500.056871-1` completed all 1185688 triangle
reference tests with `geometricControlsPassed=true`. A (76076) hit B (74162)'s
door geometry, B hit A's door geometry, and the above-cars and excluded-B controls
both missed. The stage journal confirms A's free returned before B's request,
B's free returned before CPU control creation, and CPU completion reached
sequence 4711. Cleanup and journal uncertainty flags were false. No shaded
reflection, alpha coverage or full scene geometry was verified by this result.

## Native acquisition crash incident - 2026-10-23

Revisions 6/7 quarantined both pair entry points after the original native crash.
The following incident evidence is retained; the revision 8 instructions above
supersede that quarantine for the narrow, user-approved geometry-only experiment.

The local crash log records a C++ main-thread crash 18 ms after the start command
returned, during `vehicleProvider.capture` -> prop index 4 (`ardente_paddles`) ->
`vertColorsGet`, with 479 vertices/colors. Native readback readiness was true and
FFI allocation had succeeded. The CPU ray loop had not begun. The crash reporter
cautions that its GELUA stack is contextual, not conclusive proof of the faulty
C++ operation. Root cause (stream validity, native lifetime, binding/ABI or other
memory corruption) is not established by the Lua stack alone.

Offline parsing of the preserved minidump's exception/module streams confirms
`0xC0000005` (read access violation), attempted read address `0x48`, in
`BeamNG.drive.x64.exe` at image offset `0x143296`. No debugger attachment, game
launch or dump upload was used. This supports a native invalid-memory access;
without engine symbols/source it does not identify the faulty stream object or
exclude earlier corruption. Log SHA-256:
`30bc94d0a087b290df21805a598f556052b25b258b98b0b3dd0fb1cbbb01d744`;
dump SHA-256:
`b6f33462009995378981e305e794e8ed5a50a583d5adcbde5f010e86e7287041`.

The shipped exporter defaults `exportColors=false`; our provider requested that
optional stream unconditionally despite the geometric test not using it. The
unnecessary read is now removed in [acquisition hardening](vehicle-readback-safety.md).
The native failure remains unresolved; the subsequent approved experiments are
diagnostic evidence gathering, not a verified repair.
Lua `pcall` and synthetic unit tests do not establish safety of a native getter.

The original log and minidump were copied privately to Git-ignored
`.beamrt-validation/crash-20261023-1018/`; no upload or deletion occurred.
Containment was not a verified repair. Current offline tests exercise shipped
revision 8 source unchanged, with Lua-owned fake getters and journal handles.
They verify sequential ownership, excluded streams, stage boundaries,
cleanup on journal failures and CPU controls; they do not validate the game DLL.

The separate single-car live result for vehicle 76076 copied/checked 163248
vertices and 508152 indices, with 156440 flex + 12944 prop triangle references
and 15 props. Its saved run `20261024T015358Z-1` reached native free and completion
at sequence 1573, including successful positions/indices/primitives for
`propmeshes[4]:ardente_paddles`, without color reads. The UTC run ID corresponds
to October 23 local time. One successful run supports trying the narrower path,
not a conclusion about the original crash's root cause.

Two cars are a useful dynamic-geometry target, but **not an RT implementation**.
The current vehicle provider captures CPU buffers and does not feed a tracer.
The new `vehiclePairProbe` is an opt-in acquisition preflight only: no shader,
material, vehicle, camera, physics or renderer settings are changed. No native
DLL is loaded. No files or proprietary geometry are exported.

## Preflight available now

Park two cars a few metres apart and pause physics with J. Use a distinctive
colour for source B and a smooth reflective panel on receiver A. Leave normal
lighting unchanged initially. In the **GE Lua** console:

```lua
extensions.load('beamrt_vehiclePairProbe')
print(jsonEncode(extensions.beamrt_vehiclePairProbe.listVehicles()))
```

Choose the two numeric IDs printed above. Substitute them for `ID_A` and `ID_B`
below (these labels are not literal Lua variables provided by the probe):

```lua
print(extensions.beamrt_vehiclePairProbe.start(ID_A, ID_B))
```

Wait a few real frames without resuming physics, then:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getSummary()))
```

`phase="inspected"` means both snapshots were read and inspected, **not** that
reflections work. `getSummary()` prints compact, detached reports without the
long material list/poses; `getStatus()` still exposes full acquisition metadata.
Status deliberately leaves `feedsRayTracer`,
`reflectionsEnabled`, `offscreenTestPassed`, `geometryFreshnessVerified`, and
material/transform verification false. Reported triangle counts are primitive
triangle references, not certified unique/full rendered geometry coverage.

It uses the installed BeamNG `lua/ge/extensions/util/export.lua` conventions:
one `GPUMesh.bng_getGPUMesh(id)` request per car, asynchronous `dataIsReady`,
native indexed primitives, shared flexmesh buffers, separate propmesh buffers,
and `mesh:free()` after inspection. That exporter gives props separate position
and rotation transforms; our existing provider does not preserve them. The
probe therefore reports props as **unverified placement**, not world triangles.
It reports raw flexmesh bounds and world/vehicle-origin-translated containment
candidates against each live OOBB. Neither containment candidate proves the
coordinate frame; both can pass near the origin, and unused vertices can make
both fail. No Torque3D coordinate convention is assumed.

Diagnostic revision 2 additionally tests the inverse of the shipped exporter's
prop-position conversion: raw `(x,y,z)` becomes engine-relative `(x,-z,y)`, then
adds the vehicle origin. This assumes positions already include vehicle rotation;
no extra model rotation is applied. The exporter writes GPUMesh vertex bytes
directly into glTF without a Lua swizzle, but that is **not enough to establish**
the native flexmesh coordinate contract. `exporterAxesOriginRelative` in the
compact report is only this containment candidate, with the same 0.3 m OOBB
tolerance as the original checks. `exporterAxesMaxOutsideMetres` measures the
largest excess outside the OOBB before that tolerance. Even if it passes for
every vertex, coordinate verification stays false: multiple rotated/translated
cars and independent landmark/world alignment still need validation. Props,
normals, winding and shaded ray hits are not verified by this check.

Diagnostic revision 3 compares native prop position/quaternion metadata with
independently acquired live prop transforms. The shipped editor's
`veLightsDebug.lua` looks props up by JBeam `pid`, reads
`propObj:getLiveTransformWorld()`, and adds vehicle position to column 3. The
probe follows that live-anchor convention. It requires an **exact unique** mesh
name match in `core_vehicle_manager.getVehicleData(id).vdata.props`; it never
assumes the native prop index is a JBeam pid or resolves duplicate names by
nearest distance. Missing/ambiguous names and unavailable/invalid transforms
are explicitly counted. Numeric translation errors compare both origin-relative
and absolute interpretations. Quaternion errors compare direct and inverse
rotations, ignoring the equivalent quaternion sign. This metadata comparison
does not transform prop vertices or silently choose an interpretation. Passing metadata
comparisons still leaves `propTransformsVerified=false`; world alignment,
vertex winding, normals and material shading need separate proof. These
comparisons are snapshot evidence, not a guarantee against paused prop edits.

Diagnostic revision 4 adds an **opt-in sampled wireframe**, not a tracer input.
Acquisition prepares at most 64 flexmesh triangle samples and 64 prop triangle
samples per car (at least one per prop, at most 64 props). With 15 props, that is
64 flex plus 4 per prop, 124 total per car. This intentional sampling is only
for debug drawing, never a reduced mesh masquerading as complete ray geometry.
It requires the flexmesh axis candidate and unique live matches for every prop,
with translation differences <=0.01 m and direct quaternion differences <=0.1
degrees. It uses `MatrixF:mulP3F` from the actual live prop transform after
converting raw prop-local axes `(x,y,z)` to `(x,-z,y)`, then adds vehicle origin
once. It does not hand-implement or invert a quaternion to place prop vertices.
The editor also uses `MatrixF:mulP3F` to transform local points, for example in
`editor/ezObjectSelect/selectionGeometry.lua`. The local-axis hypothesis still
needs visual validation; native point transformation alone does not establish it.

After a fresh inspected capture, enable the preview explicitly:

```lua
local ok,why=extensions.beamrt_vehiclePairProbe.showAlignment(90)
print(tostring(ok)..": "..tostring(why))
```

Close the console and inspect the cars: A flex samples are cyan, A props yellow;
B flex samples are pink, B props orange. Check the wheel/steering geometry and
body panel edges, not only whether the samples fall somewhere inside the car.
Rotate/move one car between captures to test orientation/placement independently.
The preview expires after the requested 1..120 real seconds; 90 is the default.
To hide it immediately without discarding the metadata:

```lua
extensions.beamrt_vehiclePairProbe.hideAlignment()
```

All native GPUMesh resources are freed after acquisition as before. Only bounded
plain Lua triangle samples and live prop matrix-column snapshots are retained.
No debug drawing occurs until `showAlignment`; it draws from `onPreRender`.
Pose/physics/identity/material-name invalidation and a change to any captured prop
matrix column stop the preview. `alignmentVerified`, `propTransformsVerified`,
`feedsRayTracer` and `offscreenTestPassed` remain false even while drawing.
No shader, native light pass, reflection history or scene material is modified.

Diagnostic revision 5 adds an opt-in **full-mesh CPU geometric hit control**.
Unlike the preview, this visits every captured primitive triangle reference,
including props, with no decimation or screen-frustum filtering. It reuses the
geometric segment routine extracted from `sceneVisibility`; its existing
double-sided/0.08 m endpoint tolerance and visibility material policy remain
unchanged. This is not a BVH, a GPU performance test, a gameplay rendering feed
or a shaded reflection. The legacy `feedsRayTracer=false` status refers to the
rendering path; the separate `vehicleHitTest` reports the CPU-only diagnostic.

With both cars parked/paused and sufficiently separated, reload and start:

```lua
extensions.reload('beamrt_vehiclePairProbe')
local ok,why=extensions.beamrt_vehiclePairProbe.startHitTest(ID_A,ID_B)
print(tostring(ok)..": "..tostring(why))
```

It requests one fresh readback per car and frees native handles after acquisition.
CPU buffer references are retained only for the test, capped by the existing
32 MiB-per-car allocation preflight, and dropped on completion/cancellation.
It checks up to 8192 triangle references per update, with a 60-real-second
timeout after capture. This is a count budget, not a guaranteed millisecond
frame budget. It uses the candidate transforms from the preview; this does not
automatically certify their world alignment.

The four controls are A-to-B and B-to-A (origins 0.35 m beyond each car's
supporting OOBB plane), an upward ray above both cars, and A-to-B with B excluded
from CPU test data. The last control does not hide/delete B in the game. The
cars must be separated by their projected OOBB support radii plus 0.7 m; otherwise
the test refuses the setup instead of silently starting inside a target.

After several seconds, or to check incremental progress:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getHitTestStatus()))
```

`phase="complete"` means the full scans finished. `geometricControlsPassed=true`
additionally requires the two expected vehicle IDs and both miss controls.
The compact hit status includes car/mesh/material identity and distance;
`getStatus().vehicleHitTest` additionally exposes primitive identity, barycentrics,
point and ray endpoints. Opacity stays **unknown**, including named glass materials. A miss does not
certify unobstructed visibility in the whole game world. No camera/screen input
is read, but this alone is not an off-screen reflection acceptance test.
`opaqueVisibilityVerified`, `gpuExecutionVerified`, `materialShadingVerified`
and `offscreenReflectionTestPassed` always remain false. Pose/prop/physics
invalidation cancels the job and discards partial results/buffer references.

For an already loaded older probe, reload it before the next acquisition:

```lua
extensions.reload('beamrt_vehiclePairProbe')
```

Reload cancels the old probe; it does not reset/move the cars or pause physics.

The probe limits each car's destination buffers to 32 MiB, 500k vertices per
buffer, 1.5m indices, 256 submeshes per kind and 2048 primitives total, without
truncation. This bounds subsequent Lua FFI allocations, **not** the engine's
initial native readback allocation. Native handles and provider records owned
by the probe are released after inspection/cancellation/failure. An uncertain
native free blocks further acquisitions; it is not retried blindly.

Resuming physics, changing pose/material names, replacing/removing/resetting
either vehicle or changing mission invalidates the report. Checks do not
certify deformed geometry freshness or detect every paused mesh/material edit;
recapture after any such edit. An existing provider cache is not overwritten.
To cancel/clear before another pair:

```lua
extensions.beamrt_vehiclePairProbe.stop()
```

## Actual reflection acceptance test (not implemented/passed yet)

1. Validate both vehicles' world-space triangle placement, including rotated
   cars and separately transformed props. Establish explicit material coverage;
   glass/cutouts are not automatically opaque. Build a scene-space BVH path.
2. Keep a reflective panel of A visible. Position B so it should geometrically
   appear in that panel; merely putting two cars beside each other is not enough.
   Confirm a traced hit identifies **B's triangles**, then shade that hit.
3. Hold both cars and lighting fixed. Move only the camera until B leaves the
   main view but the relevant panel of A stays visible. Verify B is outside the
   full relevant input frustum, not just covered by a UI element. A correct
   reflection should change with the camera, not remain a frozen picture.
4. Reset temporal history and explicitly isolate SSR, cached reflection probes
   and extra-camera/cubemap contributions. B must still appear through the
   scene-space ray path; a reflected scene-camera image is not ray-tracing proof.
5. Hide/remove B (and rebuild/invalidate geometry) as a negative control; its
   reflection must disappear. Recapture between parked-pair changes. Reverse A/B
   for a second run. Only then test moving or deforming cars and live updates.

A mesh-hit mask is the first milestone. Shaded off-screen reflection and safe
live composition are additional milestones. Recursive cars reflecting each
other is multi-bounce work, not needed for the first single-bounce test.
