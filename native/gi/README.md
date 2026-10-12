# Native GPU visibility to owned GI: first adapter slice

Status 2026-10-11: implemented, offline-validated resource adapter and matched
shader consumer. **Native C++ adapter not attached to BeamNG.** No loader,
launcher, graphics hooks, resource discovery, ReShade dependency or DLL install.
v0.109 separately registers an opt-in engine-managed pixel-pass backend using
the same producer query and consumer format; see [game-side activation](../../GI_VISIBILITY_BUFFER_V0109.md).
The existing worker remains ABI v2; this separate adapter has its own ABI v1.

## What this implements

1. `beamrtGIReceiverExportP_v001.hlsl` exports biased world receiver origins in
   full-float RGBA. It uses the native-consumer beauty pass's **same** decoded
   depth, eye ray, geometric-normal function and origin-bias helper. No duplicate
   depth reconstruction or native guesses about the game's depth encoding.
2. `visibility.cs.hlsl` reads that texture and the **existing** packed mesh,
   reusing `beamrtMeshBVHCommon.h.hlsl`. It tests receiver-to-surfel-centre
   segments, matching v083's 0.08-metre endpoint exclusions. Only category 2
   (declared opaque) sets a rejection bit. Unknown/cutout/blended geometry does
   not become a solid blocker; invalid/incomplete traversal retains fallback.
3. `beamrt_gi.cpp` validates native device ownership, full texture formats/views,
   known legacy resource states, dimensions, imported instance constants and
   generation tokens. It records GPU compute on a caller's **dedicated DIRECT
   command list** and restores input resource states. It never discovers a
   device, creates/submits a queue, performs CPU readback or waits for the GPU.
4. `beamrtGITraceP_v084.hlsl` consumes the output in the sixth GI input (`t5`).
   It rejects only the selected world-surfel bounce inside the existing
   integrator. Screen-space samples, sun/headlight shading, sampling, temporal
   reconstruction and denoising are not replaced. Existing Lua selects v082
   or opt-in v083 by default. Explicit v0.109 buffer selection registers v084
   and the engine-entry receiver-export v002; native v001 named entry is retained.
5. Every frame retains input/output resources, private descriptors, constants
   and pipeline objects until a host fence completes **after the last consumer**.
   Retirement is nonblocking and refuses unmarked/in-flight recorded work.
   Explicit discard is permitted only after resetting/discarding an unexecuted
   command list. Stop/join callers before destruction; unloading a DLL does not
   cancel GPU work.
6. The offline GI fixture now exercises capture-to-frame handoff. A synthetic
  producer submits the fixture's packed-mesh and receiver SRVs through the real
  capture hooks; the test supplies resource states, dimensions, scene data,
  generation keys and surfels explicitly. It then records GI compute and the
  consumer on the same DIRECT queue, rejects destruction at the compute fence,
  and retires the frame only after the consumer fence. This is not automatic
  conversion or BeamNG resource discovery.

This is a GPU resource handoff implementation, not another standalone tracer
algorithm. The remaining host integration must actually capture and supply the
game resources and order these passes; a manually fabricated host is not proof
that those resources are exposed by BeamNG.

## Matched host contract (not yet implemented)

The host must identify the **exact owned GI shader bytecode and root layout**,
not a draw size or `Present`. Capture live SRVs/views, per-draw constants,
viewport, target, frame/view identity, descriptor copies, lifetimes and barriers.
Unknown, partial, MSAA, typeless, enhanced-barrier, bundle/indirect or cross-queue
layouts retain the original rendering until explicitly supported.

For one controlled view:

- Record the receiver-export draw using the same depth/normal resources, camera
  and viewport/interpolation as the GI beauty draw. Use a full-resource
  `R32G32B32A32_FLOAT` texture at exactly GI resolution, with no encoding,
  filtering, accumulation, scaling, missing viewport coverage or history.
- Pass the exact current surfel position/radius values and active count to the
  adapter. Copy the live material-policy and imported-instance constants. The
  mesh must be the linear `R8G8B8A8_UNORM` single-mip packed atlas, not a guessed
  address, name, resource with unknown state, or cooked/lossy surrogate.
- Use distinct exact positive 24-bit generation tokens for view/frame,
  geometry/material policy and surfel data. Do not reuse a token while matching
  stale output may still exist. Fourth key channel is layout ABI 1. Camera/view,
  geometry, material policy or surfel changes invalidate prior correspondence.
- Create the frame before recording; record native compute in its own fresh
  DIRECT list. Submit export -> compute -> consumer in that order on the same
  serialized DIRECT queue. No CPU readback/upload of a per-frame mask. No
  modification of an existing host command list's descriptor heaps/PSO/root
  state. The adapter does not submit or verify host ordering on its own.
- Copy the borrowed output SRV into a **compatible consumer-owned** descriptor
  heap for t5. It is full-float `W x (H+1)`: row-zero pixel-zero key, then four
  integer byte channels packing 32 blocker bits per receiver. Invalid texels
  are negative. Consumer uses integer loads, not interpolation or tone mapping.
- Use the existing source packing (light RGB + retro A at t3). Register/bind the
  matched v084 **vertex and pixel** shaders/root layout. Rebuild perDraw constants
  using shader reflection: adding native uniforms changes offsets of following
  post-FX uniforms. Do NOT reinterpret an old raw constant buffer wholesale or
  replace pixel bytecode alone. Visibility key, enabled and size uniforms must
  match the output; stale key/size/invalid texels preserve the old contribution.
- Associate a genuine same-device fence/value scheduled after **both** compute
  and the final GI consumer. Mark before submission where possible. Keep all
  lists/resources/descriptors alive if submission/signalling fails. Do not
  discard potentially executed work to bypass retirement.
- OFF must select the **original GI graph, shaders and source bindings**, stop
  new work and safely reset changed GI history. Setting the native predicate's
  enabled field to zero is tested fallback, not proof that a game hook and its
  source-pack/history changes were removed. Those host controls remain missing.

The first-integration safety budget is at most 1,048,576 receiver/surfel pairs
per frame; overflow refuses activation, never truncates coverage. No playable
performance claim. Do not silently change the user's GI resolution/preset.

Resource-state, descriptor and retirement requirements follow Microsoft's
[resource-barrier](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12),
[descriptor-heap](https://learn.microsoft.com/en-us/windows/win32/direct3d12/descriptor-heaps)
and [fence-lifetime](https://learn.microsoft.com/en-us/windows/win32/direct3d12/fence-based-resource-management) documentation.
Loading/deployment constraints remain in [the connection review](../../NATIVE_GI_CONNECTION_REVIEW.md).

## Build and verification

Uses installed MSVC/SDK and the existing fixture generator; no prerequisites
installed. The build also compiles the isolated capture dependency using its
pinned Detours source. Artifacts remain ignored in `.beamrt-validation/`.

```powershell
./native/gi/build.ps1 -Python python -RunTest
./native/gi/build.ps1 -Python python -SyntheticFixture -RunTest -Warp
```

Local full GI/export compilation additionally accepts `-NativeIncludes` pointing
to an existing extracted BeamNG include root containing `shaders/common/`.
No engine headers or private game geometry are redistributed. CI compiles the
native producer and the **exact consumer predicate** shared by v084 and the
fullscreen GPU fixture; it cannot compile the complete engine GI shader without
local includes. The fixture is not the complete GI integrator or a live camera.

Hardware/real-guardhouse and WARP/synthetic fixture tests cover opaque rejection,
all 32 bits, unchanged independent screen contribution, disabled/ON/disabled,
stale generation keys/dimensions, viewport mapping, unresolved/mask/blend
fallback, invalid receiver/mesh fallback, ownership/contract checks, single-use
recording and fence/discard lifetime gates. The capture handoff test verifies
real captured SRV identity, explicit sidecar inputs, same-queue producer/compute/
consumer order, snapshot release and post-consumer retirement. CPU readback is
only in this isolated test executable to assert final pixels, never in the
adapter's rendering path.

Remaining unverified: actual BeamNG input capture/loading, complete GI draw
consumption, game-side source-pack/history restoration, concurrent frame/queue
integration, device-loss recovery and performance. The D3D12 debug layer was
unavailable locally. No new in-game test until a reviewed complete host path
exists; do not repeat unchanged sun/guardhouse tests.

Local results, 2026-10-11: strict MSVC `/W4 /WX`, FXC `/Ges /WX` producer and
fixture shader builds passed; RTX 4070/real guardhouse and WARP/synthetic tests
passed. Full v082/v083/v084 and receiver-export VS/PS compiled using the local
BeamNG include snapshot. The v082 pixel bytecode before versus after the guarded
integration additions is identical (SHA256
`924033ff8e0473e83e7fc8983d56f5d405acdfbbe58cdd733181c83a79a37cdc`).
The 107 Python/Lua regression checks passed. Remote CI has not been verified.
