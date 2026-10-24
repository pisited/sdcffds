# Repaired-type live observation — 2026-10-15

Follow-up: [descriptor-focused admission](DESCRIPTOR_RESOURCE_ADMISSION.md) is now
implemented and verified offline. This live run used legacy all-allocation mode
and does not establish compatibility or coverage of that new mode/ABI-4 candidate.

One separately approved observation-only startup completed without reproducing
the earlier startup access violation. This is a successful startup/draw/normal-
closure observation for one frozen build, **not** successful native GI/resource
integration or a guarantee of compatibility. The resource metadata was refused.

## Exact test and process outcome

Run: `.beamrt-validation/live-type-isolation-fb2bec14c3984f33a556c0d6f35ecda8`.
Candidate: `native-startup-resource-022288f526bb423ca5e2084714205346`.

- Host SHA256: `8229ae6f291e7e7c0e66585638427adad16e27f4aec5d2ccdf19615427be8341`.
- DLL SHA256: `b13b8051f9fa4d3f8738f19dc547d7146082d62ce8162abd062fa958a610fd82`.
- Game SHA256: `5a0420b44da74c3aa5388e460b602fcaa2baefafe2a64c6bff7c29a9345a2af2`.
- Actual cached GI VS/PS hashes remained `d407f0ef…321b3f` / `88d04569…8dde7`;
  their complete hashes and fresh cache inventory are retained in the run review.

All 19 prepared input hashes and 421 candidate artifact hashes matched before
launch. Two independent read-only reviews found no new concrete blocker for the
narrow test. Current project tests passed 266/266 and the no-launch host self-test
rejected 134 malformed cases. The user explicitly approved one new attempt after
being told a crash was still possible; no existing game or host was present.

Host PID 30296 started at 10:21:53 MDT and retained actual owned game PID 26216.
DLL attach, restored entry rendezvous and imported-device observation succeeded
on thread 30308. The user confirmed West Coast USA loaded normally with usual GI
enabled; the game log records `beamrt_main.start()`.

The host captured the exact shader pair, 168-byte root and matching GI draw, then
exited 0 at 10:23:53 MDT. The user closed the game normally; its retained handle
reported exit 0 at 10:25:45 MDT. No BeamNG/host process remained. All 53 native
source inputs and 19 prepared inputs still matched after closure, including the
startup build script. No source-reset event occurred in this run; that does not
identify the writer responsible for older resets.

## Coherent receipts, but no accepted resource interval

Independent bounded binary decoders checked the receipt sizes and identities:

- Start receipt: 208 bytes, ABI 3, PID 26216, initial/caller thread 30308,
  S_OK, healthy, ten slots attached, zero initial callbacks/objects and typed-empty
  96-byte first failure. No phantom initial resource was counted.
- Binding receipt: 1144 bytes, draw on thread 30308, command 9, generation 1875,
  serial 1, four vertices/one instance, viewport 1280×684, one output.
- Resource receipt: 2856 bytes, ABI 3, matching PID/thread/serial/command/generation.
  Interval refused, ticket 0, E_INVALIDARG for the absent accepted draw token.
  All SRV/RTV results are S_FALSE; all resource and CBV metadata are zero.
  CBV probe is 0. All camera/resource/GPU/lighting proof flags remain zero.

E_INVALIDARG here does not say BeamNG supplied invalid native graphics arguments.
It describes the observer's failed metadata interval after its tracker became
unhealthy. Native rendering calls continue forwarding.

## First recorded invalidation is now known

| Field | Preserved first event | Later draw observation |
| --- | --- | --- |
| Callback watermark | 823 | 294584 |
| Recorded overlaps | 0 | 52 |
| Capacity-pressure events | 1 | 1 |
| Descriptor revision | 212 | 212 |
| Live heaps / resources / views | 13 / 128 / 74 | 3 / 75 / 44 |

The first event is **ObjectCapacity / Placed** (`kind=4`, `method=9`) on thread
30308, callback ordinal 823, observed callback count 823, active callbacks 1,
limit 128 and attempted table entry 129; no draw tokens were live. This is a
tracker-table admission refusal, not the game's total resource allocation count.

Capacity was the first invalidation recorded under the metadata mutex, with zero
recorded overlaps then. The later 52 overlap observations did not replace or
reclassify it. This is not absolute cross-thread API-entry chronology or GPU
concurrency evidence. Lower later live counts are consistent with object lifetime
retirement/reaping; they do not undo the previously latched unhealthy state.

The recording observer separately counted 30,450,953 ownership/thread rejections
over 10,699 first-conflict epochs, mostly before target identification. Its first
16 samples are bounded/pre-target-biased, not a proof of illegal engine threading
or actual simultaneous calls. Do not remove the ownership guard based on totals.

## Scope caveats and next boundary

Native capture, worker/GI dispatch and lighting integration stayed off. No visual
improvement was expected. No hot unload, forced resumed-process close, second
startup, permanent installation, shader/Lua edit or graphics-setting change was
performed by the agent. The existing Lua startup did launch an automatic reflection
convergence experiment, rejected a simultaneous source probe, and cancelled the
convergence experiment with `restored=true; mission changed`. Other mod/global-
warning and input-action errors are in the retained log. This was not a clean
visual/steady-frame performance comparison. The debug layer was not enabled.

The next engineering issue is lifetime-safe, bounded resource admission/coverage
that can survive ordinary map loading, followed by explicit concurrent-callback
and command-ownership coverage. Do not merely raise 128, evict live entries
arbitrarily or remove the overlap guards to make a receipt pass. No further game
test is needed until the relevant offline implementation and fixtures change.

Actual resource IDs/formats, camera semantics, states, GPU ordering/completion and
native GI consumption remain unproven. Earlier loading failures and the historical
source-reset writer remain unresolved. The general deployment hold and requirement
for separate approval of every new game probe remain intact. The old crashed DLL
and negative-control bundles remain blocked from game use.

Primary evidence in the run directory: `APPROVAL.md`, `REVIEW.md`, `host.stdout.log`,
`recorded-draw.bin*`, `binding-analysis.json`, `resource-analysis.json`, retained
exit files, `beamng-after.log`, `completion.json` and completed SHA256 manifest.
