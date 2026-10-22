# Light visibility: diagnostic and integration boundary

Direct illumination and indirect transport are different responsibilities.
Native direct shading decides which receiver gets each lamp's energy after
range, cone/cookie, orientation and shadow visibility. GI then transports that
illuminated radiance between surfaces. AO must not be presented as a lamp shadow,
and a diffuse GI ray must not be presented as a receiver-to-light visibility ray.
Darkness should follow illumination/occlusion, not a global suppression preset.

## Installed native source findings

Inspected locally in the BeamNG installation; engine source and live GPU dispatch
binding are not available/verified here:

| Native path | Available inside native shading | Why ordinary PostFX cannot assume access |
| --- | --- | --- |
| `shaders/common/lighting/advanced/spotLightP.hlsl` | Per-draw light position, direction, cone, range, brightness, attenuation, projection and shadow texture; `shadowed` enters irradiance once. | Valid only with that light's native draw constants/resources, not a global map or a `castShadows` declaration. |
| `shaders/common/lighting/clustered/cluster_shade.cs.hlsl` | `clusterLights` t4, shadow atlas t14, shadow views t15; per-light `evalShadow`, cone/cookie and windowed inverse-square attenuation. | Compute-dispatch-owned structured buffers, atlas records and samplers; current raster CustomMaterial/PostFX API has no verified connection to them. |
| `shaders/common/lighting/clustered/cluster_common.h.hlsl` | Per-light position/direction, cone, color/brightness, `ownerId`, shadow view offset/count, projection and strength. | Existence of the HLSL layout does not prove a Lua getter, bindable resource name or stable scene-ID mapping. |

The legacy local-mesh hook already refuses the exposed clustered backend. Do not
remove that safety gate merely because its legacy shader compiles. The sunlight
glass hook is separate and does not establish local clustered-light access.
The public light provider still does not feed GI rays. Its new `readObject` and
`queryScene` APIs are read-only acquisition; the diagnostic consumes them only.

## v0.129 diagnostic scope

One explicit native PointLight/SpotLight ID; no auto-picked dominant light.
One-shot candidate discovery does not mutate the provider's shared cache. Frame
updates read only the selected object and verify object identity. Live axis,
cone, range, brightness/color and enabled state affect the diagnostic calculation.
An unknown enabled state is magenta/unavailable. Declared brightness is a relative
weight, not a measured candela/lumen conversion. Exposure and cookies are not
reproduced; potential influence is not the native final irradiance.

Direction is world-space **toward the emitter** at each opaque G-buffer receiver.
The visibility mode traces that segment in visible camera depth only, capped at
12 m with 32 samples. Red means a plausible depth-surface crossing (12 cm assumed
tolerance), not definitive geometry/opacity evidence. Amber means unknown:
misses, incomplete sampling, sky and off-screen travel cannot prove clear light.
No green/clear state is invented. Transparent windows are not represented as
separate G-buffer layers. Normal/depth viewport mapping mismatch passes beauty
through rather than mix incompatible receivers.

Native mode explicitly shows unavailable. There is no native atlas sampling,
native visibility readback, scene/vehicle BVH fallback, numerical pixel readback,
dominant-light selection or beauty/GI coupling in this first diagnostic. The
selected-light ID and CPU inputs are logged, while direction/potential/screen
evidence are visualized per pixel. GPU execution remains unverified until tested
in the game. No new light, native material, shadow quality or source policy changes.

## Next gates before adding final-image lighting

1. Demonstrate the correct native light/receiver/dispatch association, including
   active state, intensity conversion, atlas generation, shadow-view count and
   exposure. Test native fully lit/blocked receivers and lights without maps.
2. Export native visibility with provenance, receiver identity, light identity,
   frame/view identity and validity. Missing data must remain **unknown**.
3. Keep supplemental geometry visibility separate. A trustworthy off-screen
   solution needs actual scene/vehicle geometry, transforms and alpha/coverage
   policy, not enlarged contact AO or 32 coarse surfels. Compare screen evidence
   against geometry in controlled cases before calling it visibility.
4. Compose attenuation only once per represented obstruction. Preserve native
   visibility. Supplemental extinction requires explicit non-overlapping coverage;
   never blindly multiply two masks for the same glass pane/blocker. Unknown
   supplemental coverage retains native shading, not fabricated darkness.
5. Only then use trustworthy direct illumination as GI source radiance. Frozen
   clean-radiance diagnostics remain frozen/diagnostic, not a live material-aware
   source until capture/update and renderer input contracts are implemented.
