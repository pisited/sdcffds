# Isolated GPU ray comparison - revision 15

This moves a **small validation batch** onto a real hardware GPU. It is not a
GPU-rendered image, hardware DXR, an engine attachment or a live reflection effect.
The game still displays the paused CPU mask. The GPU receipt compares nearest
triangle owner/reference and distance for actual direct/reflected query segments.

Revision 16 adds a separate [GPU-generated BVH image](vehicle-gpu-image.md).
This twelve-ray baseline, endpoint and count limits remain unchanged.

## Architecture

The existing native worker cannot admit the full two-car scene: its packed mesh
contract caps nodes/triangles below this capture and uses a different format.
This diagnostic therefore uses a separate one-batch executable, not a modified
ABI, raised guard or automatic DLL load. It owns its D3D12 device, command queue,
buffers, shader and fences in another process. It neither discovers nor borrows
the game's device, descriptors, command lists, depth/color textures or swapchain.

The optional Lua client uses the same nonblocking LuaSocket contract already used
by installed BeamNG.Earth `beamngEarth/net.lua`: zero timeouts, partial-send
offsets, getpeername for connect completion and partial-receive handling. It does
not call that mod or change its companion connection. No Lua sandbox changes,
startup hooks, process attach, external network or third-party downloads occur.

Only a `127.0.0.1` endpoint is accepted. The helper binds an exclusive ephemeral
loopback port and publishes `/settings/beamrtGpuProbeEndpoint.json` with a random
128-bit one-session token, hardware flag and ten-minute expiry. The token is not
logged or copied into status. A wrong token is rejected without consuming the
valid batch. The helper exits after one successful batch or expiry. This is a
bounded local diagnostic, not a persistent or Internet-facing service.

## Data and limits

After BOTH native vehicle readbacks have been copied and freed, the existing CPU
BVH, original direct controls, camera checks, bounce reference/exclusion tests
and offscreen certificate run as before. GPU mode does not capture UVs, normals,
colors or any additional native mesh stream.

All copied triangle references are then converted to independent float32 records:

| Record | Bytes | Contents |
|---|---:|---|
| Triangle | 48 | a.xyz / owner, b.xyz / original reference, c.xyz / reserved zero |
| Ray | 32 | origin.xyz / reach, direction.xyz / excluded owner |
| Result | 16 | owner / original reference / distance / hit-or-miss state |

Positions and ray origins are rebased to the captured camera position BEFORE
float32 conversion. This reduces large-world precision loss but does not make
float32 identical to the CPU's double positions. There is no geometric decimation
or quantized atlas. Owner 1/2 maps only to the selected runtime IDs; owner 0 means
no exclusion. Every original triangle reference is retained, including props.

Limits are 500000 triangles and 32 rays in the host; the producer sends exactly
four direct controls plus full/excluded versions of up to eight sampled reflected
packets, at most 20 rays. The request has a 64-byte header, triangle/ray strides
and exact byte counts. Maximum payload is 24001024 bytes. Count, layout,
provenance, reserved fields, finite positions/rays, normalized directions and
segment ranges are checked before GPU submission. No CPU expected answers are
included in the request; the helper must compute its own nearest results.

Each owned triangle/ray array is converted to one bounded immutable Lua string
using `ffi.string(array, byteLength)`, as in installed `lua/common/lpack.lua`.
The largest extra string is 24 MB; it is dropped after that array is sent.
This avoids byte-pointer arithmetic, which BeamNG rejected in the first live
transfer even though stock LuaJIT tests accepted it. Triangle/ray transfer slices
the string into at most 64 KiB per coroutine/frame iteration. Socket
operations never intentionally block the game. Connect/send/readback has a
30-second deadline, inside the unchanged 180-second whole-job deadline. Packing
yields through the existing cooperative work budget. Stop/unpause/reset/camera
invalidation closes the owned socket and releases Lua buffers; uncertain native
mesh cleanup still blocks new captures. No raw vertex/index or network-payload
files are written: geometry travels through memory on loopback only. The helper
does not save it. Only metadata, a CPU image and private synthetic test artifacts
are persisted.

## GPU kernel and comparison

The shader is an explicit double-sided float32 Moller-Trumbore segment scan,
using the CPU kernel's determinant threshold 1e-7 and 0.08 m endpoint exclusions.
Each ray searches ALL references; it retains self hits and excludes only the
requested source owner. Equal float distances prefer the lowest original
reference. The CS 5.0 build uses precise values and strict IEEE compilation.
This small brute-force comparison is deliberately not a production BVH backend,
per-pixel throughput benchmark or DXR claim.

The helper copies uploaded data into owned DEFAULT buffers, transitions inputs
to NON_PIXEL_SHADER_RESOURCE, dispatches into an owned UAV, transitions the output
to COPY_SOURCE, copies it to READBACK, waits for a fence, then maps it. These
follow the public [D3D12 readback contract](https://learn.microsoft.com/en-us/windows/win32/direct3d12/readback-data-using-heaps).
GPU retirement failure terminates only the isolated helper with its resources
still alive; it must not release them early and continue serving. Hardware and
timeout behavior are not evidence of safe access to game resources.

The Lua client validates reply session, version, hardware flag, sizes and counts.
Hits must agree with the CPU on exact owner AND original reference, with distance
error at most `0.001 + 0.0001*abs(cpuDistance)` metres. Misses require the explicit
sentinel fields. Near-edge float precision or different tie choices may produce
a reported mismatch; mismatches are retained, never silently treated as a pass.
`offscreenGeometryComparisonPassed` additionally requires a matched reflected
batch ray whose full captured source bounds have the offscreen certificate.

## Build and isolated checks

Build with installed MSVC/Windows SDK; no installers:

```powershell
./native/vehicle_probe/build.ps1 -RunTest
./.beamrt-validation/python-tests/Scripts/python.exe -B tools/tests/run_vehicle_gpu_probe_transport.py
```

On October 24, the RTX 4070 passed 12 native analytic/validation checks including
500000-reference nearest-hit/exclusion stress. A separate real loopback test
then matched six Lua-produced synthetic ray segments, including one reflected
hit on wholly offscreen source geometry. It also rejected a wrong session. The
D3D12 debug layer was unavailable. These are synthetic hardware/transport results,
not an actual vehicle GPU result. Unit fake-socket tests are not GPU evidence.

## Live run

First start the built helper (normally the assistant does this). On Windows use
a hidden process; keep its console logs in the private validation folder:

```powershell
./native/vehicle_probe/start.ps1
```

This starts a hidden process, checks readiness, preserves timestamped stdout/
stderr logs and a binary/shader-hash receipt in the private validation folder.
It refuses a second live listening endpoint rather than launching duplicates.
The endpoint's token is not included in that receipt or output.

No game relaunch is required. Keep the known parked pair and physics paused.
Use the successful offscreen free-camera setup and hold it still. Within ten
minutes of starting the helper, run once in GE Lua:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startGpuReflectionProbe(); print(tostring(ok)..': '..tostring(why))
```

Close the console to see progress. After completion:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getGpuStatus()))
```

Look for `gpu.phase="passed"`, `gpu.passed=true`, all rays matched and
`gpu.offscreenGeometryComparisonPassed=true`. `gpu.hardwareExecutionVerified`
means the isolated helper's hardware readback was validated, not that a GPU
reflection was rendered into BeamNG. Top-level `gameIntegrationVerified=false`
remains intentional. The UI shows a CPU hit-mask image with a separate GPU count.

Each helper serves only one batch. A repeat needs a fresh helper endpoint;
an expired/dead helper does not trigger auto-restart or shader/DLL loading.
Saved CPU masks use `/settings/beamrtVehicleRayImage-camera-gpu-<run>.bmp`.
Matched readback/comparison metadata gets explicit pair-journal stage markers.
The live two-car GPU comparison passed on October 24; see the result below.

## First live transfer failure and repair - October 24

The first live attempt stopped at `ptr + offset` during byte-chunk conversion
with `bad argument #1 to '__add' (invalid C type)`. Both native vehicle readbacks
had been copied and freed; no full GPU packet or successful readback completed.
The separate helper reported an incomplete socket receive and exited. This is
not a GPU comparison mismatch or a successful GPU run.

The transfer now uses the installed owned-array/string contract above, with no
`ffi.cast` or pointer addition. Regression checks make pointer casts unavailable
and verify small plus multi-chunk packets still preserve every byte and match
the expected queries. The actual synthetic hardware transport was rerun and
matched six rays including one offscreen source ray.

Automatic image-job failures now keep a small error panel visible for 120 seconds
and retain a detached GPU failure summary (phase, packed/sent counts and reason).
Owned mesh arrays, coroutine work and sockets are still cancelled/freed. The
failure panel can be hidden with `hideImage()`; a fresh start or unload clears it.
This does not preserve failed geometry or turn cancellation into a passed result.

## Live vehicle hardware result - October 24

Run `20261024T160417Z-6544.2719222-1` completed with the real captured two-car
scene. The isolated RTX 4070 helper reported 338768 full triangle references and
12 ray segments, then exited normally. The live reply showed all 12 nearest
owner/reference/distance comparisons matched, no mismatches, and two matched
reflected rays to wholly offscreen captured source geometry. Both
`hardwareExecutionVerified` and `offscreenGeometryComparisonPassed` were true.
The 16261312-byte packet matches the full triangle/ray counts and protocol header.

The pair journal contains this run's `isolatedGpuReadbackComplete`,
`isolatedGpuComparisonMatched`, successful save boundaries and `cpuImageComplete`
markers. Its saved 128x136 CPU mask has 124 inter-car hits in the full row and
zero in the excluded row, with 545 receiver self-hits retained in each. The 124
mask hits are CPU image samples; only the explicit 12-ray batch, including two
offscreen positive samples, was compared on GPU. Do not call the mask GPU-rendered
or extrapolate the sampled result into all-pixel correctness/performance.

This establishes live vehicle geometry transfer plus matching isolated hardware
queries. `gameIntegrationVerified=false`, `dxrUsed=false`, and the absence of a
game-frame GPU reflection effect remain intentional. A GPU acceleration structure,
full-image ray generation, surface/radiance shading and frame composition are
separate remaining work. A later repeated command needs a new one-batch helper;
it does not change this successfully saved run's evidence.
