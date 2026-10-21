# Two rendering tracks, not a finished RTX release

Status checked against local source and recorded receipts on 2026-10-20.
No native build, DLL load, game launch, sandbox change or public upload is
authorized or performed by this tuner cleanup.

## Track A: ordinary screen-space mod

Keep the current Coherent-derived screen-space reflection backend as the main
reflection UI. Keep stock water rendering and the GI implementation intact.
Retain earlier reflection implementations as explicit Legacy comparisons,
not as another default-on stack. Four existing quality presets still belong
to the legacy GI/reflection settings; current reflection controls are session-only.

An eventual repository package must be deliberately assembled from runtime
files, not a zip of this entire development folder. The official modding
guidelines recommend drag-and-drop installation, prohibit overwriting stock
data, require permission for contributed content, and exclude unused files.
They do not establish blanket approval for DLLs or sandbox changes. Repository
approval and any native integration permission need confirmation from BeamNG:
https://www.beamng.com/game/support/policies/modding-guidelines/

## Track B: optional native scene-ray-tracing research

Separate distribution may be practical for a native companion with explicit
installation, source, exact version compatibility and an uninstall/rollback
path. GitHub hosting is NOT a waiver of game policies or user consent. Do not
silently weaken Lua sandbox settings, patch normal startup, or auto-download/load
native binaries from the repository mod. No such release is ready now.

The existing compute BVH worker traces actual imported triangles offline. It is
not a live complete-scene renderer and does not establish DXR/hardware-RT use.
The registry still marks DXR unavailable. Native GI/visibility fixtures do not
establish safe access to live game textures or completed in-game lighting.

### Next concrete milestone: resource handoff, not more SSR controls

1. Preserve the last live-tested bundle and receipts. The compact observation
   reached 1,024 descriptor locations / 47 distinct payloads, then refused
   location 1,025. See `startup/COMPACT_STORAGE_LIVE_OBSERVATION.md`.
2. Review the separately versioned interned-storage candidate and its existing
   offline tests against that exact failure. Its larger metadata capacity is
   not proof of complete resource coverage or live compatibility. See
   `startup/DESCRIPTOR_INTERNED_PROFILE.md`. Do not remove refusal guards,
   mix ABI generations or retry a historical crashed candidate.
3. Before any game run, prepare one exact-binary, bounded, separately approved
   observation with rollback/normal-close instructions. An old approval does
   not authorize a new binary, an additional launch or an existing-process attach.
4. Establish actual resource provenance, camera/depth interpretation, per-frame
   lifetime, queue/state ordering and final-consumer fence retirement. A shader
   match, readable descriptor, larger table or loaded DLL is not this proof.
5. Connect one known imported opaque mesh and a bounded visibility query to one
   owned consumer. Demonstrate a correct off-screen blocker, correct miss,
   invalid-data fallback, disable/recovery and normal closure in-game.

Only after that milestone should we expand scene extraction/material support
and build a complete reflection radiance path. A visibility bit alone does not
supply reflected surface color, lighting, textures, transparency or emissive
radiance. Moving/deforming vehicles require current geometry and acceleration
structure updates, not stale map meshes.

### Hardware RT milestone

Then evaluate a real DXR backend: supported-device checks, BLAS/TLAS generation,
ray queries/dispatch, material-aware hit shading, dynamic updates, temporal
reconstruction and safe integration with the game's frame. Choose a small,
testable scene before attempting map-wide transport. Retain SSR/environment
fallback for unsupported hardware and missing native scene coverage. Do not
label a compute BVH pass or the present screen-space tracer as RTX.

Success means demonstrated scene-space visibility and useful radiance on live
game resources, including off-screen tests and reliable rollback—not the size
of the codebase or the presence of a DLL.
