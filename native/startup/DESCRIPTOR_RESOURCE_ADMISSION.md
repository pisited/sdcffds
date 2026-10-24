# Explicit descriptor-focused admission — offline implementation

**Current transport update:** [first-copy-capacity topology](COPY_FAILURE_TOPOLOGY.md)
now uses resource handoff ABI 5 with an appended bounded companion. The ABI-4
policy implementation and prior live receipt described below remain historical.
The [subsequent ABI-5 live observation](COPY_TOPOLOGY_LIVE_OBSERVATION.md) completed
normally but refused resource metadata at genuine 256-to-257 association pressure.

Implemented in the installed unpacked BeamRT source after the 2026-10-15 game
receipt identified ObjectCapacity / Placed as the first recorded invalidation.
That game tested the earlier all-allocation policy. No game launch, shader/Lua
edit, native GI dispatch or lighting change was made during this implementation.

**Subsequent live result:** one separately reviewed and approved descriptor-mode
startup captured the GI draw and closed normally (host/game exit 0). The first
failure was ViewCapacity / CopyRanges at 256/257 associations with only 26 admitted
resources, not the earlier resource-table failure. Metadata remained refused.
See [the exact-build live evidence and remaining boundary](DESCRIPTOR_ADMISSION_LIVE_OBSERVATION.md).

**Later offline repair:** [descriptor-copy batch ordering](DESCRIPTOR_COPY_BATCH_REPAIR.md)
now avoids transient full-table refusal for net-zero mixed copies and stops the
batch immediately after genuine invalidation. All capacities and ABIs remain
unchanged in that ordering-only slice. The subsequent ABI-5 observation includes
the repair but does not reinterpret the earlier live failure as a proven
transient-capacity case; the new receipt shows no releasable destination entries.

## Policy and unchanged bounds

`BeamRT_ResourcesStart()` retains legacy all-allocation admission. The additional
`BeamRT_ResourcesStartConfigured()` accepts a 16-byte ABI-1 config, validates its
size/version/reserved/mode, and freezes the selection before tracker publication.
It cannot change a running session or restart it.

| Behavior | Legacy mode (0) | Descriptor-texture mode (1) |
| --- | --- | --- |
| Resource creation | Admit observed allocation | Forward/count/overlap-check without admission |
| Supported SRV/RTV write | Existing behavior | Validate known destination, ownership and supported shape before admission |
| Buffer/CBV lookup | Existing observed-buffer/alias checks | Explicit refusal; cleared candidate |
| Lifetime entry reuse | After tag destruction | After tag destruction; no live-entry eviction |

Capacities remain **128 admitted resources, 32 descriptor heaps, 256 views,
64 copy entries and 16 draw tokens**. A 129th genuinely relevant live admission
still latches a fail-closed first failure. This is narrower admission, not a
larger pool or a guarantee that BeamNG's supported texture usage fits its budgets.
Native methods still forward outside metadata locks, preserve return values and
LastError, count callbacks and enforce the same overlap guard. The later observed
game overlaps remain an independent unresolved coverage issue.

## Descriptor and lifetime invariants

Descriptor-mode SRV/RTV writes clear the old destination association first, then
require a tracked live heap/valid slot, same-device resource, supported texture
and complete supported view before attaching a lifetime tag. Unknown heaps,
unsupported/null views and CBV/UAV overwrites cannot retain stale metadata or
consume an unrelated resource entry. Unknown descriptor-copy sources still clear
destinations; supported copies preserve identity/revision rules.

The existing single-slice/non-MSAA Texture2D formats and view restrictions remain.
No descriptor-memory reads or new material/format support were added. Object-owned
tags do not retain resource COM references. Resource destruction invalidates
original/copied associations; new admissions receive monotonic IDs. A still-live
admitted resource is not evicted just because its descriptor is overwritten.
Keeping the fixed index also bounds live tags; placing metadata in arbitrary
live objects without a tag bound was deliberately not implemented.

OFF restores the same ten native slots. Originals, module leases and CPU session
storage remain resident for late callbacks. No hot unload, resource lease, state
history or GPU-completion proof is supplied.

## CBV and transport boundary

Descriptor mode skips buffer allocation indexing. Searching a partial index could
hide an equal-VA alias and falsely imply uniqueness, so valid direct buffer
queries return `ERROR_NOT_SUPPORTED` with a cleared result. Argument guards remain.
A direct draw query can accept texture metadata while its explicit CBV result
refuses; it cannot manufacture buffer evidence.

Startup selection is explicit: `--resource-descriptors-only` requires
`--observe-gi-resources` and rejects a nonzero CBV probe. Payload validation rejects
the same combination. Defaults remain unchanged.

Resource transport is now **ABI 4**, rejecting earlier versions: payload 48 bytes
(final field is mode), start envelope 216, record envelope 2864, reply 3080. Both
envelopes echo the immutable mode plus zero reserved field; the host checks its
requested mode. Old frozen hosts/DLLs and decoders must not be mixed with ABI 4.
The contained draw observation remains ABI 3 / 2832 bytes, resource status ABI 1 /
88, first failure ABI 1 / 96. Binding/thread ABIs and all proof flags are unchanged.

## Original offline verification

Strict MSVC `/W4 /WX` builds passed. The D3D12 debug layer was unavailable.

- Full Python/Lua suite: **278/278**; CI includes the new admission guards.
- Standalone RTX 4070 and WARP: five legacy sessions **17/17** each, plus three
  descriptor sessions **21/21** each (normal, relevant-resource pressure, overlap).
- Descriptor sessions retain **145 buffers plus 145 supported-format textures**
  without views and require zero admissions, then resolve exactly six SRVs and
  one RTV. Unknown-heap and unsupported writes remain unadmitted.
- Copy/lifetime retirement and monotonic readmission, no live eviction, cleared
  CBV refusals and existing equal-VA legacy checks pass. Relevant admission 129
  fails precisely with ObjectCapacity / CreateSRV. First failure survives OFF.
- Native GPU output remains 23 before/after OFF, with all ten slots restored.
- Production co-linked bootstrap: **15 resource cases**, including descriptor
  normal/pressure on RTX and WARP; **11 binding/thread cases**; **143** malformed
  host option/payload/receipt cases rejected.
- Co-linked descriptor cases retain **258 unrelated allocations**, then require
  seven admissions and actual six-SRV/output identities, mode echoed end-to-end,
  CBV probe 0 and cleared CBV metadata. Legacy exact-nine pressure is preserved.
- Separate CI-style WARP-only startup resource matrix: **11/11**. All private jobs
  drained; these tests selected only disposable fixture executables, never BeamNG.

## Frozen evidence and next gate

Under `.beamrt-validation/`:

- `resource-tracker-7d448bbfae664bd186174357a032e463`: standalone inputs/artifacts
  and eight separate session logs for each backend.
- `native-startup-resource-7c26d9525b44479aae2947ce497c39b1`: production co-linked
  candidate, frozen native sources, linker map and startup receipts.
- `descriptor-admission-d833fbe7f6394d8896398b8713cd13dd`: pre/post-build hashes,
  build log, full suite, WARP repeat and final verification.

Bootstrap SHA256: `9d2ccbd5cae108b52c5cbdd4799ada2f108149c86b6095b68395c0fb6b1057fa`.
Host SHA256: `c961dc7b2603d5159bf20f2165f692e3c80ce4b47d6bc49050b6d73b36aff906`.
All 53 native inputs matched their pre-build freeze; private Context/Slot isolation
remains intact. The previous live-tested ABI-3 bundle is preserved unchanged and
does not validate this mode or candidate.

Any new game probe requires exact-candidate review and separate human approval.
Keep CBV probe 0 and every capacity/lifetime/overlap guard. Resource, heap, view,
format and overlap refusals can still occur. Game coverage, camera semantics,
states, synchronization and native GI consumption remain unverified; the general
deployment hold is unchanged.
