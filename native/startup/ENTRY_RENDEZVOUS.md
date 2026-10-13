# Native-entry rendezvous: post-loader handoff, not GI integration

Implemented 2026-10-12 in the PC's unpacked BeamRT source. A separately authorized
**passive BeamNG startup test passed** on that date; see the live evidence below.
That first test activated no graphics observer, native capture or native GI. A
subsequent import-observation test is linked below. No persistent
game installation or settings/launch-option change was made by the test host.
The ordinary startup host still defaults to review-only and entry interception OFF.

## Implemented handoff

The separately opted-in `--entry-rendezvous` route uses an additional versioned
Detours payload. It binds the new child PID/initial thread, the reviewed EXE's
public PE entry RVA, one anonymous entry-receipt event and one anonymous typed
startup-status mapping. Only these handles plus the existing attach event are
inherited. Target/DLL hashes and explicit insertion acknowledgement remain
required for launch. Review can inspect the native PE shape without creating a
process. CLR/missing/out-of-image entries are rejected.

This changes the **opt-in** DLL-attach contract: after restoring the temporary
import edit, `DllMain` arms only the native EXE entry detour. It does not invoke
the initializer, install a D3D12 hook, create a device/thread, map shared status,
wait, or run GI. Without the entry payload, arming is a no-op. The mapped main
image, expected RVA and executable non-guarded memory region are checked using
public PE/Windows/Detours interfaces. No private engine function offset is
guessed and no disk image is patched.

Windows' normal native EXE entry transfer then reaches `entry_thunk.asm` after
initial DLL loading. The thunk preserves incoming RAX/RCX/RDX/R8-R11, XMM0-5,
flags and stack shape, calls `BeamRT_EntryInitialize`, restores that state and
**tail-jumps** to the original entry. It does not cast the entry to an invented
WinMain prototype. Nonvolatile registers follow the Windows x64 callee ABI;
the assembly includes unwind metadata and reserves aligned shadow space.
This is a native Windows x64 route, not a CLR, other-architecture or arbitrary
vector-call startup contract.

The one-shot callback removes its entry detour before forwarding. It records
detach success and compares the original entry's first five bytes. Failed detach
does not free a live trampoline or unload the imported bootstrap. The production
callback performs **no graphics initialization**. It publishes a one-time CPU
status outside loader-lock arming, then signals the entry event. The launcher
checks ABI, initial-thread identity, callback reach/release decision, successful
detach/restored prefix and all unknown graphics/GI flags before reporting success.
A receipt alone is insufficient. Failure after resume reports/refuses without
forcing termination of a running application.

`released` means the callback has prepared handback, not that application main,
rendering or gameplay has completed. The parent snapshot is immutable startup
evidence; it is not a frame record, camera buffer, resource-state chain or GPU
fence. `graphicsQuiescenceVerified`, `cameraVerified`, `gpuOrderingVerified` and
`lightingConsumed` always remain zero.

## Why graphics still stay OFF in production

Reaching an EXE entry point does **not** certify that arbitrary graphics callers
are quiescent. TLS callbacks and imported-DLL initialization already ran and
may have created threads/devices. Devices/resources created earlier cannot be
retroactively recovered by this hook. The loader-lock boundary follows the
normal native startup contract; no private loader-lock inspection is added.

Automatic `BeamRT_DeviceObserveStart(1,...)` exists only inside a separately
compiled `BEAMRT_ENTRY_FIXTURE_AUTOSTART` DLL, gated to the exact named disposable
fixture. Its assertion is supported by that owned application's known lifecycle,
not generalized to BeamNG. Production has neither automatic device activation
nor the test-only raw entry-frame export. The existing Lua/HLSL renderer,
native capture and GI adapter are unchanged.

A new **separate payload** can opt into [image-scoped import observation](IMPORT_OBSERVER.md)
after entry restoration. This is not automatic process-wide observer activation
or a quiescence assertion. Entry-only/default startup remains passive; the old
passive live-test hashes below do not cover the new option or current binary.
The import observer subsequently produced an actual BeamNG creation receipt,
with menu confirmation and normal closure; see its own exact-build live evidence.

## Actual disposable-process evidence

Four entry cases pass under real startup insertion:

- Passive rendezvous: entry reached/restored, no observer activation, original
  device creation/application execution unaffected.
- Automatic known-fixture hardware initialization: observer starts in the entry
  callback and sees a real device created in the EXE's C++ static constructor,
  **before `wWinMain`**, with matching device/resource ownership.
- The same automatic path on WARP.
- Deliberately failed fixture initialization: entry is restored, graphics hooks
  stay absent and the original application's device creation still succeeds.

The disposable EXE has its own assembly entry wrapper. It records the state
actually delivered to the original entry before forwarding to the normal CRT.
The defined volatile GPR/XMM/flags snapshot matches what the injected DLL saved;
only match flags, not raw register/pointer contents, are written to reports.
The application does not call observer Start itself. Actual child exit codes,
argument/directory preservation and private-job drainage are checked. No test
process remains. This establishes the controlled handoff, not game compatibility.

Strict MSVC/MASM builds and hardware/WARP device fixtures passed; the full
Python/Lua suite passes **157/157**. Read-only review of the installed BeamNG
EXE accepts its native PE entry structure. Its passive entry hook subsequently
executed in the separately authorized live startup test below.
The original nine startup failure/receipt cases remain a separate regression.
There is no native in-game lighting, gameplay stability or hot-unload proof.

Explicit owned-fixture test only:

```powershell
./native/startup/build.ps1 -RunContractTests -RunEntryTests -RunDeviceTests
```

## Actual passive BeamNG startup evidence — 2026-10-12

The user explicitly authorized one startup test. With no existing BeamNG process,
the reviewed production host created PID **26592** at 17:18:37 MDT, using the
installed 0.39.4.0 x64 build 20972 EXE, the game-root working directory and no
application arguments. The launcher (PID 56924) exited with code 0 after receipt
and typed entry-status validation: callback reached on the initial thread,
one-shot detour detached, original entry prefix restored, `deviceStarted=0` and
all graphics/GI verification flags zero. This is CPU startup evidence, not a GPU
completion receipt.

Read-only module inspection found the expected bootstrap in that same game PID,
alongside the system D3D12/DXGI runtime. The game log reports the RTX 4070 D3D12
device and startup in 6.51 seconds. The user confirmed the main menu was visible.
Existing Lua/HLSL BeamRT loaded normally; the native observer, capture and GI
adapter remained inactive. No map, shadow comparison or new GPU pass was run.

The user closed the game normally. Its log records shutdown at 17:22:57 MDT;
subsequent process checks found neither PID and no BeamNG process. No process was
force-terminated. A numeric game exit code was not retained. This proves removal
of the resident DLL with that process, **not** hot-unload or a tested normal restart.

Tested SHA-256 identities (do not substitute later output files):

- Game EXE: `5a0420b44da74c3aa5388e460b602fcaa2baefafe2a64c6bff7c29a9345a2af2`
- Bootstrap DLL: `bc2290b7d50a9777dc5a07a8f60f1e0f7b8d11811e1eac2b45c0499ecbf6c93e`
- Host EXE: `c054c9990238a3fa484399c59aad730bac28d97eb0757950f9331a75cbaede45`

Receipts and before/after logs are retained locally under the ignored directory
`.beamrt-validation/native-startup/live-startup-052231fcc5df49e8bff11e5418b96fe2/`.
The output binaries subsequently changed, with modification times of
17:24:30–31 MDT, after game shutdown, and now have different hashes. Their update
was not performed by this test; the cause is unassigned. Those newer binaries
are **not** covered by this live test.

The direct EXE launch also logged Steam online-service initialization error 1,
which was absent from the previous session's log. The visible menu and shutdown
passed, but Steam integration/normal-launch equivalence was not established;
the cause was not diagnosed. Existing duplicate-mod/input/level errors also occur
in the baseline. This is not an error-free or debug-layer-clean game result.

## Next boundary — graphics observation requires separate review

The entry-only probe above checks attach receipt, native-entry reach/restoration
and menu startup using the **production passive** DLL. It does not enable device
observation, capture, GI, shader replacement or change lighting. No visual
difference is expected from that test. This route still inserts
native code and briefly changes the new process's entry instructions, so startup
compatibility/crash risk is not zero. It must not attach to an existing session
or silently change Steam arguments, mods or sandbox settings.

Keep normal startup available, review current binary hashes and exact arguments,
and close the test process normally afterward to remove the resident DLL. Do
not attempt hot-unloading. The successful passive game probe establishes only
the actual startup handoff for the tested build. A real graphics-thread policy,
earliest device/pass identity, resource/CBV lifetimes and one intended GI consumer would still need
separate evidence before activation.

Primary contracts: [public entry-point lookup](https://github.com/microsoft/Detours/wiki/DetourGetEntryPoint),
[native PE metadata](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format),
[Windows x64 ABI](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170),
[Detours transactions](https://github.com/microsoft/Detours/wiki/Using-Detours),
[loader-lock restrictions](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices).
