# Explicit post-loader device observer

Implemented 2026-10-12; validated only in the startup-inserted disposable test
program on hardware and WARP. The containing production DLL has now passed one
passive BeamNG startup, but **this observer was not initialized in BeamNG**. This is
read-only observation of public D3D12 device creation, not rendering-pass capture,
automatic game-thread handoff or a lighting improvement.

## Activation boundary

In presence-only mode, the startup DLL's `DllMain` only validates its payload, restores
Detours' import edit and signals a receipt. It does not call observer Start, load
a runtime, install graphics hooks or create a thread/device. The DLL contains
observer exports, but they stay dormant unless the host explicitly invokes them.
Binary inspection still shows only `KERNEL32.dll` as a runtime DLL dependency.

Update: [opt-in native-entry rendezvous](ENTRY_RENDEZVOUS.md) adds a narrowly
scoped EXE-entry detour during attach, with its callback executing later. This
is not a D3D12 hook or observer initialization in DllMain. Production remains
passive; automatic observer initialization has passed only in known fixture
entry callbacks before EXE static-constructor device creation. BeamNG thread
quiescence and activation remain unverified.

Separate alternative: the new [image-scoped import observer](IMPORT_OBSERVER.md)
uses an atomic main-EXE import pointer rather than this instruction detour.
Its disposable named/ordinal hardware/WARP tests passed; it does not change the
quiescence requirements of this API or capture. A subsequently authorized BeamNG
startup observed one actual returned device candidate through that separate route;
see its dated live evidence. This process-wide instruction observer remains dormant.

`BeamRT_DeviceObserveStart` must be called **outside loader-lock work**, after the
host has loaded `d3d12.dll` and before the device calls it wants to observe. It
takes a lifetime reference to that already-loaded module and hooks its public
`D3D12CreateDevice` export with the exact SDK calling convention. It does not
create another device or select an adapter. All target/trampoline and control/
query callers must be externally quiescent throughout installation/removal;
`apiCallersQuiescent=1` is an assertion, not proof. The transaction enlists only
the control thread. API callback counters and a metadata lock do not establish
safe game-thread suspension or loader-lock freedom.

The fixture provides this condition by calling Start from its real application
entry point after loader completion, owning all creation calls, and joining its
test thread before Stop. **BeamNG has no verified callback that invokes this
initialization.** Merely inserting the DLL does not activate observation. No
automatic delayed thread, Present/timer-based assumption or Lua sandbox change
has been added to bridge that gap.

## Observed device and lifetime

- Every intercepted call is forwarded with unchanged adapter, requested minimum
  feature level, interface ID and output address. Its original HRESULT/output
  are returned. Failure and null-output capability probes are counted, not
  turned into invented device references.
- A successful real output is queried through public COM interfaces. The
  observer retains the actual `ID3D12Device` and canonical `IUnknown` identity,
  records its adapter LUID and the **requested minimum** feature level, and
  checks device removal. This is not a maximum-capability or render-device claim.
- Repeated creation on one adapter can return the same singleton, including a
  different requested interface. Canonical identity deduplicates it. A second
  distinct device or unexpected API-calling thread makes the observation
  incomplete; native calls continue unchanged and acquisition refuses to
  publish even the previously seen device. Metadata changes are serialized.
- Query returns ABI-v1 creation counters, HRESULT, thread and session generation.
  `cameraVerified`, `resourceStateChainVerified`, `gpuOrderingVerified` and
  `lightingConsumed` always remain zero. These are not frame IDs or GPU fences.
- Acquire requires a complete current session and exact expected generation. It
  transfers one COM reference and clears its output on rejection. It neither
  enumerates earlier resources nor discovers a game rendering queue.
- Stop requires the original control thread, explicit quiescence and no active
  callback. Failure retains the session and hooks. Success detaches first, then
  releases device/runtime ownership outside the metadata lock. Runtime ownership
  outlives the retained COM references. No DLL-exit cleanup or hot-unload promise
  is made; callers must keep bootstrap code loaded until safe detachment.

The API trusts valid live native interfaces and the owned host's lifecycle
assertions. It is not a security boundary for fabricated pointers or a cure for
incorrect quiescence assertions. Device singleton identity does not establish
which view, resource, shader or frame BeamNG uses for GI.

## Disposable-process verification

The startup host actually inserts the bootstrap into `beamrt_device_fixture.exe`.
The fixture then explicitly calls Start from `wWinMain`, creates real D3D12
devices through the normal public API and writes its own report. The same private
job harness binds that report to its retained child handle, checks the actual
exit code and drains all processes. The runner constructs only its own fixed
fixture paths; no BeamNG executable is accepted or launched.

Both hardware and WARP runs passed nine behavior groups (mask 511):

1. Explicit activation/no-device-ready guards and actual public-export detour.
2. Actual returned device identity, LUID and requested minimum feature level.
3. Unchanged capability-probe and unsupported-interface HRESULT/output behavior.
4. Singleton identity across repeated/differently requested interfaces.
5. A real resource's owner matches the acquired device; caller references survive
   observer detachment.
6. Duplicate activation, stale generation, missing quiescence and wrong-thread
   Stop refuse without removing the active session.
7. A joined non-owner creation caller makes observation incomplete, with unchanged
   native probe behavior and refused acquisition.
8. Restart has a new generation; another hardware/WARP device makes identity
   ambiguous and publication fails closed.
9. Stop restores the original first five bytes of the **known public export**;
   a subsequent normal API call returns its original result. No private engine
   code/offset is inspected.

The bootstrap submits no GPU commands. The target creates an upload buffer for
owner verification but no rendering queue, shader, visibility pass or GI frame.
No camera, scene geometry, game resources or live-game behavior is validated.
Strict builds and the full Python/Lua source suite pass **157/157**. Startup
presence/failure tests remain separate and capture/GI adapter code is unchanged.

Explicit disposable device test (not game deployment):

```powershell
./native/startup/build.ps1 -RunContractTests -RunDeviceTests
```

The hardware/WARP ambiguity tests require an available hardware adapter as well
as WARP. Remote CI compiles the dormant observer and runs source/no-launch tests;
it does not initialize the observer or run a game.

The entry rendezvous now supplies a controlled post-loader callback, and its
passive BeamNG startup/menu/normal-exit path passed once on 2026-10-12; see the
[exact-build live evidence](ENTRY_RENDEZVOUS.md#actual-passive-beamng-startup-evidence--2026-10-12).
The next required boundary is a policy that really establishes hook-installation
thread conditions in BeamNG. The passive entry-only game probe did not establish those
graphics conditions; only a separately reviewed graphics observation can establish
actual device/pass identity. Render-target/CBV lifetimes, shader/root bindings,
submission ordering and one real GI consumer remain additional requirements.

Primary contracts: [D3D12CreateDevice, probes and adapter singletons](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-d3d12createdevice),
[Detours calling conventions and thread enlistment](https://github.com/microsoft/Detours/wiki/Using-Detours),
[loader-lock restrictions](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices).
