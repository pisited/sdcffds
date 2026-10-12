# Opt-in native startup host: disposable-process validation only

Implemented 2026-10-12 directly in the unpacked BeamRT source. **Tested only in
disposable fixtures; not deployed or approved for BeamNG deployment.** No game files,
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
  performed in `DllMain`. No detach-time rendering cleanup is attempted.
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

## Explicit launch branch — exercised only with disposable fixtures

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
test would be opt-in for that one process. To return to an unmodified process,
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
- Full Python/Lua source/regression suite passes **153/153**.
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
- No BeamNG launch, graphics-device acquisition, live GI/camera/resource capture,
  game rendering or in-game OFF/removal behavior is verified. No in-game success claim.

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

No runnable launch command is supplied in this review stage. Review source,
binary/dependency identity, startup/receipt behavior and remaining threading
gates with the user before authorizing **BeamNG** deployment. The user separately
approved only the disposable test program. CI still runs only build/no-launch
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
