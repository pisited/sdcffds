# Startup-connected GI recording observer

Implemented directly in the PC's unpacked BeamRT folder. The observer and
creation audit are now co-linked into the **same** production bootstrap. The
standalone fixture DLL remains separate; its globals are not used by this route.
No BeamNG launch, live binding capture, GI worker/capture activation, Lua/shader
change, sandbox change or native lighting result was made in this slice.

## Explicit opt-in / unchanged old contracts

`--observe-gi-bindings` requires `--observe-gi-creation` and a new `--bindings-out`
path distinct from the root output. It inherits the entry/import, binary/shader
hash and acknowledgement requirements. Optional `--bindings-wait-seconds` is
1–300 (default 30), after creation matching. Review remains non-mutating.
Existing output or incomplete options refuse before child creation; artifacts
use CREATE_NEW. Failures/timeouts never force-close a resumed child.

Binding transport has a separate GUID, 56-byte payload and three inherited
handles: output mapping, install event, first-record event. Total handle inventory
is exactly 12 in this mode, still 9/5/3/1 for older modes. PID, initial thread,
ABI/size, distinct non-null handles and reserved fields are checked. Pipeline
transport remains ABI v2; import/entry/default startup contracts are unchanged.

The initial binding payload was ABI 1. Current [thread diagnostics](BINDING_THREAD_DIAGNOSTICS.md)
use binding handoff **ABI 2** for the expanded shared reply; old payloads refuse.
Public status/snapshot/recording artifacts stay ABI 1. New thread sidecars are
fresh-output-only CPU evidence, not resources or GI. Frozen old live pairs retain
their original ABI and were not changed.

## Actual same-session routing

The imported-device callback releases its metadata lock before the pipeline
installer. After successful pipeline installation, the separate binding payload
starts command-list observation **before** the device output returns to the
application. A missing binding payload is a no-op; DllMain never starts it.

The first verified VS/PS/root creation sets a local notification marker. Only
after the creation audit's metadata lock releases does it notify the binding
bridge. The bridge releases its own lock before calling the internally co-linked
ReadMatch/SDK decoder/target setup. Public TargetFromAudit still requires the
control thread. The internal verified-creation callback can run on the actual
creation thread, which may differ; it accepts no arbitrary target objects and
rechecks actual audit objects, supported layout and same-device ownership.
Start/OFF ownership and one-recording-thread-per-generation policy are unchanged.

The embedded decoder resolves the named public deserializer from an **already
loaded** d3d12.dll and pins that runtime. It does not import/link D3D12 into the
default-passive bootstrap or explicitly load another DLL. Dependency inspection
confirmed KERNEL32.dll only. These are narrow startup/callback policies, not
proof of loader-lock freedom, all-caller quiescence or general game compatibility.

## CPU receipts only

Install and first accepted recorded-draw regions are separately immutable and
signalled. The latter carries PID, recording thread, status and the 1008-byte
metadata snapshot. The host checks ABI/extent/identity, healthy target state,
serial agreement, counts, finite viewport bounds, CBV alignment, table/heap
alignment/ranges/overflow, CPU-handle arithmetic and zero resource/camera/GPU/GI
proof flags before writing the full receipt. These are transport/recording checks,
not descriptor-content or GPU validation. Atomic progress is diagnostic only.

This first recording can already be historical when read. Generation/serial are
CPU bookkeeping, not a frame key or completed fence. No live SRV/RTV provenance,
CBV contents, camera meaning, queue/resource-state chain or GPU consumer ordering
is established. It cannot become BeamRTGIInputs or authorize worker consumption.
The old capture quiescence and GI final-consumer fence retirement rules stay intact.

## Verification and deployment hold

Strict builds pass. No-launch checks reject **90** option/payload/record-shape
cases, including 37 malformed recording snapshots. Python/Lua suite: **197/197**.
Seven owned startup cases pass: hardware/WARP first recording, worker-thread
creation, no-draw timeout, unsupported-layout refusal, default-off and existing
output preservation. Fixture GPU readback remains 23; parent metadata is compared
byte-for-byte with the fixture's real snapshot. All private jobs drain and actual
child exits are checked. These are fixture resources, not a new BeamNG result.

Earlier normal-host import/binding reports:
`.beamrt-validation/native-startup/process-tests-19744-2411863937/` and
`.beamrt-validation/native-startup/process-tests-71744-2411870984/`.
The broader matrix also passed on a fixed artifact set with fixture-only loader
inspection enabled for the hardware import case. That is not a substitute for
the original normal-host path; the latter was restored and passed separately.

**Deployment remains on hold:** earlier full-matrix runs stopped at the legacy
hardware import fixture before a startup receipt, with `0xc0000135` (DLL lookup
failure). The unmodified fixture loads, and rebuilt normal-host suites pass, but
the earlier cause is not established. Failed report directories include
`process-tests-34944-2409281796/` and `process-tests-85048-2410120078/`.
An exit/status diagnostic was added to the production host. Import-table inspection
exists only in the disposable fault host and reads only its newly created,
suspended, explicitly named fixture. It is not an existing-process/game inspector.
Do not call this loader failure fixed or the new build game-validated.

Earlier normal-host build hashes (not the previous successful live build):

- Host: `7caa825620524b7a0401016deec2ad669b84e6255f4648ccabe0a53cd9bc0736`.
- Bootstrap: `664dd0c9138933c24f75e7acc345f8bf9e3349c4ce017500e5849a38c9bb663c`.

Update 2026-10-13: [loader evidence preservation](LOADER_EVIDENCE.md) now keeps
exact input copies, SHA-256 manifests, per-case commands, host logs and exit codes
before a rebuild can replace them. The original preserved 35-case matrix and a
fresh 37-case matrix passed; the latter includes a deliberate missing-dependency
control. It validates the diagnostics, not the cause of the earlier anomaly.
That document records the new artifact hashes and report paths. Deployment stays
held; no game launch or live binding observation was made.

## Separately authorized live diagnostic — 2026-10-13

The user subsequently explicitly approved one bounded game observation despite
the unresolved historical loader failure. On the frozen `4eef9113...` host /
`3e630fa0...` bootstrap, West Coast USA and usual BeamRT GI loaded normally.
The host captured the exact GI creation/root and a **real four-vertex
DrawInstanced recording**, 1280 x 676 viewport, one output. The 1,144-byte ABI-v1
receipt validated, with descriptor/CBV/camera/GPU-order/lighting flags all 0.
Host and game exited **0**, the latter through the retained actual-child handle
after user-controlled normal closure. No native GI/light contribution changed.

Evidence and exact boundaries:
`.beamrt-validation/native-startup/live-bindings-b947f884a7064163aa40e599257ca210/RESULT.md`.
This is live CPU recording evidence, not game resource contents or GPU completion.
The accepted receipt also reports **3,187,134 thread-guard rejections** and 8
unsupported observations across other tracking. That exposes a real coverage
limitation; we have no per-call attribution or performance proof. Investigate it
offline without weakening the fail-closed thread/state rules. The loader anomaly
did not recur, but its cause is not established and the general deployment hold
is not removed by this separately authorized diagnostic.

Subsequent offline hardening: [thread-rejection snapshot isolation](THREAD_REJECTION_ISOLATION.md)
fixes one confirmed defect without relaxing the thread guard. A rejected call on
an unrelated list no longer erases another list's accepted receipt; its own source
still invalidates immediately. Red/green RTX/WARP regressions, 198/198 project
tests and the seven startup-connected cases pass. The successful live build was
not modified; new candidate hashes and remaining boundaries are recorded there.

```powershell
./native/startup/build.ps1 -RunContractTests -RunBindingStartupTests
```

Next: investigate thread-guard traffic/coverage offline, establish descriptor
and CBV provenance/content, and keep the loader anomaly separately open. Any new
game probe requires another reviewed frozen artifact set and approval. The actual
recording receipt does not establish correct lighting or GPU visibility use.

The offline attribution slice is now implemented and passes 201/201 project
tests, RTX/WARP ledger tests and 11 startup cases on rerun. A pre-attach loader
failure also recurred and its exact input set was preserved; subsequent passes
do not diagnose it. See the diagnostic document for both outcomes and the hold.

Primary contracts: [root deserializer / dynamic access](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-d3d12createversionedrootsignaturedeserializer),
[aligned atomic data-slot exchange](https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-interlockedcompareexchangepointer).
