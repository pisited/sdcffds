# Copy-topology live observation — 2026-10-15

One separately reviewed and explicitly approved observation-only startup reached
West Coast USA normally. The user enabled usual BeamRT GI and confirmed normal
map appearance and closure. Retained host and game handles both reported exit 0;
no BeamNG or startup-host process remained. **Resource metadata still refused.**

The new companion identifies genuine capacity pressure in this observer's
256-association table: this batch needed an additional tracked destination and
had no previous destination association to release. It is not the transient
insert-before-clear case repaired offline. This is not native GI integration.

## Frozen run and closure

- Run: `.beamrt-validation/live-copy-topology-fefcfc72eb664992971a8f87ebbe48a6`.
- Candidate: `native-startup-resource-08b3c3f0b909485fbc61c9a066df5385`.
- Host SHA256: `472319fe1c3edee26c25999f6144f56e3e09e191bf3f61da5469103ff8186917`.
- DLL SHA256: `57d4f362b1131d5bb736183a5806dd116aba84ec711890534ae4167c050b088d`.
- Game SHA256: `5a0420b44da74c3aa5388e460b602fcaa2baefafe2a64c6bff7c29a9345a2af2`.
- Target VS SHA256: `d407f0efd92a209c5ad5ad486c95e454010c5abd7d34f491b0d0fd6687321b3f`.
- Target PS SHA256: `88d0456967dbfacec1e7641f1a1e4301e3835a22dae9f78b090d39bc8f88dde7`.

All 58 installed native inputs, 14 prepared artifacts and 533 candidate artifacts
matched their manifests before launch and after normal closure. The startup
build script also matched; no source reset was observed in this run. This does
not identify the historical reset writer or resolve the older loading anomaly.

Host PID 30088 started at 22:21:00 MDT and retained actual owned game PID 44140
at 22:21:06. Host exit 0 was recorded at 22:22:45; normal game exit 0 at 22:25:18.
No existing-process attach, forced resumed-game closure, hot unload, retry or
second launch occurred. This consumed the single-attempt marker and approval.
The original prepared-only `REVIEW.md` is retained as historical prelaunch state.

The host self-test rejected 153 malformed cases before launch. Prior offline
verification remains 290/290 project tests, 36 standalone RTX/WARP sessions and
the co-linked fixtures described in [the topology implementation](COPY_FAILURE_TOPOLOGY.md).
These are separate from this live observation; the D3D12 debug layer was unavailable.

## Joined CPU receipts; resource interval refused

Exact target VS/PS creation and a 168-byte root were observed on thread 51524.
The binding receipt records DrawInstanced with four vertices/one instance,
command 8/generation 1143/serial 1, viewport 1280×678 and one output. The host and
independent bounded binary parsers agree on the joined PID/thread/command keys.

Resource transport is ABI 5: start 216 bytes, record 32,480 bytes, with the
29,616-byte ABI-1 copy companion. Mode is explicitly 1 (descriptor textures),
CBV probe bytes 0. Startup was healthy with ten hooks and no observed callbacks.

At the matching draw the resource interval was refused: ticket 0, no valid output
checkpoint, E_INVALIDARG because no draw token was accepted. This is not a claim
that the game's native draw arguments were invalid. SRVs were 0/6 and outputs
0/1; view results were S_FALSE with zero metadata. CBV metadata was also zero.
All descriptor/CBV/camera/GPU-ordering/lighting-consumed proof flags remained zero.
Numeric identities in the failure companion do not constitute usable resource
leases, camera semantics, known states, GPU completion or GI consumption.

## First failure and exact copy topology

The first recorded invalidation is ViewCapacity (kind 5) in CopyRanges (method 7),
callback ordinal/observed callbacks 4456, caller 51524, active callbacks 1,
limit 256/attempted 257, overlaps 0, pressure 1, revision 4421. At that event the
tracker counted three live heaps, 26 admitted resources, 256 view associations
and zero draw tokens. This is metadata-lock-recorded order, not absolute native
API-entry or GPU chronology, and these are not whole-game resource counts.

The companion's original failure matches byte-for-byte. It contains four flattened
lanes, failed lane 1 and completed metadata prefix 1. Three destination ranges
have explicit sizes 1/1/2; four source ranges omit sizes, meaning one each.
Descriptor stride is 32. Destination indices in heap 3 are 4732/4734/4736/4737;
source indices in heap 1 are 461/2/437/322. All four previous destination view
snapshots are empty. No source/destination alias is represented.

| Heap | Observed type | Shader-visible | Descriptor extent | Entry / after-clear / failure associations |
| --- | --- | --- | ---: | --- |
| 1 | CBV/SRV/UAV | No | 1,000,000 | 28 / 28 / 28 |
| 2 | RTV | No | 65,536 | 9 / 9 / 9 |
| 3 | CBV/SRV/UAV | Yes | 1,000,000 | 219 / 219 / 219 |

Thirteen retained heap slots include ten sampled retired slots with zero
associations. Occupied counts sum to 256 at each of the three stages. Clearing
all destinations therefore released no tracked association in this batch.

Lane 0 has no known source view. Lane 1 has a known source view for resource ID
20/revision 8, a 2×2 texture with numeric format 28, copied toward previously
untracked heap 3/index 4734. Lanes 2 and 3 have no known source views. An unknown
source is not evidence of a native null descriptor; the small known texture is
not proven to be a fallback, irrelevant or safe to discard.

The current copy-order repair is present, but this batch still requires a new
association when the table is full. The receipt does not expose the payloads of
all other 256 entries, establish whole-game demand, justify resource-ID-only
deduplication, or authorize eviction or a larger limit. It also does not
retrospectively explain the earlier ABI-4 live batch, which lacked this companion.

Later draw-time status has 136870 callbacks, 13 overlaps, pressure 1, 4106 unknown
copies, three live heaps, 22 admitted resources and 179 view associations.
Revision remains 4421, equal to the first failure: no trailing revision processing
is represented after refusal. Later lifetime reaping does not restore tracker
health or prove that resuming observation or evicting live mappings is safe.

## Other limitations and retained evidence

The binding thread guard counted 2,962,359 rejected calls: 2,003 first epoch
conflicts and 2,960,356 repeats; 2,960,837 before target readiness and 1,522 after.
Its bounded first-16 sample prefix is pre-target biased. These counts do not
establish illegal engine threading, concurrent API execution, or a safe policy
for sequential recording-thread transfer. Existing guards remain unchanged.

The game log records West Coast load completion and manual `beamrt_main.start()`.
Existing Lua reflection convergence also briefly ran during loading, another
probe refused because an experiment was active, and convergence then cancelled
with `restored=true; mission changed`. Existing warnings are retained. This is
not a clean visual or performance benchmark; no Lua/HLSL/settings were changed
for this observation. Native capture, worker/native GI dispatch and lighting
integration remained OFF throughout.

The run retains raw receipts, stdout/stderr, normal-exit files, before/after game
logs, `runner.log`, the approval journal, original review/manifests, independent
`resource-analysis.json`/`binding-analysis.json`, and post-run hash verification.
Signed asset-download URLs in game logs are unnecessary to the findings and are
not reproduced here. No native source change was made while closing this run.

## Next boundary

Do not repeat this unchanged game probe. The next offline work is a bounded
descriptor-location representation/scope design that preserves independent view
descriptions, heap lifetimes and write revisions, explicit unknown coverage and
fail-closed ownership/overlap checks. Lossless compression or relevance scoping
are design candidates, not validated fixes. Do not merely raise the table cap,
evict live associations, or relax lifetime/thread guards to obtain a green receipt.

Real GI resource coverage, camera meaning, state chains, queue ordering and final
consumer retirement still need proof. This successful startup/closure does not
lift the deployment hold; every further live attempt requires a new frozen review
and specific approval.
