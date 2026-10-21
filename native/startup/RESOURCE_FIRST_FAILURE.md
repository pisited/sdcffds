# Bounded first-unhealthy resource diagnostics

**Current source update:** [copy-capacity topology](COPY_FAILURE_TOPOLOGY.md)
retains the original failure at 96 bytes and status at 88, appending a separately
validated companion in resource handoff ABI 5. A subsequent
[separately approved ABI-5 live observation](COPY_TOPOLOGY_LIVE_OBSERVATION.md)
completed normally and transported the companion, identifying genuine view-table
pressure while resource metadata still refused. Prior ABI-3/ABI-4 game results
below remain historical and do not establish the newer candidate's coverage.

The subsequent [descriptor-focused policy](DESCRIPTOR_RESOURCE_ADMISSION.md)
preserves this 96-byte failure record and all limits/guards, while revising only
the resource transport envelopes to ABI 4 for explicit mode identity. That new
mode was separately observed in a later [ABI-4 game run](DESCRIPTOR_ADMISSION_LIVE_OBSERVATION.md):
normal startup/draw/closure, but metadata refused at ViewCapacity / CopyRanges.
The historical mode-0 results below do not establish that newer mode's coverage.

**Live-test hold:** the subsequent approved startup of candidate
`native-startup-resource-babbee8fb8f040b2a4198f6f37e480aa` crashed before the GI
match. Its owned-process dump points to shared-pointer release in the bootstrap.
Read-only linkage inspection confirms incompatible global `Context` types in
the co-linked binding/resource components resolved to the same binding-layout
constructor. This candidate remains blocked. The subsequent
[private-type isolation repair and co-linked regression](PRIVATE_TYPE_ISOLATION.md)
are offline-only and do not approve a game retry. Crash evidence:
`.beamrt-validation/live-first-failure-2f2f352f6c0c45b4828f8934f1a8cd82/RESULT.md`.
The historical offline successes below do not establish live compatibility.
No retry or native source repair was performed during the original crash triage;
the later offline repair is documented separately.

**2026-10-15 update:** the repaired candidate subsequently completed one separately
approved startup/draw/normal-closure test. Its first recorded failure was
ObjectCapacity / Placed at limit 128 / attempted entry 129, with zero recorded
overlaps then; later overlaps were 52. See the
[coherent ABI-3 live receipts and limits](TYPE_ISOLATION_LIVE_OBSERVATION.md).
The old crashed candidate remains blocked; no native GI success is claimed.

Implemented in the installed unpacked BeamRT folder after the observation-only
game run refused resource lookup with aggregate pressure=1 and overlaps=73.
That old ABI-2 run cannot retrospectively identify the first event. This new
implementation was initially offline-tested only; the later separately approved
game observation is linked above. No native lighting change is part of either.

## Contract and unchanged behavior

`BeamRTResourceFailure` is a fixed 96-byte ABI-1 numeric record. All paths that
invalidate tracker health route through `fail()`. The first reason is latched
under the existing metadata mutex, with no new allocation, I/O, GPU read, resource
reference or background thread. Later failures and OFF cannot replace it.

Reasons distinguish heap/object/view/draw capacity, resource callback overlap,
counter overflow, private-tag failures, invalid/ambiguous metadata, metadata
exceptions, and hook installation/restoration failures. Caller method/thread,
callback ordinal, observed callback count, overlap/pressure/serial counters,
table counts, capacity and attempted count accompany the reason. Capacities
remain exactly 32 heaps, 128 resources, 256 views and 16 draw tokens.

Callback methods have stable diagnostic IDs 1 through 10, matching SDK slot
order plus one. Start/BeginDraw/FinishDraw/Descriptor/Disable use IDs 11 through
15. Callback methods carry their own entry ordinal assigned under the mutex;
direct API methods carry the observed callback-counter watermark, not an invented
native callback ordinal. For overlap, activeCallbacks is the fetch-add entry
count; for other reasons it is sampled when failure is recorded. No peer-call
identity, timestamps, absolute cross-thread entry chronology or GPU overlap is
established.

Counts describe tracker tables at observation time, not total game objects or
native allocation counts. The views field counts occupied associations; object/
heap lifetime tags may retire outside the metadata mutex. A full-table scan
refusal records attemptedCount=capacityLimit+1, but a live-count sample may already
have fallen by the time it is taken. Counts remain bounded and are not required
to equal the limit in receipt validation.

`BeamRT_ResourcesFirstFailure` returns a typed empty record and S_FALSE while
healthy, S_OK with the immutable event after failure, and not-ready before the
tracker exists. Null/wrong-sized buffers refuse without writing. The separate
184-byte `BeamRT_ResourcesDiagnostics` reads status and first failure under one
mutex for coherent startup transport. Existing resource status stays 88 bytes
ABI 1; existing binding payload/status/record/thread ABIs stay unchanged.

Native calls still forward outside the metadata mutex, preserving native return
values and LastError. No limit, overlap guard, draw checkpoint, lifetime rule,
OFF ownership check or proof flag was relaxed. If resource lookup itself newly
invalidates tracking, FinishDraw clears every SRV/RTV/CBV result before publishing
a refused diagnostic receipt.

## Resource-only transport revision

Resource handoff and draw observation now use ABI 3, rejecting ABI 1 and 2.
Payload remains 48 bytes. Start receipt is 208 bytes, draw observation 2,832,
record receipt 2,856, and combined reply 3,064 bytes. Both start and draw receipts
carry the fixed first event. Parent start validation separates well-formed
diagnostic metadata from successful installation, saving a coherent startup
refusal before returning. No draw is attempted or inferred from that refusal.

This remains a separate, explicit `--observe-gi-resources` payload. Default-off,
CBV-probe-zero behavior, inherited handle counts, read-only parent mapping,
event publication and CREATE_NEW output semantics are unchanged. A diagnostic
record is not a lease, state chain, camera interpretation, GPU fence or lighting
consumption proof. All proof flags stay zero.

## Original pre-repair fixture results

These historical results belong to the subsequently blocked candidate. Current
repair results are recorded in [Private-type isolation](PRIVATE_TYPE_ISOLATION.md).

The isolated resource fixture installs a fixture-owned SRV forwarding shim before
starting the tracker on a real D3D12 device. Only the fixture contains this gate.
A bounded event rendezvous holds one native-forwarding callback in flight while
a second valid write uses a different descriptor slot. This deterministically
tests overlap without relying on driver timing, invalid native arguments or
concurrent writes to the same descriptor. Normal/error paths release and join
the worker. After tracker OFF, the fixture restores the genuine native pointer.

Five separate sessions test heap/object/view/draw capacity-first and overlap-first.
Capacity-first then overlap must retain the original event byte-for-byte.
Overlap-first then native allocation pressure must keep the overlap event; the
already poisoned tracker does not resume metadata or invent a pressure counter.
They also verify bad ABI/size/shape refusal, healthy empty records, event survival
through refused draws/OFF/late cached forwarding, ten restored slots and native
GPU pixel 23 after OFF.

The strict standalone build passes on WARP and the same binaries pass on RTX
4070: each of the five sessions passes 17/17 named groups, rejects 27 malformed
draw observations and 17 malformed first-failure observations. The debug layer
was unavailable; this is not debug-layer-clean or live-game coverage proof.

The fresh strict startup candidate also passes all 9 resource-connected cases
and all 11 unchanged binding/thread cases, with all private fixture jobs drained.
Parent/child resource receipt bytes agree. Its pressure case records heap capacity,
method CreateHeap, callback 56, limit 32/attempted 33 rather than only an aggregate
pressure counter. The host self-test rejects 134 option/payload/metadata cases,
including prior resource ABI 1 and 2 and malformed startup first-event shapes.
A coherent unhealthy startup record is explicitly accepted as diagnostic metadata
before the separate health gate refuses continuation. Project discovery passes
256/256, including ten new first-event source guards. Source guards supplement,
not replace, native fixtures.

Retained artifacts under `.beamrt-validation/`:

- `resource-tracker-39e25139417d497cb57c66828aecea58`: exact standalone sources,
  strict build, five WARP and five RTX session logs.
- `native-startup-resource-babbee8fb8f040b2a4198f6f37e480aa`: fresh startup host/
  bootstrap, copied frozen source and disposable child receipts/reports.
- `first-failure-ccca9d69837841b3be7749e0b6ab1d1d`: pre-build source hashes,
  source freeze, build logs, project tests and final verification.

Frozen native source matches post-build hashes with no drift. Previously
successful live bundles are unchanged. The build only selected disposable fixture
executables; no BeamNG executable was started or attached, no existing game was
closed or changed, and no native lighting was enabled.

```powershell
./native/startup/build_resource_tracker.ps1 -RunTest -Warp
./native/startup/build_resource_tracker.ps1 -RunTest
```

## Next boundary

Review the exact new startup candidate before separately approving any future
game probe. An accepted first-event receipt would identify which tracker guard
invalidated metadata first; it would not itself fix that guard's coverage.
Capacity/concurrency changes require explicit lifetime/order correctness and new
tests. Do not just raise limits or disable overlap rejection to obtain a pass.
Native GI dispatch and consumption remain off. The historical unexplained DLL
loading anomaly and unidentified source-reset writer remain unresolved.
