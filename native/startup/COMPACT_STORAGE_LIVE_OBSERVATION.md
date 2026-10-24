# Compact storage live observation — 2026-10-16

One separately reviewed and explicitly approved startup reached West Coast USA
normally. The user enabled usual BeamRT GI, confirmed the map loaded normally,
and closed the game normally when asked. Retained host and game handles both
reported exit 0; no game/host process remains. **GI resource access still refused.**

The useful new result is real descriptor sharing: the observer reached 1,024
locations using 47 distinct full view descriptions and 32,096 arena bytes. It
then refused location 1,025 despite available byte and payload capacity. The
new limit, not failed deduplication or a full byte arena, is the first cause.
This establishes conditional compression in this game run, not native GI use,
complete resource coverage, a performance improvement or a safe larger limit.

## Frozen run and normal closure

Run/evidence:
`.beamrt-validation/prepared-compact-observation-a3da109043ca45a1a517cf3e984ef81e`.
Candidate: `native-startup-resource-834f7d003e3a4f53914507d24f4e3526`.

- Host SHA256: `703149108c6459453cb7320f26e4a6d66854e6bb305232f2600aac6a67dac021`.
- DLL SHA256: `40be3d7987c7f7b405a2ab550565f7c4d2f20895f04f2002f5a52d1172eb5368`.
- Game SHA256: `5a0420b44da74c3aa5388e460b602fcaa2baefafe2a64c6bff7c29a9345a2af2`.
- GI VS SHA256: `d407f0efd92a209c5ad5ad486c95e454010c5abd7d34f491b0d0fd6687321b3f`.
- GI PS SHA256: `88d0456967dbfacec1e7641f1a1e4301e3835a22dae9f78b090d39bc8f88dde7`.

The copied host rejected 171 malformed no-launch cases; exact default review
passed. Fresh cache inventory found the same shader pair in 1,620 records,
30,208,314 bytes (cache SHA256
`748fe3035a7719c140a383285a58fb8bdac3209c1d396664246cd5117d16bac8`).
Cache identity alone was not treated as execution proof. Before launch all 61
native inputs, 428 candidate artifacts and 281 prepared files matched manifests.
Original prepared-only review documents remain historical prelaunch state;
APPROVAL.md and the consumed attempt marker record this one authorized attempt.

Host PID 46140 started at 21:13:53 MDT, retained owned game PID 15240 at 21:13:59,
and exited 0 at 21:15:39. Game normal exit 0 was retained at 21:17:07. No retry,
second launch, existing-process attach, hot unload or forced resumed-game closure
occurred. Native capture, worker/native GI dispatch and lighting integration
stayed off. No source/settings/shader change was made as part of this test.

## Joined CPU receipts

Exact target GI VS/PS creation matched with a 168-byte root on thread 8488. The
recorded DrawInstanced has four vertices/one instance, command 8/generation 781/
serial 1, viewport 1280x677 and one output. Resource transport ABI6, mode1,
profile1 and probe0 join that same PID/thread/serial. Start was healthy with ten
attached slots and zero callbacks/occupancy.

The prepared compiled ABI6 decoder accepted exact start352, binding1144 and
resource32704 files. An independent reviewer reran it read-only with expected
PID15240/mode1/profile1 and found no contradictions. An independent binding/
thread parser also accepted the unchanged binding1144/thread1184/prefix912 layouts.
The old ABI5 resource decoder was not used.

At the GI draw, the resource interval is refused: intervalAccepted0, ticket0,
no valid output checkpoint, E_INVALIDARG from the absent/nonmatching token path.
This is not evidence that BeamNG's native draw arguments were invalid. All six
SRV and one active output metadata records are empty, with S_FALSE view results.
CBV metadata is empty and probing is off. Descriptor/CBV/camera/GPU-ordering/
lighting-consumed proof flags are zero.

## Precise first failure and copy population

First invalidation is ViewCapacity (kind5) in CopyRanges (method7), callback/
observed-callback16779, serial19950, caller8488, active1, overlaps0, pressure1.
It is the first event recorded under the metadata mutex, not absolute API-entry
or GPU chronology. These are observed CPU associations, not whole-game totals.

| Sample | Locations | Payloads | Arena bytes |
| --- | ---: | ---: | ---: |
| Original first failure | 1,024 / 1,024 | 47 / 256 | 32,096 / 47,104 |
| Attempted insertion | 1,025 | 47 | 32,120 |
| Later matching GI draw | 886 / 1,024 | 41 / 256 | 27,824 / 47,104 |

The original event counted three live heaps, 32 admitted resources and zero draw
tokens. Later status counts 111,423 callbacks, zero overlaps, pressure1, 18,700
unknown copies, 29 live admitted resources and unchanged serial19950. Reduced
occupancy is consistent with dead-ID reaping, not restored observer health.

The immutable copy companion matches the original first failure and storage
sample exactly. It has three lanes, failed lane2/applied prefix2, and entry,
after-clear and failure occupied counts all1,024. Heap associations are:

| Heap | Type | Shader-visible | Descriptor extent | Entry / clear / failure |
| --- | --- | --- | ---: | --- |
| 1 | CBV/SRV/UAV | No | 1,000,000 | 34 / 34 / 34 |
| 2 | RTV | No | 65,536 | 15 / 15 / 15 |
| 3 | CBV/SRV/UAV | Yes | 1,000,000 | 975 / 975 / 975 |

Ten other retained heap slots were sampled retired with zero associations.
All three previous destinations are empty. The first two source views are
unknown, not proven native null descriptors. The failed third lane has a known
source: heap1/index16, resource22/revision10, 128x128 texture, numeric format28,
copied toward heap3/index8452. The earlier destination indices are8450/8451;
source indices420/407. These snapshots are not leases, native resource pointers
or evidence that this texture is a GI input/fallback/irrelevant.

## Caveats and next boundary

Binding diagnostics count 1,408,738 thread-guard rejections, all before target
readiness: 1,187 first epochs and 1,407,551 repeats. The bounded first16 samples
are pre-target biased. These are not evidence of illegal engine concurrency or
authorization to relax ownership/overlap guards.

The game log records West Coast completion and manual `beamrt_main.start()`.
Existing automatic reflection convergence briefly ran during loading; another
probe refused because an experiment was active, then convergence cancelled with
`restored=true; mission changed`. Later ordinary preset/camera changes also appear.
This is not a clean visual or performance benchmark. No settings were changed by
the native probe. Signed log URLs are retained raw but not reproduced here.

The earlier unexplained loading anomaly did not recur but remains unresolved.
No debug-layer-clean or ASan-clean claim is made. Frozen native/prepared/candidate
hashes are rechecked after closure; this does not identify the historical reset
writer. Raw receipts, before/after logs, approval/attempt marker, runner exits,
strict resource/binding analyses and post-run manifests are retained.

Do not repeat the unchanged 1,024-location probe. The next offline decision is
bounded GI-relevant descriptor coverage or a more compact exact location/range
representation, preserving heap/resource lifetimes, individual write revisions,
copy ordering and explicit unknown coverage. Simply raising the cap, evicting
live mappings or removing guards is not a demonstrated fix. The GPU-visible heap
dominates this sample, but the receipt alone does not identify which mappings
can safely be discarded or infer whole-game demand.

Real resource coverage/leases, camera meaning, known states, queue ordering and a
native GI consumer remain separate unproven requirements. This test does not lift
the deployment hold; any future game attempt needs a new review and approval.
