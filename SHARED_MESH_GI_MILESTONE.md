# BeamRT v0.103 — shared material-aware mesh visibility

## Missing / changed / implemented

The full guardhouse mesh was consumed only by a geometry preview; GI retained a
12-triangle experiment. This batch connects its 776 faces/255 BVH nodes to actual
**receiver-to-world-surfel GI bounce rejection**. Screen GI, its estimator, noise,
temporal filtering, presets and native lighting retain their existing paths.

Live native Material declarations classify supported opaque surfaces. Alpha-tested,
blended, incomplete, mismatched and nonstandard materials retain the old/native
behavior; missing offline fields never become opaque by guesswork. The shared
query finds later definite opaque blockers even after an uncertain intersection.
Invalid data, missing geometry and exhausted budgets do not become false occlusion.

One native-resolution R32F preparation pass preserves precisely direct-light RGB
and retroreflectance A, freeing slot5 for mesh data while retaining six GI inputs.
The existing history/STBN/native-noise atlas is untouched. The extra pass runs only
when GI is rendering hybrid/world paths, world strength is positive, supported
opaque materials resolve, and the captured scene is current. Default is OFF.
At 2560x1353 the target costs about 52.9MiB plus bandwidth; performance is unmeasured.

Disabling, stale geometry, unavailable materials and unload restore the v082 shader
and native samplers and stop the preparation pass. Geometry/material policy changes
reset GI history. Content-addressed data textures avoid stale geometry-cache reuse.

Known fixes bundled before asking for a reload: stale visibility-registry lookups
resolve the required module; temporary reflection magenta returns are removed;
existing variance weighting is restored; variance OFF removes its three extra
passes. Fresh reflection entries load restored behavior. No new denoiser is enabled.

## One normal-render activation

While parked near the captured guardhouse, use GE Lua. This preserves your saved
tuning, reloads the code, and explicitly selects hybrid GI/world strength 0.35 so
there are world bounce paths to guard. It does not change time, marcher, camera,
vehicle, reflection settings or open debug views:

```lua
local savedBeamRT=beamrt_main.getSettings(); beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.unload("beamrt_meshBVH"); extensions.load("beamrt_main"); beamrt_main.applySettings(savedBeamRT); beamrt_main.enable(); beamrt_main.setGISource("hybrid"); beamrt_main.setWorldGIStrength(0.35); beamrt_main.setSharedMeshVisibilityEnabled(true); dump(beamrt_main.getSharedMeshVisibilityStatus())
```

Expected: tuner v0.103; effective=true if supported live opaque materials resolve.
Normal scene remains. World bounce leakage through the building may be reduced;
weak/black world radiance can make the visible change small. If inactive, the status
gives the reason and selects the old path. Inspect logs first, not another wire test.
CPU effective status does NOT prove successful GPU loading or correct image pixels.

Disable with `beamrt_main.setSharedMeshVisibilityEnabled(false)`. The tuner exposes
the same toggle and inactive reason. It is not saved as a graphics preset because
dataset/material availability must be rechecked. `savedBeamRT` remains available
to restore the previous source/world contribution with `applySettings`.

## Unverified / remaining work

Live native material results, GPU data decoding, appearance and frame cost remain
unverified. Full alpha-texture cutouts, glass transmission, map-wide geometry and
dynamic meshes are not implemented. Unknown materials are NOT made solid.

Native sun/local shadow replacement remains separate: this batch does not multiply
a shadow mask into an already-lit scene or pretend diffuse/specular/emissive are
separated there. Only imported-world-mesh GI visibility is newly connected.
The existing alignment screenshot is accepted as front-view evidence; no repeat
alignment test is requested. Off-screen persistence still needs actual image evidence.

Next substantial milestone: UV/alpha-texture-aware queries and additional real mesh
instances in the GPU scene, then selective light/shadow integration with fallback.

## Local verification

25 actual-Lua integration/motion regressions, 7 alignment fixtures, 5 BVH controls
and 23 geometry/packing tests pass. Native Lua5.1/LuaJIT/Lua5.5 compile checks pass.
Surfel physics acquisition is stubbed in the graph fixture because its camera
vectors are plain tables; that fixture is not evidence of physics acquisition.
New entries compile strictly with FXC. Legacy v082 GI, v062 cache and v001 mesh
VS/PS binaries are byte-identical to the baseline. No Git/network publication done.
