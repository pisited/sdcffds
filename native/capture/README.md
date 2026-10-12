# Read-only D3D12 resource-capture prototype

Status, 2026-10-11: implemented and tested **only in the isolated test process**.
No BeamNG loader, launcher, DLL insertion, game-file change, Lua sandbox change,
ReShade dependency or lighting replacement is included. The existing game-side
renderer is unchanged. This is an input-capture milestone, not a shadow fix.

## What is actually implemented

`beamrt_capture.dll` intercepts 24 real public D3D12 API method implementations
using Microsoft Detours. The fixture invokes normal SDK methods; it does not
fabricate observations or feed a list of pretend resource handles to the DLL.

- Exact compiled pixel/compute shader bytes **and** exact serialized root
  signature identify the intended pass. Size, filename, draw dimensions and an
  exposed `ClusteredShading` name are not pass identities.
- Actual SRV creation, CPU staging-to-GPU descriptor copies, pipeline/root/heap
  binding, command-list resets, draws/dispatches and queue submissions establish
  descriptor provenance. No descriptor-heap memory is read by the capture code.
- SRV resource references are resolved at submission, so legal changes made
  between recording and submission are represented. Null, unknown, CBV/UAV
  overwrites and unsupported views do not reuse old SRV provenance.
- Graphics and compute root state are tracked separately. Heap changes clear
  both table sets, including a sampler-heap change. Reset/ClearState start a new
  recording generation. Bundles/indirect commands conservatively invalidate
  capture for that list; the original API calls still run unchanged.
- A snapshot retains its actual `ID3D12Resource` references after explicit host
  detachment. It contains the submitted view descriptions and a recording and
  submission serial. It is **not automatically current-frame data**.
- The DLL does not record GPU work, replace draws, allocate a visibility target,
  submit commands, read GPU pixels or modify lighting. Errors disable capture;
  callbacks forward the renderer's original arguments/results.

Method slots come from `offsetof` on the public Windows SDK COM interfaces in
`sdk_methods.c`, not guessed BeamNG offsets, engine-memory scans or object names.
Start uses the caller's valid device and creates empty SDK objects to discover
method implementations. It does not create another device or submit those lists.

## Strict scope: not ready for game deployment

The caller must provide an exact pass contract and call Start **before** the
target root, pipeline, heaps, views and command lists are created. Late attach
does not recover existing descriptors. An unsupported/unknown binding produces
no certified capture.

This prototype supports **one D3D12 API-calling thread**, the Start caller.
Start and Stop require externally established API-call quiescence, explicitly
passed as `apiCallersQuiescent=1`. A timer, paused simulation or Present hook does
not establish that condition. Other-thread API activity poisons capture while
forwarding the original call. This guard is not a multithread-safe game host.

Only legacy CreateCommandList and graphics/compute pipeline creation are
observed. Supported views are one-mip, non-array, non-MSAA Texture2D views and
structured-buffer SRVs. Raw/typed buffers, texture arrays, unbounded tables,
pipeline streams, newer creation methods and other method implementations are
not supported. The root contract is decoded through the version-1 deserializer.
Only the last matched draw/dispatch in a command-list recording is published.
Non-target submissions can leave a historical snapshot available; callers must
never treat availability alone as evidence of frame freshness.

Metadata holds strong references until Stop and has hard limits: 64 heaps,
512 tracked SRVs, 32 matching roots, 64 matching pipelines and 64 command lists.
Budget exhaustion disables capture. It intentionally lacks game-scale object
retirement, heap recreation/resize, device-removal recovery and queue retirement.
References prevent premature deletion, but do not prove safe GPU use or fences.

`cameraVerified`, `gpuOrderingVerified` and `lightingConsumed` always remain zero.
No camera matrices/root constants, viewport, depth interpretation, RTV/UAV
output, barriers, fences or producer-to-consumer synchronization are certified.
Matching resource format/size does not establish its semantic role. There is
no connection from these snapshots to `native/gi` or the offline worker yet.

## Build and isolated verification

Requires an existing x64 MSVC toolchain and Windows SDK FXC. No installer runs.
Build outputs and dependencies stay in ignored `.beamrt-validation` paths.

```powershell
./native/capture/build.ps1 -RunTest
./native/capture/build.ps1 -RunTest -Warp
python -B tools/tests/test_native_capture_contracts.py
```

The build fetches official Microsoft Detours v4.0.1, pinned to
`e4bfd6b03e50de46b47abfbd1e46b384f0c5f833`. It checks origin, revision and tracked
source modifications before building only the library's `src` directory. No
Detours sample injector is built/run. Detours is
[MIT licensed](https://github.com/microsoft/Detours/blob/e4bfd6b03e50de46b47abfbd1e46b384f0c5f833/LICENSE.md);
preserve that license notice in any future binary distribution.

Latest local strict `/W4 /WX` C/C++ and `/Ges /WX` shader builds passed. The
graphics and compute fixtures passed on RTX 4070 and WARP, including actual
texture/structured-buffer binding recovery, both descriptor-copy APIs,
pre-submit descriptor changes, null-view invalidation, unsupported-bundle
rejection, other-thread rejection, retained snapshot lifetime and explicit
detach/reattach. Known GPU output remains unchanged before, during and after
capture. The debug layer was unavailable locally; these are **not debug-clean
proof or performance results**. Windows WARP CI is defined separately and has
not been run remotely by this change.

The capture build does not depend on the older worker. At source snapshot
`f270cf0`, `native/worker/beamrt_worker.cpp` reports ABI v1 while its header/test
expect v2. That separate rollback is not repaired by this prototype and must be
resolved before rebuilding an integrated worker/adapter path.

## API and removal contract

Capture ABI v1 is separate from the worker ABI. Start/Stop and exported calls
are caller-serialized; valid native interfaces/handles are required, not Lua
objects or integers guessed to be addresses. Config bytecode is copied on Start.
Snapshot output handles must initially be null. Resource pointers returned by
ReadSnapshot are borrowed until ReleaseSnapshot; obtain your own COM reference
if you need them afterward. Copy LastError before another API call on that thread.

Start installs hooks only when called explicitly, outside loader-lock work.
Stop detaches only on the original calling thread with no API callbacks active.
Failed detach retains the host/hooks: **do not unload the DLL**. Release every
snapshot explicitly before unloading code. Process exit is not proof of a safe
runtime OFF/ON lifecycle. No game removal steps are needed because this change
does not install anything into the game.

## Next milestone

Before any BeamNG deployment, review early loading, quiescence/thread handling,
resource retirement and complete removal with the user. Establish the actual
owned GI or source-lighting pass's compiled shader/root contract, camera and
output bindings and command ordering. Then connect one real GPU visibility
result to the intended lighting contribution with reliable OFF restoration.
Do not repeat the unchanged v0.109 sewer comparison or broaden the standalone
tracer while that connection remains unproven.

The parked GI query tests receiver-to-surfel segments only. Fixing bright
daytime interiors also requires visibility from the light/sky to contributing
surfaces; native orange headlight bleed needs the actual local-light consumer.
Input capture alone cannot correct either issue.

## Public API references

- [Detours signatures, transactions and thread enlistment](https://github.com/microsoft/Detours/wiki/Using-Detours).
- [D3D12 descriptor-copy source restrictions](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-copydescriptorssimple).
- [Heap changes and descriptor-table invalidation](https://learn.microsoft.com/en-us/windows/win32/direct3d12/setting-descriptor-heaps).
- [D3D12 root signatures](https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signatures).
- [DLL loader-lock practices](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices).
