# BeamRT: one real building, alignment milestone

Goal: a hybrid renderer with a shared world-geometry/material/light foundation,
then accurate persistent shadows and GI visibility. Playable and cinematic
use the same scene representation with different quality budgets.

This stage is **implemented and offline-tested, not yet visually verified**.
It does not enable GI visibility, replace native shadows, load the 12-triangle
caster experiment, or change reflection reconstruction.

## Prepared real building

The installed West Coast USA ZIP contains
`levels/west_coast_usa/art/shapes/buildings/guardhouse.dae`.
The `guardhouse_L150` visual node has **776 triangles, 776 UV-bearing faces,
8 material names, and 255 offline BVH nodes**. Seven material names resolve to
one candidate engine Material definition from the map/shared-art ZIPs;
`construction` remains unresolved. Opacity is unknown for every face until
verified; windows and other uncertain materials are never silently called opaque.

Generated private package:
`art/beamrt/alignment/wcu_guardhouse.beamrt.json`.
It is ignored by Git: the source repository does not redistribute game geometry.
The game installation archives are read-only and were not modified/extracted.

## First in-game check

While parked in West Coast USA, enter this in **GE Lua**:

```lua
extensions.load("beamrt_meshAlignment"); beamrt_meshAlignment.previewNearest(); dump(beamrt_meshAlignment.getStatus())
```

This selects the nearest instance **of the prepared guardhouse asset**, not the
nearest arbitrary building. Its initial camera distance, object ID, placement,
and material evidence are reported. The selected building may be outside the
current view; use the reported location/distance to find it. No camera teleport,
physics pause, scene mutation, or production renderer changes are performed by
the default preview command.

If the selected guardhouse is far away, this **explicit** command positions only
the free camera beside it (not your car), so you do not have to search the map:

```lua
beamrt_meshAlignment.focusPreview()
```

Return to the previous camera mode with `beamrt_meshAlignment.restoreCamera()`.
Focus is never triggered automatically and is not restored automatically on
mission changes, preventing stale camera positions from being applied to a new map.

Orange lines represent actual imported mesh edges, not an AABB. Compare them
to the native walls, roof, and door/window outlines. At most 2400 edges are drawn;
`wireframeIsPartial` identifies a budget-limited display without removing mesh
triangles from the stored geometry. Selection and geometry transformation happen
once on command, not for every static object each frame.

Other commands:

```lua
beamrt_meshAlignment.setMode("materials") -- edge colors keyed to material names, NOT PBR shading
beamrt_meshAlignment.setMode("wire")
beamrt_meshAlignment.setMode("off")       -- hide without deleting capture
beamrt_meshAlignment.clear()              -- release only this preview
```

For an exact object, pass its scene name or numeric ID:

```lua
beamrt_meshAlignment.previewObject(OBJECT_ID)
```

After visually checking alignment, explicitly record that evidence if desired:

```lua
beamrt_meshAlignment.confirmAlignment(true)
beamrt_meshAlignment.exportWorldMesh("/settings/beamrtAlignmentWorld.json")
```

Export includes **all** world-space triangles, UVs, material references, native
placement and the confirmation flag. It does NOT upload them to the renderer.
The 776-face export cannot be loaded directly into the old 12-face shader proof;
we do not truncate the building to make it fit.

The preview periodically checks its object's native basis. Removal, movement,
shape changes or scaling disable it and clear its confirmation. Mission changes
and extension unload release it. Camera motion alone does not invalidate it.

## What changed in extraction and placement

- Select one visual scene node, excluding sibling LOD/collision meshes.
- Compose its ancestor/node matrix, translation, rotation and scale in source
  order, then convert asset units/up-axis to engine-model metres/Z-up.
- Keep geometry/node/material provenance and separate POSITION/TEXCOORD indices.
- Obtain native TSStatic placement by evaluating `MatrixF:mulP3F` on scaled unit
  points, with `getScale()` applied once. Capture native columns as independent
  evidence; do not parse the raw matrix string or transpose it heuristically.
- Compare extra native transformed control points against the captured basis;
  disagreement above 2mm is rejected. This checks affine math, **not** visual
  agreement with BeamNG's mesh/pivot/LOD interpretation.
- Manifest exports now include this JSON-safe native placement when available;
  unavailable APIs produce a specific `placementError`, not invented coordinates.
- Negative texture-coordinate indices are rejected, avoiding Python's otherwise
  valid negative indexing into a different UV.

Matrix conventions: Khronos COLLADA 1.5 specification says column-vector matrices
are serialized row-major and node transforms are postmultiplied in order:
https://www.khronos.org/files/collada_spec_1_5.pdf . Native matrix APIs were checked
against the installed BeamNG editor's `api/object.lua` and `objectTool.lua`.

## Reproduce the private package

From this mod folder in PowerShell, using a Python interpreter:

```powershell
python -B tools/beamrt_scene_align.py --archive "E:\SteamLibrary\steamapps\common\BeamNG.drive\content\levels\west_coast_usa.zip" --materials-archive "E:\SteamLibrary\steamapps\common\BeamNG.drive\content\art_shapes.zip" --asset levels/west_coast_usa/art/shapes/buildings/guardhouse.dae --node guardhouse_L150 --output art/beamrt/alignment/wcu_guardhouse.beamrt.json
```

For another asset, inspect its nodes with `--list-nodes` before selecting an
exact visual node. Unsupported transforms, missing meshes and partial primitives
fail rather than becoming misleading approximate geometry. Collision/LOD union
is deliberately not an automatic fallback.

## Validation and remaining work

14 offline extraction/transform/material/BVH regressions and the importer's
6 original synthetic checks pass. Seven actual-Lua control fixtures pass, including
rotation/nonuniform scale, stale rejection, safe export, opt-in camera focus/restore
and no GI mutations.
Lua 5.1, LuaJIT and Lua 5.5 compilation checks pass. These are not GPU/visual tests.
The workflow now includes the Python alignment regression suite; it has not been
pushed or run in remote CI in this task.

Next: confirm the live wire alignment, then connect the full mesh/BVH to validated
GPU storage and traversal, resolve opacity textures, and prove accurate shadows
persist when the caster is off-screen. None of those later milestones is claimed
complete here. This preview does not fix GGX noise or prove native cubemap replacement.
