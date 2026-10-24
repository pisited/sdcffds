# Heap-interned location storage — CPU-only experiment, 2026-10-16

Historical prototype snapshot. The subsequent [explicit interned profile](DESCRIPTOR_INTERNED_PROFILE.md)
integrates this representation behind new versioned contracts and offline native
fixtures. It does not retroactively change the evidence or claims below.

This is a new lossless numeric storage prototype in the installed unpacked mod,
**not a change to the observer, ABI6 receipts, active storage profiles or game**.
The live-tested 1,024-location candidate and earlier evidence remain frozen.
No BeamNG launch, GPU work, settings/shader/Lua change or new DLL deployment was
performed for this experiment.

## Why this approach

The [live compact test](COMPACT_STORAGE_LIVE_OBSERVATION.md) proved sharing of
full descriptions: 1,024 locations referred to 47 distinct payloads. It still
hit the location bound with byte capacity left. Its GPU-visible heap accounted
for 975 locations, but the receipt exposed only three copy lanes—not all indices,
payload assignments or revisions. It did not prove those locations form ranges.

GI-only filtering is not safe to infer yet. Binding identity becomes authoritative
after earlier copies may have happened; discarding a source or chasing its later
handle can lose the value already copied before that source was overwritten.
There is no demonstrated predicate for dropping unrelated-looking mappings.

The narrow first step is therefore a **14-byte flat location**, with no adjacency,
affine-revision, range-density or relevance assumptions. Optional bitmap/range
storage remains a later design choice, not implemented here.

## Exact representation and explicit budgets

`descriptor_location_store.h` uses the existing exact 152-byte shared payload
key and 160-byte payload records. Every view byte other than normalized heap ID
and per-location revision remains in the payload, including full descriptions,
resource lifetime/identity, signed-zero and padding bits.

Each location is serialized field-by-field with memcpy:

| Field | Bytes | Meaning |
| --- | ---: | --- |
| Heap slot | 1 | Index into a fixed full-ID directory, never a truncated heap ID |
| Payload slot | 1 | Internal index 0..255, not the count256 sentinel |
| Descriptor index | 4 | Entire uint32 index, including UINT32_MAX |
| Revision | 8 | Entire caller-supplied uint64 revision, including non-affine gaps |

No unaligned packed-struct dereference is used. The 32-entry heap directory costs
512 bytes **inside** the 47,104-byte arena. Each 16-byte slot stores its full
64-bit heap lifetime ID, logical reference count and reserved zero. Slots are not
evicted or compacted; their last reference releases them. Numeric IDs/refcounts
are not native object leases or an independent lifetime detector.

Current prototype occupancy is:

`512 + 14 * logicalLocations + 160 * distinctPayloads <= 47,104`.

Empty usedBytes is therefore512, not0. There are explicit bounds of32 occupied
heap IDs,256 payloads and4,096 logical locations/work items. The byte bound may
stop much sooner (even one payload permits only3,316 locations). These heap counts
mean directory slots with locations, not all tracked/live native heaps. The
compiled Store is47,176 bytes: arena47,104 plus72 explicit bookkeeping bytes.
There is no hidden allocation, dynamic fallback, live eviction or smaller ID.

The legacy256-distinct case still fits:45,056 bytes including the directory,
versus47,104 in the previous representation. For counts matching the live failure,
L1024/P47 would cost22,368 bytes instead of32,096, independent of index placement.
That is representation arithmetic, not a replay or proof of a successful game
handoff. The synthetic fixture also fits2,000 scattered locations/P47 in36,032
bytes, with irregular full-width revisions and arbitrary descriptor indices.

## Preserved semantics and integration boundary

The caller must serialize access, validate heap extents/ownership and supply
accurate lifetime observations. The primitive is not a graphics interceptor.
It preserves full returned value copies, independent location revisions, global
strictly increasing revision watermark, overwrite clear-before-insert behavior
and copied-source snapshot independence. The fixture's batch model snapshots
sources before clearing all destinations; unknown sources remain holes, not
fabricated native null descriptors.

Key capture happens before overwrite clearing; heap/payload slots are looked up
again afterward because deletion can release a heap slot or relocate a payload.
All surviving references to a moved payload are repaired. Capacity precedence is
logical locations, occupied heaps, payloads, then arena bytes; attempted demand
and the original post-clear first failure remain explicit and immutable.

Strict operations refuse after poison and clear failed lookup outputs. Diagnostic
reaping of caller-observed dead IDs can reduce counts after failure but cannot
restore health, reset revisions or replace the cause. External registries must
still retire old lifetime IDs before reusing their own slots.

**Not drop-in compatible:** ABI6 still requires24*L+160*P and a1,024 compact bound.
Silently substituting this Store would falsify its metrics and contracts. Any
integration must first define honest versioned storage semantics/configuration,
preserve legacy/default behavior, rerun real native copy/lifetime/OFF/co-linked
fixtures and obtain separate frozen review/approval for a game attempt. This
experiment neither changes that bound nor approves a larger one.

## Verification

- Strict `/W4 /WX /std:c++17 /MT /O2` build:11 CPU groups pass.
- Checked `/Od /RTC1` build: same11 groups pass. This is not ASan-clean proof.
- Each run includes5,000 deterministic operations against an independent map of
  full168-byte values, not a reference reusing the production key encoder.
- Tests cover all32 occupied heap slots and a33rd refusal; same-index heap IDs
  differing only in high bits; high64-bit revisions; UINT32_MAX indices; payload
  slot255; many references to a moved payload across32 heaps; last-reference heap
  slot reuse; raw-byte identity; source overwrite/retirement after copying;
  unknown holes; clear-before-capacity; malformed values/limits; and poisoning.
- Exact byte boundary: L3248/P7 uses47,104; one shared insertion needs47,118 and
  refuses. Invalid IDs, revision equality/regression and capacity priority refuse.
- Two isolated broken copies compile and exit1 at intended runtime assertions:
  compare only low32 heap-ID bits; omit moved-payload reference repair. They are
  never observer or deployment candidates.
- Full isolated Python/Lua project suite: **319/319**, including eight new source
  guards. CI adds this separate CPU experiment without activating an observer.
- All61 existing game-facing native inputs are checked against the live-tested
  freeze. No production source/profile/ABI/cap or frozen candidate is changed.

Performance, contention, game population demand, native resource coverage,
camera semantics, states, GPU ordering and native GI consumption remain unproved.
No GPU/game tests were repeated for an unintegrated CPU primitive.

## Frozen evidence and next step

Final optimized source/binary:
`.beamrt-validation/descriptor-location-store-ff22cc0baca745f490c862c41d8e3869`.
Checked/full-suite/negative-control and preservation evidence:
`.beamrt-validation/location-store-prototype-5495366c8afb492785eb6eb56d4b81bb`.
Earlier intermediate builds are retained but are not the final result.

Next is a separately reviewed integration contract, not another unchanged game
probe. Do not silently reinterpret ABI6, change defaults, guess GI relevance or
relax lifetime/thread guards to obtain a green receipt.
