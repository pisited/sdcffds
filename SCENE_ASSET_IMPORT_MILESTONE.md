# BeamRT static mesh import and BVH groundwork

**Status:** Experimental first stage, PR #2, branch
`experiment/sun-shadow-tracer-v0102`. No production GI, shadowing,
or existing camera-depth tracing is modified by this milestone.

## What was implemented

1. **TSStatic shape discovery** in
   `lua/ge/extensions/beamrt/sceneAssetManifest.lua`, reachable from
   `beamrt_main.exportStaticSceneManifest(...)`. It enumerates stable
   scene object identities, shape asset paths, positions/scales where
   exposed, raw transform text, and material name *hints*. It deduplicates
   shape assets in a JSON manifest. It never serializes userdata.
2. **A standalone .dae geometry importer** in
   `tools/beamrt_scene_import.py` (Python standard library). It handles
   Collada `<triangles>`, `<polylist>` and simple `<polygons>`,
   dereferences separate POSITION and TEXCOORD index streams, converts
   asset units and up-axis to Z-up metres, and captures per-face material
   symbols/unique name candidates from `<instance_material>`. All
   `alphaMode` values remain **unknown** until real opacity rules and
   textures are checked.
3. **Offline BVH preprocessing** per extracted asset. The importer builds
   a flat hierarchy of bounding boxes, indices and leaf ranges, capped
   at eight triangles per leaf. This accelerates a future ray traversal,
   but **no GPU resources, texture buffers or acceleration-structure
   shaders are bound yet**.
4. **Batch import using the manifest**. It deduplicates assets before
   parsing, rejects paths outside the supplied asset root, saves
   deterministic per-asset JSON and an `index.json` of imported, missing
   and unsupported assets.

### What is NOT implemented yet

- Meshes in BeamNG's `.cdae`, `.dts` or packed archive formats
  are not decoded. Only **extracted plain-text .dae** files are supported.
- Parent/child scene-node transforms within the Collada file and BeamNG
  instance world matrices are not yet baked. Vertices remain
  **asset-local**, not world-space. Do not feed these coordinates directly
  to `beamrt_shadowRenderer.loadOffscreenTriangles()` or the GPU GI path.
- No real alpha-texture lookups, car deformation updates, forest instances,
  terrain traversal or normal/reflection material evaluation.
- The BVH is **CPU-generated data**, not a GPU BVH until a validated
  buffer upload and traversal implementation is added.
- The old 12-triangle experimental shader cap is unchanged. There is no
  claim of map-wide GI occlusion or persistent accurate mesh shadows.

## Export real scene references from BeamNG

After pulling the branch, **restart BeamNG** so its cached Lua modules
are refreshed. In the GE Lua console:

```lua
extensions.load("beamrt_main")
local ok, report = beamrt_main.exportStaticSceneManifest(
  "/settings/beamrtSceneManifest.json", 512)
dump({ok = ok, report = report})
```

This enumerates up to 512 TSStatic objects and exports distinct asset
paths into `beamrtSceneManifest.json` under BeamNG's *active user
folder* settings directory. Pass a higher maximum (up to 20000)
only if needed. Scanning the full map can be slower. If `truncated`
is true, the selected records are only a bounded sample.

For the already cached frustum records, which may include fewer objects:

```lua
local ok, report = beamrt_main.exportStaticSceneManifest(
  "/settings/beamrtCachedSceneManifest.json", 512, true)
dump({ok = ok, report = report})
```

To inspect counts without writing a file:

```lua
dump(beamrt_main.getStaticSceneManifestStats(512))
```

The manifest includes `shapePath`, `assetKey`, `name`, and
optional position / scale / raw transform data. **Transforms are marked
unverified** because the Lua provider has not established BeamNG's
native MatrixF storage convention/pivot.

## Run the Python importer on your own extracted files

From the root of the BeamRT Git checkout in PowerShell:

```powershell
python tools/beamrt_scene_import.py --self-test
python tools/beamrt_scene_import.py --input "C:\\ExtractedBeamNG\\levels\\west_coast_usa\\art\\shapes\\example.dae" --output "C:\\BeamRTMeshData\\example.beamrt.json"
```

The example shape path is illustrative, **not** a claimed real West
Coast USA asset filename. You must provide a path that actually exists.

For batch preprocessing, where `C:\\ExtractedBeamNG` contains the
relative `levels/.../something.dae` paths referenced by the manifest:

```powershell
python tools/beamrt_scene_import.py --manifest "C:\\PATH_TO_BEAMNG_USER_FOLDER\\settings\\beamrtSceneManifest.json" --assets-root "C:\\ExtractedBeamNG" --output-dir "C:\\BeamRTMeshData" --max-assets 32
```

The importer will **report and skip** unavailable / packed / unsupported
assets rather than inventing triangles. The batch JSON contains
`gpuUploaded=false`, `worldTransformsBaked=false`,
`verifiedCompleteScene=false`. The per-asset BVH JSON also explicitly
reports `instanceTransformsBaked=false`.

The importer protects against unexpected huge triangle arrays
(`--max-triangles`, default 200000 per asset), and fails rather than
silently truncating meshes. There is no reliance on third-party Python
packages or running arbitrary scripts embedded in Collada.

## Test status and the actual next step

An automated GitHub Actions check compiles the Python source and runs
its synthetic 2-triangle/BVH test using Python 3.11. This verifies only
the **offline parser and BVH data structure**, not rendering in BeamNG.

Next, establish and verify the exact TSStatic world-matrix convention
from an in-game object. Apply the asset/node transforms in the importer
and confirm a selected object aligns to its in-game position. Then
replace the 12-uniform-triangle proof with a GPU-readable triangle/BVH
buffer and conservative alpha-aware visibility queries for both shadows
and GI. Only after those tests pass can we call it automatic
off-screen geometry support.
