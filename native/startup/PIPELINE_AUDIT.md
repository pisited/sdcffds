# Creation-only GI pipeline identification

Implemented 2026-10-12 directly in the PC's unpacked BeamRT folder. This closes
part of the pass-identity gap, **not** the live draw/resource handoff. The new
standalone audit DLL remains available. The production startup bootstrap now
contains a separately opted-in [startup handoff](STARTUP_PIPELINE_HANDOFF.md),
validated in owned fixtures. The first authorized BeamNG probe invalidated
metadata before a match. A separately authorized v2 probe now captured the exact
GI shader pair and an actual 168-byte root, then closed normally (both exits 0).
See [the scoped live evidence](STARTUP_PIPELINE_HANDOFF.md#live-v2-creation-match--2026-10-12).
No Lua/shader edit, sandbox change or native GI activation was performed.

## Exact game-compiled candidate

`tools/beamrt_shader_cache.py` reads the installed game's cache without modifying
it. The observed format is a MessagePack header followed by three-field records,
not SQLite. Parsing enforces byte/value/depth/item limits, exact source prefixes,
matching duplicate keys, container/chunk extents and bytecode/key stage agreement.
Extraction requires exactly one vertex/pixel permutation and a fresh directory
under the workspace's ignored validation folder. Unknown tags/models, compressed
data, overlapping/truncated chunks and ambiguous permutations refuse extraction.
These are structural checks, not a substitute for compiler/driver validation.

The actual cached v082 GI shader uses **SM6.0/DXIL**, despite Lua's `pixVersion=5.0`.
The offline capture/consumer fixtures use SM5.0. The reader supports both verified
container forms rather than assuming the fixture's format is the game's format.
Installed DXC successfully inspected the extracted real shaders.

Snapshot at `.beamrt-validation/gi-pass-manifest-20261012/`:

- Cache: `current/temp/shaders/shaders.d3d12.db`, 29,486,238 bytes, 1,594 records.
- Cache SHA-256: `be3b7a52ae16676963c510420e4877f5945e09afcdeb97631a3e82563c78e841`.
- Build tag: `0.39.4.0.20972 RELEASE Aug  7 2026 18:20:05`.
- Source: `shaders/beamrt/beamrtGITraceP_v082.hlsl`, exact cached stage macro keys
  retained in `manifest.json`, including reversed-depth/D3D12 flags.
- Vertex: 10,184 bytes; SHA-256 `d407f0efd92a209c5ad5ad486c95e454010c5abd7d34f491b0d0fd6687321b3f`.
- Pixel: 94,344 bytes; SHA-256 `88d0456967dbfacec1e7641f1a1e4301e3835a22dae9f78b090d39bc8f88dde7`.

DXC reports pixel `perDraw` at b0 and six Texture2D inputs at t0–t5: prepass,
depth, back buffer, light info, auxiliary and material spec. Samplers occupy
s0–s3 and s5; an unused s4 is not invented. The vertex signature has POSITION0
float3, TEXCOORD0 float2 and TEXCOORD1 float3. These are **compiled declarations**,
not actual bound resources, readable constants or verified camera semantics.
Cache availability does not prove current execution or freshness after edits.
After the first live run, a fresh read-only inventory found the same sole v082
vertex/pixel permutations and the exact shader hashes above. The overall cache
hash is now `19b733e5a7ddd86fca699cab26c23c684c8b8c4309fbe8c570aa3f0e68cfe583`;
the older manifest is preserved unchanged. This rules out changed candidate
bytes in that cache, not a different active shader or missed creation path.

## Native creation audit

The caller supplies exact vertex/pixel bytes and a valid same-process device
outside DLL attach. Start copies both byte arrays. The audit observes public SDK
`CreateRootSignature` and legacy `CreateGraphicsPipelineState` calls. A match
requires both exact byte arrays, successful native creation, actual device-child
ownership and a root whose serialized bytes were observed in this session.
Unknown/earlier roots do not become inferred layouts. The first matching root/
PSO is retained; ReadMatch copies the root blob and transfers actual COM refs.

`ID3D12Device2::CreatePipelineState` streams are explicitly counted as unsupported,
not cast to a legacy descriptor or claimed as shader matches. If BeamNG uses
that path, it must be implemented/validated before declaring live pass identity.
Creating a pipeline is not binding it to a command list, submitting it or executing
the shader. Draw-binding, camera, GPU-ordering and lighting flags remain zero.

Interception atomically swaps **public SDK vtable data slots**, derived with
`offsetof` in `pipeline_slots.c`. It does not replace function instructions,
copy/truncate interface tables, create discovery GPU objects, suspend threads,
change shader bytecode or install the old 39-method capture session. The table
may be shared by other device instances: all native calls are forwarded, while
metadata is filtered by canonical device identity. This is a native interception
prototype, not an engine-supported plug-in or a zero-risk game integration.
Concurrent third-party page-protection changes are unsupported.

Original function/table module leases and context are published before exposure.
Partial installation remains disabled and resident. Disable requires the control
thread and restores only slots still containing our callbacks. Old/prefetched
callbacks keep forwarding after OFF; no callback-count reclamation, restart or
hot-unload exists. Pending unexposed state releases COM refs before module leases.
Only the matching PSO/root and two shader copies (16 MiB each) are retained until
exit. Other observed roots own COM metadata under a BeamRT-specific private-data
GUID; the audit does not hold those root objects alive. Each tag holds an immutable
CPU layout record, never a device/root reference or GPU resource. Byte-identical
layouts found in a 32-entry **weak** cache share records. Cache eviction removes
only the lookup entry: any live tagged root remains resolvable, including a target
created before many unrelated layouts. Expired cache entries are pruned.

The 2 MiB **accounted CPU metadata** budget includes serialized bytes, record/tag
sizes and fixed control-block/registry-entry allowances. It is not a total heap,
allocator-overhead or GPU-memory measurement; shader copies, the bounded weak
cache/registry buckets and the first-match blob copy are separate. Budget pressure
skips new root evidence and increments `budgetSkipped`; an exact shader using an
unclassified root remains an unknown-root rejection. Pressure does not disable the
audit or silently substitute another layout. Native results/LastError still forward.

Tag destruction updates atomic budget counters without taking the audit lock. The
process-resident context/module policy remains necessary for late callbacks and
tag destructors. This is CPU evidence retirement, **not** GPU fence retirement or
permission to unload the module. The capture/GI retirement rules are unchanged.
Private-data reads validate tag size, a registered owned interface pointer and
session identity before using layout bytes. Foreign/conflicting tags invalidate
evidence without dereferencing an unknown pointer or overwriting it. If an unknown
tag actually contains a foreign COM interface, its GetPrivateData reference cannot
be safely released without knowing the data type; that one conflict reference can
remain until process exit, and the invalidated audit stops further observation.
Concurrent/hostile rewriting of the audit's private GUID is unsupported; this is
not an authentication boundary against other in-process code.

Info ABI v2 records the immutable **first** fatal reason and HRESULT: counter,
root-byte/interface/ownership/evidence, pipeline-shape/interface/ownership,
allocation/metadata exception, slot installation/restoration or device removal.
ReadMatch clears all outputs after invalidation; OFF/late calls do not overwrite
the first reason. Config ABI remains v1; startup transport/receipts are v2.

## Verification and remaining boundary

Strict MSVC builds passed. The existing SM5 test shaders passed on RTX 4070 and
WARP: unknown-root refusal, exact VS/PS matching (including a different valid VS),
copied caller buffers, actual root/PSO ownership, unsupported stream reporting,
wrong-thread refusal, concurrent creation through OFF and a saved old callback
executed after OFF with frozen counters. These tests create pipelines but do not
submit GPU draws or prove unchanged rendered pixels/debug-layer cleanliness.

The **actual cached SM6.0 GI shaders** also passed that creation/ownership/disable
path on both backends. Their test root is explicitly **fixture-created** from
the reflected register/input declarations, not a root captured from BeamNG.
The different-VS negative case belongs to the SM5 runs; the cached-game mode
does not substitute an incompatible vertex signature merely to force a mismatch.
No game camera data, textures, descriptor provenance or GI result was captured.
The updated fixtures additionally pass on both backends: 96 distinct live layouts
beyond the old object cap, duplicate-record reuse, matching after cache eviction,
metadata release on actual native-root destruction, a real 2 MiB budget refusal
using valid large root signatures, and a same-size raw tag conflict with exact
failure/HRESULT and cleared match outputs. No artificial production limit or
malformed appended blob is used to reach the budget. Startup-connected pressure
and conflict receipts pass too. Full Python/Lua regression suite: **183/183**.

```powershell
./native/startup/build_pipeline_audit.ps1 -RunTest
./native/startup/build_pipeline_audit.ps1 -RunTest -Warp
```

The startup-host connection is now implemented and fixture-verified; the next
step is SDK deserialization of the actual game root and review/fixture validation
of matched draw/descriptor/CBV/output observation. The v2 live receipt establishes
creation identity only; the earlier live cause remains unconfirmed. Before observing the
matched command-list bindings, descriptor provenance, viewports/outputs and
queue ordering. Existing capture quiescence and GI fence/retirement requirements
remain unchanged; this audit does not bypass them. Do not enable the original
capture module merely because device observation or cache extraction worked.

Primary contracts: [DXIL containers](https://github.com/microsoft/DirectXShaderCompiler/blob/main/docs/DXIL.rst),
[COM interface layout](https://learn.microsoft.com/en-us/windows/win32/com/com-technical-overview),
[pipeline creation](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-creategraphicspipelinestate),
[aligned pointer exchange](https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-interlockedcompareexchangepointer).
Metadata lifetime contracts: [SetPrivateDataInterface](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12object-setprivatedatainterface)
owns a reference until object destruction/overwrite; [GetPrivateData](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12object-getprivatedata)
AddRefs a returned stored interface. The fixture checks retirement under those
contracts, not under an assumed GPU-completion timestamp.
