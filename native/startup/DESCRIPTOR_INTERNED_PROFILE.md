# Explicit heap-interned descriptor profile — 2026-10-17

The installed unpacked BeamRT source now integrates the
[14-byte location prototype](DESCRIPTOR_LOCATION_STORAGE.md) into an explicitly
selected observer profile. **This is offline-tested metadata storage, not a
lighting change or game-tested DLL.** Legacy remains the default; no BeamNG
launch, shader/Lua/settings change, ReShade dependency or native GI activation
occurred in this step. The last live-tested ABI6 bundle remains frozen.

## The problem this targets

The [last compact game observation](COMPACT_STORAGE_LIVE_OBSERVATION.md) stopped
at 1,024 locations / 47 distinct payloads / 32,096 bytes. It refused location
1,025 while considerable byte capacity remained. That is a real location-table
bottleneck, not evidence that GI inputs are otherwise usable.

Profile2 replaces repeated full heap IDs in location records with bounded slots
in a full64-bit heap-ID directory. Exact descriptor bytes, per-location full64-bit
revisions and copied-value independence remain intact. It does not filter for
assumed GI relevance, approximate descriptors, evict live entries or repair
unknown sources by guessing. The wrapper holds exactly one active arena.

| Profile | Selection | Logical locations | Exact occupied-byte accounting |
| --- | --- | ---: | --- |
| Legacy0 | Default / existing APIs | 256 | `24*L + 160*P` |
| Compact1 | Explicit config ABI2 | 1,024 | `24*L + 160*P` |
| Interned2 | Separate config ABI3 / API | 4,096 | `512 + 14*L + 160*P` |

All three retain the 47,104-byte arena and 256-payload cap. Interned2 includes
its fixed 512-byte directory in that arena, including when empty. H is the number
of occupied directory entries, bounded by32; it is not a count of live native
heaps. Logical4,096 is a work/count ceiling, **not a population that fits**:
even one shared payload fits at most3,316 locations. With seven payloads the
exact boundary is3,248 locations. The next shared insertion requires47,118 bytes
and is refused. Performance and callback-contention impact remain unmeasured.

## Explicit versioning and refusal rules

- `BeamRT_ResourcesStartProfiled` still accepts only config ABI2/profiles0–1.
  `BeamRT_ResourcesStartInterned` requires ABI3/profile2, descriptor-texture mode,
  zero reserved fields and no CBV inference. Existing default entry points do
  not select the new backend.
- Host selection is separately opt-in: `--resource-interned-storage` requires
  descriptor-only resource observation without CBV probing. Compact+interned,
  duplicates and invalid combinations are refused.
- New physical storage snapshot ABI2 is64 bytes; immutable storage failure ABI2
  is104 bytes. Explicit fields report directory bytes, location width, occupied
  H, heap limit and attempted H. Old reserved fields stay zero.
- The new binary uses resource transport ABI7 (payload56/start392/record32768/
  reply33160 bytes), draw ABI5, copy ABI3 and fixture report ABI3. Status/failure
  numeric layouts remain88/96 bytes with semantic ABI1/2/3 by profile. Do not mix
  these binaries or decoders with the frozen ABI6 candidate.
- Capacity priority is location → occupied heap → payload → byte. Attempted
  bytes charge the new location and any new payload, never the fixed directory
  twice. Original failure is immutable. Poisoned callbacks cannot insert;
  observed dead-ID reaping may only shrink current L/P/H/bytes, not revive health.
- Same-lock copy evidence joins original H to the number of heap summaries with
  nonzero failure occupancy. Attempted H additionally accounts for whether the
  failed destination heap was empty. Neither `aliveAtEntry` nor native live-heap
  counts are substituted for association occupancy.

Lifetime identity, old-ID retirement, thread/overlap guards, exact descriptions,
unknown-copy behavior and restoration of the ten observer slots remain required.
No camera, state-chain, resource lease, GPU-ordering or GI-consumption proof flags
are enabled by increased storage capacity.

## Offline verification

Strict `/W4 /WX /std:c++17` builds and the following checks passed:

- **25 standalone sessions on RTX4070 and25 on WARP**, using identical final
  binaries:18 unchanged legacy cases, four compact cases and three interned
  cases per backend. Interned healthy draw: L2013/P7/H3,29,814 bytes. Payload
  refusal: L256/P256/H2,45,056 bytes, attempted257 payloads/45,230 bytes. Byte
  refusal: L3248/P7/H2,47,104 bytes, attempted47,118. Dead-heap diagnostic reaping,
  first-cause immutability, OFF10, cached native forwarding and pixel23 passed.
- **195 no-launch refusal controls,11 startup-connected binding cases and31
  startup-connected resource cases.** The latter include interned healthy,
  payload and CopyRanges byte pressure on both hardware and WARP. Healthy
  cross-process receipt: L2000/P7/H3,29,632 bytes; after retirement/OFF:
  L7/P7/H2,1,730 bytes. Default-off and legacy/compact behavior remain covered.
- The large native fanout uses a **non-shader-visible CPU descriptor heap**.
  Six real GPU input descriptors and the actual output/draw/pixel are checked,
  but this is not a replay of the975 shader-visible locations in the live game.
- **12 CPU view-store groups** pass optimized and checked `/Od /RTC1` builds.
  Public interned accounting covers canonical empties, original/current joins,
  capacity priority, directory-preserving reaping and malformed receipts. Four
  malformed H samples retain valid standalone byte math but fail copy topology.
  Empty/occupied destinations and liveness-independent occupancy are exercised.
- Two isolated guard-removal builds each fail at their intended assertion:
  removing original occupied-H validation; removing attempted-H validation.
  Neither broken copy is an observer/deployment candidate.
- The separate location primitive still passes its11 CPU groups, including5,000
  independent full-value map operations. Directory33 and logical-limit cases are
  CPU/synthetic evidence: the observer's outer heap guard and byte budget may
  stop first, so no native coverage of those unreachable cases is claimed.
- **`tools/test.ps1`:327/327**, with pinned Lupa2.8/Lua5.1/LuaJIT. CI now opts
  into both compact and interned standalone WARP cases; CI itself was not run
  here. The D3D12 debug layer was unavailable; this is not debug-layer-clean,
  ASan-clean, performance or live-game proof.

The final63 native source inputs match both the frozen source manifest and the
installed mod. The preceding live observation's307 retained evidence hashes and
the CPU prototype's47 retained evidence hashes remain unchanged. Existing
unrelated staged/unstaged work was preserved; no files were staged or committed.

## Evidence and next boundary

- Integration work/source63/logs:
  `.beamrt-validation/interned-storage-integration-2357ff90f488487690aa2ca33f6758f2`.
- Final standalone binaries/source30:
  `.beamrt-validation/resource-tracker-9c93ca64d6bd47388c69a80167d7b906`.
- Final startup-connected candidate:
  `.beamrt-validation/native-startup-resource-e96d984928844cce8d4f8e2882c5be70`.
  Host SHA256:`dc5389dd8f294d708f0d61228f12601a2f0eb39f4ae69ef1eb7a5dcabaaa2cff`;
  DLL SHA256:`e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38`.

Next is a fresh frozen review and a separately approved, bounded **observation-only
game run**, not native GI activation. Its useful question is whether the actual
descriptor population now survives the old1,025th-location failure and reaches
the existing strict resource observation boundary. A new refusal must be retained
honestly; more storage does not certify descriptors, ownership, states, camera
meaning, submission order or lighting consumption.
