# GPU-generated BVH hit image - revision 16

Revision 15 verified twelve hardware ray queries on all 338768 captured vehicle
triangle references, including two rays to a wholly offscreen source. Revision
16 uses a BVH and generates the entire small camera/reflected-ray grid **on the
GPU**. The old twelve-ray comparison remains available unchanged.

This is an actual GPU-traced geometry image in a separate helper, displayed next
to a CPU reference. It is not painted/material-shaded reflections, live vehicle
updates, hardware DXR, or composition into the native game frame.

## Run

Start the image helper, normally done by the assistant:

```powershell
./native/vehicle_image/start.ps1
```

It starts hidden, preserves timestamped logs/hash receipts, and publishes a
separate localhost endpoint for one image. This session lasts **30 minutes**.
The old ray-probe endpoint cannot be used for the image protocol. No game restart
or engine hook is needed.

Keep two parked cars and physics paused with J. Use the successful offscreen
free-camera setup: point at one car's inward-facing door, with the other car
entirely outside the view. Keep camera/FOV/window size still. In GE Lua:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startGpuImageTest(); print(tostring(ok)..': '..tostring(why))
```

After completion, or if an error panel appears:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getGpuImageStatus()))
```

The four-panel image is 256 pixels wide and twice the frozen primary grid height:

| | Left | Right |
|---|---|---|
| Top | CPU full-pair reference | GPU primary + full-pair reflected queries |
| Bottom | CPU source-excluded reference | GPU source-excluded reflected queries |

Green=other car, orange=receiver self, slate=primary hit/reflected miss, dark=
primary miss. Purple in the GPU column means an invalid/incomplete query, never
a fabricated miss. The CPU does not supply the GPU's primary hit or reflected
directions; those are computed independently in the shader.

`gpu.passed=true` requires all pixels' primary/full/excluded records to match
the CPU in owner, original triangle reference and distance tolerance, with zero
invalid/incomplete pixels. `gpu.offscreenGeometryControlsPassed=true` additionally
requires positive GPU hits on a wholly offscreen captured source, exclusion and
unchanged receiver self hits. Counts/differences remain visible if float32 and
double results disagree; a mismatch is not silently accepted. Completion alone
does not mean a pass. A valid all-miss view can complete without an offscreen pass.

## Full geometry and acceleration structure

All copied primitive triangle references are retained as the existing 48-byte
camera-relative float32 records. The CPU-built BVH's topology and full triangle
permutation are sent too. The helper validates child ordering, parent uniqueness,
connectivity, depth, all leaf ranges, range non-overlap and complete permutation
coverage. It refuses missing/duplicate references, cycles/shared children and
over-budget trees. It does not silently discard triangles to fit.

Bounds are then rebuilt bottom-up in the helper from the **actual uploaded float
vertices**. This avoids clipping caused by rounding old double bounds separately.
GPU nodes are 48-byte float-bound records; topology construction/refitting is CPU
work, while primary/reflected traversal is GPU compute. This is not DXR BLAS/TLAS
construction. The root and every descendant cover all their uploaded triangles.

The shader uses a 64-entry explicit stack for the host-validated maximum depth
40. Box tests have a small conservative float padding; the triangle test and
endpoint policy retain the previous geometric segment rules. Traversal searches
nearest hits, retains receiver self intersections and excludes only the other
owner in the negative control. Equal float distances prefer the lowest original
reference. Normals come from the nearest float triangle's cross product, with
no native normal stream, smoothing, face-forward repair or normal-map sampling.

The native helper rejects leaves above 4096 references. Each GPU query is bounded
to 8192 node visits and 65536 triangle tests. Budget exhaustion returns explicit
state 3 (incomplete); malformed traversal state returns state 2 (invalid). Neither
is state 0 (miss), and either prevents a pass. `incompletePixels` is reported as
a subset of unusable/invalid pixels. These caps are not all-scene coverage claims.

## Camera and independent references

The native-unprojection-validated frozen main-camera contract is unchanged. The
shader receives right/forward/up, near/far, asymmetric frustum edges and the
secondary segment length, with the camera translated to origin zero. It generates
one near-plane primary ray per 128-wide grid sample (height 32..96), finds the
nearest of both cars, derives its face normal, reflects, offsets by 0.01 m and
traces full/source-excluded segments. The 0.08 m segment endpoint exclusions and
1000 m primary cap remain. No depth/color screen buffer is an input.

The CPU independently renders the same grid using double world positions and
its existing BVH. The original direct controls plus bounded linear primary and
bounce reference comparisons still run. CPU primary/full/excluded owner, reference
and double distance are kept in a local 48-byte-per-pixel expected array. They are
**not sent to the helper**. Every returned GPU query record is checked, not just
the twelve earlier samples. Distances retain tolerance
`0.001 + 0.0001*abs(cpuDistance)` metres; owner/reference matches are exact.

FP32 conversion, face-normal differences and silhouette/coplanar edge ties can
produce legitimate disagreements. `ownerDisagreements`, `primitiveDisagreements`,
`distanceDisagreements` and up to eight witness records remain in status. They
prevent `passed=true`; the diagnostic still shows both images to inspect them.
The native offscreen certificate describes captured triangle bounds and the
frozen frustum, not every engine draw/VFX pass or a complete native scene.

### Automatic full-scan recheck

Protocol 2 automatically rechecks at most eight differing pixels with a separately
compiled GPU shader that scans every uploaded triangle without using the BVH.
Only pixel indices are sent for this second step. The original camera and uploaded
float geometry are reused; no CPU expected hit, distance or direction is supplied.
All three query records (primary, full and excluded) are checked against the
original accelerated GPU records in state, owner and reference, with distance
tolerance `0.000001 + 0.000001*abs(gpuDistance)` metres. Invalid/incomplete records
cannot pass this audit. Bit-exact record agreement is also counted separately.

`gpuLinearRecheckPassed` describes only the selected GPU rechecks.
`gpuLinearRecheckCoversAllDisagreements` is false if more than eight pixels differ.
`primitiveOnlyCpuDisagreement` requires that every differing pixel was audited,
all GPU rechecks matched, and the CPU comparison differed only in references.
**None of these changes the original strict `passed` or offscreen result.**
A passing recheck supports agreement between the two GPU traversal paths; it does
not by itself prove why the CPU selected another triangle. Small mesh/material
provenance records are attached to mismatch witnesses for further investigation.

## Separate bounded transport

The new protocol uses `/settings/beamrtGpuImageEndpoint.json`, schema
`beamrt.gpu-image.v2`, a random one-session token, loopback-only ephemeral port,
and separate input/output magic. No DLL is loaded into BeamNG. No sandbox,
startup, device/descriptor hook, native renderer state or car placement changes.
Both native mesh handles are freed before BVH/image transport begins.

The request has a 64-byte header followed by full triangles (48N), topology (16M),
permutation (4N), and camera floats (64 bytes). At most 500000 triangles,
`2N-1` nodes and 128x96 primary pixels are admitted. Maximum payload is 42000048
bytes. Camera coordinates, dimensions, axes, handedness and ranges are checked.
Result records contain three 16-byte hits per primary pixel, at most 589824
payload bytes, preceded by a 64-byte authenticated/session-bound header.

The same socket then requires a 64-byte `BRGCHK1` version-2 header plus up to
eight uint32 pixel indices. A zero-count request explicitly finishes a fully
matching image. The `BRGCKO1` version-2 reply contains a 64-byte session header
and one 52-byte record (index plus three hits) per requested pixel. Dimensions,
token, unique indices, count and strides are validated. The helper retains the
geometry only until this bounded handshake completes, the socket closes or its
receive timeout expires. Old version-1 image endpoints are refused before capture.

Owned arrays convert through the already live-tested `ffi.string(array,length)`
path; no byte-pointer arithmetic is used. Strings transfer in at most 64 KiB per
coroutine/frame iteration, and all socket operations are nonblocking in the game.
Each image/audit transfer has a 60-second deadline within the 180-second whole-job
deadline. Geometry stays in memory and is never written to a mesh/network dump.
Only metadata and the comparison BMP are saved. The helper exits after one image
or session expiry. Stop/reset/unpause/camera changes close sockets, clear expected
arrays and cancel coroutine-owned buffers. Failure summaries/error panels survive
for inspection; they do not retain failed geometry.

Owned D3D12 input buffers transition from COPY_DEST to compute SRV, the result
UAV transitions to COPY_SOURCE, and readback is mapped only after a fence. A GPU
retirement failure terminates only the isolated host with its resources still
alive. This does not establish synchronization/lifetime rules for game resources.
`gameIntegrationVerified=false` and `dxrUsed=false` remain intentional.

## Validation

```powershell
./native/vehicle_image/build.ps1 -RunTest
./.beamrt-validation/python-tests/Scripts/python.exe -B tools/tests/run_vehicle_gpu_image_transport.py
```

The RTX 4070 hardware test compares accelerated traversal with a separately
compiled, full linear GPU scan. The endpoint uses that reference shader only
for the bounded selected-pixel audit. Across normal, rolled/asymmetric, odd-height, maximum-size and
single parallel-ray images, **29185 pixels matched exactly**. The baseline had
144 reflected source pixels; four invalid topology/permutation guards passed.
Four selected-pixel reference dispatches also matched the accelerated records
bit for bit.

The real loopback test then sent Lua-produced synthetic geometry/topology/camera
and compared all **8704 GPU-generated pixels** against independently generated
CPU rays. All matched, including eight offscreen source hits, with zero invalid
pixels. Its zero-count audit handshake completed normally. A second hardware run
deliberately changed one CPU expected reference as a synthetic negative control:
the selected full-scan GPU recheck matched bit for bit while the strict CPU
result remained **8703/8704, failed**. It rejected a wrong session. The D3D12 debug layer was unavailable, so
this is not a debug-layer-clean claim. Unit mock sockets are not GPU evidence.
The synthetic CPU/GPU comparison PNG and metadata are private validation artifacts.

### First live vehicle image

Run `20261024T165216Z-9423.6187347-1` uploaded all **338768 triangle references**
and **134795 BVH nodes**. The image completed with **8703/8704** strict pixel
matches, zero invalid/incomplete queries and no owner or distance-tolerance
disagreements. One full reflected query at `(76,35)` selected CPU reference
207578 versus GPU reference 207569, both in owner 2. Its distances were
3.7230736676637 m and 3.7230467796326 m (about 27 micrometres apart). The strict
result remains a mismatch; this run predates the automatic GPU recheck, so its
cause has not been established. This view had 103 reflected other-car hits but
zero certified offscreen hits because neither full captured car bound was outside
the frozen frustum. It does not replace the earlier offscreen 12-ray result.

No playable performance, temporal
stability, deforming geometry update, opacity, roughness, material radiance or
native frame composition has been established. Saved comparisons use
`/settings/beamrtVehicleRayImage-camera-gpu-image-<run>.bmp`. The journal records
`isolatedGpuImageReadbackComplete`, matched/mismatch and save completion markers.
