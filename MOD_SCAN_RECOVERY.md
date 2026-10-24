# Mod-manager scan recovery - 2026-10-19

## Cause and evidence

BeamNG 0.40 could not enable/deactivate the unpacked mod. The live log showed
`recursive_directory_iterator::operator++: The system cannot find the path specified`
at `modmanager.lua:648` (recursive ZIP discovery under all `/mods/`) and `:908`
(recursive file notification enumeration for the unpacked BeamRT folder).
The Lua source files were present; `extension unavailable` followed the mount
failure and was not caused by the new shader or SSR compatibility interlock.

`tools/diagnose_mod_scan.cpp`, a read-only C++17 filesystem scanner, reproduced
Windows error 3 at a retained long-path negative test under:

`.beamrt-validation/early-shim-ack-b7a090e8687b4adaa6a9cd7eb509e2b8/build/t-18636-37625/`

The next component was a 150-character x directory; its absolute path was 312
characters. Skipping only the top-level validation tree passed 3,084 entries.

## Recovery

After confirming normal BeamNG shutdown, five non-runtime artifact directories
containing overlong paths were moved out of the game-scanned mods tree to:

`C:/Users/ab/Documents/Codex/beamrt-mod-scan-recovery-2026-10-19/`

The exact source/destination map is preserved in `relocation.json` there:

- `early-shim-ack-b7a090e8687b4adaa6a9cd7eb509e2b8`
- `startup-owned-integration-b2ea7154f0584ad7b03b5fbe73f6d657`
- `outer-child-8a037eeb9c344631bf11c24fa4083fdb`
- `native-reflection-experiment`
- `prepared-interned-observation-33567a29140a4465a2d4e18ed6a85d5b`

Nothing was deleted. Historical evidence contents were not rewritten. Absolute
paths/junction targets in these retired fixtures retain their original values;
the moved fixtures are not certified runnable at their new locations. Old build
helpers with hardcoded references to these artifact paths need separate review.
Do not restore them under `/mods/` merely to make those old references work.

The actual installed Lua, shaders, assets and scripts stayed in place. A combined
SHA256 of all 285 runtime files and their paths matched before/after relocation:

`A7772CB126AD0CF347A0C416C93178A06FD8FFAFBC7170AA45285F6F6F49BAA9`

## Verification and prevention

- Full absolute BeamRT directory scan: **PASS, 24,897 entries, zero exclusions**.
- Full absolute `/mods/` directory scan: **PASS, 24,951 entries, zero exclusions**.
- No native settings, mod database, stock engine files or game processes changed.
- This verifies the filesystem blocker is removed; the next normal game launch
  must verify the engine mounts and loads BeamRT successfully.

Long-path/reparse negative fixtures must be generated outside the live `/mods/`
tree. Git ignore rules do not exclude a directory from BeamNG's mod scan.
The project-local Python environment and ordinary short validation outputs remain
in place. No global Python packages or settings were changed.
