# Thread-rejection snapshot isolation — 2026-10-13

Implemented in the installed unpacked BeamRT folder after the successful live
recording probe. This is a narrow observer correctness fix, **not** a diagnosis
or reduction of the 3,187,134 live thread-guard rejections, a threading-policy
relaxation, or a lighting/resource integration change. No new game run occurred.
The successful frozen live host/bootstrap remain byte-for-byte unchanged.

## Confirmed defect and repair

The old foreign-thread branch invalidated its own command-list epoch but also
unconditionally cleared the global last-snapshot availability. Thus a rejected
viewport call on list B could erase a valid historical GI receipt from list A.
This was inconsistent with the list-local invalidation used for unsupported
operations and successful Reset.

The branch now clears availability **only when the rejected list is the snapshot
source** (`latest.commandId == state.id`). It still marks the rejected epoch
incomplete, increments the rejection counter, returns without applying the state
update, and leaves recording ownership unchanged. Native calls still forward.
Fatal observer conflicts still fail globally; matching rejected draws retain
their existing refusal behavior. No ABI, hook, capacity, lifetime, GI retirement
or proof flag was changed. Reset still pins the epoch to its caller's thread;
same-generation cross-thread handoff remains conservatively unsupported.

## Deterministic red/green regression

The added standalone fixture accepts a real GI recording on list A, then creates
list B and resets it on the main thread. A joined worker records one viewport
call on B. It must be rejected exactly once without poisoning observer health,
and Read must return a byte-identical copy of A's accepted snapshot. The negative
B recording is closed but never submitted to the GPU. There are no simultaneous
calls on one list in this test.

Before the fix, the RTX 4070 run failed with:
`unrelated thread rejection erased accepted GI snapshot`.
After the fix, the same regression passes on RTX 4070 and WARP. A separate test
first accepts a snapshot on A itself, then performs the joined-worker viewport
call on A and checks Read immediately refuses, before another draw. This guards
against accidentally retaining a receipt whose own epoch became uncertain.

The full existing fixture also passes reset/rebind, indexed recording, root/
bundle/indirect/render-pass refusals, 64-context pressure/retirement, OFF/late
forwarding and unchanged normal GPU pixel **23** on both backends. Debug layer
was unavailable: these are not debug-layer-clean or new live-game proofs.

Strict builds and no-launch 90-case host checks passed. The startup-connected
seven-case fixture matrix also passes, with saved reports and exact input copies:
`.beamrt-validation/native-startup/process-tests-5452-2444092671/`.
Python/Lua/source contracts pass **198/198**.

New candidate artifacts (not game-tested):

- Host: `6577fad08bf0a73825bd648a1b62e66a164d337b6d758722fdb934649e902c34`.
- Bootstrap: `8d1bf1d08fba46d7d1941b6fab475f0a440f75fb22d77d4253c296c606541c67`.

These are separate from the preserved successful live `4eef9113...` host /
`3e630fa0...` bootstrap. No hot reload/unload or automatic repeat launch occurs.
The original DLL-loading anomaly and general deployment hold remain open.
Next: attribute rejected traffic without weakening the thread guard, then verify
descriptor/CBV ownership and contents before any GPU consumer is authorized.

Primary API context: [command-list recording and reuse](https://learn.microsoft.com/en-us/windows/win32/direct3d12/recording-command-lists-and-bundles),
[Reset semantics](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12graphicscommandlist-reset).
