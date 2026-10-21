# Installed source coverage: no game execution

This adds a broader physical inventory and a bounded, retained-file lease. It
does not turn the existing review-only game plan into a launcher, and does not
claim that every engine/world input or mounted VFS winner is protected.

`installed_input_coverage.build_spec(...)` is pure. `collect(spec)` explicitly
reads and hashes the selected files and records physical directory membership,
empty directories and optional absence. It does not follow links/reparse points
or obey `.gitignore`. The protected scope includes the whole installed BeamRT
tree except declared control/cache directories (`.git`, `.beamrt-validation`,
`.vscode`, `.github`, `__pycache__`) and Python bytecode. This includes ignored
generated HLSL hooks, DDS/PNG resources, packed art JSON, bootstrap scripts,
native sources and offline tools, not just active shader entry points.

The engine scope includes all loose `lua`, `shaders`, `Bin64` (excluding log
files) and default `settings` files, plus `gameengine.zip`, `shaders.7z`,
`startup.ini` and `startup.default.ini`. Five separately declared/pinned native
artifacts are required: startup host, observation DLL, vertex/pixel bytecode and
the CPU receipt decoder. A native artifact cannot disagree with its pin even
if a serialized coverage digest is recomputed.

## Mutable context is not locked

User settings, `mods/db.json` and `temp/shaders` are hashed context snapshots,
not share-denying immutable input handles. These are normal write targets;
locking them could prevent a future startup or shutdown from behaving normally.
Other mod providers, user override roots and the West Coast/common-vehicle
archives are shallow metadata observations, not protected archive bytes.
The inventory report never returns `gameExecutionAvailable`, `namespaceSealed`
or `fullEnvironmentProtected` as true.

The audit found 282 installed runtime resource files in the four traditional
BeamRT subtrees: 32 Lua, one bootstrap script, 228 shader/resource files and 21
art files. The older 252-file Lua/HLSL inventory omitted those other resources.
The new whole-mod scope also covers unexpected runtime files elsewhere in the
mod, rather than assuming autoload scripts can only exist in those subtrees.
The currently empty `shaders/common` directory is included in membership checks.

## Bounded physical protection

`CoverageLease(manifest, run_directory, protector_factory=..., backend_factory=...,
inventory_check=...)` receives explicit frozen-source-loaded dependencies.
Importing either module is inert. There is no claim, process, launch or shutdown
API. `open()` checks inventory, holds all batches, then checks inventory again.
`verify_inventory()` supplies another explicit checkpoint; a refusal releases
every batch, including partial setup, and cannot be reopened/retried.

Each original `ProtectedInputs` batch retains its unchanged 512-file limit.
The new coordinator permits at most 8192 files overall while preserving the
1 GiB/file and 2 GiB total byte limits across all batches. One shared backend
checks physical file identities across batches, so a hardlink alias in batch
two cannot evade batch one's duplicate check. Reads route through the original
held handles, not a later path reopen. All batches remain held until close.

Membership/type/size/time and mutable-context checkpoints detect declared
snapshot drift. They are not an atomic namespace seal. A directory handle
prevents its rename, not creation of another file within it; future additions,
transient VFS winners, preexisting writable mappings and hostile writers remain
outside the claim. The trusted Python/OS limitations of ProtectedInputs remain.

## Concrete remaining game blockers

- Stock Lua uses mounted virtual paths: `lua/ge/main.lua:11,58-59` establishes
  Lua/extension search paths; `core/modmanager.lua:625-662` rescans ZIPs/unpacked
  mods. Its autoload discovery also includes `scripts/**/modScript.lua` and
  `mods_data`. Holding a few physical source paths or `db.json` is not proof of
  which virtual source executes.
- The audit found five active mods: BeamRT, BeamExposureControl, BeamMP,
  polish_roads and taa_standalone. Exposure/TAA autoload their own Lua/shaders.
  No mod was disabled or changed, and no cache was cleared by this work.
- West Coast is 3,268,216,729 bytes; common vehicles 4,179,294,666 bytes; the
  active polish_roads ZIP 2,256,591,038 bytes. These exceed the existing budgets.
  They are not silently excluded from a claimed complete environment, nor are
  those budgets silently raised. Complete world/provider protection needs a
  separately reviewed scope/budget or isolated-profile decision.
- Loose engine Lua (3180 files) and shaders (406 files) provide broad static
  source coverage, not a certified executed dependency graph. Conditional
  includes, VFS overrides and compiled shader-cache selection still need actual
  observation. Dynamic system/driver modules are not claimed to be covered.
- `parseArgs.lua:87-90,101-104` queues `-lua` and records `-level`; this does not
  prove their startup execution order. The late-attachment refusal stays intact.
- Future compatibility of deny-write locks with generated-asset writes has not
  been game-tested. No actual game resource/camera/GPU-lifetime/lighting proof
  follows from an inventory or lease test.

## Verification

Verification is recorded in the fresh ignored `input-coverage-*` evidence
directory. Tests include portable schema/membership regressions and real Windows
513-file multi-batch sharing, hardlink-alias refusal and late-inventory refusal.
The full installed-input acquisition is an explicit read/lock-only test; it
must not create a runner claim, start BeamNG or deny writes to mutable context.
Final counts and results belong to that run's result manifest, not this static
audit's earlier file counts.
