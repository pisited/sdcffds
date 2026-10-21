# Unattended observation driver components (inactive)

These are **preparation-only, offline-tested components**, not a launch-ready
unattended test. Nothing in this directory is an active BeamNG extension.
Importing the modules does not launch the game, install hooks, read receipts,
start GI, or change settings. No game run was performed while preparing them.

The separate [outer exact-child fixture owner](OUTER_CHILD_OWNER.md) now moves
child creation, execution release and shutdown outside the native setup host.
It is a disposable-process safety experiment, not a game-enabled profile; the
older protected runner and its frozen binary pins remain separate and unchanged.

[Installed input coverage](INSTALLED_INPUT_COVERAGE.md) adds a whole-mod and
broad engine-source inventory with bounded multi-batch physical leases. Mutable
settings/cache state remains observational; full VFS/world closure and game
execution remain unavailable rather than being inferred from a manifest.

The intended future run is the existing **observation-only** startup experiment:
load West Coast USA, enable the usual Lua/HLSL BeamRT GI, collect one CPU draw
receipt, and request a normal quit. Native capture, native GI compute, resource
reuse, and new lighting contributions remain off. Calling the usual
`beamrt_main.start()` is deliberately part of that future test; it is not an
activation of the native GI adapter.

## What is implemented

| File | Explicit responsibility |
| --- | --- |
| `controller.lua` | Injected-API state machine; readiness, deadlines, GI start, acknowledgement joins, and a single normal-quit request. |
| `engine_adapter.lua` | Installed engine API adapter, fresh-run context checks, bounded own-run file I/O, and virtual event sinks. |
| `bootstrap.lua` | Explicit physical-source loading, context validation, controller arming, and event-sink registration. Importing it only returns a function. |
| `early_shim.lua` | Explicit early proxy and bounded API-readiness wait; immediate bootstrap when ready and fail-closed refusal of late mission attachment. |
| `receipt_ack.py` | Runs the hash-pinned, read-only ABI7 decoder against a complete CPU receipt bundle and publishes a no-overwrite acknowledgement. It cannot launch BeamNG. |
| `receipt_handoff.py` | Bounded ready/context join with an explicit owner-supplied PID; delegates to the pinned full validator/publisher once. No process control. |
| `startup_plan.py` | Pure, immutable game/native argv and one-line Lua declarations; generated native argv selects review, not launch. |
| `protected_inputs.py` | Held-handle input hashing/read protection, physical ancestor retention and atomic one-shot machine claim. No process operations. |
| `protected_runner.py` | Default review CLI; execution restricted to exact pinned disposable WARP fixtures. Game execution is unavailable. |
| `watchdog_policy.h` | Portable one-shot normal-request/grace/force decision policy, with explicit force permission and exit confirmation kept separate. |
| `owned_watchdog.h` | Win32 exact-created-process capability; private master handles and separate OS exit proof. |
| `startup_owned_session.h` | Explicit opt-in startup-host bridge; reduced-right setup duplicates and a concurrently scheduled lifecycle watcher. |
| `startup_stop_channel.h` | Fresh host claim, pre-resume token/PID context, and asynchronous one-shot stop-file publication. Queue acceptance is not delivery proof. |

The lifecycle is:

`unarmed -> waiting_ready -> starting_gi -> waiting_receipt -> quit_requested`

Errors and deadlines after a successful claim also request normal quit. A
returned quit call, including a nil return from the engine, does **not** prove
exit. If updates continue beyond the quit grace, the state becomes
`quit_unconfirmed`. The controller never reports `processExitVerified=true`.

### Readiness and limits

One `onClientStartMission` event must be observed. Readiness additionally requires
the exact expected level, mod-manager readiness, no current loading, freeroam,
and `worldReadyState == 2`. Both a stable time window and an actual
`onPreRender` frame delta are required before calling the existing GI start once.
There is no late-attach recovery if the mission-start event was missed.

The controller requires explicit bounded values; it has no hidden defaults:

| Setting | Allowed range | Offline fixture setting |
| --- | --- | --- |
| Load deadline | 1-300 seconds | 300 seconds |
| Receipt deadline after GI start | 1-120 seconds | 120 seconds |
| Overall deadline after arm | 1-480 seconds | 480 seconds |
| Stable readiness | 0.1-5 seconds and 2-60 whole frames | 2 seconds and 8 frames |
| Quit grace | 1-30 seconds | 10 seconds |

GI's requested Lua state must subsequently report enabled/`lighting` within the
shorter of 10 seconds or the receipt deadline. This is only requested-state
confirmation, not proof that a shader executed. Later readiness or GI-state loss
fails closed. Deadlines do not restart on readiness regressions. Engine update
callbacks cannot enforce deadlines while the engine is hung; an external owner
must enforce a separate wall-clock deadline beginning at process creation.

## Explicit run context, not implicit permission

A future reviewed owner must pass absolute physical source/run paths, a fresh
lowercase 32-hex token, and explicit controller limits. The engine starting
arguments must contain exactly one `-level west_coast_usa` and exactly one
matching `-beamrtObservationToken` argument. `startup_plan.build_plan()` now
generates those arguments and literal one-line Lua from an exact fixed schema.
Its native argv explicitly uses `--review`; declared hashes/physical paths are
not verified by that pure planner. There is still no game-execution command.

The adapter reads only bounded, exact-schema context files from the run directory:

- `launch-approval.json`: token, scope `beamrt-unattended-observation-v1`, and
  `allow=true`.
- `process-context.json`: token and positive uint32 `expectedPid`.

The PID must come from the future owner's **retained, actual test-child process**,
not from receipt contents or a process-name search. The adapter does not discover
or independently certify its own OS PID. A JSON approval file is a configuration
guard, **not human authorization** or an OS ownership proof.

Both validation and claim reject an existing `started.json`, `driver-ack.json`,
`unattended-events.jsonl`, or `owner-stop.json`. The Lua start marker checks write/close/read-back,
but portable Lua I/O does not provide atomic create-new or fsync. Therefore this
is only a best-effort replay guard under a serialized owner. Before any live
launch, the parent must enforce its own atomic one-shot attempt claim and fresh
directory, protect frozen inputs, and prevent concurrent/bootstrap retries.

The adapter registers virtual event sinks through the installed
`newExtensionProxy` API. It does not edit `package.path`, active extensions,
autostart, user settings, game installation files, or renderer sources. Missing
or foreign context refuses arming without requesting quit on an unowned game.

The explicit early shim accepts a 1-30 second API deadline, a physical
`bootstrapSourcePath`, and a nested `bootstrap` configuration. Import and factory
construction are inert. `arm(token)` installs hooks, then attempts bootstrap
immediately if the required APIs exist, otherwise waits on updates. Both proxies
enter `setExtensionUnloadMode(proxy.extName, 'manual')` in memory: the installed
freeroam loader otherwise unloads them, even with `__manuallyLoaded__`. No
persistent manual-load list or settings file is changed. Reentrancy, late mission
attachment and invalid/regressing clocks refuse; an already claimed returned
controller aborts normally rather than starting GI twice. A Lua call cannot be
interrupted by this deadline; a late return is checked afterwards.

The installed `-lua` parser queues code through native `LuaExecuteQueueString`;
the local Lua source does not establish when that queue drains relative to stock
map loading. A shim that runs too late deliberately refuses. Offline fixtures
therefore do not prove a usable queued startup sequence in BeamNG. The argument
builder is review-only; no automatic game invocation is enabled.

## Receipt acknowledgement boundary

`receipt_ack.py` requires an explicit expected PID and token. It pins the decoder
SHA256 to `0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804`.
It validates the exact 1144-byte binding record, 392-byte resource-start companion,
and 32768-byte resource companion through that decoder. Expected configuration
is resource transport ABI7, draw ABI5, interned profile2, descriptor-only mode1,
CBV probe bytes0, and all proof flags zero.

Validation must complete successfully, identity/configuration must match, and
the bundle bytes and decoder hash must remain unchanged across decoding. The
helper rejects malformed/duplicate/nonfinite JSON and existing output. It
publishes `driver-ack.json` by a same-directory atomic no-overwrite hard link,
cleaning up only its own temporary file. A domain-separated SHA256 joins the
acknowledgement to the exact validated bundle bytes. This is not an executable
file lock, hostile-filesystem security boundary, or power-loss durability proof;
the future owner still has to protect and serialize inputs.

The controller joins the acknowledgement to the expected token, PID, ABI,
profile, mode, probe configuration, and digest format. A valid numerical
**refused observation** can still be a validated receipt. Acknowledgement does
not mean resources were usable, GPU work completed, a camera was identified,
lighting changed, or the process exited. The helper does not infer success from
the mere existence of a receipt or log file.

## Approved owned-process shutdown fallback

The opt-in host receipt wait publishes `receipt-ready.json` only after all three
CPU bundle files close, then waits for actual retained-handle child exit, not
merely ACK publication. This prevents its ordinary `Finish()` from immediately
publishing owner-stop, which Lua intentionally polls before ACK. The original
overall watchdog continues throughout; the additional wait is capped at30 seconds.
`receipt_handoff.wait_and_ack()` checks exact context/approval/ready schemas and
fixed `recorded-draw.bin` size/paths before calling the pinned publisher. Missing
ready/sharing contention has a bounded poll; readable malformed ready or incomplete
bundle refuses immediately. The bridge's polling deadline excludes the decoder's
separate20 second bound. Neither ready nor ACK proves engine consumption or exit.

The user approved a narrow fallback: after a normal-quit request and its full
grace period, a watchdog may force-close **only the exact test process it
created**. This is not approval to launch a game, attach to an existing process,
kill a process by name/PID, terminate descendants, retry, or hot-unload a DLL.

For a claimed engine run, the future owner can publish `owner-stop.json` with
exact keys `token`, `expectedPid`, and `kind="normal_quit_requested"`. The adapter
checks this bounded file through the controller's existing reentrancy guard,
before readiness, deadlines, GI startup or receipt acceptance. A matching request
requests ordinary engine quit once, including during loading. Malformed or
unreadable stop data fails closed with a normal-quit request on that already
claimed run; it is not accepted as valid ownership data. An unclaimed run does
not poll the file or quit. No Lua code performs forced termination.

The native helper seals process/thread handles behind its creation factory.
Explicit configuration gates **live** forced termination. Setup failure before
any resume attempt has a separate, exact-owned never-executed suspended-child
cleanup path, reported through `neverExecutedCleanup*` fields rather than the
live force fields. It cannot target a previously running application.
The normal-request callback
runs at most once; returning false or throwing does not skip the grace period.
This primitive measures that grace from the request **attempt**, not from
callback completion or proof that the engine received it.
Forced termination is at most one attempt on the retained handle, after a late
exit recheck, and its return is not exit proof. Only a signaled retained process
handle followed by a successful exit-code query confirms exit. A forced exit is
reported separately from an exit observed without forced termination.

All callbacks (normal request, pre-resume setup and final-report observation)
must be bounded/nonblocking. Synchronous callbacks, pre-resume work, OS
calls and owner-thread scheduling are not an independently bounded external
watchdog. The explicit startup-host bridge is now wired; closing
its report does not make an unconfirmed exit into a confirmed one. An eventual
coordinator still needs an independent startup/total deadline and protected,
serialized publication of the stop/context files.
The current host callback queues publication without filesystem waits. A separate
worker records publication success/failure; grace begins at the queue attempt,
not at delivery. A delayed publication can reduce the engine's actual response
window, so this is not a completion-origin engine-grace guarantee. Observation/API errors remain unconfirmed;
they are not evidence of normal shutdown or permission to target another PID.

## Required before an unattended game run

The startup host now owns one suspended child through its cleanup and records
the actual retained-handle exit result. The following remain **unfinished or
unauthorized**:

1. Promote the fixture-only protected runner to a newly reviewed game candidate
   only after an independent exact-child cleanup capability exists. Retained
   on-disk input/attempt wiring now runs end-to-end on fixed disposable fixtures;
   it is not yet a game launcher or an authenticated/hermetic executable chain.
2. Live verification that the now-implemented early shim runs before mission
   start. Native queued-Lua ordering is unproven; no late-attach guessing is added.
3. An independent outer exact-child watchdog that remains usable if the native
   host crashes/hangs. The runner verifies its retained HOST exit, and separately
   reports native-owner child-exit evidence; it cannot independently verify or
   force-close that child and never reopens its PID or terminates the host.
4. Live-game verification of the opt-in host bridge and stop channel. The narrow
   fallback permission is settled, but the old manual runner must not reopen a
   printed PID to use it. No retry,
   hot-unload, arbitrary termination or unbounded background run is approved.
5. A newly frozen and independently reviewed unattended launch candidate plus
   fresh user approval. The older prepared manual workflow and approvals are
   not silently repurposed.

The components do not schedule work for two days or keep operating after a turn.
No heartbeat or recurring automation is installed.

## Offline verification

Run `./tools/test.ps1` in the project-local pinned test environment. The focused
files are `tools/tests/test_unattended_observation.py` and
`tools/tests/test_unattended_ack.py`, plus `test_early_engine_shim.py` and
`test_unattended_handoff.py`; CI runs their portable cases as well.

Lua behavior is executed under both Lua 5.1 and LuaJIT 2.1 with mocked engine,
clock, file, and process-context APIs. Tests exercise the real
bootstrap -> adapter -> controller call path, stale contexts, readiness,
timeouts, reentrancy, write failures, acknowledgement joins, and one-shot quit
semantics. They do not prove installed-engine compatibility.

The acknowledgement suite mocks subprocess execution for its portable cases.
An optional Windows-only integration case executes the exact pinned read-only
decoder against **temporary copies of historical offline fixture receipts**.
It leaves the originals unchanged and does not inspect or start a game process.
That case skips when the ignored frozen artifacts are absent. Final counts and
source hashes are recorded separately in the preparation evidence directory.

The fixed `receipt_handoff_fixture.py` additionally accepts only exact hash-pinned
disposable host/child/DLL/shader/decoder artifacts under project validation. Its
child reuses the real WARP interned GPU fixture, then waits for its CPU-validation
ACK and writes a fixture-consumption marker before returning. Four runtime cases
cover validated ACK/natural exit, missing ACK, corrupt-bundle decoder refusal,
and the original overall deadline cutting short the additional receipt wait.
The native owner confirms actual exit separately; the positive case publishes no
owner-stop and makes no force attempt. This marker is not a BeamNG consumption
receipt. The builder requires existing pinned ignored artifacts and is **not**
wired into clean CI as though those private binaries were present. Runtime
receipt paths remain short because older core artifact writers use ordinary
Win32 paths; only owner metadata has the separately tested long-path support.

`build_owned_watchdog.ps1 -RunTests` builds and runs only named disposable Win32
fixtures and the portable policy test. It does not accept a BeamNG target.
The fixtures exercise cooperative exit and hung/failed-request paths using
their own created processes. The child has its own fail-safe deadline. CI also
compiles/runs the same portable policy fixture with a strict C++17 compiler.
These are process-lifecycle tests, not a native rendering or live-game test.

See `STARTUP_OWNER.md` for the host's five-option opt-in contract, final exit
receipt, fixture scope, and remaining unattended-launch boundary.
See `PROTECTED_RUNNER.md` for the protected fixture execution/review distinction,
held-source Python loading, proof fields, and explicit unknown-state behavior.

See `ISOLATED_PROFILE.md` for the preparation-only BeamRT resource copy, pristine
settings/cache boundary, exclusive destination checks, and still-unverified
userpath/VFS/cloud behavior. Preparing it does not enable game execution.
