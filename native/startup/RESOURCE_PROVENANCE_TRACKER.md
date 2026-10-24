# Offline descriptor/resource provenance tracker

**Latest offline integration:** [explicit heap-interned profile2](DESCRIPTOR_INTERNED_PROFILE.md)
adds honest14-byte location accounting and resource transport ABI7. It is opt-in,
not game-tested or a GI integration. The older ABI references below are
chronological verification snapshots; legacy remains the default.

**Current internal-storage update:** [lossless Store integration](DESCRIPTOR_STORE_INTEGRATION.md)
replaces full per-location copies while retaining the legacy 256-location contract,
ABI 5, lifetime/failure guards and default-off startup. It has passed the native
fixtures but is not game-tested and does not resolve the live 257th-location limit.

**Current source:** [bounded copy-failure topology](COPY_FAILURE_TOPOLOGY.md)
adds a separately validated companion and resource transport ABI 5. Earlier
standalone/ABI-3/ABI-4 results below retain their original scope. A subsequent
[separately approved ABI-5 observation](COPY_TOPOLOGY_LIVE_OBSERVATION.md) completed
normally but refused resource metadata at genuine 256-to-257 association pressure.
No native GI activation accompanies that diagnostic result.

Current source also provides an explicit opt-in
[descriptor-focused admission mode](DESCRIPTOR_RESOURCE_ADMISSION.md), verified
offline on RTX/WARP and in the co-linked startup fixture. A separately approved
[descriptor-mode game test](DESCRIPTOR_ADMISSION_LIVE_OBSERVATION.md) completed
normally but refused resource metadata at ViewCapacity / CopyRanges. The later
[offline copy-batch ordering repair](DESCRIPTOR_COPY_BATCH_REPAIR.md) preserves
Legacy Start, all capacities/guards and the ordering-only slice's ABIs. The later
ABI-5 observation contains the repair; it does not reinterpret the old ABI-4 batch.

Subsequent default-off [startup connection](STARTUP_RESOURCE_OBSERVATION.md) is
now implemented and verified in disposable fixtures. Its original ABI-3 receipt,
output-binding checkpoint, native draw span and remaining game-review boundary
are documented there. The paragraphs below preserve the original standalone
slice's scope and results; they do not describe the later startup connection.

Implemented in the installed unpacked BeamRT folder, but **not wired into the
production startup bootstrap, launcher, binding observer or live game**. This is
a separately built candidate DLL and disposable GPU fixture. No existing frozen
startup DLL/host, Lua/HLSL renderer, lighting setting or GI adapter was changed.

## Implemented observations

Ten public SDK vtable data slots observe descriptor-heap creation, SRV/RTV writes,
CBV/UAV overwrites, both descriptor-copy APIs, and the original committed/placed/
reserved resource-creation methods. Native calls always forward; return values
and native LastError are preserved. Slot offsets come from SDK C interfaces, not
engine offsets. OFF restores still-owned slots; originals, module leases and CPU
session storage remain resident for late cached callbacks. No restart/hot unload.

The tracker stores numeric IDs, canonical identity values, resource descriptions,
explicit/default view descriptions and write/copy revisions. It never reads
descriptor-heap bytes, maps a resource, submits GPU work, or returns a callable
resource pointer. It uses object-owned private-interface lifetime tags instead
of retaining heap/resource COM references. Tag destruction invalidates the token;
descriptor queries then discard both original and copied associations. New objects
get monotonic IDs, even if an address is reused.

Bounded storage: 32 live tracked heaps, 128 resources, 256 views, 64 entries per copy.
Overflow, capacity exhaustion, unsupported tag collisions and observed callback
overlap refuse metadata rather than bypassing limits. Original calls still forward.
This deliberately conservative global callback guard is not a multithreaded game-
coverage or performance claim. The existing GI recording-thread policy is untouched.

Supported view provenance is intentionally narrow: single-slice, non-MSAA Texture2D
resources with R32G32B32A32_FLOAT, R32_FLOAT or R8G8B8A8_UNORM formats, matching explicit
view formats, or supported default views. Unsupported/null SRVs and CBV/UAV rewrites
erase old SRV associations. Typeless, array, multisampled, buffer-SRV and other view
forms remain unknown. Samplers/DSVs and modern resource-creation variants are not
covered; no whole-device allocation coverage is claimed.

Copy provenance follows observed creation/copy operations, not descriptor memory.
Source descriptors must be in a known non-shader-visible heap; unknown sources
clear destinations. Sparse range flattening, omitted sizes, descriptor types,
alignment, extents, arithmetic overflow, duplicate destinations and overlaps have
explicit guards. Invalid original API calls are not sent to the driver to test
synthetic malformed arguments.

## Buffer address candidates, not camera contents

The root-CBV lookup only identifies a unique **candidate among observed live
buffers**, with an explicitly requested span, aligned address, offset and remaining
extent. Known equal-VA aliases refuse. Unobserved/newer allocation paths and aliases
can still exist, so candidateOnly always remains 1. This is not a validated CBV
binding, descriptor, readable camera block, resource state or GPU lease. A caller-
supplied span is not automatically the shader's true required size.

The standalone fixture reads the existing binding observer's actual recorded
descriptor addresses, resolves all six input identities and the output identity,
and queries the buffer candidate at the recorded CBV address. It owns the actual
resources, keeps them alive, and supplies their expected identities and 16-byte
fixture constant span explicitly. It does not reconstruct those facts from BeamNG.

These descriptor lookups occur separately after recording; they are not an atomic
draw-time provenance receipt. Descriptors may have changed since an old binding
snapshot. No automatic production join or conversion to BeamRTGIInputs was added.
All existing descriptor/CBV/camera/GPU-order/lighting proof flags remain zero.

## Verification

Strict MSVC /W4 /WX builds passed. RTX 4070 and WARP each pass all **13 named groups**
in three separate heap/resource/view-pressure sessions. Actual GPU readback remains
23 both while observing and after OFF. Both backends exercise known equal-VA
placed-buffer alias refusal.

Groups cover cold/start/owner controls; unknown pre-existing buffers; CBV offset,
alignment and extent; placed buffers/aliases; explicit/default SRVs; CPU-to-visible
copies; RTV copies; recording-to-resource fixture queries; null/CBV/UAV rewrites;
sparse ranges; descriptor bounds/type; real resource/heap/buffer lifetime retirement;
fixed-capacity refusal; restored slots and late cached forwarding after OFF.

Full project discovery passes **238/238**, including six new isolation/source
guards. Those guards complement executable fixtures; they are not GPU proof.
The D3D12 debug layer was unavailable. No debug-layer-clean, actual game-resource,
frame-coherence, GPU-ordering, in-game lighting or performance result is claimed.

```powershell
./native/startup/build_resource_tracker.ps1 -RunTest
./native/startup/build_resource_tracker.ps1 -RunTest -Warp
```

Each build copies inputs into a fresh ignored validation folder, retaining a
SHA256 artifact inventory and separate pressure-session logs. The build uses
already installed tools, validates SDK candidates instead of trusting a stale
registry entry, and does not run the startup/capture/worker builds or download
dependencies. CI runs the isolated WARP matrix and source guards.

Verified frozen local run:
`.beamrt-validation/resource-tracker-3ba2ec19fe7b4b7da3ced57a00123fad/`.
Its six hardware/WARP pressure-session logs are retained.

## Next gate

Before any separately approved game observation, integrate a bounded, explicitly
opted-in transport into the existing startup session, with a draw-time resource
receipt and full-callback/lifetime synchronization review. Evaluate real allocation
and view coverage/capacity instead of assuming this small fixture fits BeamNG.
A startup observer that exhausts its budgets before the GI draw is not useful proof.

After a real resource receipt, establish camera constants and resource states,
then queue/consumer fence ordering before native visibility can affect GI.
The historical DLL-loading anomaly and source-reset writer remain unresolved;
this offline result does not lift the deployment hold or authorize a game launch.

Primary contracts:
[CPU descriptor copies and source-heap restrictions](https://learn.microsoft.com/en-us/windows/win32/direct3d12/copying-descriptors),
[private-interface lifetime](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12object-setprivatedatainterface),
[buffer GPU virtual addresses](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12resource-getgpuvirtualaddress).
