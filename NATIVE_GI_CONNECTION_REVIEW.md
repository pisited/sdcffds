# Native-to-GI connection: loading and interception review

Update 2026-10-19: [GI frame validity repair](native/gi/GI_FRAME_VALIDITY.md) makes
receiver preparation require explicit valid-frame success and rejects invalid
viewport mappings in the actual shared visibility consumer. No new automation,
game loading or native resource bridge was added; in-game consumption remains
the separate unverified milestone.

Update 2026-10-13: [GI/reflection history safety audit](native/lighting/README.md)
repairs GPU-reproduced HDR-statistics clipping and invalid history/filter samples
in the installed Lua/HLSL renderer. This is independent of native resource
access; no DLL loading, GI adapter contract or game-activation claim changed.

Update 2026-10-13: [sunlight producer/consumer GPU audit](native/shadows/README.md)
reproduced and repaired invalid receiver/visibility classification in the actual
HLSL. Offline RTX/WARP proof does not establish native sunlight consumption in
BeamNG or resolve the independent startup/resource-access gap.

Status: deployment review plus isolated capture implementation, updated 2026-10-13.
This document does not authorize BeamNG DLL loading/injection, hook installation,
game-file changes or tests. A separately approved passive startup test is recorded
below; native graphics/GI activation remains unverified. No standalone tracer
expansion. Current working Lua/HLSL renderer stays intact.

Update 2026-10-13: [startup loader evidence](native/startup/LOADER_EVIDENCE.md)
preserves exact fixture binaries, commands, hashes and host logs. The fresh
37-case matrix and 197/197 source/Lua tests pass, including a known unresolved
test dependency. The historical intermittent failure remains unexplained and
deployment remains held. No game launch or native GI result was added.

Subsequent separately approved 2026-10-13 diagnostic: [live GI recording](native/startup/STARTUP_BINDING_HANDOFF.md#separately-authorized-live-diagnostic--2026-10-13)
captured an actual four-vertex GI draw with CBV/table/viewport/output handles in
the game. Host and normally closed game exited 0. This confirms CPU observation,
not resource contents, camera semantics, queue/fence ordering or native GI
lighting. The first receipt reports substantial thread-guard rejections; attribute
and fixture-test that limitation before expanding capture. The historical loader
cause and general deployment hold remain separate open questions.

Subsequent offline [snapshot-isolation correction](native/startup/THREAD_REJECTION_ISOLATION.md)
prevents rejected unrelated-list calls from erasing the accepted GI receipt.
The source-list guard, thread policy, ABI/proof flags and GPU retirement remain
unchanged. RTX/WARP regression and startup fixtures pass; the high live rejection
traffic remains unexplained. No new live run or native lighting was added.

The next [bounded thread-attribution slice](native/startup/BINDING_THREAD_DIAGNOSTICS.md)
is implemented with checked per-method counters, first-conflict samples, and
no-draw timeout evidence. The recording guard stays intact; no resource or GPU
proof is added. Project tests pass 201/201 and the normal-host startup rerun
passes 11 cases. A pre-attach loader failure recurred on the first run; exact
inputs/logs are now preserved, but its cause is still unknown. Deployment stays
held and the successful live build remains untouched.

Offline renderer audit while the user was away: [two shared traversal safety
defects](native/gi/BVH_SAFETY_AUDIT.md) were reproduced on GPU and repaired.
Overflowing triangle indices and malformed preorder links no longer produce
certified hit/miss results. Compute and game-pixel producer fixtures verify -1
unknown masks and exact-consumer baseline fallback on RTX/WARP. Project tests
pass 205/205, and game-header GI/local-light compile checks pass. This is not a
new game or lighting result; loader/resource/clustered-light boundaries remain.

Further offline [collapsed-face audit](native/gi/DEGENERATE_GEOMETRY_AUDIT.md)
confirms the existing packer can lose a thin face's area. Shared traversal now
returns unknown for nonfinite/zero-area decoded faces while valid parallel rays
remain misses. RTX/WARP compute and game-pixel fixture consumers preserve baseline
lighting on invalid geometry; current project suite is 208/208. The startup log
review did not identify the missing dependency. No game test or deployment-hold
change occurred.

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
detach. ABI v3 records opt-in multi-thread metadata, queue-specific snapshots,
raw root/viewport/output context, transition barriers and queue fence events;
concurrent two-thread/two-queue tests passed on both backends, including
invalidation isolation and retained queue ownership after detach. These are not
verified camera semantics, complete resource-state chains, GPU completion or a
lighting consumer. This is not a game-ready host. Live attach/detach still requires externally established
quiescence across all callers; that game-side policy is not implemented. No
capture/GI DLL has been installed into BeamNG. A separate passive bootstrap was
loaded for the authorized startup observations below; neither activated capture/GI.

The offline GI fixture now exercises capture-to-frame handoff using a synthetic
producer. Only its mesh/receiver SRVs come from capture; resource states,
dimensions, scene/surfel data and generations are explicit fixture inputs. It
records compute and consumer on the same queue and checks retirement after the
consumer fence. This validates module composition, not live BeamNG bindings.

Update 2026-10-12: [the offline handoff validator](native/gi/HANDOFF_VALIDATION.md)
now rejects incomplete context, incompatible ownership/views/viewport, missing
starting states, broken or unsupported transitions, stale generations and
unsuitable fence/consumer receipts. Inputs are published only after validation;
actual completion is queried separately from CPU queue bookkeeping. The owned
fixture still supplies the semantic/state/serialization evidence explicitly.
No camera decoder, general game-state converter or native loading is added.

The offline validator now also checks reflected producer/consumer shader layouts
against their serialized root signatures. A retained fixture-owned UPLOAD buffer
registry resolves captured CBV addresses using actual allocation bounds and
explicit current byte mirrors; a nonzero-offset binding is verified by GPU
output. Consumer constants use reflected fields. This does not discover live
game CBV resources/contents or establish camera meaning; those mappings and the
early-load/quiescence policy still require a verified BeamNG host contract.

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

Update 2026-10-12: an [opt-in startup host review build](native/startup/README.md)
now exists. It defaults to no-launch file/argument/hash review and has a separately
gated new-suspended-child insertion branch. The inert bootstrap only reports DLL
attach; capture/GI are not linked or activated. Strict builds, no-launch contracts
and read-only review ran. The user subsequently approved a disposable-process
test only: nine startup/receipt/failure cases passed, including real insertion,
target-side status and actual exit-code checks, pre-resume cleanup and the real
missing-receipt timeout. All private fixture jobs drained. At that stage no BeamNG
startup or game deployment occurred. Safe game-thread/device handoff and actual GI bindings
remain unimplemented; this fixture approval is not approval for BeamNG launch mode.

A dormant [post-loader device creation observer](native/startup/DEVICE_OBSERVER.md)
is now available through explicit native exports. Its startup-inserted hardware
and WARP fixtures observe the real public API return, verify device/resource
identity and reject ambiguity, unexpected threads and stale generations. It
does not initialize itself from DllMain or add an automatic game callback. The
real BeamNG control/thread handoff remains required; creation observation is not
render-pass or lighting integration, and no in-game activation was performed.

The [native-entry rendezvous](native/startup/ENTRY_RENDEZVOUS.md) now reaches an
automatic post-loader callback without a game-side API call. Production only
records entry reach and one-shot detachment in parent-validated CPU status;
automatic device initialization is separately compiled for known fixtures only.
Four fixture entry cases pass, including pre-main hardware/WARP creation and
failure fallback. The installed EXE's native PE structure was reviewed read-only,
not executed at that stage. No graphics-quiescence claim follows from that callback.

Subsequent live update, 2026-10-12: the user authorized one **production-passive
BeamNG startup**. DLL receipt, native-entry reach/one-shot restoration and menu
startup passed on 0.39.4.0 build 20972, D3D12/RTX 4070. The user closed normally;
the game recorded shutdown and neither launcher nor game process remains.
See [exact tested hashes and limitations](native/startup/ENTRY_RENDEZVOUS.md#actual-passive-beamng-startup-evidence--2026-10-12).
The direct launch reported a Steam initialization error; Steam behavior was not
validated. Output binaries changed after shutdown, so the newer hashes are
not live-tested. Device observation, resource capture and native GI stayed OFF.
This establishes one actual startup handoff, not graphics quiescence, gameplay
stability, camera/resource access, GPU ordering or lighting consumption.

New implementation: a separately opted-in [image-scoped import observer](native/startup/IMPORT_OBSERVER.md)
atomically swaps one verified main-EXE D3D12CreateDevice import after entry
restoration. Named and ordinal hardware/WARP fixtures passed actual candidate/
resource ownership, ambiguity rejection, concurrent forwarding and disable with
retained late-call lifetime; a missing-import application continued normally.
This avoids guessing quiescence for a process-wide instruction detour, but does
not provide that condition for capture, identify a game rendering device/pass,
recover prior resource creation or connect GI. The new route is default OFF and
was subsequently tested in one separately authorized BeamNG startup. An actual
returned candidate was observed at import slot RVA 0x1ce75f0; the user confirmed
the menu and normal closure, and shutdown/process absence were verified. See the
[new exact-build receipt and limits](native/startup/IMPORT_OBSERVER.md#actual-beamng-creation-receipt--2026-10-12).
This is real creation observation, not a verified rendering device/pass or GI
resource connection. The previous passive startup is not its validation.

Creation-audit update: [the exact cached GI manifest and new SDK-slot audit](native/startup/PIPELINE_AUDIT.md)
are implemented separately. The installed cache's v082 shaders are SM6.0/DXIL,
not the offline fixture's SM5.0; both vertex and pixel byte hashes are preserved.
Hardware/WARP fixtures recover an actually observed root and matching PSO,
including the real cached GI bytecode under a fixture-created compatible layout.
Pipeline streams are explicitly unsupported/counted, and draw/resource/camera/
GPU/lighting flags stay false. The [startup-host connection](native/startup/STARTUP_PIPELINE_HANDOFF.md)
now passes eight inserted-process cases, including independent root-byte transfer
validation and fail-closed/no-overwrite checks. One subsequently authorized
BeamNG probe installed the audit and observed real legacy creation calls, but
metadata invalidated and the exact-match wait expired: 50 roots, 34 legacy PSO
calls, no matches and health 0. The reason was not exported; the 32-root limit
is a hypothesis to verify, not a confirmed diagnosis. No live pipeline/root or
bindings were established. The old capture
thread contract and GI adapter's fence retirement are unchanged.
The follow-up audit v2 exports the immutable first failure/HRESULT and replaces
the strong root-object cap with object-owned CPU tags, bounded weak layout reuse
and a 2 MiB accounted metadata budget. Pressure skips unclassified roots rather
than poisoning the session. Hardware/WARP fixtures verify capacity, native-root
lifetime retirement, matching after cache eviction, precise conflict reporting
and eight startup handoff cases. One separately authorized **live v2 probe** now
captured the exact reviewed GI shader pair with an actually observed **168-byte
same-device root signature**. Host and game exited **0**, with normal closure and
no remaining test processes. This establishes live creation identity/root capture,
not draw execution, descriptor/resource/CBV contents, camera meaning, GPU ordering,
a lighting fix, resource retirement proof or native GI deployment. Next inspect
the actual root and fixture-test the matched binding observer; no automatic use
of the old capture module or relaxation of GPU retirement is authorized.
The [standalone recording observer](native/startup/GI_BINDING_OBSERVER.md) now
SDK-decodes the actual root (b0 CBV, t0–t5 and s0–s5 tables) and fixture-validates
draw-time address/handle metadata on hardware/WARP. All descriptor-provenance,
CBV-content, camera, GPU-ordering and lighting flags remain false. The standalone
version did not share the production bootstrap's audit session. The subsequent
[default-off startup bridge](native/startup/STARTUP_BINDING_HANDOFF.md) now co-links
that actual session and passes seven isolated receipt/control cases. It has no
new live result and deployment is on hold for an unresolved pre-start loader
anomaly in the legacy import fixture. These CPU observations cannot become
BeamRTGIInputs or replace resource/fence/camera verification.

The installed BeamNG raw-LiDAR example documents external ffi.load as requiring
a disabled Lua security sandbox (that particular sensor also requires .tech).
We must not silently disable the sandbox or assume that example is a general
renderer plug-in API. Lua reload is not native DLL load/unload.

Candidate under review: an explicit startup launcher that would load the native adapter
before the required resource/view creation, using a pinned interception library
such as Microsoft Detours. This **is DLL insertion into the new game process**,
not an engine-supported mod API. It avoids treating a same-named d3d12.dll proxy
as reliable, but introduces compatibility/loader risks and is not yet approved
for deployment. The current inert startup build does not attach that
adapter. Normal startup without the launcher must remain
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
and WARP/synthetic GPU tests. Commit `f2d05d6` later reverted the matching
`b59cc8c` worker implementation to ABI v1 while leaving the v2 header/tests.
The current cycle restored those known-working changes directly in the PC's
unpacked BeamRT source; the normalized source matches `b59cc8c` exactly. Strict
rebuilds and real-guardhouse RTX 4070/synthetic WARP tests passed. New source and
CI guards check the ABI and every declared entry point to catch that rollback.
None of those offline checks establishes access to BeamNG resources or GI
consumption, and the optional acquisition path remains unused in the game.

The resource adapter and GPU output/owned-GI consumer slice is implemented;
see [native GI contract and validation](native/gi/README.md). Existing Lua does
not register or activate these shaders. The adapter accepts verified host
resources and records on a dedicated DIRECT list; it does not discover game
resources, submit work, load itself or install interception. The separate
v0.109 engine-managed backend can schedule the matched pixel producer and GI
consumer without that DLL, while retaining inline/default rendering fallback.

The offline handoff fixture composes the capture snapshot and GI frame only with
explicit fixture sidecar values. The read-only capture slice is implemented,
but the next native work must address real game pass identification, game-scale
lifetime handling, camera and output bindings and command ordering. Then the reviewed host can record the matched
receiver export, order native compute and bind its output to the owned GI
consumer, with original-graph/history restoration on OFF. Only after reviewing
a complete loading mechanism should a bounded in-game test check lighting
consumption and restoration. No old sun/guardhouse comparison, LUID-only game
probe, further BVH rewrite or additional screen-space algorithm.

Receiver-to-surfel visibility cannot by itself remove daytime sky/ambient fill
or fix a surface that was lit through a wall. Visibility to the light at secondary
surfaces and the real local-light consumer remain required for those problems.
