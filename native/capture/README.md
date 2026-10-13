# Read-only D3D12 resource-capture prototype

Status, 2026-10-11: implemented and tested **only in the isolated test process**.
No BeamNG loader, launcher, DLL insertion, game-file change, Lua sandbox change,
ReShade dependency or lighting replacement is included. The existing game-side
renderer is unchanged. This is an input-capture milestone, not a shadow fix.

## What is actually implemented

`beamrt_capture.dll` intercepts 39 real public D3D12 API method implementations
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
- Matched draws snapshot root 32-bit values, root CBV/UAV GPU addresses,
  viewport/scissor rectangles and RTV resources. Root buffer contents are not
  copied or interpreted. RTV provenance resolves at submission; DSV output,
  unsupported descriptor forms or capacity overflow mark the context incomplete.
- Transition barriers recorded before the matched draw are retained with their
  resource references. Queue-local Execute serials and the latest successful
  Signal/Wait fence pointers and values are recorded as observations. They do
  not establish initial resource state, a complete state chain, cross-queue GPU
  ordering or fence completion.
  Split BEGIN/END barriers mark context incomplete; their flags cannot be
  discarded and interpreted as completed full transitions.
- A snapshot retains its actual `ID3D12Resource` references after explicit host
  detachment, plus the actual submitting `ID3D12CommandQueue` reference. It
  contains the submitted view descriptions and a recording and submission serial.
  `GetSnapshotForQueue` isolates each queue's result: an invalid target on one
  queue cannot borrow or erase another queue's result. These are CPU observation
  serials, **not GPU fence values or automatically current-frame data**.
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

The default `BEAMRT_CAPTURE_SINGLE_THREAD` mode supports only the Start caller;
API calls from another thread poison capture while forwarding the original call.
Opt-in `BEAMRT_CAPTURE_MULTITHREAD` mode serializes capture metadata updates and
keeps the latest snapshot separate for each observed command queue. It does not
make concurrent use of the same command list, descriptor slot, or other D3D12
object race-safe. Queue identity also does not establish GPU execution order or
snapshot freshness.

Both modes require Start and Stop to run only with externally established
quiescence across **all** D3D12 API callers and capture queries, explicitly passed as
`apiCallersQuiescent=1`. A timer, paused simulation or Present hook does not
establish that condition. Stop must run on the original Start thread. This
limited metadata synchronization is not a multithread-safe game host or a
BeamNG loading mechanism.

The transaction currently enlists only its control thread. All other callers
must remain outside target/trampoline code for the entire transaction; enlisting
the current thread does not make live-game attach/detach safe. The fixture starts
its rendering threads after installation and joins them before removal. No game
thread enumeration or suspension is implemented or performed.

Only legacy CreateCommandList and graphics/compute pipeline creation are
observed. Supported input views are one-mip, non-array, non-MSAA Texture2D views
and structured-buffer SRVs; output capture supports RTVs without a DSV. Raw/typed
buffers, texture arrays, unbounded tables, pipeline streams, newer creation
methods and other method implementations are not supported. The root contract
is decoded through the version-1 deserializer. Only the last matched draw/dispatch
in a command-list recording is published.
Non-target submissions can leave a historical snapshot available; callers must
never treat availability alone as evidence of frame freshness.

Metadata holds strong references until Stop and has hard limits: 64 heaps,
512 tracked SRVs, 256 RTVs, 32 matching roots, 64 matching pipelines, 64 command
lists and 32 observed target queues. A snapshot retains output, transition and
fence references in addition to its SRVs.
Budget exhaustion disables capture. It intentionally lacks game-scale object
retirement, heap recreation/resize, device-removal recovery and queue retirement.
References prevent premature deletion, but do not prove safe GPU use or fences.

`resourceStateChainVerified`, `cameraVerified`, `gpuOrderingVerified` and
`lightingConsumed` always remain zero. Root constants and output/viewport values
are raw per-draw observations; camera meaning is not inferred. Barrier records
do not include a verified initial state or replay across queues. Queue Signal and
Wait records are not completion proof. Matching resource format/size does not
establish semantic role. The capture API still does not submit work or feed the
GI adapter or offline worker automatically.

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
rejection, default single-thread rejection, retained snapshot lifetime and
explicit detach/reattach. The ABI-v3 test also captures deterministic root
constants, viewport/scissor, RTV identity, transition barriers and queue
Signal/Wait events, while checking all verification flags remain false. It
creates, records and submits on
two concurrent API threads and two independent queues, verifies per-queue
resource provenance and invalidation isolation, tests sequential list handoff
to another thread, and retains queue/resource snapshots after detach. Known GPU
output remains unchanged before, during and after
capture. The debug layer was unavailable locally; these are **not debug-clean
proof or performance results**. Windows WARP CI is defined separately and has
not been run remotely by this change.

Callback errors mark the session unhealthy under the metadata lock, before
another thread can publish partially updated state. A valid 65-heap fixture
exceeds the capture budget and confirms that original API success is preserved
while capture is invalidated. Local regression/source-contract tests pass in the
isolated test environment; the existing offline GI producer/consumer restoration
fixture also passed after the worker restoration. None of these uses BeamNG
resources.

The capture build is independent of `native/worker`. The current worker source
reports ABI v2, matching its header and self-test. This agreement does not create
an integration between the capture snapshots and the offline worker.
The worker was restored directly in the local unpacked mod to the known-working
`b59cc8c` implementation and passed real-guardhouse RTX 4070 and synthetic WARP
tests. `test_native_worker_contracts.py` and worker CI now check the implementation
against all declared entry points so the observed v1 rollback is caught early.

## API and removal contract

Capture ABI **v3** is separate from the worker ABI. Check AbiVersion and rebuild
clients with the current header; config/info/status layouts have changed.
Lifecycle operations are caller-serialized; runtime metadata queries are locked,
but must finish before Stop. Valid native interfaces/handles are required, not Lua
objects or integers guessed to be addresses. Config bytecode is copied on Start.
Snapshot output handles must initially be null. Resource pointers returned by
ReadSnapshot, including the queue pointer, are borrowed until ReleaseSnapshot;
obtain your own COM reference
if you need them afterward. Copy LastError before another API call on that thread.

Start installs hooks only when called explicitly, outside loader-lock work.
Stop detaches only on the original calling thread with no API callbacks active.
Failed detach retains the host/hooks: **do not unload the DLL**. Release every
snapshot explicitly before unloading code. Process exit is not proof of a safe
runtime OFF/ON lifecycle. No game removal steps are needed because this change
does not install anything into the game.

## Next milestone

Update 2026-10-12: a separate [creation-only pipeline audit](../startup/PIPELINE_AUDIT.md)
and read-only cache manifest now identify the game's actual SM6.0/DXIL candidate
bytes. Hardware/WARP creation fixtures pass. This does not activate this capture
DLL, establish its all-caller quiescence, recover live bindings or certify a GI frame.

Before any BeamNG deployment, review early loading, quiescence/thread handling,
resource retirement and complete removal with the user. Multi-thread metadata
and raw draw/queue context capture are tested, but game-scale lifetime/resize
handling, complete resource-state-chain validation and GPU completion proof
remain missing. Establish the actual
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
- [Why un-enlisted executing threads cannot be assumed safe](https://github.com/microsoft/Detours/wiki/DetourUpdateThread).
- [Command-list/allocator recording and reuse restrictions](https://learn.microsoft.com/en-us/windows/win32/direct3d12/recording-command-lists-and-bundles).
- [Descriptor copies require non-conflicting access](https://learn.microsoft.com/en-us/windows/win32/direct3d12/copying-descriptors).
- [D3D12 descriptor-copy source restrictions](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-copydescriptorssimple).
- [Heap changes and descriptor-table invalidation](https://learn.microsoft.com/en-us/windows/win32/direct3d12/setting-descriptor-heaps).
- [D3D12 root signatures](https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signatures).
- [DLL loader-lock practices](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices).
