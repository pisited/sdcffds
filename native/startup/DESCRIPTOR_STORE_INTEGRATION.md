# Legacy-capacity descriptor store integration — 2026-10-15

Historical verification snapshot. The subsequent [explicit compact profile](DESCRIPTOR_COMPACT_PROFILE.md)
versions its configuration and receipts; the legacy defaults/results below remain unchanged.

The [lossless storage prototype](DESCRIPTOR_VIEW_STORAGE.md) is now used inside
`resource_tracker.cpp`, explicitly with **legacyLimits: 256 locations / 256
payloads**. This is a source/build change to the installed unpacked BeamRT folder,
not an in-game deployment. No BeamNG launch, shader/Lua/settings change, native
GI dispatch or lighting integration occurred.

**This does not solve the live 257th-location refusal yet.** All public capacities
remain 32 heaps / 128 resources / 256 views / 64 copy lanes / 16 draw tokens.
The compact 1,024-location profile remains CPU-fixture-only. Resource transport
ABI 5, view/status/failure ABIs and all proof flags are unchanged. A new production
profile needs explicit versioning and validator/receipt treatment before a game
review; simply selecting compactLimits here would violate the existing contracts.

## Preserved behavior and integration repair

The old per-location full-view array is replaced by the 47,104-byte shared arena
plus 56 bytes of Store bookkeeping. Payloads share only exact view bytes other
than destination heap/revision. Full descriptions, resource lifetime identities,
per-location revisions and independent copied values remain intact. There is no
resource-ID-only merge, hidden unbounded allocation or live-entry eviction.

The observer still performs owner/device/heap/shape validation and holds its
existing metadata mutex. Lookups reconstruct full values, not internal payload
indices. A missing entry stays unknown; an unexpected internal Store refusal
poisons the observer as MetadataException rather than silently becoming missing.
Only the expected legacy location-capacity failure maps to ViewCapacity/256→257.

Copy handling retains full source and previous-destination snapshots before
mutation, alias/extent checks, clear-all-before-insert order, a fresh revision per
lane and immediate stop after failure. Companion counts read aggregate occupied
locations, without reaping or reconstructing state while freezing the event.

Two integration-specific lifetime rules are explicit:

1. Before reusing a dead Object registry slot, retire its previous lifetime ID
   **before** replacing the slot or attempting the new tag. The old flat reaper
   could discover orphaned IDs by scanning values; the registry-driven reaper
   cannot discover an ID already overwritten. This prevents a hazard introduced
   by the representation change, not a claim that the earlier flat store had it.
2. Diagnostic `reapDeadHeap` / `reapDeadResource` can remove caller-observed dead
   IDs even after Store poison. They never admit a view, reset revisions, restore
   health or modify the frozen first failure. Strict put/get/clear/retire APIs
   continue to refuse while poisoned. Zero diagnostic IDs are rejected without
   modifying storage or failure. Aggregate occupancy remains available.

Unsupported/null/CBV/UAV writes still clear tracked provenance without being
passed as valid views to Store::put. Original native methods and LastError still
forward; OFF restores ten owned slots and retains process-lifetime originals.
No resource/heap COM leases, camera interpretation, state chain or GPU-completion
proof is added. Bounded scans and callback contention remain unbenchmarked.

## Verification

- Full isolated Python/Lua suite: **306/306**, including updated type-identity
  guards and legacy-integration contracts. The initial obsolete View-declaration
  assertion was updated to check the actual uniquely namespaced shared types;
  Context/Slot/Life and exported-header scope protections remain intact.
- CPU Store fixture: **nine groups**, including 5,000 independent-reference
  operations, on strict optimized and checked `/Od /RTC1` builds.
- Same standalone native binaries: **18 RTX 4070 + 18 WARP sessions**, all pass.
  Group totals vary by mode/pressure case (18/19/22/23). Every run exercises real
  resource admission before any intervening status/lookup reap after old-ID death.
- View/copy pressure runs release the capacity heap after failure (256→15 views),
  then a retained unused resource (15→14), then its heap. Status counts update,
  while health stays false and the complete original failure/companion stay equal.
- Existing real GPU 23/24/25 copy independence, mixed full-table copy ordering,
  67 malformed companion refusals where applicable, native forwarding and final
  GPU23/OFF10 checks remain intact.
- Co-linked production bootstrap fixtures: **11 binding/thread cases**, **17
  resource cases** including hardware/WARP and **153** no-launch malformed-case
  refusals. All private jobs drain. No real game target is selected.
- Two disposable WARP negative controls compile and exit 1 at the intended new
  runtime assertions: omit old-ID retirement before slot reuse; suppress dead-ID
  cleanup after poison. These deliberately broken DLL copies are never deployment
  candidates and remain only in the isolated validation directory.

The D3D12 debug layer was unavailable; no debug-layer-clean claim is made.
AddressSanitizer was unavailable in the preceding prototype toolchain check and
was not retried or installed here. Checked `/RTC1` is not an ASan substitute.

## Frozen evidence and next boundary

- Work, checked/negative tests and full suite:
  `.beamrt-validation/descriptor-store-integration-1503090215a7459c8e5c477a73b1d7b5`.
- Standalone source/binaries and 36 session logs:
  `.beamrt-validation/resource-tracker-b0a9cb7c889441d297bd7ec9951beed4`.
- New co-linked candidate:
  `.beamrt-validation/native-startup-resource-fc9dfb5fa6c340d8a8adb53d64762845`.

Host SHA256: `1af225c6e7d44598ee18dbb9d0035c0928c6f14afbbf1a0f31467c24c6f9d033`.
DLL SHA256: `0165dba5d4c4401f9b96c15b1824b3604aaaf197a0480d3179375a2778590a71`.
All 59 native build inputs, including the new storage header, matched after the
build/test sequence. The startup build script remains unchanged at
`9c5c3bdc817169839d02078172c0f3fb3fbc055ff761e9989bc0f7d0ee0786a0`.
Earlier frozen live/prototype bundles are retained and are not reinterpreted.

Next is an explicitly versioned compact storage profile with honest capacity
diagnostics and fail-closed validation—not another unchanged game probe. Its
compression benefit in the real live table is still unknown. Real game resources,
camera meaning, states, execution ordering and a GI consumer remain separate
unproven boundaries. This candidate is not game-approved; every further game
attempt needs its own frozen review and specific authorization.
