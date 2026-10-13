# Image-scoped D3D12 creation observer

Implemented directly in the PC's unpacked BeamRT folder on 2026-10-12. This is
a separate opt-in creation-observation route, not capture/GI integration. The
earlier passive BeamNG startup did **not** test this observer or the new binary.
The user subsequently authorized one observation-only BeamNG startup; its actual
creation receipt, menu confirmation and normal shutdown are recorded below.

## Narrow activation without an invented quiescence assertion

Read-only inspection of the installed 0.39.4.0 build 20972 EXE found a normal
`d3d12.dll` import whose ordinal resolves to the installed public
`D3D12CreateDevice` export. The existing process-wide device observer requires
externally proven all-caller quiescence for instruction detours. That condition
is still unavailable in BeamNG and is not inferred from entry or counters.

This separate route changes **one aligned import pointer in the main EXE**.
Public PE import enumeration matches the loaded `d3d12.dll`, resolves named and
ordinal imports against its named public export, and requires exactly one slot
already containing that function pointer. Missing, ambiguous, pre-replaced,
unaligned, outside-image and unsupported-protection slots refuse activation.
No game offset or production ordinal is hardcoded.

An atomic compare/exchange swaps only the pointer and records restoration of
the page's prior protection. No D3D12 export instructions, trampoline, vtable or
other image's import is patched. No thread is suspended/enumerated. Concurrent
third-party page-protection changes are unsupported; pointer identity conflicts
are refused. This does **not** establish quiescence for the unchanged capture
module or process-wide device observer.

The entry callback installs only after successful one-shot entry restoration,
outside DLL attach, and only with the separate versioned payload.
`--observe-device-import` defaults OFF and requires `--entry-rendezvous`.
Reviewed hashes and native-insertion acknowledgement are still mandatory for a
new-child launch. Review mode never creates a process or loads the DLL.

## Forwarding, identity and deliberately bounded retention

The wrapper preserves adapter/minimum feature level/IID/output arguments,
native HRESULT/output and native thread LastError. It creates no device, queue,
shader, command list or GPU workload. Probes/failures are counted, not converted
into device references. One real output device/canonical IUnknown is retained;
removal, unsupported output, counter overflow or another distinct device
invalidates acquisition. Multiple caller threads are serialized for metadata,
not treated as proof that callers are quiescent. Acquire checks current PID and
a complete, enabled candidate. Candidate identity is not render-device selection.

Disable must run on the original control thread. It restores the slot only if
it still points to this observer; a changed slot is not overwritten. Successful
OFF records pointer/page restoration and disables acquisition/new updates. The
original function, runtime lease, one device/identity and bounded heap metadata
remain until process exit. A saved old callback can still forward after OFF.
There is no restart, zero-counter reclamation, dynamic image unload or hot-unload.
Retention can delay device destruction; it is not a resource-retirement policy
for future game frames. The GI adapter's fence rules are untouched.

## One immutable first-candidate receipt, not live coverage

Two additional anonymous inherited handles carry an event and typed CPU mapping.
Payload size/ABI/magic/PID/initial-thread/handle/reserved checks are mandatory.
After the first actual candidate or terminal failure, the DLL writes one immutable
receipt, signals it and closes its handles. Probes alone do not certify a device.
The parent validates that sample or reports refusal/timeout, retaining a resumed
child. Later ambiguity invalidates the in-process Query/Acquire state **without
rewriting the initial receipt**. The parent sample must not authorize later GI use.

Camera, resource-state, GPU-ordering and lighting-consumption flags remain zero.
Calls before installation, cached direct pointers, GetProcAddress and other
images can be missed. No existing resource/descriptor is discovered. Steam
compatibility beyond this one startup, mitigation behavior and complete game-call
coverage remain unverified; no lighting difference is expected from observation.

## Verified disposable-process evidence

Strict builds and all **5** import cases passed: named hardware/WARP, ordinal
hardware/WARP and missing-import refusal with the original application exiting
normally. Each hardware case uses the RTX 4070. Every owned child exit was checked
and every private job drained. Reports are retained under
`.beamrt-validation/native-startup/process-tests-780-2391233578/`.

The fixture creates a real device in an EXE static constructor before wWinMain;
it never calls Start. It verifies candidate/device/upload-resource ownership,
original HRESULT/output/LastError, rejected acquisition, additional caller
threads, distinct-device ambiguity, unchanged public-export bytes, refusal to
overwrite a changed import, concurrent calls through disable, actual pointer
restoration, a saved old callback executed after OFF, frozen counters and retained
caller references. Each reports 11 behavior groups (mask 2047) and seven guards.
The test-only ordinal import library mirrors the observed installed export and
refuses a runtime where it does not match the named API. Production has no ordinal
constant. These runs are not debug-layer-clean or live-game rendering evidence.

```powershell
./native/startup/build.ps1 -RunContractTests -RunImportTests
```

No-launch option/payload checks reject 26 cases. CI builds and runs source/no-launch
guards only, not game insertion. Existing entry/process-wide device fixtures also
passed; native capture, GI and Lua/HLSL rendering remain unchanged.

## Actual BeamNG creation receipt — 2026-10-12

After explicit user approval, the production host created game PID **50968** at
17:53:27 MDT. No existing game was attached. The target was the installed
0.39.4.0 x64 build 20972 EXE, with game-root working directory and no application
arguments. Separate `--entry-rendezvous --observe-device-import` flags and both
reviewed hashes were supplied. Launcher PID 29400 exited with code **0** after
validating DLL attach, restored entry and the import observation receipt.

The receipt records a real returned device candidate from the main EXE's import
slot RVA **0x1ce75f0**, caller thread **83652**, with **one device result**. The
parent requires successful installation, restored page protection, a complete
first candidate and zero camera/resource/GPU/lighting proof flags. This is an
actual in-game creation output, not an offline fixture or adapter-LUID-only probe.
It does not establish that the candidate owns the game's later rendering pass.

Same-PID read-only inspection found the fixed audit-copy DLL plus system D3D12/
DXGI/D3D12Core modules. The game log reports RTX 4070 D3D12 and startup in **2.09
seconds**. The user confirmed the main menu and then closed the game normally.
The log records shutdown, last written at 17:57:17 MDT; at 17:58:19 MDT both PIDs
were absent and no BeamNG process remained. No force-close or live hook removal
was attempted. A numeric game exit code was not retained. Native capture/GI and
additional GPU work remained OFF; no map, lighting A/B or GI resource capture ran.

Tested SHA-256 identities:

- Game EXE: `5a0420b44da74c3aa5388e460b602fcaa2baefafe2a64c6bff7c29a9345a2af2`
- DLL: `13eda1c2e9d649a02eec4f19c69955d435e33e50dbb763069a3aab426b57f2de`
- Host: `6bd208313a90451554fdbfb2898b31ccd2887f10ec33ed9a92881a47ab4f0408`

These exact binary copies, launcher stdout/empty stderr and before/menu/after
logs are retained in the ignored local directory
`.beamrt-validation/native-startup/live-import-362ec0b21cfa478c84c218f0c9e6ddc8/`.
The direct launch still reports Steam initialization error 1, also present in
the preceding passive direct-launch baseline. Steam/normal-route equivalence,
continuous device validity, game-specific OFF, hot-unload, gameplay stability
and live GI remain unverified. The full Python/Lua suite passes **161/161**;
all nine startup regression cases also passed with private jobs drained.

Primary contracts: [import enumeration](https://github.com/microsoft/Detours/wiki/DetourEnumerateImportsEx),
[aligned pointer compare/exchange](https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-interlockedcompareexchangepointer),
[64-bit Windows aligned access](https://learn.microsoft.com/en-us/windows/win32/sync/interlocked-variable-access),
[page protection](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect).
