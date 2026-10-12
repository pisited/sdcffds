# Native-to-GI connection: loading and interception review

Status: deployment review plus isolated capture implementation, 2026-10-11.
No BeamNG DLL loading/injection, hook installation, game-file change or new
in-game test is authorized or performed by this document. No standalone tracer
expansion. Current working Lua/HLSL renderer stays intact.

Update v0.109: an opt-in engine-managed PostFX producer/consumer route is now
registered through game-side Lua, with underground mesh GI selection. See
[game-side integration and bounded activation](GI_VISIBILITY_BUFFER_V0109.md).
This is not native DLL loading/resource interception. The user subsequently
reported no noticeable lighting improvement with the underground buffer
activated; native shadows also blinked in/out. Correct selection/settings are
not GPU consumption proof. That bounded experiment is parked, not a passed
lighting milestone, and should not be repeated without new evidence.

Update, native capture: [native/capture](native/capture/README.md) now implements
read-only interception of real public D3D12 calls in an isolated process.
Exact shader/root matching and observed descriptor creation/copies recover
actual texture and structured-buffer SRVs at submission. RTX 4070 and WARP
graphics/compute fixtures passed with unchanged normal output and explicit
detach. This is not a game-ready host: one API-calling thread, bounded retained
metadata, and no verified camera, barriers/fences or lighting consumer. No DLL
has been installed into BeamNG. No Lua reload or new game test is needed.

## First consumer and acceptance gate

Target BeamRT's owned GI pass, not native headlights or the clustered shade pass.
The current GI trace reads prepass normals/depth and writes #BeamRT_CurrentGI
before its existing moments, temporal, denoising and composition chain.

First visibility use: reject a receiver-to-world-surfel bounce segment when the
existing real imported opaque geometry blocks it. This is already the scope of
the shared-mesh GI experiment and provides a defined physical contribution.
Do NOT multiply all GI by a primary sunlight shadow mask: shadowed receivers can
still receive legitimate indirect light. Unknown alpha coverage keeps fallback.

The pass must consume native GPU visibility, not a displayed diagnostic image or
a per-frame CPU readback. Source packing already frees the sixth sampler slot
for geometry; the native consumer can use the corresponding slot for visibility
without adding a seventh 2D input. The matched v084 consumer and GPU-only
resource adapter are now implemented under native/gi, with frame/view, scene
and surfel keys. Actual game-resource capture, activation and full GI draw
consumption remain unimplemented; offline fixtures are not game integration.

The initial useful comparison uses the same geometry, light, GI settings and
view: bridge OFF = original GI; bridge ON = only the intended geometry visibility
change; OFF again = original rendering restored. If world-surfel contribution is
zero, that consumer cannot produce a visible difference. Do not infer failure
or alter unrelated intensity/denoising to compensate.

## Loading options and recommended boundary

No automatic load, silent installer, system-DLL replacement or background
remote-process injector. Any deployment requires explicit user review of the
binary, dependency versions, path, loading method and complete removal steps.

The installed BeamNG raw-LiDAR example documents external ffi.load as requiring
a disabled Lua security sandbox (that particular sensor also requires .tech).
We must not silently disable the sandbox or assume that example is a general
renderer plug-in API. Lua reload is not native DLL load/unload.

Candidate to review: an explicit startup launcher that loads the native adapter
before the required resource/view creation, using a pinned interception library
such as Microsoft Detours. This **is DLL insertion into the new game process**,
not an engine-supported mod API. It avoids treating a same-named d3d12.dll proxy
as reliable, but introduces compatibility/loader risks and is not yet selected,
built or approved for deployment. Normal startup without the launcher must remain
unmodified. Steam/arguments/working directory and other loaded mods must be preserved.

Primary references: [Detours usage](https://github.com/microsoft/Detours/wiki/Using-Detours),
[DLL loading practices](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices).
GPU/device creation, waiting on fences, file I/O and full adapter initialization
must not be done in DllMain. Hook installation/detachment requires an explicit
thread/quiescence policy; restoration cannot rely on process teardown callbacks.

## Narrow graphics interception, not engine reverse engineering

The controlled GI consumer is currently a **graphics/pixel-shader pass**. A
compute-dispatch callback or Present hook alone cannot identify or modify it.
The adapter needs verified public D3D12 observations for:

- Pipeline/shader creation and binding: exact owned shader bytecode identity and
  root layout, never merely draw size or the presence of a namespace.
- SRV/resource/view creation and descriptor copies/binding: recover actual
  resource ownership, texture format, mip/view range and depth interpretation.
- Per-draw constants and target binding: correct camera/viewport, GI resolution,
  output texture and scene/frame generation. File names are not GPU handles.
- Command submission, barriers, reset and lifetimes: real producer/consumer
  ordering, state transitions, queue ownership and in-flight resource retirement.

Late loading can miss existing resource/descriptor creation. The adapter must
refuse unknown bindings rather than guess a resource pointer. Capturing a valid
device candidate does not enumerate textures or establish these observations.
Unsupported enhanced barriers, indirect/bundle submission, layouts or views must
retain native behavior until explicitly supported.

The native compute pass needs a private compatible layout and actual GPU inputs.
An unused shader register is not an engine binding; replacing shader bytes alone
does not expand a Direct3D 12 root signature. Original bindings and state must
be restored before any subsequent game draw. No global shared-layout mutation.

Primary reference: [D3D12 root signatures](https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signatures).

## Native output and reliable OFF

Create a matched GPU visibility output/consumer with explicit invalid/fallback
state. Prefer a BeamRT-owned output target, not writes into unrelated native
lighting or arbitrary unused channels. Validate dimensions, view/frame generation,
scene generation, resource owner and synchronization before applying it.

Native OFF must restore the original GI shader/input bindings and its original
source-pack state, discard bridge history safely, and stop submitting work. Retire
native resources only after their GPU use completes. Keep passive observation or
the DLL resident if safe hook detachment cannot yet be guaranteed; do not equate
disabling rendering with unloading code still referenced by another thread.

Never accumulate the result repeatedly into native lightinfo, run both replacement
and original contributions, or use final-image darkness as visibility proof.
No overlay-only success satisfies the rendering milestone.

## Worker baseline history and next implementation

The user explicitly approved restoring the matched ABI v2 baseline on 2026-10-11.
That restoration passed strict compilation and isolated hardware/real-guardhouse
and WARP/synthetic GPU tests. However, the later source snapshot `f270cf0` again
contains the ABI-v1 worker implementation while its header/self-test expect v2.
The current capture cycle leaves that separately committed rollback untouched;
its independent build does not hide or resolve the mismatch. The matched worker
baseline must be restored before rebuilding an integrated worker/adapter path.
None of those offline checks establishes access to BeamNG resources or GI
consumption, and the optional acquisition path remains unused in the game.

The resource adapter and GPU output/owned-GI consumer slice is implemented;
see [native GI contract and validation](native/gi/README.md). Existing Lua does
not register or activate these shaders. The adapter accepts verified host
resources and records on a dedicated DIRECT list; it does not discover game
resources, submit work, load itself or install interception. The separate
v0.109 engine-managed backend can schedule the matched pixel producer and GI
consumer without that DLL, while retaining inline/default rendering fallback.

The read-only capture slice is implemented, but the next native work must address
real game pass identification, multithread/lifetime handling, camera and output
bindings and command ordering. Then the reviewed host can record the matched
receiver export, order native compute and bind its output to the owned GI
consumer, with original-graph/history restoration on OFF. Only after reviewing
a complete loading mechanism should a bounded in-game test check lighting
consumption and restoration. No old sun/guardhouse comparison, LUID-only game
probe, further BVH rewrite or additional screen-space algorithm.

Receiver-to-surfel visibility cannot by itself remove daytime sky/ambient fill
or fix a surface that was lit through a wall. Visibility to the light at secondary
surfaces and the real local-light consumer remain required for those problems.
