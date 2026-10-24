# Default-off startup resource observation — 2026-10-14

**Current source update:** the separately opted-in
[descriptor-focused admission mode](DESCRIPTOR_RESOURCE_ADMISSION.md) uses
resource transport ABI 5, with explicit mode echo, CBV inference unavailable and
an appended [bounded first-copy-capacity companion](COPY_FAILURE_TOPOLOGY.md).
A [separately approved ABI-5 game observation](COPY_TOPOLOGY_LIVE_OBSERVATION.md)
now records normal startup/closure but a true new association at the 256-entry
limit, with no previous destination association to release. Metadata still refused.
The earlier [separately approved mode-1 game test](DESCRIPTOR_ADMISSION_LIVE_OBSERVATION.md)
completed normally with the earlier ABI 4 but refused metadata at ViewCapacity /
CopyRanges. That receipt does not validate the new ABI-5 candidate. ABI-3
descriptions and results below remain historical evidence, not mode-1 validation.

The later [offline descriptor-copy repair](DESCRIPTOR_COPY_BATCH_REPAIR.md) fixes
transient batch capacity refusal and post-failure processing without changing
the ordering-only slice's ABIs or budgets. The ABI-5 test linked above contains
the repair; it does not reinterpret the previous ABI-4 receipt. Every further
attempt still needs separate frozen review and specific approval.

Implemented directly in the installed unpacked BeamRT folder. The resource
tracker is now co-linked into a **new candidate** startup bootstrap and connected
to the existing, explicitly selected device/creation/binding session. The
implementation and fixture work made no BeamNG launch, installed game binary
change, Lua/HLSL edit, native GI work or lighting change. A separately approved
live observation is recorded below; its resource lookup was refused. Existing
copied successful live-test binaries remain untouched.

## Explicit selection and preserved transports

The new host option is `--observe-gi-resources`. It requires the already explicit
entry/import, exact-shader creation and binding observations. Without its separate
payload, resource hooks remain OFF. The resource start occurs only at the binding
bridge's validated existing-device gate, outside DLL attach and outside bridge
locks; no new graphics device, injected thread or duplicate audit DLL is created.

A separate resource payload/reply now uses **handoff ABI 3**, 48-byte payload,
208-byte start receipt and 2,856-byte record receipt. The 2,832-byte observation
uses draw ABI 3 and includes [immutable first-failure diagnostics](RESOURCE_FIRST_FAILURE.md).
ABI 1 and 2 refuse; the earlier live ABI-2 run below remains historical evidence,
not a new-layout receipt or a retrospectively known first failure.
Existing binding handoff ABI 2 and the 1,144-byte recording, 1,184-byte thread
ledger and 912-byte thread-prefix artifacts remain unchanged. Resource selection
adds two inherited handles (14 total); binding-only selection remains 12.

For a new `--bindings-out <record>`, selection adds:

- `<record>.resources-start.bin`: immutable startup metadata, saved even for a
  coherent startup refusal or when the later matching draw times out.
- `<record>.resources.bin`: one immutable observation associated with the
  same accepted binding command ID, generation, serial, record thread and PID.

These paths must be new and must not alias the root output; existing files refuse
before child creation. CREATE_NEW prevents overwrite races at artifact creation.
The resource record is written before the binding bridge signals its existing
record event. The parent reads only the read-only mapping after that event, and
validates the matched receipt and declared layout. No polling flag or mutable
multi-frame receipt was added.

## Bounded CPU intervals and descriptor reuse

The original DrawInstanced/DrawIndexedInstanced calls are bracketed by a bounded,
caller-specific token. Sixteen token slots, unique tickets and exact caller/
counter checks reject forged, replayed, wrong-thread or exhausted tokens.
No metadata lock is held across native draw execution. Every non-target/rejected
path cancels its scope; valid outstanding tokens can drain after OFF.

An output-binding checkpoint is taken **before** the native OMSetRenderTargets
call. Accepted resource observations require the same observed resource-callback
count at that checkpoint, before Draw, and through the metadata lookup after
native Draw returns. Any observed resource callback during this span causes a
conservative refusal, including unrelated writes. This closes a real ambiguity:
looking only at a later descriptor could misidentify an RTV overwritten after
the native output binding. The fixture demonstrates refusal of that case while
the original GPU output stays 23. SRV lookups additionally match the tracked
heap's canonical identity to the bound heap identity.

This is a CPU observation span through lookup, **not the entire wrapper exit,
GPU execution or a descriptor/resource lease**. Unhooked APIs remain unobserved;
resource/heap lifetimes, legal caller synchronization and external private-GUID
interference retain the tracker document's limitations. It does not relax the
binding observer's recording-thread guard. Do not substitute command/generation/
serial or callback counters for real frame keys, queue submissions or fences.

## Partial/refused results and CBV candidates

Every declared view has its own result. Unsupported/unobserved descriptors remain
zero metadata with an explicit unknown/refusal result. Budget exhaustion or an
unhealthy tracker can still produce a coherent **refused diagnostic receipt**
for an accepted binding draw. Receipt transport success is not successful resource
identification or game rendering proof.

The CBV diagnostic probe is OFF by default. Optional
`--resource-cbv-probe-bytes 1..65536` explicitly requests a buffer-address candidate
for that span; it is not the shader's actual camera-block size. CandidateOnly
always remains 1. No CBV contents are read or mapped.

All descriptor-provenance/CBV-content/camera/GPU-order/lighting proof flags remain
zero. No BeamRTGIInputs conversion, worker activation, resource-state/barrier
certification or GPU ownership/retirement rule changed.

## Historical pre-repair verification

These results predate the co-linked type-isolation repair. See
[the repair's verification](PRIVATE_TYPE_ISOLATION.md) for current counts.

Strict MSVC /W4 /WX candidate builds pass. The startup matrix passes **9/9**:

1. Automatic resource start and matched receipt on RTX 4070.
2. The same on WARP.
3. CBV probe default-off.
4. Valid native R16 texture producing an explicit 5/6 partial SRV observation.
5. Capacity refusal preserved in a diagnostic receipt.
6. Output descriptor rewritten after binding: receipt refuses.
7. No draw: start evidence only; no resource record invented.
8. Resource observation default-off with binding observation still active.
9. Existing resource artifact preserved without creating a child.

Fixture reports independently compare resource identities to fixture-owned actual
COM objects, exact parent/child receipt bytes, thread/serial association and GPU
pixel 23 before/after OFF. All private fixture jobs drain. Existing **11/11**
startup binding/thread cases also pass, with resources default-off.

Standalone RTX/WARP resource matrices each pass **16/16** named groups in four
heap/resource/view/draw-pressure sessions. These additionally exercise 26 malformed
observation shapes, replay/forgery/wrong-thread cancellation, mutation during Draw,
pre-Draw checkpoint mutation, known equal-VA aliases, real object retirement and
late cached native forwarding. The debug layer was unavailable.

The original Python/Lua discovery passed **246/246**, including eight new startup/
interval guards. The subsequent ABI-3 first-failure update passes **256/256** and
the same 9 resource / 11 binding startup cases. Source guards supplement runtime tests; neither establishes
live BeamNG resource coverage, native lighting, debug-layer cleanliness or game
performance.

The partial-view fixture initially retired an old texture before its recorded
upload finished. It was repaired by waiting for that upload, and then uploading
and replacing the unsupported-format texture in a separate completed submission.
That fixture failure is distinct from the historical unexplained DLL-loading
failure; no game process or loader-cause claim was involved.

```powershell
./native/startup/build.ps1 -RunContractTests -RunResourceStartupTests -RunBindingStartupTests -FreshArtifacts
# CI without a hardware adapter:
./native/startup/build.ps1 -RunContractTests -RunResourceStartupTests -FreshArtifacts -WarpResourceStartupOnly
```

FreshArtifacts writes a new ignored candidate directory, preserving prior
startup bundles. The fixture harness accepts only its bounded native-startup
validation directory names and fixed disposable executable names; it accepts no
arbitrary game target. CI runs the WARP-only startup matrix and source contracts.

## Live observation — 2026-10-14

After frozen-input review and explicit approval, one new observation-only BeamNG
startup used host SHA256 `516e97abd5e36c36fbdcd1567d236be2e85e758a2605bdbe670ea9397bdbf0e6`
and bootstrap `58598e2e505de8846973e91c77810ebea34d38ddd247296f333f0983fc24c4e6`.
Evidence is retained under the installed mod's ignored
`.beamrt-validation/live-resource-e996a738d3ba491888e37e9a4ce826ee/`, including
`RESULT.md`, exact inputs, immutable receipts and independent decoders/readouts.

Startup/device observation and exact v082 GI VS/PS/root identification succeeded.
The accepted CPU draw has four vertices, one instance, viewport 1280x684, one
output, command 23/generation 6036/serial 1. The resource receipt matches its
PID/thread/serial, but **resource lookup was refused**: intervalAccepted=0,
ticket=0, no valid output checkpoint, healthy=0, one capacity-pressure event and
73 observed callback overlaps across 1,035,738 resource callbacks. All six SRV,
eight RTV and CBV metadata records are zero; CBV probe was off. All binding and
resource proof flags remain zero. A valid refused receipt is not resource access.

The start receipt was healthy with all ten slots attached. At draw receipt time,
three heaps, 67 resources and 42 views remained live. Those later counts do not
identify which earlier capacity limit was hit. The aggregate counters contain
neither a first-unhealthy event nor ordering of pressure versus overlap.
`E_INVALIDARG` here is the absent/nonmatching draw token path, not evidence that
BeamNG supplied invalid native graphics arguments.

The game log records West Coast USA loading and manual `beamrt_main.start()`.
It also contains automatic reflection experiments and later ordinary GI/settings
changes, so this is not a controlled, diagnostic-free steady-frame comparison.
The user's last map-readiness response was still loading/not ready; do not infer
a visual compatibility confirmation from the receipt or exit code.

The user closed BeamNG normally. Retained child and host handles both reported
exit 0; no game/host process remained. Frozen inputs and native source hashes
were unchanged. Native capture, worker/GI dispatch and lighting changes stayed
off; no second launch, forced live closure, hot unload or permanent installation
was made. The historical intermittent loader failure did not recur, but remains
unexplained. The D3D12 debug layer was not enabled.

## Next boundary

The subsequent first-failure candidate's approved game startup crashed before
the GI match. See the [live-test hold and linkage defect](RESOURCE_FIRST_FAILURE.md).
The same candidate must not be retried. The subsequent
[private-type isolation repair and co-linked regression](PRIVATE_TYPE_ISOLATION.md)
pass offline, including old-DLL negative controls. The repaired candidate then
completed one [separately reviewed and approved live observation](TYPE_ISOLATION_LIVE_OBSERVATION.md)
with normal startup/map/GI draw/closure and both exits 0. Its ABI-3 receipt
identifies ObjectCapacity / Placed as the first recorded invalidation (128-entry
limit, attempted 129, zero recorded overlaps then), followed by 52 later overlaps.
Resource metadata remains refused; the deployment hold is not lifted. New frozen
review and separate approval are still required for every further game probe.

The precise first unhealthy event is now preserved in the new offline-tested
[diagnostic contract](RESOURCE_FIRST_FAILURE.md), not retroactively in the old
game receipt. Review a new frozen candidate before any separately approved probe.
Then address observed capacity and concurrent-callback coverage with explicit correctness/lifetime
rules, not guessed larger limits or removed guards. This run does not establish
resource IDs, formats, camera meaning, states, queue ordering or native GI use.
Any new game probe still requires reviewed frozen inputs, separate approval and
normal user-controlled closure. A refusal is evidence, not a reason to bypass
the guards.

Only after actual resources, camera interpretation and known states are established
should queue/consumer-fence ordering and native GI consumption be attempted.
The historical loading anomaly and unidentified source-reset writer remain open;
this observation does not lift the general deployment hold.

Primary references:
[CPU descriptor copy rules](https://learn.microsoft.com/en-us/windows/win32/direct3d12/copying-descriptors),
[CPU event publication](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setevent),
[command-list object lifetime](https://microsoft.github.io/DirectX-Specs/d3d/CPUEfficiency.html).
