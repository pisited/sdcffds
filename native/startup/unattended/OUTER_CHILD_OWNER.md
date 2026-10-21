# Independent child ownership: disposable fixtures only

This is a separate outer-owner implementation and native host participant, not
an approved unattended BeamNG runner. The native outer mode accepts only the
named disposable startup fixtures; game execution is unavailable. No native
GI, GPU dispatch, render-resource integration, shader activation or lighting
change is enabled. Importing the Python module or including the native header
does not start anything.

This work does not update the older protected-runner profile, frozen candidate
or binary pins. Those remain separate evidence. A future game candidate still
requires a complete reviewed integration, fresh immutable inputs and explicit
launch authorization.

## Why the owner is outside the native host

The outer process creates the exact child suspended and retains its original
process/thread handles privately. It starts its watcher before creating the
native host. The host receives only reduced setup capabilities for that
already-owned child. There is no interval in which an independently created
host child must first export its master handle to gain outer protection.

The normal path is:

```text
Outer creates suspended child and starts watcher
  -> host receives five reduced inherited capabilities
  -> host requests IPC relay; outer relays to its exact child
  -> host finishes setup and requests execution release
  -> outer releases its original thread and returns the actual result
  -> host reports core completion; outer still owns shutdown and exit checks
```

A host crash before release leaves a never-executed suspended child for the
outer owner to clean up. A nonzero host exit or host-observation failure after
a release attempt requests normal stop, then observes the full configured
grace before any authorized force attempt. A hung host cannot reset the
creation-origin overall deadline. A successful host exit does not itself
request stop: it must not preempt the Lua controller's later CPU-receipt ACK.

This protects against failure of the native host, not failure of the outer
process. The outer process, its watcher, the OS and scheduler must remain
functional. Process creation, handle operations and callbacks are not
hard-real-time operations. A blocked or failed outer API/policy operation can
still prevent cleanup; unknown/error reports are not converted into exit
proof. No further supervisor or job-object kill-on-close layer is claimed.

## Source and explicit APIs

`outer_child_owner.py` provides `OuterChildOwner.create(...)`. Ordinary
construction refuses. The explicit factory requires an executable, exact
argument vector and working directory, lowercase run token, configuration
digest, known IPC count, bounded overall/grace settings, explicit force policy
and a normal-request publisher. Production uses the real Windows backend and
watcher; injected backends/clocks or suppressed watchers are test seams only.

The returned owner offers:

- `prepare_host_capabilities()`: one-shot creation of the fixed shared channel
  and reduced inheritable duplicates, before the native host exists.
- `launch_host(...)`: creates and retains its own host with an explicit
  five-handle inheritance list, no shell, and internally supplied channel/digest
  options. An existing host or caller-supplied channel override is refused.
- `await_setup_and_resume(...)`: validates the relay and setup phases, retained
  child identities and deadlines, then releases only the original child thread.
- `request_stop()`, `report()`, `finish()` and `close()`: exact-child policy and
  report access. Closing does not discard a still-running watcher.

`outer_child_session.h` supplies the host-side `OuterChildSession`:

```text
OuterChildSession(mapping, token, expectedDigest, expectedExe,
                  overallSeconds, graceSeconds, expectedIPCcount)
Setup() -> caller-owned reduced PROCESS_INFORMATION duplicates
RelayIPC(localHandles, count)
ChildValue(localHandle) -> child-local relayed numeric handle
Resume() -> outer owner's actual previous suspend-count result
Complete(coreResult)
Fail(error) noexcept
ProcessId() -> cached validated diagnostic child PID
```

The header owns the original five inherited handles and closes them on
destruction, including validated handles on constructor refusal. `Setup()`
duplicates only into the current host; its caller owns those duplicates.
Destruction only closes handles. It does not execute child cleanup, wait for
exit, signal success or silently release execution.

The native launcher selects this participant only with both
`--outer-owned-channel` and `--outer-config-sha256`, all five existing owned
options, and no host-owned receipt-wait option. The target basename must be
`beamrt_startup_fixture.exe` or `beamrt_binding_startup_fixture.exe`. The old
manual and host-owned branches are retained. The outer branch translates every
payload handle through `ChildValue`, reports core completion/failure, and does
not enter the host's direct termination branch.

These APIs do not infer authorization from their options, PID fields or digest.
The digest joins explicit reviewed configuration bytes; it is not an
authenticated process capability or human permission.

## Capability boundary and fixed IPC relay

Only the outer factory holds the original child masters. The host's inherited
capabilities are:

| Capability | Rights available to the host |
| --- | --- |
| Child process setup | VM operation/read/write, process query information, synchronize (`0x100438`) |
| Child thread setup | Thread query information, synchronize (`0x100040`) |
| Shared 512-byte channel | Mapping read/write (`0x6`) |
| Host-to-outer event | Event modify state (`0x2`) |
| Outer-to-host event | Synchronize (`0x100000`) |

The host has no child process-duplication or termination right and no thread
execution-release right. The native participant contains no child creation,
execution-release, termination or PID-open API. It validates handle metadata,
nonzero/non-pseudo/unique inherited numeric values, process/thread identities
and the child's executable image. The reduced access masks originate in the
reviewed outer factory; ordinary public handle metadata is not an independent
enumeration of granted access.

The host cannot relay its own IPC handles into the child. Instead, it publishes
the exact local source IDs once. The outer owner uses its retained, actually
created host handle as the source process and its retained child master as the
target. It never reopens either process by a recorded PID. Only the known IPC
prefix counts `1, 3, 5, 9, 12, 14` are accepted. Child access is fixed by slot:

| Slots | Payload objects | Child access |
| --- | --- | --- |
| 0 | Startup event | Event modify state (`2`) |
| 1-2 | Entry event and output mapping | Modify event / write mapping (`2`) |
| 3-4 | Import event and output mapping | Modify event / write mapping (`2`) |
| 5 | Pipeline input mapping | Read mapping (`4`) |
| 6-8 | Pipeline output mapping and two events | Write mapping / modify events (`2`) |
| 9-11 | Binding output mapping and two events | Write mapping / modify events (`2`) |
| 12-13 | Resource output mapping and event | Write mapping / modify event (`2`) |

Repeated, pseudo, inherited-capability-aliasing or unused nonzero source slots
refuse. Remote child IDs must be nonzero, non-pseudo and unique within their own
table, with unused slots zero. A remote ID may numerically equal a host ID:
they belong to different process handle namespaces. These numeric tables are
not GPU resources, leases, execution-completion fences or exit evidence.

No PID reopening, name matching, process-tree selection or host termination is
implemented. The outer owner cleans up only the child it created. A hung host
is reported rather than being force-killed by this implementation.

## Shared channel ABI 1

The channel is exactly 512 bytes, little-endian, Windows x64. The C++ header
compile-asserts every field offset, alignment-relevant size and total size.

| Offset | Field |
| --- | --- |
| 0 | Eight-byte magic `BRTEXT1\0` |
| 8, 12 | Byte size `512`, ABI `1` |
| 16, 32 | Binary 16-byte token, binary 32-byte configuration digest |
| 64, 68, 72 | Child PID, thread ID, creation-origin tick |
| 80, 84, 88, 92 | Overall ms, normal grace ms, termination wait ms, expected IPC count |
| 96, 104, 112, 120 | Inherited setup process/thread and host-to-outer/outer-to-host event IDs |
| 128, 132, 136, 140 | Atomic state, resume result, core result, error |
| 144, 256 | Fourteen source IDs, fourteen child-local IDs |
| 368 | 144 reserved zero bytes |

The first 128 bytes are immutable. Token/digest, child identities, image,
limits and original handles must agree with the explicit host configuration.
Reserved bytes stay zero. Initial state is `0`; resume/core results are
`0xFFFFFFFF`; error and both handle tables are zero. The shared termination wait
is fixed at 5000 ms.

State transitions are `0` initial, `1` host IPC request, `2` outer IPC grant,
`3` host setup ready, `4` outer execution grant, `5` host core complete, and `6`
failure. Aligned state publication and event signaling order the CPU handoff.
Both sides reject changed identity, fields/tables outside their phase, skipped
or repeated phases, and unknown context. State `5`, a successful resume result
or an event notification does not prove child exit. This channel is not the
capture ABI, GI adapter contract, camera proof or GPU-completion contract.

## Clocks, grace and exit proof

The owner records monotonic creation origin and the native-compatible tick
before actual child creation. The watcher already exists before the host is
launched. Host launch, map readiness, draw collection and ACK publication do not
reset that origin. The native participant bounds relay/grant waits using the
channel's original creation tick and retained child handle, not a fresh timeout
per retry. The overall limit is at most 480 seconds and normal grace at most
30 seconds; the native configuration additionally requires whole seconds.

Before any release attempt, failure can clean up only the never-executed
suspended child. After a release attempt, including a failed or unexpected
release result, policy conservatively uses normal-stop attempt plus full grace.
The normal publisher runs separately, so blocked file publication does not
hold the policy's grace clock. Queue acceptance, publication completion and
publication success are distinct report fields. Grace starts at the request
attempt, not engine delivery: a delayed or failed file publication may give
the engine less time or no opportunity to respond. No delivered-response grace
guarantee is claimed.

Only explicit force authority permits a force attempt after grace. Natural
exit prevents it. Exit observation errors block release and force decisions
and remain unknown. A successful force API call alone is not verified exit:
the retained process handle must become signaled and its exit-code query must
succeed. Exit code `259` is valid only after that signaled wait. Reports retain
separate normal-attempt time, force-attempt time, call outcome and actual exit
evidence so the grace interval can be audited.

## Verification status

- The deterministic outer-owner suite passes 37 tests, including
  fixed rights/relay, malformed phases, host crash/hang, delayed normal
  publication, full grace, natural exit, failed watcher creation and unknown
  exit evidence. Controlled post-Create failures retain an owner capability
  when exit is unconfirmed; they cannot silently discard the master handles.
- The coordinator suite passes 25 tests, including unchanged-review gating,
  fixed pins, exceptional cleanup, diagnostic I/O failures and lock retention
  while child/host/publisher completion is unknown.
- The new static native session suite passes 12/12. These
  are source regressions, not Windows runtime permission or cleanup evidence.
- The production and fault hosts compile under strict MSVC
  `/W4 /WX /EHsc /std:c++17 /MT`. The no-launch host self-test rejects 229
  unsafe option/payload cases. Existing host-owned 27 cases / 1632 assertions
  and original manual startup's nine disposable cases still pass.
- All seven real outer-owned Windows process cases pass: cooperative stop,
  abrupt host exit before/after resume, and bounded host hangs before/after
  resume with cooperative or ignored normal requests. In the ignored-quit
  hang, normal request occurs at 2000 ms and force at 3000 ms, with the host
  still alive at verified child exit. No host is terminated by this owner.
- The complete 14-IPC WARP fixture also passes with the same outer owner:
  entry/import/pipeline/binding/resource receipts, pinned full ABI7 validation,
  actual child ACK consumption, and independently verified child0/host0 exits.
  No normal-stop request or force occurs. The original run is
  `.beamrt-validation/ocw-897ced01a4bf/`; its review-first coordinator is retained
  in the current evidence directory, not installed as a game launcher.
- The project suite passes 724 tests (722 passed; two expected Windows symlink
  privilege skips). All 252 installed Lua/HLSL inputs and their full inventory
  match the earlier frozen source; 4283 prior evidence manifest rows match.
- No BeamNG startup, world loading, native GI or lighting test is covered here.

The retention diagnostic threshold is not a lock-release deadline. On an
unconfirmed child/host exit or still-running normal publisher, the coordinator
retains the same capabilities and input locks and continues read-only exit
observation. It does not promise a bounded host shutdown or bypass unknown
liveness with PID lookup, host termination or process-tree cleanup. Abrupt
outer-runner or OS failure remains outside this contract.

Current combined evidence is under
`.beamrt-validation/outer-child-8a037eeb9c344631bf11c24fa4083fdb/`, with the
seven-case original run under `.beamrt-validation/oc-381fab91d472/`.

### Native empty-directory lease repair

The native stop-channel retention mask now includes `FILE_LIST_DIRECTORY`
alongside attributes/synchronization access and omits delete sharing.
Attributes-only access had allowed the empty preclaim run directory to move.
The new private fixture seam retains the same native state before
`CreateClaim`, without creating an event, publication worker or host claim.

The recorded strict MSVC file-only run passed 16 cases / 395 assertions,
including real empty-run and ancestor rename refusal, zero host claims, release
of both leases, and successful move/restoration of both exact fixture paths.
Five additional runs passed all 16 cases; assertion totals vary with bounded
publication polling. Existing real junction-refusal coverage remains present.

A frozen negative control removes only `FILE_LIST_DIRECTORY`. It compiles but
fails exactly at `retained empty preclaim run directory could be renamed`.
That demonstrates the new test detects the original access-mask defect rather
than relying on a run directory already populated by claim/context files.

Local ignored evidence is retained under
`.beamrt-validation/stop-dir-lock-10865fdefd3a4c67a0e5205f6c5d84ca/`:
`RESULT.md`, `source-final.sha256.csv`, `build-repeat.log`, `repeat-five.log`,
and `negative-build.log` / `negative-run.log`. No fixture evidence was deleted.
This establishes the tested local file-handle/rename behavior, not general
filesystem adversary protection or game-resource access.
