# v0.108 — exact-adapter native device bootstrap; no game attachment yet

## Missing functionality / new concrete route

The worker originally required a caller to provide an ID3D12Device pointer. No
verified BeamNG rendering export supplied that pointer. However, the documented
Direct3D 12 API normally reuses an existing same-process device for an adapter.
That offers a narrower device-bootstrap route than building a proxy/injector just
to discover a device. It does **not** enumerate game textures or render passes.

Primary contracts: [D3D12CreateDevice](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-d3d12createdevice),
[EnumAdapterByLuid](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgifactory4-enumadapterbyluid),
[resource GetDevice](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12devicechild-getdevice).
The game log also shows BeamNG finding the already-loaded System32 D3D12 runtime,
then creating and releasing a throwaway capability-probe device. Capturing the
first device creation or placing a same-named DLL is not reliable attachment proof.

## Implemented

Worker C ABI v2 preserves the existing create/upload/trace/destroy functions and
their scene/ray/hit layouts, adding:

- `BeamRT_WorkerCreateOnAdapter`: exact adapter LUID, explicit candidate-creation
  opt-in, no default-GPU fallback, validated compute shader and worker ownership.
- `BeamRT_WorkerGetDeviceInfo`: reports adapter identity and acquisition provenance.
  Supplied-device (1) and adapter-candidate (2) are not game-connected states.
- `BeamRT_WorkerDeviceMatchesResource`: checks canonical COM device identity
  against the parent of a valid resource supplied by a verified native host.
  Foreign-device resources are not accepted as ours.

Important: D3D12CreateDevice can create a device when none exists. The explicit
candidate opt-in prevents silent creation, but cannot distinguish reuse by itself.
Same adapter/LUID alone must not be reported as BeamNG attachment. Owner identity
is stronger evidence, but still does not prove that the resource is game depth,
belongs to the right view/frame, or has correct synchronization/state.

There is no memory scan, private engine address, hook, proxy, ReShade dependency,
DLL installer, automatic load or sandbox change. The worker still executes on its
own queue/resources. No code reads or modifies BeamNG's process in this batch.

## Current tuner availability

Main runtime v0.108 marks underground local-light visibility unavailable on the
unverified clustered interface, rather than offering a button that repeatedly
fails. A preflight refuses activation before loading the extension. Read-only
status uses rawget so querying the tuner cannot implicitly load it through
extensions.__index. Existing enabled legacy hooks remain disableable; legacy
activation remains supported when the original backend guard permits it.

This is availability handling, not a local-light fix. Namespace exposure still
does not prove the active rendering path. Native light output and existing
GI/SSR/presets remain unchanged. The v0.107 optional-noise resource fix remains.

## Verification

- Strict MSVC /W4 /WX and compute FXC /Ges /WX compilation passed.
- On RTX 4070, exact-adapter bootstrap reused the offline test host's device,
  matched a resource created by that host, and rejected a WARP resource owned by
  another device. Missing opt-in, unknown adapter, invalid ownership arguments,
  ABI provenance and the original caller-device route are checked.
- The real 776-triangle/255-node guardhouse batches still match CPU brute force
  for opaque/uncertain coverage and transformed instances. Synthetic WARP checks
  also pass. Controlled fixture opacity is not live material evidence.
- Seven new actual Lua/main/tuner tests cover inert unavailable UI, no automatic
  extension loading, legacy activation and reliable disable. All 102 regression
  tests pass; main compiles in Lua 5.1 and LuaJIT. The Windows workflow already
  runs the enlarged native self-test; remote CI awaits publication.
- D3D12 debug layer remains unavailable locally. No live-game compatibility,
  device-loss/timeout, frame synchronization or performance claim follows.

## Remaining integration boundary / next substantial milestone

The five-condition in-game milestone is NOT passed. The candidate-acquisition
library has never been loaded into BeamNG. Real camera/depth resource acquisition,
producer/consumer queue synchronization and a lighting consumer are missing.
The current ray-batch CPU readback remains offline validation only.

Next is obtaining a real game-owned frame resource through a verified native
mechanism, checking its device/view identity, and feeding a native visibility
result into intended lighting with reliable restoration. Do not expand the
standalone renderer or ask for another old guardhouse comparison instead.

Review loading/integration and removal separately before any game deployment.
If no real resource handle is available, an in-game LUID-only success message
would not answer this blocker and is not a useful new test. Lua scene objects
must never be cast to guessed graphics pointers.

Use the one-line GE Lua reload at the top of README for the v0.108 tuner change.
That reload does not import a native DLL or activate a new shadow path.
