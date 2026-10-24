# Bounded binding thread diagnostics — 2026-10-13

Implemented directly in the installed unpacked BeamRT folder. This adds useful
CPU evidence for the unexplained live rejection count; it does not retrospectively
attribute the old 3,187,134 calls or relax the recording-thread guard. No BeamNG
launch, lighting/GI work, resource reads, shader/Lua change or hot unload occurred.
The successful live host/bootstrap remain unchanged.

## Evidence and limits

`BeamRT_BindingsThreadDiagnostics` returns a separate version-1 CPU ledger under
the existing metadata lock. Public status/snapshot layouts remain 120/1008 bytes;
the recording artifact remains 1,144-byte ABI v1. Diagnostics survive OFF, marked
disabled. Unknown extent/unstarted reads refuse. No object pointers or leases are
added; the context owns only fixed arrays and primitive values.

- 24 SDK-method counters, with overflow/bounds validation.
- Total rejected calls partitioned into first epoch conflicts/repeats and
  pre-target/post-target traffic. Reset-pinned epochs with no accepted **observed
  graphics callback** are counted separately; unobserved commands may have run.
- At most **16 first conflicting epochs**, with command ID/generation, method,
  claimed/caller/Reset/first-accepted-observed thread IDs, prior observed target
  PSO association and metadata/snapshot-source state before rejection.
- Further distinct epochs increment a dropped-sample counter; repeated calls
  never allocate or append samples. ClearState preserves the epoch's conflict
  latch; successful Reset creates a new epoch and keeps the old caller pinning.

Samples reflect this observer's bookkeeping, not native-call overlap, timestamps,
safe inter-thread handoff, fresh frames, GPU completion or camera/lighting truth.
The first 16 epochs can be biased toward early/non-target traffic. A prior observed
PSO can be stale after a rejected setter; it is deliberately not labeled the
call's actual current PSO. Thread IDs are numeric observations, not retained thread
lifetime identities. No backtraces, per-call files, new hooks or new threads are
added. No game-performance claim is made.

## Startup transport and files

The binding **handoff payload is now ABI 2**: the shared reply adds a coherent
first-record diagnostic receipt and immutable first-conflict slots. Payload size
is still 56 bytes and inherited handle count still 12. ABI-v1 payloads refuse,
avoiding silent old/new reply-layout mixing. Creation/startup/import transports
and the public recording artifact remain unchanged; frozen old pairs still work
together and are not retroactively converted.

First-conflict entries publish once with an atomic completed-prefix count, at
most 16 times per session. Parent reads a bounded published prefix from the
read-only mapping with a CPU barrier, never an interlocked write to that mapping.
The full first-record ledger publishes before the existing record event and is
validated against its PID/thread/serial and legacy rejection count.

For `--bindings-out <record>` the host retains new companions:

- `<record>.threads.bin`: 1,184-byte coherent first-record ledger, only if a draw
  was accepted. Exact serial/PID/thread and checked counter partitions/sums.
- `<record>.thread-samples.bin`: 912-byte bounded immutable-prefix copy, saved
  after acceptance **or the no-draw timeout**, even when no recording was accepted.
- Host log: method totals and at most 16 concise conflict lines with thread IDs
  and metadata context, so the failure log can be useful without binary decoding.

Companion paths must be fresh and distinct from the root output. Existing
companions refuse before child creation; CREATE_NEW prevents later overwrite.
Prefix and complete-ledger artifacts can reflect different CPU observation
points; do not merge them into a coherent frame or infer missing call history.
No-draw timeout does not invent a complete ledger or overwrite a recording file.

## Verification and remaining hold

RTX 4070 and WARP fixtures verify **55 calls, 23 conflicting epochs, 32 repeats,
16 samples and 7 dropped epochs**, two method buckets, Reset-only/pre-target and
available-snapshot-source classifications, unchanged pixel **23**, source-list
invalidation and unrelated-list isolation. Diagnostics remain readable after
OFF. Negative recordings are never submitted. Debug layer was unavailable.

The strict host self-test rejects **115** option/payload/evidence cases, including
legacy binding transport and 24 malformed ledgers (overflow, invalid partitions,
thread/method/boolean bounds and duplicate epochs). Source/Lua suite: **201/201**.
The expanded startup matrix passes **11 cases**, including hardware/WARP thread
attribution, byte-for-byte comparison with the fixture's queried ledger, conflict
evidence without a draw, default-off, unchanged output and existing-sidecar refusal.
All fixture jobs drained; no game process was started.

**The first new-build startup run did fail before attach with `0xc0000135`.**
Exact files and logs are preserved in
`.beamrt-validation/native-startup/process-tests-63080-2446046890/`.
All 21 copied inputs were independently verified. A no-rebuild rerun with the
same production binaries passed all 11 cases at
`process-tests-90160-2446251593`; this does not explain the earlier loader failure.
The final host-only logging build passed the same matrix at
`process-tests-51900-2446847031`. No fault/diagnostic host replaced the normal path.
Bootstrap dependencies remain KERNEL32.dll only.

Offline candidate hashes (not game-tested at this checkpoint; subsequent single
live diagnostic below):

- Host: `8d4eb9fbadc17ac71af9eeebb2ca77d7484ad12f889cc1e1b5808b4eb5bdd62d`.
- Bootstrap: `293a595e535f1fba54aa78910d0f2c81f71da26cd3e960cadda0f100b6cc8845`.

Deployment stays held. The newly preserved failing set gives us reproducible
input identity, not a proven reproducible failure or its cause. Resolve/review
that loader boundary before another separately approved live diagnostic. This
telemetry enables a future run to test threading hypotheses without guessing
from the old aggregate count. GPU resource provenance/CBV/state/fence integration
remains subsequent work, not something this diagnostic authorizes.

## Separately approved live thread-diagnostic observation

The user approved restoration of the removed observer/loader build wiring, then
explicitly approved one fresh observation-only BeamNG startup on this frozen
8d4eb9fb/293a595e pair despite the unexplained historical loading failure. Fresh
checks passed: 115 no-launch refusals, 2 loader controls, 11 startup-binding cases
and 227/227 project tests. No rebuild, old frozen-build replacement or ordinary
game-setting installation occurred.

The run captured the exact v082 four-vertex draw, 1280x676 viewport and 168-byte
root plus complete/early thread ledgers. Host/game exited 0 after user-controlled
normal closure; no game or test host remained. Native GI/lighting stayed off.

Useful result: 7,557,023 rejected calls partition into 4,943 first conflicting
epochs and 7,552,080 repeats. Of those calls, 7,555,107 were counted before target
identification and 1,916 after. The 16 early samples show accepted observed
commands from one thread followed by viewport/output setters from another;
Reset-only/no-accepted-command conflicts total zero in this recording. This
narrows the hypotheses but does not establish overlap or a safe ownership
transfer. The first samples are pre-target biased, not representative GI coverage.

Exact scope, automatic Lua-diagnostic activity during loading, independent saved
receipt checks, frozen identities and remaining limits:
`.beamrt-validation/native-startup/live-thread-diagnostics-0b7f74ef10564e7c96efb95f8baebffb/RESULT.md`.
No descriptor/CBV content, camera, GPU ordering or lighting proof was added. The
loader anomaly remains open and this run does not lift the general deployment
hold. Next work is a conservative offline ownership/handoff model, not another
unchanged game probe or automatic GPU consumption.

Final source check: after the approved build-wiring restoration passed 227/227,
the same script rollback reappeared during this work without an edit by this
agent. Final discovery is 224/227: binding, handoff and loader source contracts
fail again. The source writer is unknown and its change was preserved rather
than repeatedly overwritten. Frozen observed host/DLL bytes and the successful
game shutdown are unaffected; source/build reconciliation is needed before a
future rebuild. The run's RESULT.md records this distinction.

### Build-wiring recovery after editor closure

After the user reported closing VS Code, the previously authorized observer and
loader wiring was restored again from the matching Git index version in the
installed mod folder. The script parses without errors and the project suite
passes **227/227**. Its SHA256 remained
`85fed1b493d43ccc438ec1b8208d94f8f4d391ff8c045e42dc1c2d3fd0f70ab1`
through a subsequent check more than one minute after restoration. No native
rebuild or new BeamNG launch occurred. This bounded stability check does not
identify the rollback writer or establish that VS Code caused it. Recovery
evidence is retained in
`.beamrt-validation/build-wiring-recovery-eb6aa5a60ff541a79b36fe3f68f3a0c7/`.

### Separately approved observation-only repeat

The user then explicitly approved one repeat on the same frozen host/bootstrap.
Startup, device/target creation and the four-vertex GI CPU recording passed again;
host and game exited 0 after user-controlled normal closure. The restored build
script remained unchanged through shutdown. No rebuild or native GI/lighting
activation occurred. The historical loading failure did not recur, but neither
its cause nor the rollback writer is established.

The recording again shows pre-target-biased foreign-thread refusals: 2,610,237
calls, 3,451 first conflicts, zero Reset-only conflicts, and 16 early samples
with prior accepted observed commands before viewport/output calls from another
thread. Different counts are not a performance improvement. Keep the guard;
timestamps, safe transfer, resource contents and GPU ordering remain unknown.
The log also records automatic Lua reflection diagnostics during loading, so
usual GI activation is user-confirmed, not proof of a diagnostic-free frame.
Full scope and retained evidence:
`.beamrt-validation/native-startup/live-thread-repeat-c0be85cb40034df6bb3b2ecb5b1bb41d/RESULT.md`.

### Controlled offline interval model

The separately approved next step adds the [CPU-only handoff fixture](THREAD_HANDOFF_FIXTURE.md).
It models full callback intervals and passes 17/17 scenario groups, including
joined sequential handoff, overlapping same-list forwarding spans, post-native
metadata gaps, concurrent different lists, lifecycle/token/ceiling refusals and
receipt-source isolation. No model code is linked into the observer or startup
DLL, and the existing recording-thread guard/ABI remain unchanged. These stand-in
results do not establish actual BeamNG overlap or authorize GPU consumption.
