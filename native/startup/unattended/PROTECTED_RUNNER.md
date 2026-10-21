# Protected startup wiring: fixture execution only

The default CLI reviews a candidate and creates no claim/output/process:

```text
python -I -B protected_runner.py --candidate <candidate.json>
```

`startup_plan.build_plan(*, files, run_directory, token, limits)` is a pure
game-observation argument generator. Its immutable native vector explicitly
selects `--review`. Ten exact path/hash roles and eight bounded settings produce
one literal-only, one-line queued Lua invocation of the early shim. UTF-8 byte
escapes preserve Unicode in Lua5.1/LuaJIT without code injection. Paths,
Detours' ASCII DLL bound, native MAX_PATH artifact bounds and Windows command
length are checked lexically. No input is opened/claimed by this planner.
Queued-Lua execution before mission startup remains unverified in BeamNG.

## Candidate and execution boundary

Candidate schema1 has exactly `schema`, `profile`, `files`, `helpers`,
`run_directory`, `token`, and `limits`. The helper declarations are the six
fixed sibling Python sources, each with a lowercase SHA256. Duplicate/nonfinite
JSON, extra/missing fields and role aliases refuse. Review checks source used
for planning but does not certify declared executable bytes or physical paths.
The canonical candidate SHA256 joins all declarations; it is a machine guard,
not human launch approval or an authenticated process capability.

Only profile `fixed-warp-receipt-v1` can execute, with a second explicit CLI
flag and the exact reviewed candidate SHA256. Its host, child, DLL, shaders and
decoder have fixed independent pins, sibling paths, WARP backend, fixed token,
20-second native overall bound,1-second normal grace and5-second receipt wait.
There is no arbitrary target, host-argument, backend, PID, shell or environment
passthrough. The runner itself constructs the exact argv from pinned roles.
`beamng-observation-review-v1` execution refuses even with those flags/digest.
No code here promotes `--review` into a game launch.

## Retained on-disk input protection

`ProtectedInputs` accepts a complete explicit manifest, at most512 files,
1GiB/file and2GiB total. It rejects local aliases, streams, devices, network or
non-fixed drives, reparse components and duplicate physical file identities.
Input handles share read only; hashes and bounded source reads use those same
handles. Ancestor directories and the run directory are retained against
rename/delete using LIST_DIRECTORY plus attributes/synchronization access.
Real Windows testing found attributes-only access insufficient for an empty
directory; that test now exercises and protects the otherwise-empty preclaim
run directory. Unrelated child-file creation remains possible/necessary.

All known runtime final and pending names must be absent before atomic
`runner-claim.json` CREATE_NEW, and freshness is rechecked at claim. The claim
contains token and canonical configuration digest, is flushed/read back and
retained. A partial claim remains consumed. Input/claim/setup failure cannot
reach process creation; repeating a consumed directory refuses without repair.
Existing files are never deleted or overwritten to make a retry work.

The runner compiles checked helper Python SOURCE bytes, then compiles/executes
the exact held source during the protected run. It never consults helper `.pyc`
caches; it injects the checked ACK publisher into the real handoff helper rather
than taking its lazy-import path. The already-running Python interpreter,
stdlib and entry code are trusted: this is not a hermetic/authenticated chain,
ACL, hostile same-user defense, or proof against preexisting writable mappings,
administrator/kernel access or power loss. Directory handles prevent rename,
not concurrent same-user creation of a new file. Hashes/claims are accidental
drift, stale-cache and race guards under a serialized reviewed operator.

## Lifecycle and honest proof fields

After claim and before Popen, reviewed source, clock and output creation must
succeed. The actual retained HOST is launched with shell=False, close_fds=True
and hidden-window flags. The native host separately owns the exact test child.
Ready/context joins are bounded, the pinned full decoder runs once, and one
atomic CPU ACK may be published. Success additionally requires the fixture's
matching consumption marker, host exit0, exact complete typed native exit
report, child exit0/no force and no lifecycle diagnostic failure. The withheld
ACK fixture expects host17/child98 after normal stop, not lighting success.

Proof fields remain distinct:

- `hostExitVerified`: the outer runner observed its retained Popen host exit.
- `nativeReportedChildExitVerified`: the native owner reported its retained
  child exit through the exact schema/token/PID report. Not independent proof.
- `independentChildExitVerified`, `outerChildFailsafeAvailable`, and
  `gameExecutionAvailable`: always false in this implementation.
- `ackValidated` and `fixtureAckConsumed`: CPU validation and disposable fixture
  consumption only; never a BeamNG consumption/GPU/rendering claim.

An outer12-second ready deadline and40-second host polling bound supplement the
native creation-origin watcher. Invalid/regressing clocks and poll/sleep/file
failures become explicit unknown/failed reports and cannot turn into a pass
when a later poll succeeds. No unbounded finally wait, PID reopening, host kill,
process-tree/job termination, second launch or DLL hot-unload exists. If the
host remains active or crashes without a valid owner report, child state is
unknown. Input locks end when this bounded runner returns/exits; unknown does
not mean cleanup succeeded. Synchronous hashing, filesystem, process creation
and OS scheduling are not independently preemptible real-time operations.

## Offline verification and remaining game blockers

`build_protected_runner_fixture.ps1` defaults to preparing three frozen-source
candidates and reviewing them with no process. `-RunTests` executes only pinned
disposable fixtures: ACK/natural exit, deliberately withheld ACK/normal stop,
wrong review digest/no claim or process, and consumed-attempt replay unchanged.
It borrows exact locally ignored artifacts rather than rebuilding/deploying a
DLL. No BeamNG target is accepted or selected. Those private runtime artifacts
are not assumed to exist on clean CI; portable plan/input contracts and mocked
Windows coordinator contracts have separate workflow coverage.

The new runner's LIST_DIRECTORY locks cover its fixture preclaim window. The
older native StartupStopChannel still uses attribute-only directory handles;
its previous nonempty-directory tests did not establish empty preclaim/ancestor
retention. Repair and freshly test that native guarantee before standalone or
game use; do not silently change/relabel the old frozen host or approvals.
An independent outer exact-child handle/cleanup mechanism is also required
before any game execution, followed by a newly frozen/reviewed candidate,
fresh user approval and live verification of the queued-Lua startup order.
Game promotion must also protect the complete actual installed Lua/HLSL/native
source inventory, not treat the planner's ten minimal launch roles as a full
renderer-input manifest. No game candidate with that coverage is supplied here.
No active shader, existing renderer, game settings or installation is changed.
