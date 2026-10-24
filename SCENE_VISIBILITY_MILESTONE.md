# BeamRT shared scene visibility, milestone 1 (experimental)

**Repository:** `pisited/sdcffds`, branch
`experiment/sun-shadow-tracer-v0102`, draft PR #2.

This milestone links the previously separate shadow-proxy dataset to a
conservative, **opt-in GPU occlusion test for world-surfel GI bounces**.
It does not replace BeamNG lighting, import every game mesh, or claim
full-scene visibility.

## Architecture and what is actually wired

- `sceneDatabase.lua` registers the new `visibility` provider.
- `sceneVisibility.lua` exposes a stable world-space ray-segment query,
  a bounded scene snapshot, optional approximate AABB evidence, and
  material transparency **candidates**. The three meaningful outcomes
  are `blocked` (confirmed intersection with explicitly opaque triangles),
  `possible-blocker` (uncertain/alpha or box evidence), and `unknown`
  (no verified obstruction; the scene is incomplete).
- `worldMeshCasters.lua` stores **up to 12 world-space triangles**, optional
  `materialName` and `alphaMode`, and a monotonically increasing
  `generation` to trigger GI uploads when material/geometry changes.
  `getOpaqueTriangles()` excludes `mask`, `blend` and `unknown`.
- Existing material, light, TSStatic and vehicle providers remain intact.
  The scene snapshot normalizes cached metadata, never pretends texture
  contents, instance triangles or live vehicle deformation are available.
- The new **GI v082** shader is v081 plus a macro-gated shared-scene
  segment test. It checks only the path from the current receiver to a
  **cached world surfel**, *after* the surfel was hit. A verified opaque
  triangle crossing that segment rejects the bounced radiance. It does
  not rewrite the screen-space GI estimator, inject point lights,
  replace the existing native sun shadows, or multiply shadow masks
  into already-lit radiance.
- `main.lua` has an opt-in toggle that defaults **false**; when enabled,
  up to 12 explicitly opaque triangles are copied to v082 shader constants.
  Material/geometry generation changes cause a rebind. The toggle
  resets accumulated GI history so A/B comparisons are meaningful.
- The independent `shadowRenderer.lua` still handles diagnostic
  `worldbox`, `worldboxprobe`, `worldmesh`, and visual split-screen.
  Its GPU shadow test is independent of the new GI safety classification,
  so an orange mesh-intersection image alone is **not** proof of opacity.

## First in-game test

After a `git pull origin experiment/sun-shadow-tracer-v0102`, restart
BeamNG **once**. Lua `require()` caches modules, and reloading only the
extension can leave the changed shared providers in memory from before
this milestone.

In the GE Lua console:

```lua
extensions.load("beamrt_main")
dump(beamrt_main.getSceneProvider("visibility").selfTest())
dump(beamrt_main.getSceneVisibilityGIStatus())
dump(beamrt_main.getSceneProvider("visibility").getSnapshot(8))
```

The self-test must report `cpuIntersection=true` and `cpuMiss=true`.
This verifies only CPU intersection math, **not HLSL compilation or
render-target bindings**. `getSceneVisibilityGIStatus()` should initially
show `enabled=false`, and `effectiveOpaqueTriangles=0`. Snapshot
`complete=false` is intentional; absent providers aren't evidence of
unblocked rays.

## Add a small, verified opaque object and test GI

World-space triangle JSON, 1 to 12 faces:

```json
{
  "triangles": [
    {
      "a": [100, 200, 5],
      "b": [103, 200, 5],
      "c": [101, 200, 8],
      "materialName": "verified_opaque_wall",
      "alphaMode": "opaque",
      "source": "measured-world-space-facade"
    }
  ]
}
```

The coordinates above are **illustrative only**, not valid positions
for the user's map. Supply true world coordinates and a material whose
opaqueness has been **verified**. A screenshot or material name by itself
does not prove alpha is opaque. Glass, chain-link fences, and trees with
cutout leaves should stay `alphaMode="mask"`, `"blend"`, or `"unknown"`
until UV and opacity textures are available.

```lua
extensions.load("beamrt_shadowRenderer")
local ok,err=beamrt_shadowRenderer.loadOffscreenTrianglesJson(
  "/mods/unpacked/beamrt/shadow_triangles.json")
dump({ok=ok,error=err})
dump(beamrt_main.getSceneVisibilityGIStatus())
beamrt_main.setGISource("hybrid")
beamrt_main.setSceneVisibilityGIEnabled(true)
dump(beamrt_main.getSceneVisibilityGIStatus())
```

`effectiveOpaqueTriangles` must become positive before the GI test can
affect any rays. The `setSceneVisibilityGIEnabled` toggle controls only
world-surfel bounce occlusion. Effects also require cached surfels, active
world GI, and a segment actually intersecting a verified triangle.

Turn it off for exact baseline comparisons:

```lua
beamrt_main.setSceneVisibilityGIEnabled(false)
```

If the new GI shader fails to compile, keep the experiment disabled and
use the unmodified `main` branch as the fallback. Static source checks
cannot substitute for in-game compilation.

## Query geometry and light paths

```lua
local provider=beamrt_main.getSceneProvider("visibility")
dump(provider.getStats())
dump(provider.getMaterialCandidate("KNOWN_MATERIAL_NAME"))
dump(beamrt_main.getSceneDatabaseStats().providers.visibility)
-- With a world-space segment that you measured:
dump(beamrt_main.querySceneVisibility({0,0,1},{0,0,6}))
-- If a world surfel and a cached light are available:
dump(beamrt_main.auditWorldSurfelLightPath(1,1))
```

`getMaterialCandidate` is a **hint**, not a trusted final opacity
classification. The light path audit reports evidence; it does not
modify BeamNG's point or spot lighting.

## Why this matters for accurate GI

Currently, a world-surface radiance sample can otherwise contribute
despite a **known opaque piece of geometry between the receiver and the
surfel**. The new optional segment test supplies a real visibility
rejection for that narrow case. It avoids the inverse mistake of treating
every ray that *misses our incomplete database* as definitely lit.

What remains for actual production-quality GI and off-screen shadows:

1. Import and transform complete static, forest and vehicle triangle
   meshes, with coherent LOD and deformation updates.
2. Carry per-primitive UVs and material IDs, then alpha test textured
   fences, vegetation and transparencies at the hit point.
3. Provide accelerated GPU scene structures rather than 12 uniform
   triangles. Avoid testing thousands of faces per GI pixel.
4. Add verified secondary **sunlight** visibility and local-light
   occlusion at hit points, respecting BeamNG's already-lit radiance
   to avoid double shadows.
5. Validate visual differences and GPU budget in BeamNG.

**Status:** GitHub code milestone and CPU self-test entrypoint provided.
Engine shader compile/runtime behavior is pending user testing; GI changes
are OFF by default.
