# Descriptor-focused live observation — 2026-10-15

One separately approved descriptor-only startup loaded West Coast USA normally,
captured the GI draw metadata and closed normally. **Resource metadata was still
refused.** The first recorded failure moved from allocation-driven resource
capacity to descriptor-view capacity; this is diagnostic progress, not a native
GI connection or a guarantee of compatibility.

## Frozen run and process outcome

Run: `.beamrt-validation/live-descriptor-admission-cc8f4704d69a4bff95d3952e4ab3cc8c`.
Candidate: `native-startup-resource-7c26d9525b44479aae2947ce497c39b1`.

- Host SHA256: `c961dc7b2603d5159bf20f2165f692e3c80ce4b47d6bc49050b6d73b36aff906`.
- DLL SHA256: `9d2ccbd5cae108b52c5cbdd4799ada2f108149c86b6095b68395c0fb6b1057fa`.
- Game SHA256: `5a0420b44da74c3aa5388e460b602fcaa2baefafe2a64c6bff7c29a9345a2af2`.
- Actual GI VS/PS: `d407f0ef…321b3f` / `88d04569…8dde7`; full hashes and fresh
  read-only extraction are retained in the run review and cache manifest.

All 493 candidate artifact hashes, 53 native source inputs and 19 prepared run
inputs matched before launch. Exact frozen reviews, 278/278 project tests and
143 no-launch host refusal cases passed. The user explicitly approved one
descriptor-only attempt with crash risk acknowledged; no game/host existed.

Host 46604 started at 11:16:21 MDT and retained actual owned game 24128. Attach,
restored entry rendezvous and imported-device observation succeeded on thread
21120. The user confirmed normal map loading and usual GI; the log records
`beamrt_main.start()`. The host exited 0 at 11:17:48 MDT. Following normal user
closure, the retained game handle reported exit 0 at 11:22:11 MDT. No game/host
process remained. No forced closure, hot unload, retry or second launch occurred.

All 53 native inputs and 19 prepared inputs still matched afterward, including
the startup build script. No source-reset event was observed in this run; the
historical writer remains unidentified. Prior frozen game bundles are unchanged.

## Coherent ABI-4 mode identity, refused resource interval

The host and independent bounded binary decoders verified:

- Resource start: 216 bytes, ABI 4, mode 1, reserved 0, PID 24128, initial/caller
  thread 21120, S_OK, healthy, ten hooks, zero initial callbacks/resources and
  typed-empty first failure.
- Exact GI shader pair and 168-byte root; binding receipt 1144 bytes, draw of four
  vertices/one instance, viewport 1280×680, command 14/generation 194/serial 1.
- Resource record: 2864 bytes, ABI 4, mode 1/probe 0, matching binding PID/thread,
  command/generation/serial. Contained observation remains ABI 3 / 2832 bytes.
- Resource interval refused: ticket 0, E_INVALIDARG for no accepted draw token,
  no valid output checkpoint. Every SRV/RTV result is S_FALSE; all resource/CBV
  metadata and all five proof flags are zero. This is not invalid native engine
  arguments, resource identification, camera meaning, GPU ordering or lighting use.

## First recorded failure: ViewCapacity / CopyRanges

The first event is `kind=5`, `method=7`: **ViewCapacity during CopyDescriptors**
on thread 21120, callback ordinal/observed count 4413, active callbacks 1,
limit 256 / attempted table entry 257. Three heaps, 26 admitted resources,
256 occupied view associations and zero draw tokens were observed at that event.
The 128-resource pool was not the first recorded failure in this run.

| Field | First invalidation | Later draw observation |
| --- | --- | --- |
| Callback watermark | 4413 | 148203 |
| Recorded overlaps | 0 | 30 |
| Pressure events | 1 | 1 |
| Descriptor revision | 4509 | 4511 |
| Live heaps / resources / views | 3 / 26 / 256 | 3 / 23 / 214 |

The first failure remains immutable. The later overlaps did not replace it.
Revision advancing by two is consistent with remaining iterations in the same
copy batch: `copied()` ticks per element and does not break immediately when
`write()` latches capacity failure. Do not claim revision froze at first failure.
Later callbacks skip unhealthy observation actions; lifetime retirement/reaping
can lower counts without restoring health.

Counts are tracker entries, not all game allocations or future resource demand.
In particular, 26 at the first failure does not mean the whole game needs only
26 resources: later admissions are refused after health is lost. This is the
first invalidation recorded under the metadata mutex, not absolute API-entry
chronology or evidence of GPU concurrency. The first failure is not a timestamp.

Descriptor copies can create many distinct associations for relatively few
resources. Locations, subresource/view descriptions, revisions and independent
overwrites still matter. The receipt does not justify deduplicating solely by
resource ID, evicting live associations or merely increasing the 256-entry limit.

## Scope and next work

The recording observer also counted 5,258,066 thread-guard rejections across
2,649 first-conflict epochs, mostly before target identification. The bounded
first 16 samples are not evidence of illegal engine use, simultaneous calls or
a legal sequential-handoff rule. No ownership/overlap guard was relaxed.

Existing Lua startup launched a reflection convergence experiment, rejected a
simultaneous source probe, and cancelled the convergence experiment with
`restored=true; mission changed`. Mod/global/input warnings remain in the saved
log. No agent shader/Lua/settings changes or visual/performance comparison was
made. Native capture, worker/GI dispatch and lighting integration remained off;
the debug layer was not enabled. This was one observation-only run, not a benchmark.

The next offline issue is descriptor-location/copy provenance and observation
scope under a bounded lifetime-safe design, while preserving independent view
semantics and fail-closed behavior. Resource/heap/view/format and overlap coverage
remain incomplete. Do not repeat this unchanged test or raise budgets blindly.
Actual GI resource access, camera, states, fences and native lighting consumption
remain unproven; the general deployment hold and separate approval requirement
for every future game test remain intact.

Evidence in the run directory includes APPROVAL/REVIEW, frozen manifests, native
host logs, original `recorded-draw.bin*` receipts, independent binding/resource
analysis JSON, retained exit files, normal-shutdown game log and completion.json.

**Subsequent offline work:** the [copy-batch ordering repair](DESCRIPTOR_COPY_BATCH_REPAIR.md)
reproduces and fixes a transient-capacity defect plus trailing post-refusal
revisions. It does not establish that this historical game's final batch fit the
table; no copy-range topology was recorded here. This run's evidence and frozen
binaries are unchanged, and the newer repair has not been game-tested.

The subsequent [ABI-5 copy-capacity companion](COPY_FAILURE_TOPOLOGY.md) is also
offline-only. Do not decode this historical ABI-4 receipt as if it contained
the new range/lane snapshots; no new game launch was made.
