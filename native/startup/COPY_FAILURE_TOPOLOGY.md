# Bounded first-copy-capacity topology — offline, 2026-10-15

**Subsequent live result:** one separately approved ABI-5 observation completed
with normal map appearance and host/game exit 0. Its companion identifies genuine
256-to-257 association pressure with no destination association to release;
resource metadata still refused. See [the exact-build evidence](COPY_TOPOLOGY_LIVE_OBSERVATION.md).
No unchanged repeat is planned; every further attempt needs new review/approval.

Implemented directly in the installed unpacked BeamRT folder. During the offline
implementation, the user requested no game tests while away; nothing was
scheduled to launch when that time passed. Native capture/worker/GI
activation, lighting integration, Lua/HLSL and game settings remain unchanged.

This follows the [copy-batch ordering repair](DESCRIPTOR_COPY_BATCH_REPAIR.md).
That repair avoids transient capacity refusal; this slice explains a genuinely
refused copy without guessing its topology or increasing any tracking limit.

## Narrow capture contract

`BeamRT_ResourcesCopyFailure()` returns a fixed 29,616-byte ABI-1 companion only
when the first recorded invalidation is ViewCapacity in CopyDescriptorsSimple or
CopyDescriptors, after the existing bounded flatten/source-snapshot phases.
The original 96-byte failure remains authoritative and is copied byte-for-byte.

The companion records:

- Actual observed range starts/effective counts, original range counts and
  supplied-size-array flags. Simple is normalized to one range per side, with
  flags zero because its native API takes a direct count, not size arrays.
- At most 64 flattened lanes: source/destination CPU handle values, heap lifetime
  IDs and indices, separately observed heap/visibility facts, frozen full source
  views and previous destination views taken before any destination clears.
- At most 32 retained heap slots, including retired slots, with ID/type/extent/
  stride, entry liveness sample and occupied association counts at entry,
  after all destination clears and at failure.
- Exact first-failure linkage, immutable mode, failed lane and completed metadata
  prefix. The failing lane's revision tick is included in the original failure;
  no trailing lane is processed after refusal.

"Entry" means metadata processing after its initial reap, not native API entry.
Counts are occupied tracker associations, not all game descriptors or native
live-resource totals. Later lifetime changes can lower counts; the validator
does not infer an exact cross-stage resource-liveness equation.

No caller arrays/pointers or resource COM references are retained. The per-copy
staging plan is fixed session storage under the existing metadata mutex, not a
new 29 KiB callback-stack local. Freezing copies it by value into a separate
immutable record. Storage/scans are bounded, but their contention/performance
impact has not been benchmarked in BeamNG. The one-shot publisher also copies
the large numeric receipt; this is not a claim of negligible overhead.

Before Start, the query returns NOT_READY with cleared output. Once started,
healthy or nonapplicable first failures return S_FALSE with only bytes/ABI set;
all other bytes, including mode, are zero. An applicable captured failure returns
S_OK and survives later calls, lifetime retirement and OFF. Wrong-sized/null
outputs are rejected without writing. Unsupported/over-budget copy plans retain
their original failure but do not invent a complete topology companion.

## Strict validation and transport

Validation checks byte sizes, versions, enums, bounds, reserved/unused zeros,
exact original event and mode, overflow-safe range flattening, heap locations,
view snapshots, destination uniqueness, source/destination alias rules, phase
occupied-count sums and the failed known source/destination. A required missing
or mismatched companion refuses; topology is never reconstructed from pointers.

Resource transport is explicitly **ABI 5**, rejecting prior versions 1–4:

| Record | Bytes |
| --- | ---: |
| Payload | 48 |
| Start receipt | 216 |
| Draw resource receipt, including companion | 32,480 |
| Mapped reply | 32,696 |

Only the draw envelope grows. Original status ABI-1/88, failure ABI-1/96, metadata
view ABI-1/168 and draw observation ABI-3/2,832 remain unchanged. Binding/thread
ABIs and every descriptor/CBV/camera/GPU/lighting proof flag remain unchanged.
Old frozen hosts, DLLs and decoders must not be mixed with ABI 5.

Publication looks only at the historical draw's own original first failure. If
it requires the companion, the immutable query and exact linkage validation run
before taking the resource bridge lock; otherwise canonical empty metadata is
used without querying a newer failure. The joined record is written before the
existing binding event, and the host independently validates it before saving.

This deliberately does **not** add a failure event or continuous monitor. No
matching binding draw means no companion is transported. A failure after the
first saved healthy draw is not reported by that earlier one-shot receipt. The
existing early-start-save gap also remains. These are diagnostic boundaries,
not evidence that a failure did not occur.

## Verification

Strict MSVC `/W4 /WX` builds pass; the D3D12 debug layer was unavailable.

- Full isolated Python/Lua suite: **290/290**; CI runs the new topology guards.
- Same standalone binaries on RTX 4070 and WARP: **18 sessions per backend**,
  ten legacy at 17/17 groups and eight descriptor at 21/21 groups.
- Real native copy cases cover failure at lane 0, prefix 1/failure 1, and a full
  64-lane copy with prefix 63/failure 63. Simple and explicit-size range calls
  also produce correctly normalized receipts.
- Each applicable session rejects **67 malformed companion variants**. Healthy
  mixed copies and non-copy first failures retain canonical empty companions;
  later forwarded calls/OFF cannot replace either the original or companion.
- Existing GPU 23/24/25 snapshot independence, lifetime retirement, true 257th
  refusal, legacy alias checks and ten-slot OFF restoration remain intact.
- Co-linked production bootstrap: **17 resource cases**, including present
  copy-pressure publication on hardware/WARP, plus **11 binding/thread cases**
  and **153** no-launch malformed-option/payload refusals. A separate same-build
  WARP-only resource repeat covers 12 cases. All private fixture jobs drain.

Final evidence under `.beamrt-validation/`:

- `copy-topology-4a0d20f931b14923ac31224a9d21e8c2`: source snapshots and build/test
  logs; source-reviewed is the final 58-input freeze after moving staging into
  fixed session storage. Earlier snapshots/runs are preserved as intermediate.
- `resource-tracker-5e43a3903cc34e53934e28590e1b83c7`: final standalone inputs,
  binaries and 36 hardware/WARP session logs.
- `native-startup-resource-08b3c3f0b909485fbc61c9a066df5385`: final co-linked host,
  bootstrap, linker map and disposable fixture receipts.

Host SHA256:
`472319fe1c3edee26c25999f6144f56e3e09e191bf3f61da5469103ff8186917`.
DLL SHA256:
`57d4f362b1131d5bb736183a5806dd116aba84ec711890534ae4167c050b088d`.

No old game receipt is reinterpreted as new topology evidence. The subsequently
approved candidate's live result is linked above; resource coverage, camera
meaning, states, GPU ordering and real native GI/lighting consumption remain
unproven. Exact-candidate review and separate approval are required for every
further game attempt; no general deployment approval follows from that test.
