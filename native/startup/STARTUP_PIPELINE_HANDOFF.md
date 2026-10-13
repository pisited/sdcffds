# Startup-connected creation audit

Implemented directly in the PC's unpacked BeamRT folder on 2026-10-12. The
production bootstrap now contains the creation audit and a separately opted-in
handoff from the first actual imported device output. Default startup remains
passive. The first live probe installed but failed to obtain an exact creation
match. A separately authorized **v2 live probe captured the actual GI shader pair
and a 168-byte observed root**; both dated results are below. The previous
device-creation test does not validate these new binaries/shared-table hooks.
Native capture, GI worker/adapter, Lua/HLSL and lighting remain unchanged.

## Explicit review gates

The additional `--observe-gi-creation` flag requires entry/import observation,
two explicit local shader files, both expected shader SHA-256 hashes and a new
`--pipeline-root-out` path. Existing target/DLL hashes and insertion acknowledgement
remain required. Shader files are held open without write/delete sharing;
DXBC/DXIL container bounds and vertex/pixel stage roles are checked before launch.
Wrong hashes/stages, incomplete options or an existing output refuse without
creating the target. The root artifact uses CREATE_NEW: no existing file is replaced.

Review mode still creates no process, loads no DLL and writes no root artifact.
The optional wait is 1–300 seconds (default 30), with parent-only progress at
10-second intervals. Timeout, failure or child exit never force-close a resumed
application. Waiting longer does not make a missed/unsupported pass valid.

## Device handoff and CPU receipts

The 72-byte v2 payload binds PID, initial thread, four anonymous inherited
handles, bounded shader sizes and zero reserved fields. The inherited-handle list
contains exactly nine handles in this mode. Input shader bytes are mapped read-only
in the child and copied into the audit; no file read, extra DLL load, new thread,
GPU object creation or GPU submission is added inside its callbacks.

The import observer takes an owned first-candidate reference, releases its
metadata lock, then calls the pipeline installer. The installer requires the
initial thread and a return address in executable memory belonging to the main
EXE. These are a **narrow startup-call policy**, not proof of loader-lock freedom,
all-caller quiescence, render-device selection or game compatibility. No private
loader lock/engine offset is inspected. No installer is called from DllMain.

Two disjoint regions are written once and signalled separately:

1. Installation: actual Start result, caller identity and audit status.
2. First exact creation match: actual captured root bytes and creation metadata.

The parent validates both. Installation alone is not a pass match. A match is
not an executed draw, actual descriptor/resource binding or a GI result. The
parent saves the observed root only after a complete matching receipt. The
camera/draw/GPU-ordering/lighting flags must remain zero. These events publish
CPU data, never GPU completion. Later metadata/device changes do not rewrite
these first-sample receipts or authorize future frame consumption.

Separate aligned atomic diagnostic counters show roots, legacy PSOs, streams,
shader matches, unknown roots, metadata health, the first fatal reason/HRESULT,
live tags/layouts, cache evictions and metadata budget/skip counts on timeout. Individually atomic
values do not form a coherent frame/snapshot and are never eligibility gates.
Pipeline streams remain unsupported. The old 32-root **strong-retention** cap has
been replaced by object-owned CPU tags, a 32-layout weak lookup cache and a 2 MiB
accounted metadata budget. Pressure leaves new roots unclassified rather than
invalidating all evidence. See [the exact lifetime/budget limits](PIPELINE_AUDIT.md).
Info and start/match receipt ABIs are v2; input shader/config ABIs remain v1.
Old transport versions are rejected, not silently interpreted as new layouts.

## Actual controlled-process verification

The named disposable fixture does not call Start. The production launcher/DLL
install the audit from the fixture's real imported D3D12 creation return. On RTX
4070 and WARP it captures an exact shader/root creation, obtains the actual native
root/PSO owner and transfers a 132-byte observed root to the parent. An independent
fixture SHA-256 verifies the parent's saved bytes, not just file existence.

Eight cases pass: hardware/WARP matches after 97 root creations and cache eviction,
hardware/WARP deliberate tag conflicts with exact parent-visible failure/HRESULT,
installation with a different valid pixel shader and no match, wrong shader hash,
existing output preservation and wrong stage. Conflict/native creation still
succeeds while the audit refuses a match; no root artifact is written.
The no-match case exercises a real bounded wait and leaves the child alive until
its natural exit. Preflight refusals create no child. Every retained child exit
was checked and all private fixture jobs drained. Source/Python/Lua suite:
**183/183**. The original device, entry and import fixture suites also passed
with the new default-off bootstrap. This is not debug-layer-clean or game proof.

Latest reports: `.beamrt-validation/native-startup/process-tests-64856-2401445640/`.
They contain fixture shaders/roots, not a root observed inside BeamNG.
The no-launch argument/payload test rejects 40 cases, including legacy transport ABI. Original nine startup
failure/receipt cases passed again. Read-only review of the installed game and
both exact cached SM6 shaders accepted the new option without launching BeamNG
or writing a root output.

Latest tested build SHA-256:

- Host: `72264623af86bdecc00a9c6104c7d2e259af5a2d23d548c6460cebaa2b751f2e`.
- Bootstrap: `d16d5e05454259f8be4f0c0acf66d7bc738fd1400e3aa2497b37f7fddcf83ca4`.

```powershell
./native/startup/build.ps1 -RunContractTests -RunPipelineStartupTests
```

## First live probe — 2026-10-12

The user authorized one 300-second probe. Game PID 20604 started at 19:45:31 MDT
with fixed reviewed host/DLL/SM6 shader copies. Entry/import and pipeline-audit
installation receipts passed. West Coast USA loaded; the game log confirms
existing lighting/GI enablement within the observation window. No new shaders
or native lighting contributions were applied.

The exact match timed out and no root file was written. Diagnostics at timeout:
**50 root-creation calls, 34 legacy pipeline-creation calls, 0 observed streams,
0 shader matches, 0 unknown-root matches and audit health 0**. The audit had
invalidated metadata, so these are not continuous/full-session counters. The
32-root retention limit is a plausible cause, but no specific reason or retained
count was emitted; root validation/allocation failure is not ruled out.

The user closed normally. Shutdown was logged, and by 19:55:38 MDT the host,
main game and all BeamNG helper processes were absent. No force-close or hot-unload.
This proves installation and real legacy creation-call observation, **not** live
GI pass identity, root capture, descriptor/resource access or lighting correctness.
The numeric game/host OS exit codes were not retained for this live run.

Exact binary/shader copies and before/map/after logs are preserved under
`.beamrt-validation/native-startup/live-pipeline-20d80b08c5004e62b6aaaa18d3ce9410/`.
That probe's host SHA-256 was `d618aa3016b7987870551fa333913f6dd037ae0403e01e3367ff065f44662eec`
and DLL SHA-256 was `fcee7523a5ac6b9df20d9c894e8e3d2ccb4fe858a92146b401bb0638198eb076`.
They are **not** the updated v2 build listed above. No source changes or second
live attempt were made during that first probe. The separately authorized v2
live result below used different reviewed binaries.

## Live v2 creation match — 2026-10-12

The user authorized one new observation-only startup with the exact v2 build
hashes listed above, copied into a fresh validation directory. At 21:19:04 MDT
host PID 93264 launched game PID 11928. Entry/import/installation receipts passed.
The user confirmed normal West Coast USA loading; the final log independently
records `beamrt_main.start()` and lighting/GI enablement at elapsed 100.04 s.

At 21:20:44 MDT the host validated an **exact target VS + PS creation match** with
an actually observed, same-device root and healthy/enabled metadata. It saved a
**168-byte** root blob (not the fixture's 132-byte layout) and exited **0**.
Root SHA-256: `27b09f74ab916278b8a179a6e415803db26d41eb376dced7e7df49d2082e2d46`.
The receipt's observed unsupported-stream count was zero at that match. Full
capacity counters/continuous post-match health were not retained by the success
output and are not asserted. The old failure's specific cause remains unknown.

The user closed normally; the retained game process handle reported exit **0**
at 21:22:55 MDT. Normal shutdown appears in the log. At 21:23:30 neither host,
main game nor helpers remained. No forced termination, live detach or hot-unload.
Exact copies and before/after logs are in
`.beamrt-validation/native-startup/live-pipeline-v2-cea3ba6480204092a473096f1aa4c2fd/`.

This is **live creation identity/root capture**, not an executed draw or GPU
resource handoff. Draw bindings, camera, GPU ordering and lighting-consumption
proof flags remained zero. No native capture/GI worker or lighting change was
enabled. Next: SDK-deserialize the actual root and review/fixture-test matched
draw/descriptor/CBV/output observations before another separately approved probe.

Follow-up: [the standalone recording-binding observer](GI_BINDING_OBSERVER.md)
now SDK-decodes this actual root and passes isolated hardware/WARP recording,
invalidation/restoration and unchanged-output fixtures. It is **not linked into
this startup host/bootstrap**, has no new live game result and cannot yet recover
resource provenance or camera/CBV contents. A separate reviewed startup routing/
control/receipt bridge remains required before another authorized game probe.

## Before another bounded game probe

Requires separate user approval, immutable reviewed binary/shader copies and
normal user closure afterward. Loading a normal map and enabling the existing
BeamRT GI once may be necessary to create its pipeline; the observer itself
must not replace shaders, change quality/intensity or apply native visibility.
The prior direct-launch Steam warning remains an open compatibility caveat.

A specific first-failure reason and bounded object-owned root metadata are now
implemented and fixture-tested. They do not retroactively establish the earlier
live cause. The new tag path now has one live creation match, not general
game-scale or per-frame resource coverage. Do not weaken the GPU frame/input retirement contract
or blindly increase every limit. The saved exact-match root justifies reviewing matched draw/descriptor/
viewport/output observations. A no-match/unsupported-stream/budget result is
evidence about that boundary, not a reason to repeat lighting screenshots or
claim the GI integration works. Capture's quiescence and GI adapter retirement
rules stay intact. Close normally; no hot-unload or automatic game-hook removal.
