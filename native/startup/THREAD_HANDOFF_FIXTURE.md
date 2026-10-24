# Controlled offline callback interval fixture

Implemented in the installed unpacked BeamRT folder. This is a **fixture-only**
model and executable, not a replacement for the game's recording-thread guard.
Neither its header nor executable is linked into a native observer or startup
DLL. No production ABI, hook, thread policy, resource lease or proof flag changes.

## What it models

Each owned synthetic callback progresses through:

`enter -> forwarding span -> native returned -> metadata updated -> exit`

The token remains active until exit. Only a completed, consistent fixture
interval can publish a **synthetic receipt**. A short mutex protects each model
transition; it is never held across the stand-in forwarding body or waiting gate.
The fixture uses explicit gates/joins, not sleeps, to establish the intended
schedule. Each gate has a five-second failure timeout; worker exceptions reach
the test runner after join.

Four fixed synthetic lists and eight active-token slots bound storage. Tokens
bind slot, unique ticket, list, generation and caller. No native object pointers,
GPU addresses, real command lists, device, resource, fence or external process
is accepted. The executable refuses arguments. Caller IDs and lifecycle boundaries
are fixture-owned facts, not automatically available game evidence.

## Seventeen scenario groups

- Same-thread callbacks and explicitly joined sequential A-to-B-to-A recording.
- Overlapping forwarding spans on the same synthetic list, with both stand-in
  forwards occurring despite refused observations.
- A second callback in the first callback's post-native/pre-metadata gap: full
  callback overlap is distinguished from overlap of forwarding spans.
- Two different lists active concurrently, without a global overlap refusal.
- Same-caller re-entrancy, Close/Reset crossing an active callback, and recovery
  only through a fixture-known quiescent close/reset into a new generation.
- Stale generations, forged tokens, duplicate exits, wrong callers, missing
  entries/phases/exits, and reordered phases refuse and clear outputs.
- OFF while a callback is active, late entry refusal, list/caller bounds and
  fixed token pressure; outstanding valid tokens can still drain after refusal.
- Ticket, generation, publication and diagnostic counter ceilings. Small explicit
  fixture ceilings exercise exhaustion without attempting 2^64 operations.
- Uncertainty on the receipt's own list invalidates it; known unrelated-list
  uncertainty preserves another list's accepted historical synthetic receipt.
  An unknown/forged token instead makes the entire model unhealthy, because its
  actual ownership cannot safely be assigned.

These are seventeen named groups, some with several rejection subcases. The
existing GPU binding fixture separately continues to test the unchanged strict
thread-identity policy. The synthetic model's accepted sequential handoff must
not be described as acceptance by the current observer.

## Build and verification

```powershell
./native/startup/build_thread_handoff_fixture.ps1 -RunTest
```

The script uses the existing MSVC compiler with `/W4 /WX`, reuses an initialized
toolchain, and otherwise initializes only this process's compiler environment.
It does not invoke worker/capture/startup builds, fetch dependencies, rebuild any
DLL or install software. Each build gets a fresh ignored validation directory,
copied model/fixture inputs, runtime log and SHA256 artifact inventory. CI runs
this executable and its isolation/source guards; full local project discovery
also includes the guards. A local run passed all **17/17** groups.
Full project discovery passes **232/232** including five new isolation/source
guards. Thirty-two repeated fixture runs also passed, and an extra argument is
refused with exit 2. Repetition checks fixture scheduling stability, not live
game compatibility or complete driver-call coverage.

## Boundaries that remain

This is a controlled stand-in model, **not instrumentation around the real
gi_bindings.cpp wrappers**. It cannot diagnose which live BeamNG calls overlap,
prove coverage of unhooked APIs, recover descriptor contents, establish camera
meaning, synchronize GPU work, or make a native visibility result affect GI.
Forwarding-span overlap refers to the modeled bracket, not measured driver
execution. A lack of modeled overlap is not a complete engine synchronization
or legal handoff proof. The production one-thread-per-generation guard remains
unchanged. No new game launch or deployment is authorized by these tests.

The next diagnostic implementation would need bounded full-wrapper interval
evidence, careful object/generation lifetime handling, partial-coverage labeling
and separate ABI/transport validation. It should first report evidence without
relaxing acceptance or holding a metadata lock across native execution.
