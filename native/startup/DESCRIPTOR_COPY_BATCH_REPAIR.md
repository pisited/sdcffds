# Descriptor-copy batch ordering repair — offline

**Subsequent source update:** [bounded copy-failure topology](COPY_FAILURE_TOPOLOGY.md)
adds a separately validated companion and resource transport ABI 5. This document
preserves the original ordering-only repair and its ABI-4 build evidence; its
"unchanged ABI" statements describe that earlier slice, not the later transport.

The [subsequent ABI-5 live observation](COPY_TOPOLOGY_LIVE_OBSERVATION.md) includes
this repair and closed normally, but still refused on a genuine new association
at full capacity. Its batch had no tracked destination association to release.
The old ABI-4 batch remains unexplained by that newer topology evidence.

Implemented in the installed unpacked BeamRT folder on 2026-10-15. No BeamNG
launch, shader/Lua change, native GI dispatch or lighting integration was made.
This repairs two demonstrated observer defects; it does not establish why the
earlier game copy exceeded the table or whether the game's final population fits.

## Reproduced defects and repair

At 256 occupied associations, a two-lane copy can insert a known view into a new
destination and clear an existing destination with an initialized null SRV.
Its final population is still 256. The old observer inserted before performing
the later clear, falsely latching ViewCapacity on the transient 257th entry.
Reversing that lane order avoided the defect.

`copied()` now validates the bounded ranges and alias rules, snapshots all source
values, clears every destination, and only then inserts the frozen values. The
existing metadata mutex covers every phase. Copies remain independent values,
not references to source slots or deduplicated resource identities. Independent
view descriptions, heap lifetime IDs and per-write revisions remain intact.

The old loop also continued processing after a real capacity failure. The red
three-lane fixture recorded pressure 3 and revision 302, despite the first failure
being revision 300. Health checks now stop processing immediately after a poisoned
source lookup, destination clear or insertion. The same overflow fixture records
pressure 1 and revision 300, equal to the immutable first-failure revision.

This is not rollback or an atomic-success guarantee. A genuinely over-capacity
batch can leave partial internal metadata; health remains false and public
descriptor/draw evidence refuses it. Native calls already forwarded, outside the
metadata lock, before observation. No GPU work is performed by the tracker.

Capacities remain 32 heaps, 128 live resource entries, 256 location associations,
64 flattened copy lanes and 16 draw tokens. No live entry eviction, compression,
resource-only deduplication, ownership relaxation or resource retention was added.
Resource metadata/status/failure ABIs, draw ABI 3 and handoff ABI 4 are unchanged.
Both legacy and descriptor-focused admission use the same repaired copy helper.

The native fixtures use initialized same-type descriptors, non-shader-visible
copy sources and non-conflicting writes, following Microsoft's
[descriptor-copy requirements](https://learn.microsoft.com/en-us/windows/win32/direct3d12/copying-descriptors).
Questionable native arguments are not forwarded just to exercise observer guards.

## Verification and evidence

The old implementation independently failed the net-zero capacity and trailing
revision regressions on WARP before the repair. Strict MSVC `/W4 /WX` builds pass.

- Full project suite: **281/281**.
- The same standalone binaries pass ten sessions each on RTX 4070 and WARP:
  six legacy cases at 17/17 groups and four descriptor cases at 21/21 groups.
- Both modes test full-table mixed copies in both lane orders, preserve known
  provenance, clear unknown destinations, and retire the temporary heap back to
  the original fifteen-view baseline.
- Genuine copy-originated 257th association refusal remains ViewCapacity /
  CopyRanges, immutable through later overlap and OFF, with no trailing revisions.
- Completed GPU submissions verify pixel 23 survives source-slot overwriting;
  recopying the replacement changes it to 24; independently overwriting the
  destination changes it to 25 without modifying its source. Restoring views
  restores 23. Different LOD-clamp descriptions of one resource are checked as
  metadata only, then the original view is restored before GPU verification.
- Production co-linked bootstrap tests pass 15 resource and 11 binding/thread
  cases. The existing descriptor normal cases on hardware and WARP also exercise
  both mixed-copy orders at full capacity, retire back to exactly seven GI
  resources/views, and retain the GPU-23 / OFF-ten-slots checks.
- Host self-test rejects 143 malformed option/payload cases. Private fixture jobs
  drain normally. The debug layer was unavailable; no debug-layer-clean claim.
- The same co-linked candidate also passes the separate CI-style WARP-only
  eleven-resource-case matrix. All 55 frozen native inputs still match the
  installed sources after testing, including the unchanged startup build script.

Evidence under `.beamrt-validation/`:

- `descriptor-copy-order-0e18fbc99d4446aaadc6e85c4400acb8`: before/after source
  hashes, exact red failure logs, final full-suite and co-linked build logs.
- `resource-tracker-5743461d1de04251bd3065b5fd1af859`: final standalone sources,
  binaries and twenty hardware/WARP session logs.
- `native-startup-resource-e8bb18dfc500433693a3dcbabb8e47c9`: new co-linked candidate,
  linker map and disposable startup receipts.

Candidate DLL SHA256:
`d9d8e9d7eb6a4f2d31d8509f7fb961f11c66889cab4034c23365103a3a81ea1e`.
Host SHA256:
`362aaf1de3a6ce621cd994ea78a0235d564fb66c6cb656566eda15d158590bca`.
Previously approved/frozen game bundles remain unchanged.

## Remaining game boundary

The earlier [descriptor-only live refusal](DESCRIPTOR_ADMISSION_LIVE_OBSERVATION.md)
did not capture range shapes or final batch occupancy. Do not retroactively call
it a transient-capacity failure. A future separately reviewed and approved probe
can test this candidate; a genuine remaining refusal may still require bounded
copy-topology telemetry before choosing observation scope or lossless compression.
There is no automatic game retry or hot reload. Resource access, camera meaning,
states, GPU ordering and native GI/lighting consumption remain unproven.
