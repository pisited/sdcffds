# Fixed-memory descriptor view store — offline experiment

Current follow-up: [explicit compact profile and verification](DESCRIPTOR_COMPACT_PROFILE.md).
The prototype results below remain a historical snapshot.

**Subsequent integration:** the observer now uses this storage at its unchanged
256/256 legacy profile. Explicit dead-ID diagnostic reaping preserves cleanup
after failure; compactLimits is still fixture-only. See [the integration and
current native results](DESCRIPTOR_STORE_INTEGRATION.md). The original prototype
scope, frozen results and strict-retirement boundary below describe that earlier
slice, not the later diagnostic-reaping extension.

This follows the [ABI-5 live capacity diagnosis](COPY_TOPOLOGY_LIVE_OBSERVATION.md).
Implemented in the installed unpacked BeamRT folder, but deliberately **not
included by the production observer, loader, resource transport or GI adapter**.
No existing capacity constant, native hook, ABI, frozen game bundle, shader/Lua
code or game setting is changed. No BeamNG launch is part of this work.

The live receipt established 256 occupied locations and a required additional
copy, but did not capture all existing payloads. Twenty-six admitted resources
does not imply twenty-six unique views. Compression effectiveness in BeamNG
remains unknown; this experiment must not be reported as fixing the live refusal.

## Representation and explicit budget

The old internal `View` is a 168-byte `BeamRTResourceView` plus two 64-bit location
fields, 184 bytes per association. The experiment uses a fixed **47,104-byte
arena**, the same as 256 old records, plus at most 64 bytes of explicit Store
bookkeeping (compiler assertions enforce both). It does not allocate dynamically.

The arena contains two dense regions growing toward each other:

- A 160-byte payload: exactly 152 preserved view bytes plus reference count and
  reserved field. Only the original heapId and revision bytes are omitted.
- A 24-byte location: heap lifetime ID, per-write revision, validated 32-bit
  descriptor index and internal payload index.

Every view byte other than heapId/revision remains in the sharing key, including
resource lifetime ID, canonical identity, complete resource/SRV/RTV descriptions,
default-view metadata, floating-point bits and padding. Conservative byte equality
may miss a sharing opportunity if padding differs; it must not merge unequal
descriptions. Resource ID alone is never a sharing key. No internal payload index
is exposed; lookup reconstructs a complete value snapshot with the location's
heap and revision.

The default legacy profile allows 256 locations and 256 unique payloads. All 256
distinct view/location pairs fit exactly, retaining the old worst-case capacity.
The explicitly selected compact **offline** profile permits up to 1,024 locations
and 256 payloads, but still cannot exceed the same arena byte budget. This is a
conditional storage experiment, not a silently enlarged production table.

For example, 1,024 copies of one payload use 24,736 arena bytes. Conversely, 256
distinct payloads at 256 locations fill the entire arena: even another copy of
an existing payload must refuse. With 255 payloads at 256 locations, one further
copy can fit (46,968 bytes for 257 locations). These are constructed capacity
controls, not a reconstruction of the unknown live table.

## Mutation, snapshots and refusal

The caller supplies synchronization, supported heap/index validation, valid
resource/heap lifetimes and a globally increasing positive write revision.
The primitive performs no device access, hooks, COM retention, GPU work, queue
submission, fence operation or lifetime discovery. A caller-supplied retirement
ID is not independent proof that an object died.

`put()` snapshots its full input and sharing key before clearing an overwritten
location. It reuses a payload only after byte comparison. Overwriting/clearing a
location releases exactly one reference; shared payload contents are immutable.
At zero references the payload can be reclaimed. Dense removal moves the last
payload and repairs every referring location, preserving each location's revision.
Heap/resource retirement removes only matching lifetime IDs. Numeric addresses
are not used as substitute lifetime identities.

Lookup, exact-key matching and moved-payload repair use bounded linear scans.
The compact profile can scan more locations than the old table; CPU contention,
callback duration and game performance are unmeasured. A smaller byte footprint
is not a claim of lower overhead or compatibility with the render-thread workload.

This is not a copy-batch implementation: a future integration must retain the
existing complete source/previous-destination snapshots, alias checks, clear-all
then insert ordering, lifetime reaping, native forwarding and overlap guards.
Holding a bare internal payload index across clearing/compaction would be wrong.

Invalid mutations, non-increasing revisions and true exhaustion poison the store.
The first failure remains immutable, distinguishing location, unique-payload and
byte capacity, and recording occupancy and attempted sizes. An overwritten old
location may already have been cleared when exhaustion occurs; no rollback or
atomic-success claim is made. All subsequent metadata lookups clear their output
and refuse, and later mutations cannot recover health. Invalid read-only queries
return Invalid with zero output without poisoning an otherwise healthy store.

## Validation and remaining integration

`build_descriptor_view_store.ps1 -RunTest` freezes its five source inputs into a
fresh `.beamrt-validation/descriptor-view-store-*` directory and compiles a
CPU-only executable with MSVC `/W4 /WX /O2`. It never invokes a startup build or
loads an observer DLL. The fixture and source-contract checks exercise lossless
round trips, exact versus distinct view sharing, copy snapshot independence,
compaction/reclamation, caller-supplied lifetime-ID retirement, all three capacity
causes, immutable refusal and comparison with an uncompressed reference model.
The CI workflow runs this separate experiment without changing the game test path.

2026-10-15 verification:

- Strict optimized `/W4 /WX /O2` and checked `/W4 /WX /Od /RTC1` runs pass all
  eight CPU-only groups, each including 5,000 deterministic reference operations.
- The default 256-distinct case uses exactly 47,104 arena bytes; the compact
  1,024-identical case uses 24,736. Both paired 257th-location controls behave as
  described above. Total compiled Store size is 47,160 bytes (56 bookkeeping).
- Fifteen exact byte variants stay distinct, including mip/LOD/default/type,
  resource/identity changes, signed-zero and resource-description padding.
- Two disposable negative controls fail on incorrect full 168-byte reconstructed
  values: resource-ID-only matching and omitted moved-payload-index repair. They
  are intentionally broken CPU copies, never production/deployment candidates.
- Full isolated project suite passes **301/301**, including eleven new source
  guards. These are not 301 in-game or GPU tests.
- AddressSanitizer compilation reached linking but could not find
  `clang_rt.asan_static_runtime_thunk-x86_64.lib` (LNK1104). No runtime was installed
  or downloaded. The results are not ASan-clean proof.
- Independent read-only implementation/claim review found no concrete blocker in
  this offline scope. All 58 production native inputs remain unchanged.

Final optimized frozen build:
`.beamrt-validation/descriptor-view-store-9dd982e5512c485fb0a15f3fd363e799`.
Checked/full-suite/negative-control evidence:
`.beamrt-validation/descriptor-storage-validation-4086d76c8bd14748a8181e6ac9076b59`.
Earlier build/freezes in that work directory are retained as intermediate evidence.
GPU/backend tests are not a substitute for this CPU algorithm test, and no GPU or
in-game result follows from passing it.

Before replacing production storage, review a narrow legacy-capacity integration
and rerun the actual native-copy, lifetime, forwarding, OFF and co-linked fixtures.
This primitive is not a drop-in policy replacement: the current observer can
still reap dead associations for later diagnostic counts after failure, whereas
the experimental Store freezes all mutations after poisoning. Integration must
explicitly preserve that diagnostic retirement behavior without recovering health
or altering the immutable first failure. Unsupported/null writes must also retain
the observer's clear-and-unknown policy, not be passed to `put()` as valid views.
Any higher-location production profile needs explicit versioned configuration,
capacity diagnostics and validators/receipt compatibility; current ABI-5 checks
still enforce 256. Camera meaning, state chains, resource leases and GPU ordering
remain separate unresolved requirements. There is no new game-launch approval.
