# Preparation-only BeamRT profile

`isolated_profile.py` stages a new, short, explicitly named physical directory
outside both the normal BeamNG user tree and the game installation. It never
launches a process, deploys a DLL, creates a launch/runner claim, or changes a
user-folder pointer, Steam option, registry entry, `startup.ini`, or normal mod.
Import is inert; preparation requires an explicit plan digest and injected,
verified-source-loaded file-only protection dependencies.

## Disk layout and exact copy

```
beamrt-profile-<fresh token>/
  profile-plan.json
  profile-receipt.json
  control/                    # four Lua driver sources; not auto-loaded
  user/current/
    settings/                 # empty
    temp/shaders/             # empty
    mods/unpacked/beamrt/
      art/
      lua/
      scripts/
      shaders/                # includes generated files and empty directories
```

The four runtime trees are physically enumerated, not selected with Git or an
ignore-aware search. Only their declared resource extensions are accepted.
Only named `art/beamrt`, `lua/ge/extensions/beamrt`, `scripts/beamrt` and
`shaders/beamrt` resource namespaces are accepted, plus the empty directory-only
`shaders/common` hierarchy (currently `material/shadergen`).
There is no copied native DLL, build tooling, Git data, validation evidence,
normal settings, mod database, cache, saved vehicle or other mod. The four
control Lua files (`early_shim`, `bootstrap`, `engine_adapter`, `controller`)
live outside the mounted user tree and are not executed by preparation.

Limits are 512 total held source files, 32 MiB per file and 128 MiB overall;
aggregate metadata budgets are checked before hashing. Hash reads compare
opened-file identity/size/time and stop at the initial size plus one byte.
Source and destination ancestry, membership and physical types are checked;
symlinks, reparse points, hardlinks, case aliases and ambiguous Windows names
are refused. Destinations are exclusive new files with different source file
identities, not links. All declared empty directories are preserved.

Preparation holds source bytes using the unchanged `ProtectedInputs` helper
(SHA256 `d6c95facda3589ef01e963136b652a0c40e30496d2499e13bf135cad3dcba64a`).
It holds destination ancestry/directories against ordinary rename while writing,
flushes new files, and checks both source membership and the complete staged
namespace. No machine attempt claim is made. Failure retains the consumed partial
directory; it is never resumed, merged, recursively removed or overwritten.
Every acquired outer directory handle gets a close attempt even if another
cleanup fails. This relies on the supplied protection implementation and a
trusted Python/OS, not a hostile administrator/kernel security boundary.

`verify_prepared(plan)` must succeed against the actual tree. A receipt file's
presence alone is insufficient: an interrupted final publication/readback can
leave metadata in a failed partial attempt. The review digest is a preparation
integrity check, not human launch approval. Verification is a checkpoint, not
an atomic namespace seal or a durable guarantee after handles are released.

## Runtime boundary remains closed

The plan includes only the inert candidate argument fragment
`-userpath <profile>/user`. The expected versioned directory is `user/current`.
The official [BeamNGpy process construction source](https://github.com/BeamNG/BeamNGpy/blob/master/src/beamngpy/beamng/beamng.py)
uses `-userpath` for a custom user directory. This does **not** prove exact
version-folder selection or early queued-Lua ordering for the installed drive
build. No launch command/shortcut is generated, and no fallback to the normal
profile is allowed if a future check reports another path.

Empty settings/cache directories mean only **pristine staged disk state**.
They do not prove stock runtime defaults: local/cloud overlays and mounted
providers must be observed later. The existing normal-profile log records shared
`BeamNG.drive.ini` and sibling `BeamNG.drive.cloud` activity, so a custom user
folder cannot yet promise that a future launch leaves shared metadata untouched.
No unverified `-nosteam`/`-safemode` workaround is applied. Safe mode would also
suppress normal mod mounting and therefore is not a BeamRT-only configuration.

Before any future game/map/GI action, a separately reviewed startup must verify
the actual `FS:getUserPath()`, mounted provider identities and virtual-source
winners, plus the shared metadata/cloud-write boundary. Stock
`core/modmanager.lua` scans virtual `/mods/**/*.zip`, `/mods/unpacked/*`,
`/scripts/**/modScript.lua` and `/mods_data/*/modScript.lua`; physical staging
alone does not certify the active virtual namespace. The existing installed-input
collector requires settings and `mods/db.json`; do not fabricate either to make
a fresh profile pass that different contract. A later collector needs an explicit
fresh-profile policy.

All receipts keep `gameExecutionAvailable`, `runtimeUserPathVerified`,
`runtimeDefaultsVerified`, `vfsIsolationVerified`, `namespaceSealed`,
`cloudIsolationVerified` and `nativeGIEnabled` false. There is no camera,
resource-state, GPU-lifetime, live lighting, performance or game compatibility
proof in this step. Old host pins, approvals and fixture-only execution gates
remain unchanged.

## Tests

`tools/tests/test_isolated_profile.py` exercises only disposable file trees,
portable injected file dependencies and real Windows input/directory handles.
No native fixture, game executable, DLL or shell launcher is run. The normal
`tools/test.ps1` suite includes it; both workflows run the focused contracts.
Actual preparation paths, counts, hashes and preservation checks belong in a
fresh ignored evidence directory, not in this source document as stale results.
