# Fail-closed offline handoff validator

Implemented 2026-10-12 in `handoff_validation.h`, used only by the isolated GPU
fixture. It does not load BeamNG, convert arbitrary capture snapshots, decode
camera buffers or change `beamrt_gi.cpp` and its existing retirement rules.

## Accepted context

The controlled producer has an exact two-SRV plus root-CBV shader contract:
receiver origins at t0, the packed mesh at t1 and fixture controls at b0. The fixture allocates a full-resolution
diagnostic RTV, records six full legacy transitions before its draw and leaves
states unchanged afterward. It owns one serialized DIRECT queue on one thread.

`HandoffEvidence` explicitly supplies device/resource roles, starting states,
the current generation keys, scene/material data, surfels and the known queue
schedule. Initial shader-read states come from the fixture's completed upload,
not from guessing what a texture descriptor means. The snapshot supplies actual
SRVs/views, output/viewport/scissor, recorded pre-draw transitions and observed
queue events. CPU bookkeeping is compared against independent fixture values;
it is never substituted for a generation key or GPU completion value.

The input gate checks:

- Actual canonical device/resource/queue/fence ownership, correct resource roles,
  full one-mip non-array/non-MSAA default-heap textures and exact SRV mappings.
- Supported, complete producer context, expected submission/recording/queue
  observations and full viewport/scissor coverage of the expected RTV.
- Known starting states and uninterrupted, all-subresource transition cycles for
  receiver, mesh and output. COMMON promotion, partial/split/enhanced/alias/UAV
  barriers and other programs are unsupported. Input write states are rejected.
- Explicit dimensions, scene/material layout, finite surfels and matching
  positive integer generation keys. Extra root constants/UAVs and unresolved
  address-only CBVs are rejected.
- A same-device producer fence that actually reached its expected value. A
  recorded Signal alone is not sufficient; unexpected queue waits are rejected.

Any failure returns a reason and clears the GI input output structure. The
fixture creates a GI frame only after this gate succeeds and while the capture
snapshot still retains the borrowed resources. The adapter then takes its own
references before the snapshot is released.

## Reflected shader layout and owned CBV resolution

`shader_contract.h` builds immutable contracts from the two owned SM5.0 pixel
fixture shaders and their serialized root signatures. Reflection checks exact
resource names, types, counts and registers, plus constant field names, scalar/
vector types and extents. Root deserialization checks parameter roles, b0,
register spaces, SRV ranges, table offsets and visibility. The inspected byte
copies are also used to create the actual PSOs/root signatures and the producer
capture filter. This establishes the owned fixture's binding layout, not camera
semantics or correctness of arbitrary shaders with similar reflected names.

The producer binds its 16-byte float4 control at **offset 256 in a 512-byte
UPLOAD buffer**. The earlier bytes contain a different sentinel. An explicit
fixture-owned registry retains the resource and an exact copy of its uploaded
bytes, generation keys and a no-overwrite lifetime assertion. Resolution checks
canonical device ownership, actual GPU virtual base and allocation width,
256-byte alignment, a full padded CBV span inside the allocation and a complete,
current upload mirror. Address subtraction avoids wrapping a base-plus-size
comparison. Missing, duplicate, foreign or inaccessible ownership is rejected;
default/GPU-only heaps do not become readable because a CPU mirror was supplied.
Failed resolution clears both retained ownership and copied contents.

Consumer constants are rebuilt by reflected field offsets rather than copying
the C++ `TestConstants` structure wholesale. Its existing real visibility
predicate and OFF/ON/OFF tests remain unchanged. After capture has detached and
the final GI consumer has retired, a separate diagnostic GPU readback checks
that all four producer control values reached the actual output. This readback
is test-only; neither capture nor the resolver reads GPU contents or dereferences
a captured virtual address.

The registry/mirror and immutability assertions are still supplied by the trusted
host. Capture v3 itself records only the root CBV address, not a buffer reference,
its bytes or a camera matrix. No live BeamNG upload tracking, reflection manifest
or semantic decoder has been added. GPU-only/default buffers and unknown layouts
continue to fail closed.

## Consumer completion gate

`ConsumerReceipt` binds the same queue/fence, submission/recording identity and
generation keys to the fixture's actual compute and final-consumer steps. It
requires a final consumer receipt, a later completion value than compute, and
`GetCompletedValue()` reaching that value without the device-removal sentinel.

The positive path records compute and its consumer on the same ordered queue.
The negative path attempts retirement at compute completion; both the validator
and the unchanged GI adapter reject it. Only after the later consumer fence does
validation and adapter destruction succeed. Missing/stale receipts, unrelated
fences and compute-only completion values are rejected.

## Scope and verification

The evidence and receipts are **trusted assertions from the owned offline host**,
not discoveries of game state. A caller lying about queue serialization, starting
states or later consumers cannot be made safe by a plain metadata validator.
Native pointers must be valid live interfaces. This is not a security boundary
for fabricated pointers or a global state tracker for arbitrary command streams.

Capture verification flags remain false. No camera meaning, complete BeamNG
state chain, live frame freshness or game lighting consumption is certified.
The producer RTV is diagnostic, not an automatically recognized game export.
Production integration still needs a verified host contract and loading review.

Local validation covers 68 rejected input cases and 14 rejected shader/root/field
contracts, consumer-fence/receipt guards,
the accepted GPU path and a legal split-barrier pair that capture marks
incomplete. Strict MSVC/FXC builds and RTX 4070/WARP fixtures passed. The full
Python/Lua suite passes 143/143. The debug layer was unavailable; this is not
debug-layer-clean or live-game proof. Remote CI has not been run by this change.

```powershell
./tools/test.ps1
./native/gi/build.ps1 -Python ./.beamrt-validation/python-tests/Scripts/python.exe -RunTest
./native/gi/build.ps1 -Python ./.beamrt-validation/python-tests/Scripts/python.exe -SyntheticFixture -RunTest -Warp
```

Reference contracts: [legacy transitions and split barriers](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12),
[fence completion and removal sentinel](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12fence-getcompletedvalue),
[root descriptors are GPU addresses](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-descriptors-directly-in-the-root-signature),
[constant-buffer reflection](https://learn.microsoft.com/en-us/windows/win32/api/d3d11shader/nf-d3d11shader-id3d11shaderreflection-getconstantbufferbyname),
[256-byte constant-buffer placement alignment](https://learn.microsoft.com/en-us/windows/win32/direct3d12/constants).
