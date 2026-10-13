# GI recording-binding observer (standalone prototype)

Implemented directly in the installed unpacked BeamRT folder. No new BeamNG
launch, shader/Lua edit, sandbox change, old capture activation or GI deployment.
The production startup host/bootstrap remain unchanged: they do **not** link or
start this component. The previous live creation match remains a different,
explicitly scoped result, not validation of these new interception methods.

## Actual game root, SDK-decoded

`root_inspect.cpp` uses D3D12CreateVersionedRootSignatureDeserializer on the saved
168-byte game root, SHA-256
`27b09f74ab916278b8a179a6e415803db26d41eb376dced7e7df49d2082e2d46`.
The SDK successfully decodes version 1.0, flags ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
no static samplers and these ALL-visible parameters:

| Parameter | Actual declared binding |
| --- | --- |
| 0 | Root CBV: b0, register space 0 |
| 1 | One SRV range: t0–t5, register space 0, table offset 0 |
| 2 | One sampler range: s0–s5, register space 0, table offset 0 |

These are **declared layout facts**, not readable CBV contents, actual texture
provenance or camera semantics. `gi_root_layout.h` refuses different versions,
flags, visibility, counts/types/registers/spaces/offsets or extra parameters.
The inspector creates no device, queue, command list or GPU work.

## Narrow observation contract

- Start is explicit, same-process and outside DLL attach. Its control thread
  owns target setup and OFF. No auto-start, thread injection or game API call.
- TargetFromAudit calls the existing creation audit's ReadMatch, obtaining the
  actual matched PSO/root and copied observed blob. It validates SDK layout and
  canonical device ownership. There is no arbitrary-pointer/guessed-target API.
  It deliberately does not hold the binding lock across the audit API call.
- Public SDK vtable **data** slots are atomically swapped. SDK `offsetof` drives
  indices; tables/instructions are not cloned, truncated or Detours-patched.
  Device CreateCommandList and Device4 CreateCommandList1 seed actual DIRECT
  command-list contexts. A pre-existing/unobserved list is never inferred.
- Shared tables can affect other instances; original calls always forward,
  metadata is filtered by canonical device/context ownership. Public API prefix
  slots are untouched elsewhere. Concurrent third-party table/protection changes
  and saved callbacks invoked on unrelated/incompatible tables are unsupported.
- Up to 64 live lists own CPU tags; the observer holds no command-list COM ref.
  Tags retain current root/PSO references for identity safety until rebind/reset
  or actual list destruction. Heap identities/ranges are copied metadata, not
  resource leases. Tags do not allocate GPU buffers. Additional native-object
  retention is bounded by context count, not a total GPU-byte budget.
- Capacity pressure skips new contexts without poisoning old ones. Modules,
  immutable originals, matched target and published context remain process-
  resident. OFF restores only still-owned slots; no restart/hot unload or
  callback-count reclamation. Late cached callbacks remain valid.

Recorded snapshots require the exact target PSO/root identity, valid CBV alignment,
six SRV/sampler entries inside the currently bound same-device shader-visible
heaps, viewports/scissors and output handles. Table handles are resolved to CPU
descriptor **addresses only**, with range/alignment/overflow guards. Direct and
indexed Draw call arguments are copied after normal native recording returns.
There is no descriptor-content, buffer-content or shader-execution proof.

Root changes invalidate arguments; identical root reassignment preserves them.
Changing heaps invalidates table arguments; identical heaps preserve them.
Successful Reset clears state and advances the recording generation; ClearState
clears it. Bundle/indirect/render-pass/ray-tracing-pipeline calls invalidate the
context until Reset/ClearState. Unknown/foreign tags fail closed. A tag of unknown
type is never dereferenced/released speculatively; one foreign interface reference
can remain after a fatal conflict, as in the root audit. Rewriting private GUIDs
from hostile/concurrent in-process code is not supported or authenticated.

Recording is deliberately one thread per generation. Sequential thread handoffs
without Reset are rejected, even if legal for the application; simultaneous
recording on one list is not supported. Different tracked lists can be recorded
by different threads. Start/target setup require a future verified control gate.

## What a snapshot is NOT

Read copies the last accepted **recording observation**, not necessarily this
frame. Command ID, generation and serial must never be substituted for a frame
key, queue submission or completed fence. A matching rejected draw or reset of
the source invalidates availability; other activity can leave a historical
receipt available. No immutable-resource lease or consumer ordering is provided.

Descriptor provenance, CBV contents, camera meaning, GPU ordering and lighting
consumption flags always remain zero. The observer does not capture SRV/RTV
creation/copy contents, resource state/barrier chains, vertex/index buffers,
primitive topology, queue Execute/Signal/Wait or enhanced barrier semantics.
It cannot convert this receipt into BeamRTGIInputs or start the worker safely.
Capture quiescence and GI final-consumer fence retirement remain unchanged.

## Verification

Strict MSVC /W4 /WX builds passed. The actual captured game root was supplied to
hardware RTX 4070 and WARP fixtures; shader code/resources are fixture-owned,
**not** a captured game draw. GPU readback was 23 with hooks active and after OFF.
Both runs passed direct/indexed binding snapshots, redundant root/heap semantics,
reset/rebind, unobserved list/root mismatch/bundle/indirect/render-pass/thread
refusals, 64-list capacity and object-owned retirement, concurrent creation/OFF,
wrong-thread OFF refusal and a prefetched draw callback after OFF.
ClearState plus full rebinding also restores an unsupported recording context;
that restored draw produces the same GPU pixel.
Negative recordings are not submitted. Debug layer was unavailable: no claim of
debug-layer-clean proof, whole-scene unchanged pixels or game compatibility.
Full Python/Lua suite: 188/188.

CI uses an explicitly fixture-owned SDK-generated equivalent layout and WARP;
it does not require ignored PC artifacts or represent live root capture. The
`--fixture-root-out` path uses CREATE_NEW and never replaces an existing file.

```powershell
# CI/disposable root, no game loading:
./native/startup/build_bindings.ps1 -RunTest -Warp
# Existing actual captured blob can be supplied explicitly:
./native/startup/build_bindings.ps1 -RunTest -InspectRoot <absolute-existing-root-path>
```

## Next gate

Review a separately opted-in startup connection before deployment. It must seed
observation early enough, provide owner-thread target setup **outside the creation
audit lock**, preserve default-off behavior and publish bounded CPU recording
receipts without authorizing GI. Only after isolated startup fixtures and a fresh
user-approved game probe can we claim live draw/binding observation. Resource
provenance and camera/CBV-content discovery are subsequent separate contracts.
The standalone DLL links the standalone creation-audit DLL. Its session storage
is **not** the audit compiled inside the production bootstrap. A production bridge
must explicitly route to/co-link the actual existing audit session, not load a
duplicate audit and assume those globals or receipts are shared. That routing,
owner-thread scheduling and startup transport are not implemented by this slice.

Primary contracts: [SDK root deserialization](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-d3d12createversionedrootsignaturedeserializer),
[root/argument invalidation and bundle semantics](https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-a-root-signature),
[descriptor heap binding](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-setdescriptorheaps).
