# Disposable startup loader evidence — 2026-10-13

This is test infrastructure in the installed unpacked BeamRT source, not a new
BeamNG deployment or rendering feature. The production launcher, bootstrap,
observer and GI retirement contracts were not changed in this slice. No game
was launched, and no game settings, Lua or HLSL were modified.

## Retain failures before rebuilding

Every disposable process suite creates a fresh `process-tests-*` directory and,
before its first child, preserves its EXE/DLL/shader inputs under `inputs/`.
`inputs.sha256.tsv` records the original physical source path, copy path and
SHA-256. Each copy and its source are checked against the pre-copy hash. Capture
fixture VS/PS files outside the startup directory are included when available.
These files are evidence, not alternate binaries selected for execution: tests
continue to use the original artifact paths and normal production host.

Each case also retains:

- `<case>.command.utf16`: exact host command, raw little-endian UTF-16, no BOM.
- `<case>.host.log`: combined host stdout/stderr, including pre-attach failures.
- `<case>.host-exit.txt`: actual host exit code, separate from fixture reports.
- Existing child reports, completed-exit files and root/binding receipts.

The fixture harness redirects only its owned host's standard streams, inheriting
only the log and NUL input handles through an explicit handle list. It reuses the
test console rather than adding a new console. The production host's separate
1/3/5/9/12-handle child transport is unchanged. Fresh logs use CREATE_NEW; no old
evidence is overwritten or deleted. Snapshots and logs alter fixture I/O/timing;
passing this instrumented harness is not proof about an earlier cold-loader run.

## Controlled refusal, not a diagnosis of the earlier anomaly

`loader_missing_fixture.cpp` imports one intentionally absent test-only DLL. Its
import library is built, but the dependency DLL is never built or installed.
`--loader` first runs the normal hardware import fixture, then inserts the same
normal production bootstrap into this newly created disposable control.

The control must produce no startup receipt or child-entry report. The test checks
host exit 2 and the host's actual retained-child status `0xc0000135` in the log,
then verifies the private job drains. It does not claim to independently retain
a second child handle after that rapidly terminating process has disappeared.
The host itself queried the handle returned by its own CreateProcess call.
No existing process, game executable, graphics work or external diagnostic tool
is involved. This intentionally generated missing dependency is **not** evidence
of which dependency failed in the earlier intermittent import-fixture run.

```powershell
./native/startup/build.ps1 -RunContractTests -RunLoaderTests
```

## Verified scope

Before these harness changes, the preserved previous artifact set passed the
original **35-case** matrix on the normal host path. A fresh strict build then
passed **37 cases**: startup 9, device 2, entry 4, loader evidence 2, import 5,
pipeline 8 and startup binding 7. RTX 4070 and WARP cases retained the existing
output and refusal checks. All private fixture jobs drained. The source/Lua suite
passes **197/197**. No debug-layer-clean or live game binding claim is made.

Fresh full-matrix reports under `.beamrt-validation/native-startup/`:

- `process-tests-14128-2413791796` — startup.
- `process-tests-43872-2413812968` — device.
- `process-tests-76708-2413816812` — entry.
- `process-tests-61912-2413830406` — loader evidence.
- `process-tests-81712-2413832453` — import.
- `process-tests-46664-2413839765` — pipeline.
- `process-tests-82564-2413851328` — startup bindings.

PowerShell independently verified all **147** preserved copies (21 per suite)
against the manifests and unchanged sources. Raw invocation evidence retained
the actual Unicode and empty arguments. The deliberate refusal log retained
`0xc0000135` and no child-entry report. A later harness-only text-mode replay fix
removes doubled CR characters from console display, without changing saved logs
or production binaries; loader/import/binding suites were rerun after that fix.

Those follow-up reports are `process-tests-45076-2414053093` (loader),
`process-tests-10172-2414055093` (import), and `process-tests-68972-2414062437`
(startup bindings).

Production artifacts tested by this fresh matrix:

- Host: `4eef91138f2743b443bb80de21d0e26681dad02ae594a4d789b0d24dad2211c2`.
- Bootstrap: `3e630fa04a499ccaccfba6fb372d88a161f9b104de29ed80814afd7955b862ac`.

**Deployment remains held.** The earlier non-control failure has not reproduced
and its cause is still unknown. These additions preserve useful evidence for the
next occurrence; they do not fix or explain it. Do not launch another game test
while the user is unavailable. A later live probe requires its own reviewed
frozen artifact set, approval and normal user-controlled map/GI/shutdown steps.

Primary handle contracts: [explicit inherited handle list](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute),
[CreateProcess and startup handles](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).
