# Offline BeamRT D3D12 BVH worker

**Not a BeamNG bridge, loader, injector or ReShade add-on.** This is the small
native worker portion of the proposed integration. It uses a caller-supplied
ID3D12Device and its own command queue/resources. It has no engine discovery,
device interception, sandbox changes or automatic DLL loading.

It reuses `beamrt_bvh_pack.py` and the existing
`beamrtMeshBVHCommon.h.hlsl`, not a second geometry importer or tracer. The native
shader uploads lossless RGBA8 data directly, avoiding texture cooking. It traces
unit world rays through the instance inverse basis without renormalizing the
model-space direction. Only explicit opaque coverage returns category 2;
unknown/cutout/blended coverage is uncertain, not a certified blocker.

## Build / isolated validation

Requires installed x64 MSVC and Windows SDK FXC. The build script finds Visual
Studio through vswhere; it never installs prerequisites. Output is confined to
Git-ignored `.beamrt-validation/native-worker/`. Example from the repository root:

```powershell
./native/worker/build.ps1 -Python python -RunTest
```

The default fixture uses the existing private guardhouse package. CI uses
`-SyntheticFixture -RunTest -Warp`; it must not redistribute game geometry.
WARP is explicit and is not hardware performance evidence. RunTest starts only
the separate self-test executable, never BeamNG. No files go into game Bin64.

The DLL ABI rejects a missing host device; successful standalone creation is
not a game attachment. The self-test owns a separate device, loads the worker
in that test process, and checks GPU results against CPU brute-force queries on
the exact packed triangles. Controlled opaque/unknown policies are test inputs,
not a claim about the guardhouse's live alpha materials.

## Implemented

- Versioned C ABI, caller-device retention, owned compute queue/root layout/PSO.
- Existing packed texture upload, explicit world instance/material constants,
  batched GPU ray traversal and deterministic category/visit results.
- Count/layout/header/finite/transform/ray validation; failed input replacement
  preserves existing scene state. Corrupt BVH topology returns invalid on GPU.
- Fences before allocator reuse/readback/resource retirement; timed-out or
  unsignaled GPU work retains resources and the worker for later cleanup rather
  than freeing live objects. Stop/join callers before destruction.
- Dedicated command lists: no native command-list state is modified.

The current synchronous readback API exists for offline validation only. It is
not a production per-pixel/gameplay bridge. No buffer aliasing, borrowed game
depth resource, in-game command submission or lighting composition is implemented.

## Validation and remaining boundary

On 2026-10-11 the strict FXC cs_5_0 and MSVC /W4 /WX builds passed. An isolated
RTX 4070 run used the real 776-triangle/255-node guardhouse data. Opaque,
uncertain and translated/non-uniformly scaled 128-ray batches agreed with CPU
reference categories. Invalid input, corrupt node topology, recovery, destruction
and recreation are checked. The D3D12 debug layer was unavailable locally; this
is not a debug-layer-clean claim. GitHub workflow results require publication.

Device loss/timeout and concurrent game rendering have not been exercised.
There is no measured playable performance, live material/mesh alignment proof,
game camera/depth access or consumption of a native visibility result by BeamNG.
The original five-condition in-game integration milestone is **not passed**.

Next step is a separately approved, verified host adapter that supplies the
actual game device/resources, synchronization and a real lighting consumer.
Do not install this worker with ffi.load and call it integrated: loading a DLL
does not provide those missing capabilities. No ReShade dependency is introduced.
