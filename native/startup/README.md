# Opt-in native startup host: passive startup, not GI integration

Implemented 2026-10-12 directly in the unpacked BeamRT source. Disposable fixtures
and **separately authorized passive and import-observation BeamNG startups** passed.
The second observed a real device-creation output; native capture/GI deployment
remains unverified. No game files,
Steam launch options, registry settings, Lua sandbox settings or normal startup
were changed. No ReShade, proxy system DLL, installer or persistent background
process is included.

This is a launcher and minimal startup bootstrap, **not a game GI observer yet**.
The current build does not link or call the capture or GI adapter. Building this
slice does not establish graphics-device access, safe game-thread interception,
actual GI pass identity or any lighting improvement.

Update: the DLL now includes a dormant [post-loader device observer](DEVICE_OBSERVER.md).
Only an explicit host call outside loader-lock work initializes it. Startup
insertion itself still performs no graphics initialization. Hardware/WARP
disposable fixtures observed actual creation outputs and resource ownership;
the corresponding BeamNG initialization/thread handoff is still unverified.

The [opt-in native-entry rendezvous](ENTRY_RENDEZVOUS.md) now provides an automatic
post-loader callback and parent-validated startup status. Its production path
is passive; device auto-start and entry-register snapshot exports are fixture-only.
The installed game's passive native-entry handoff and menu startup subsequently
passed, followed by user-requested normal closure and verified process absence.
See [the dated live-test evidence and exact tested hashes](ENTRY_RENDEZVOUS.md#actual-passive-beamng-startup-evidence--2026-10-12).
Thread quiescence and rendering integration remain unverified. Later output
updates have different hashes and are not covered by that live test.

New, separate route: [image-scoped device-import observation](IMPORT_OBSERVER.md)
is implemented behind `--observe-device-import` plus `--entry-rendezvous`. It
atomically swaps one verified main-image import pointer outside DLL attach, not
the process-wide D3D12 function instructions. Default startup remains passive.
This is not quiescence for capture or a game GI connection. Named/ordinal imports
passed disposable hardware/WARP fixtures. A subsequent authorized game run also
observed an actual creation output and closed normally; see the
[exact-build live observation evidence](IMPORT_OBSERVER.md#actual-beamng-creation-receipt--2026-10-12).
The previous passive test does not validate this observer/new binary.

Next implemented slice: [exact cached shader manifest and creation-only audit](PIPELINE_AUDIT.md).
The game cache contains SM6.0/DXIL GI shaders. A separate, default-inactive audit
matches exact VS/PS bytes and observed root creation; its hardware/WARP fixtures
pass, including real cached GI bytecode. A separate [startup connection](STARTUP_PIPELINE_HANDOFF.md)
is now implemented and passes eight real inserted-fixture handoffs. It is default
OFF. A subsequent authorized BeamNG probe installed it and observed legacy
creation calls, but metadata became unhealthy and no exact shader/root match
was captured. It is **not connected to live resource capture or native GI**;
the handoff document records the failed match and next boundary.
The updated v2 audit now reports the exact first failure/HRESULT and uses bounded,
object-owned CPU root metadata rather than retaining 32 root objects. Pressure,
retirement, matching after cache eviction and parent-visible conflict refusals
pass hardware/WARP fixtures. A separately authorized v2 BeamNG probe now captured
the exact target GI shader pair and an actual **168-byte root**; host and game
both exited **0** after normal closure. That is creation identity, not an executed
draw, descriptor/resource access, camera data or native GI consumption. Those
remaining boundaries are unchanged; see the handoff's dated live v2 evidence.
Next slice: [GI recording-binding observer](GI_BINDING_OBSERVER.md) SDK-inspects
the captured root and fixture-tests actual draw CBV/table/viewport/output metadata.
It is separate/default-off and not linked into the production startup build;
no new live binding capture, native GI or lighting result is claimed.

## Files and default behavior

- `launcher.cpp`: Windows x64 host. No arguments show help. Normal configuration
  defaults to **review only**, validating/printing paths, PE types, SHA-256 hashes,
  working directory and the quoted application command line. Unicode/control
  characters are escaped for display only; actual UTF-16 arguments are unchanged. Review does
  not create a child, load a DLL or modify game files.
- `bootstrap.cpp`: minimal DLL attach contract. It verifies an exact versioned
  startup payload for its own PID, restores Detours' temporary in-memory import
  edit and signals one inherited receipt event. No hooks, device creation, GPU
  commands, thread creation, waiting, file logging or renderer initialization are
  performed in `DllMain` in presence-only mode. Opt-in entry mode arms an EXE
  entry detour there, but never executes its initializer or installs graphics
  hooks there. No detach-time rendering cleanup is attempted.
- `startup_contract.h`: shared POD-only x64 payload and presence status. The
  exported `BeamRT_StartupQuery` always reports capture/GPU/lighting fields zero.
  The launcher does not remotely invoke this export. It uses the receipt event.
- `build.ps1`: strict MSVC build and optional **no-launch** argument/payload tests.
  Reuses the existing capture build for toolchain/pinned Detours preparation;
  the resulting bootstrap does not link `beamrt_capture.lib` or the GI adapter.
- `process_test.cpp` and `fixture_target.cpp`: separately opted-in disposable
  startup/receipt/failure tests. The runner selects only its compiled fixture,
  holds each process tree in an unnamed private Windows job, checks the loaded
  bootstrap from the target's entry point and waits for every job to drain.

Artifacts stay under `.beamrt-validation/native-startup/`. The DLL exports
Detours' required ordinal 1; this host does not use a mixed-bitness helper.
Detours is the existing official MIT-licensed v4.0.1 source pinned to
`e4bfd6b03e50de46b47abfbd1e46b384f0c5f833`.

## Explicit launch branch — disposable fixtures and bounded game observations

Launching requires **all** of these separate inputs: `--launch-reviewed`,
`--expected-target-sha256`, `--expected-dll-sha256`, and
`--acknowledge-native-insertion startup-observation-only`. `--review` and launch
are mutually exclusive. Missing, duplicate, unknown or incompatible inputs
refuse launch. Hashes must match the current files; a rebuild/update requires
another review. Hashes establish identity, not trust or binary signing.

The reviewed launch implementation:

1. Opens/canonicalizes the explicitly chosen local x64 EXE and x64 DLL; keeps
   read-only file handles without write/delete sharing while reviewing/starting
   them. Rejects network/removable paths and ambiguous non-ASCII/long DLL import
   names. The working directory is explicit or defaults to the EXE's directory.
2. Quotes the exact supplied argument vector using Windows backslash/quote rules.
   It does not invoke a shell, infer Steam arguments or alter launch options. The
   caller must review the intended executable, directory and arguments; this
   does not verify Steam's actual startup/relaunch behavior.
3. Creates **one new suspended child**, with an explicit inherited-handle list
   containing only its anonymous startup-receipt event. It never opens/attaches
   to an existing BeamNG process and does not enumerate/suspend game threads.
4. Calls public `DetourUpdateProcessWithDll` on that owned child and copies a
   tagged startup payload using `DetourCopyPayloadToProcess`, then resumes the
   initial thread once. These operations insert native code and modify the
   **new process's memory/import table**; they are not an engine-supported mod
   API or a claim that insertion is risk-free. No automatic helper fallback is
   used.
5. Waits up to 15 seconds outside the game for a bootstrap receipt or child exit.
   The receipt means **DLL attach only**, not entry-point completion, stable
   rendering, capture, camera meaning, resource access or GI consumption.

Failures before a resume attempt terminate only the new, still-suspended child
and report cleanup failure if necessary. After a successful resume attempt,
timeouts/errors report the PID and do **not** force termination of a running
game. Controlled child tests now exercise these paths, as described below.

## Removal / limits

No launcher shortcut, game-bin copy, service, scheduled task, registry entry,
environment override or automatic activation is installed. A future reviewed
test is opt-in for that one process. To return to an unmodified process,
close it normally and start BeamNG through its original startup route. Removing
the bootstrap file while it is loaded is **not** hot-unloading. No safe live
hook detach or in-game OFF restoration is claimed by this inert bootstrap.

The remaining BeamNG host work must establish device acquisition outside loader-lock
work, an actual safe thread handoff, early resource observation, the real GI
shader/root manifest, CBV ownership/contents, frame freshness, resource lifetimes,
submission ordering and compatible output consumption. Loading this bootstrap
alone does not establish any of those conditions. Capture/GI remain disabled.

## Verification performed

- Strict `/W4 /WX` MSVC compilation succeeds.
- Read-only binary inspection confirms the required ordinal 1 and status export;
  the bootstrap has only `KERNEL32.dll` as a runtime DLL dependency.
- No-launch self-test checks exact Windows argument roundtripping and rejects
  16 invalid option/payload cases. No child is created or DLL loaded by that test.
- Review-only execution against the installed BeamNG EXE prints physical paths,
  hashes and intended working directory without launching it. SHA-256 output is
  cross-checked with PowerShell's independent file hash implementation.
- Review mode rejects an incorrect DLL hash and a DLL passed as the target EXE.
- Full Python/Lua source/regression suite passes **161/161**.
- Explicitly authorized disposable-process testing passes **9/9** cases. This
  includes actual DLL insertion/receipt and target entry, exact Unicode/empty/
  quote/backslash arguments and directory preservation, hash refusal before a
  child is created, injected failures before insertion/payload/resume, failure
  after resume, child exit without a receipt and the real 15-second timeout.
- The target queries the already-loaded bootstrap, verifies attached ABI/PID/
  initial thread and zero capture/GPU/lighting flags, and writes its own reports.
  The harness retains a query/synchronize handle only to the named target in its
  private job and verifies its actual OS exit code, not merely a completion file.
  One case intentionally returns 37 after a valid receipt: host success is not
  mistaken for application success.
- Before-resume failure cases create then retire a still-suspended fixture
  without reaching its entry point. After-resume failure/timeout leaves the child
  alive until its planned natural exit; each final private job has zero active
  processes. Job kill-on-close is the harness's emergency cleanup, not a new
  production-game termination policy.
- The initial harness's separate headless console added a Windows `conhost`
  process to its private job; using the existing test console removed that
  harness-only accounting mismatch. Unicode command display was also repaired
  so it cannot truncate the later startup receipt/log output.
- One separately approved production-passive BeamNG launch reached/restored the
  native entry and displayed the main menu on D3D12/RTX 4070. Normal closure and
  process absence were verified. Steam initialization reported error 1; normal
  Steam-launch equivalence and gameplay were not tested. No graphics-device
  acquisition, live GI/camera/resource capture, native lighting consumption,
  hot-unload or native GI OFF/restoration behavior is verified.

Fault injection and suppressed receipts exist **only** in separately compiled
test host/DLL variants, not production artifacts. The fixture GUI process creates
no windows, GPU work or child processes. Reports use fresh directories under
`.beamrt-validation/native-startup/process-tests-*` and remain available for
inspection; no existing user reports are overwritten or deleted.

Build and safe review commands (neither launches BeamNG):

```powershell
./native/startup/build.ps1 -RunContractTests
./.beamrt-validation/native-startup/beamrt_startup_host.exe --review --target "E:\SteamLibrary\steamapps\common\BeamNG.drive\Bin64\BeamNG.drive.x64.exe" --dll "C:\Users\ab\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\beamrt\.beamrt-validation\native-startup\beamrt_startup_bootstrap.dll" --workdir "E:\SteamLibrary\steamapps\common\BeamNG.drive"
```

No reusable game-launch command is supplied here. Review source,
binary/dependency identity, startup/receipt behavior and remaining threading
gates with the user before any further **BeamNG** deployment. Approval for the
completed passive/import observations is not approval for rendering capture, GI
activation or repeat launches.
CI still runs only build/no-launch
contracts, not insertion. Disposable process testing is a separate explicit opt-in:

```powershell
./native/startup/build.ps1 -RunContractTests -RunProcessTests
```

That runner constructs its own fixed fixture paths; it cannot accept a game
executable argument. It never selects or starts the installed BeamNG EXE.

Primary contracts: [Detours startup insertion](https://github.com/microsoft/Detours/wiki/DetourUpdateProcessWithDll),
[tagged payload transfer](https://github.com/microsoft/Detours/wiki/DetourCopyPayloadToProcess),
[payload lookup](https://github.com/microsoft/Detours/wiki/DetourFindPayloadEx),
[restricted inherited handle lists](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute),
[private job/process-tree lifetime](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
[loader-lock limitations](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices).
