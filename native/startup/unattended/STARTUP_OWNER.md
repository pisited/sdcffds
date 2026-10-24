# Opt-in exact-owned startup host

This is host lifecycle integration, **not a ready-to-launch unattended BeamNG
workflow**. No game was launched while implementing it. The old default/manual
path is unchanged. No Lua shim invocation, engine autostart, receipt validator invocation,
native capture/GI work, or lighting change is enabled by these options.

For the new fixture-only mode that survives setup-host failure, see
[the outer child owner](OUTER_CHILD_OWNER.md). It supplies a separately created
suspended fixture through restricted inherited setup capabilities; this document
continues to describe the original host-owned lifecycle and its limits.

## Explicit contract

All five options must be provided together:

- `--owned-run-directory`: an existing physical absolute directory on a fixed
  local drive, without reparse components or preexisting runtime outputs.
- `--owned-run-token`: exactly 32 lowercase hexadecimal characters.
- `--owned-overall-seconds`: 1-480 seconds from immediately before actual process
  creation, not from map readiness or the first draw.
- `--owned-normal-grace-seconds`: 1-30 seconds from a normal-stop request attempt.
- `--acknowledge-owned-force-close exact-created-child-after-normal-quit`.

These are not human authorization. The existing explicit launch switch,
reviewed executable/DLL hashes and native-insertion acknowledgement are still
required. Default/review mode never creates a child, thread or run claim.
There is no `--pid` attachment or process-name selection. A frozen live test
still needs its own review and fresh user approval.

## Ownership and shutdown

`Create suspended -> publish exact PID context -> Detours setup -> owned resume
-> receipt observation -> normal-stop attempt -> grace/exit check -> final report`

The session creates the process itself and keeps the original process/thread
handles private. Setup receives duplicate process handles with VM/query/wait
rights only, and thread handles with query/wait rights only. They cannot resume
or terminate. Only the session resumes its private thread or force-closes its
private process. The observer may wait on a setup duplicate without transferring
ownership. The normal request receives a diagnostic PID only for the file join;
termination never reopens that PID.

A watcher services the lifecycle while the main host thread waits for startup,
entry, creation or draw receipts. Before any resume attempt, setup failure or
deadline can clean up only the never-executed suspended child. After any resume
attempt, the normal/grace policy applies. Core success, early failure, exception
and timeout all finish the same session. No automatic second launch occurs.

The stop channel atomically consumes `host-claim.json`, publishes exact context
and machine approval before resume, and refuses stale start/ack/event/stop/exit
files. It opens physical directory-component handles and rejects reparse
locations, flushes each file and publishes without replacement. Attribute-only
directory access has not established empty preclaim/ancestor rename protection:
new real Windows tests found LIST_DIRECTORY is needed. The protected fixture
runner supplies that stronger outer lock, but the native helper still needs a
repair and fresh tests before standalone/game use. The older nonempty-directory
fixture does not prove this preclaim guarantee. Context files
remain ordinary CRT-readable and retained against rewrite/delete.

The normal-stop callback performs only a one-shot atomic enqueue and event
signal. A prestarted worker owns its state while it publishes `owner-stop.json`;
neither the watcher nor channel destruction joins filesystem I/O. Queue success
is not publication or engine delivery. Grace is attempt-origin: if publication
is delayed or fails, the exact-owned child may be force-closed after that grace
without the engine ever reading the request. The final report distinguishes
these states rather than claiming a full response interval after delivery.

## Optional CPU-receipt rendezvous

The separate `--owned-receipt-wait-seconds 1-30` option additionally requires
all five ownership options, interned descriptor-only resource observation,
no CBV probe, and `--bindings-out <owned-directory>/recorded-draw.bin`.
It remains absent by default. Only successful core receipt collection publishes
the exact-schema `receipt-ready.json`, after all three bundle files are closed.
The channel flushes and publishes it without replacement and retains it against
rewrite/delete; it refuses stale final or pending ready files before creation.

The host then waits for its retained child's actual exit, an observation error,
an original-overall-deadline stop, or the additional <=30 second deadline.
It does **not** finish or publish owner-stop merely because an ACK exists. This
gives the Lua controller a chance to read ACK and request normal quit itself.
Failure/deadline returns17 after the unchanged normal/grace cleanup; core failure
does not publish ready or wait. This branch does not invoke the decoder, launch
a coordinator, install the shim, or claim ACK consumption from process exit.
The original creation-origin watcher remains active during publication/wait.

`receipt_handoff.py` is an explicitly called, bounded file join that delegates
to the existing pinned full decoder/publisher. The expected PID must be supplied
by the actual owner, not discovered from a raw receipt. Ready/context/approval
must match exactly; readable ready with an incomplete bundle is refused.
It publishes one CPU-validation ACK, never a shutdown or process-exit receipt.
Its polling bound excludes the decoder helper's separate20 second subprocess
bound, so the independent native overall deadline is still required.

The older core receipt/root writers still use ordinary Win32 artifact paths.
Use short runtime evidence paths: the owner's independently tested long-path
metadata support does not extend those legacy writers. An overlong root writer
path was refused during the disposable handoff test and its owned child exited;
that failure is retained separately from the succeeding short-path run.

## Final exit receipt

`owned-exit.json` is create-new, flushed, token/PID joined, and written after
session finish. Its `processExitVerified` requires a signaled retained process
handle plus a successful exit-code query. `forceCallSucceeded` is never exit
proof. Exit code259 is valid when the handle is signaled. Unconfirmed exit does
not become confirmed merely because the host is closing.

The receipt separates core return code, actual exit code, resume state,
normal-request outcome, live force attempt/result, never-executed cleanup,
pre-resume timeout, observation errors, and queued/completed/successful stop
publication. Publication timestamps use GetTickCount64; process timing fields
are elapsed since creation. Pending publication is an honest point-in-time
snapshot, not evidence that it will eventually succeed.

An existing core failure keeps its return code. Otherwise the host returns14
for unconfirmed child exit,15 for a force attempt,16 for a nonzero child exit,
or0 for a confirmed zero exit without force. Core insertion diagnostics saying
"retained" do not disable the owned watcher; the mode banner and exit JSON are
authoritative for this separate lifecycle.

## Verification and remaining limits

The fixed disposable fixture launches only named sibling host/child/DLL artifacts.
It tests ordinary stop, ignored stop, a watcher cutting short the main 15-second
receipt wait, pre/post-resume faults, nonzero exits, no-child review/refusals,
stale files and long evidence paths. The file-only fixture additionally tests
CRT readability, no-overwrite races, retained directories and actual junction
refusal. Fixture process-tree cleanup is limited to its own disposable job and
is not a production game-termination mechanism.

All pre-resume, OS, logging and mutex operations remain subject to Windows
scheduling and API behavior. This watcher is an independent host thread, not a
separate fail-safe process able to recover a hung/crashed host. Synchronous
pre-resume context publication can stall the host even though the watcher can
stop its suspended child. A protected outer coordinator now executes only fixed
disposable fixtures with held on-disk inputs and atomic attempts. Independent
outer exact-child cleanup and a newly reviewed live candidate remain unfinished.
The early engine shim
and validated-receipt file bridge now exist as explicit inactive components,
not an installed run. No live-game compatibility, resource reuse or rendering improvement
is claimed by these process tests.

Prior frozen manual artifacts are preserved. The installed launcher source has
intentionally changed, so an older runner pinning its previous source must refuse
rather than silently use the new code. A new reviewed candidate is required.

See `PROTECTED_RUNNER.md` for the now-implemented review-only argument plan,
fixture-only protected runner, separate host/native-reported child proof fields,
and explicit unknown-state behavior. No game execution is enabled there.
