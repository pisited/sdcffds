# Explicit compact descriptor profile — 2026-10-16

Later source now offers a separate [heap-interned profile2](DESCRIPTOR_INTERNED_PROFILE.md)
with ABI7 transport and offline native tests. Profile0/1 defaults and the frozen
ABI6 live observation below remain unchanged; this page is its historical snapshot.

Subsequent separately approved [live observation](COMPACT_STORAGE_LIVE_OBSERVATION.md)
confirmed real sharing (1,024 locations / 47 payloads / 32,096 bytes), but still
refused the next location. The offline implementation/results below remain a
historical snapshot, not proof of a working GI resource handoff.

The installed unpacked BeamRT source now supports a separately selected compact
descriptor-storage profile. **Legacy remains the default.** This is an offline
implementation and validation result, not a BeamNG deployment or lighting change.
No game launch, native GI dispatch, shader/Lua/settings edit or DLL installation
occurred in this step.

The last live observer stopped at 256 descriptor locations. This profile may
remove that particular limit when descriptions repeat, but its benefit for the
real game population remains unknown. These fixtures do not prove the next game
run will reach usable resource metadata.

## Limits and compatibility

| Profile | Locations | Distinct payloads | Arena bytes |
| --- | ---: | ---: | ---: |
| Legacy, default | 256 | 256 | 47,104 |
| Compact, explicit | 1,024 | 256 | 47,104 |

The lossless Store uses 24 bytes per location and 160 per exact shared description.
Its compiled size remains 47,160 bytes, including 56 bookkeeping bytes. Sharing
excludes only destination heap and revision, not resource lifetime, full view
descriptions, signed-zero bits or padding. No resource-ID-only merging, live
eviction or unbounded storage is used.

Thus 1,024 identical descriptions fit in 24,736 arena bytes. Conversely, 256
distinct descriptions use all 47,104 bytes: an additional copy of an existing
description needs 47,128 and must fail. This is conditional compression, not a
universal fourfold capacity increase. Heap/resource/copy/draw budgets remain
32/128/64/16. Scans and callback contention remain unbenchmarked.

Selection is immutable before observer publication:

- Old `BeamRT_ResourcesStart` and Config v1 always select legacy.
- Config v2 / `BeamRT_ResourcesStartProfiled` explicitly select profile 0 or 1.
  Compact requires descriptor-texture admission; buffer/CBV inference stays off.
- The host requires the explicit compact-storage option in addition to existing
  resource/descriptor-only gates. No mode activates by default.
- Status and first-failure layouts stay 88/96 bytes, but semantic ABI is 1 for
  legacy and 2 for compact. Default legacy validators reject compact even below
  256 locations. Full view metadata remains ABI 1 / 168 bytes.
- Resource transport is ABI **6**: payload 56, start 352, record 32,704 and reply
  33,056 bytes. Draw ABI **4** is 2,960 bytes; copy companion ABI **2** is 29,704.
  Fixture report ABI **2** is 33,160 bytes. Do not mix old hosts/DLLs/decoders with
  these files; prior frozen bundles retain their original contracts.

## Coherent failure evidence

Diagnostics expose locations, distinct payloads and arena bytes separately, with
selected profile and exact limits. The original first failure retains its own
immutable storage sample and exact attempted counts. Capacity causes preserve
Store order: **location, then payload, then byte budget**. Byte attemptedCount is
actual required bytes, not `limit+1` in the wrong units. Older failure enum values
are not renumbered.

Current storage is copied under the same metadata lock as draw/status/first
failure, not queried later and joined to a historical draw. After failure,
diagnostic dead-ID reaping may reduce counts, but cannot recover health, insert
metadata, reset revisions or replace the first cause. Validators also require
current locations/payloads/bytes not to exceed their original failure sample.

Copy companions remain limited to applicable first copy-capacity events. The
bridge, host and process harness join the exact immutable storage sample, not just
its location count. Nonapplicable companions remain canonical typed empty.
Native forwarding, LastError, lifetime tags, full source snapshots, clear-all
before copy insertion, overlap refusal, process-lifetime residence and OFF10 are
retained. No resource lease, state chain or GPU-completion proof is added.

## Verification

- Strict `/W4 /WX` standalone and actual co-linked bootstrap/host builds pass.
- Full isolated project Python/Lua suite: **311/311**.
- CPU Store fixture: **10 groups**, including 5,000 deterministic independent-
  reference operations, optimized `/O2` and checked `/Od /RTC1` runs. New cases
  test explicit ABI discrimination at zero views, malformed metrics/failure
  records, exact capacity units, precedence and post-reap joins.
- A disposable negative copy with monotonic checks removed compiles and exits 1
  at `post-failure occupancy growth accepted`. Never a deployment candidate.
- Same standalone binaries: **18 legacy + 4 compact sessions on RTX 4070**, and
  the same **22 on WARP**. Healthy compact fanout retains 413 locations through
  a real draw. Separate cases reach each of the three limits, retain immutable
  failure through reaping/OFF, and verify unchanged native GPU pixel 23.
- Production co-linked fixtures: **11 binding/thread cases**, **25 resource
  cases** (including four compact cases on both backends), and **171** rejected
  no-launch option/payload cases. Private jobs drain. Healthy compact records
  retain 307 locations / 7 payloads / 8,488 bytes at the draw; location pressure
  stops at 1,024/1,025; payload pressure at 256/257; byte pressure at 47,104/47,128.

The D3D12 debug layer was unavailable. These are not debug-layer-clean, ASan-clean,
performance, full game-resource coverage or live-game integration results.

## Frozen evidence and next boundary

- Work, source freeze, full suite, checked CPU and negative control:
  `.beamrt-validation/compact-storage-profile-d0ad942168904c23855ed4b6f1f5d48e`.
- Optimized CPU source/binary:
  `.beamrt-validation/descriptor-view-store-c42cf375d80e41d3b346d4f4fb0efb0e`.
- Standalone source/binaries and 44 session logs:
  `.beamrt-validation/resource-tracker-069cd05286b243f2a534151599ba7bc9`.
- Final co-linked candidate:
  `.beamrt-validation/native-startup-resource-834f7d003e3a4f53914507d24f4e3526`.

Host SHA256: `703149108c6459453cb7320f26e4a6d66854e6bb305232f2600aac6a67dac021`.
DLL SHA256: `40be3d7987c7f7b405a2ab550565f7c4d2f20895f04f2002f5a52d1172eb5368`.

This candidate is **offline-only, not game-approved**. Next is its own frozen
launch review, then a separately authorized bounded observation run measuring
the actual game population and first refusal, if any. No lighting change belongs
in that probe. Camera meaning, resource states, GPU ordering and an actual GI
consumer remain separate unproven boundaries.
