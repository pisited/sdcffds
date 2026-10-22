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

## v0.129.1 receiver self-intersection experiment

The visibility producer uses a new v002 shader. It reconstructs receiver tangent
vectors from four adjacent depth samples, preferring the closer valid neighbour
per axis to avoid reaching across silhouettes. Degenerate/missing frames and
large depth discontinuities return unknown. The resulting normal is oriented
toward the camera; the probe does not use bump/shading normals for this bias.
Normals used by the influence view's lighting term remain unchanged.

The normal offset is `clamp(.004 + .1 * footprint, .005, .025)` metres. Candidate
hits must lie in front of the receiver tangent plane by more than
`clamp(.002 + .05 * footprint, .003, .015)` metres. A separate parallel blocker
is not rejected simply for sharing the same normal. This can miss very thin or
near-coplanar geometry inside the tolerance and may be imperfect on curvature;
it is not guaranteed to preserve every contact.

Projected point depth fetches are snapped to texel centres, and reconstruction
uses that same centre's ray. Combining a point-sampled depth with the unsnapped
continuous ray invents offsets on sloped surfaces. The old fixed 35 mm shading-
normal offset is removed. Ray count/reach, hit thickness, diagnostic colors and
unknown-on-miss policy are otherwise retained; there is no spatial blur.

This does not sample a shadow map. Shadow cascades, shadow-map resolution, PCF/
PCSS or native lamp bias settings therefore cannot fix this particular probe's
self-hit test. Those are separate native-renderer concerns. No native shadow
settings or beauty/GI attenuation are changed. Offline shader compilation and
analytic geometry reference tests do not prove the live acne is fixed.

## v0.129.2 depth-crossing refinement experiment

The v002 isolated test `gap > .015 && gap < .12` accepts only a 10.5 cm band.
At the maximum 12 m reach, its 32 midpoint samples are about 37 cm apart. A
continuous blocker can therefore be accepted/missed periodically as the receiver
changes, producing repeated offset silhouette strips even with correct bias.
Analytic phase-sweep tests reproduce this failure independently of shadow maps.

The v003 shader uses 32 coarse samples including segment endpoints, brackets
changes in the signed ray-to-visible-depth gap, then performs six bisections.
Either crossing direction is permitted for opaque two-sided depth evidence.
It accepts only an endpoint with at most 2 cm residual and a distinct front-of-
receiver-plane candidate; the old isolated thickness band is removed. Missing
samples break continuity, and silhouette/depth jumps without residual convergence
are not accepted merely because their signs differ. At most two brackets are
refined per ray (44 depth samples total, plus receiver-frame acquisition).

This does not guarantee intersection continuity across subpixel silhouettes;
refined samples can still contain single-layer depth artifacts. Thin geometry can
be missed between coarse samples. Invalid brackets, exhausted budgets and misses
remain unknown. No denoising, larger bias, shadow cascades or beauty attenuation
are introduced. This revision needs a live same-lamp/same-camera comparison.

## v0.130 native per-light relay experiment

The user confirmed the runtime label `Advanced Lighting 1.5`; `setShadowVizLight`
and `ClusteredShading` were nil. That does not itself prove the legacy local-light
PS executes. The new test requires this observed manager label and uses a private
copy of the installed point/spot PS, keeping its native light-space shadow code.
The actual `shadowed` value is captured before optional lightmap adjustments;
native BRDF/irradiance and outA/outB RGB assignments are otherwise untouched.
Point cube/paraboloid, cookie, reversed-depth and `NO_SHADOW` variants are compiled
offline, but compilation is not evidence of a live native draw or visible fix.

The inspected native `lighting.hlsl` writes `outB = float4(specular.rgb, 0)` and
`lightinfoUncondition` reads `bufferSample1.rgb`. This experiment leases that
otherwise-unused RT1 alpha, not a beauty channel, and reads `#lightinfo[RT1]` in
an early capture immediately after `AL_LightBin`, not in the late display.
Availability of that alias/format, native shader selection,
same-frame clear/order and cross-view behavior still require live verification.
Third-party alpha consumers or alternate renderers are not supported. The scope
is a diagnostic, not a stable public engine shadow-texture/matrix export API.

The selected native draw is matched by a CPU-unique position/range and spot
axis/outer-cone tuple, because `LightDataAdv` has no scene object-ID field. Scene
enumeration rejects coincident tuples before activation; the native comparison
uses immutable defines on a fresh private ShaderData. This is not an ID supplied
by the native dispatch, and sources outside that enumeration can still be an
ambiguity. A disabled/moving/replaced selected light stops the test. Brightness,
cookie evaluation and shadow-map decisions remain native.

One owned 1x1 RGBA32F producer emits the frame tag before `AL_LightBin`. The native
PS reads it via extra sampler14 and writes a finite binary16 bit packet to RT1
alpha: a non-repeating epoch and a 0–15 visibility code, or code16 unavailable.
`NO_SHADOW`, missing dimensions or invalid filtered visibility do not produce
an asserted lit sample. No camera-depth intersections are executed by this relay;
native camera depth is still used as usual to reconstruct the receiver.

The v0.130.1 live screenshot showed one white bar: the tag texture was not 1x1
at the reader, before visibility was tested. This does not distinguish a missed
producer dispatch from a target allocation/lifetime or binding failure.
Two architectural issues were then identified using the official
[PostFX lifetime/timing documentation](https://documentation.beamng.com/modding/postfx/):
normal effect targets are frame-local and lightinfo must not be read by late
PostFX. v0.130.2 uses explicit bin-timed, skip-draw parents with owned on-demand
children. The children still execute every frame in parent chain order: Frame
before AL_LightBin, Capture immediately after it. Capture copies the packet and
validity into our own RGBA32F target. The late display reads that snapshot only.
Lazy target requests cannot authorize capture: both children require a current
schedule-epoch constant, cleared each frame and set only by their timed parent's
preProcess callback. Unscheduled captures report stage 13 before reading alpha.
This is a lifecycle correction, NOT proof that the live relay now succeeds.

Capture checks lightinfo against the same render-resolution prepass. The late
display uses engine viewport mapping and point sampling for the snapshot, with
the documented color-jitter offset. It no longer compares render-resolution
lightinfo directly to potentially upscaled beauty. Snapshot signatures and epochs
are checked before packet decoding; failures remain unknown/unavailable.

Tags 32..2015 skip 480 (the missing-alpha default 1.0) and 992..1055 (Inf/NaN and
negative subnormal encodings). The 1,919 remaining tags are finite normal half
values. A full controller-lifetime packet round-trip test covers every code/tag.
The controller auto-restores instead of wrapping. Stops/restarts consume distinct
remaining tags; a complete module reload resets the sequence, so native buffer
clear and producer order on reload remain an explicit, unverified freshness gate.
Other writers, overdraw, clamping, missing alpha, stale tags or an unused native
path can invalidate the relay; they must not be interpreted as full visibility.

Only the display colors change. The native shaders still calculate and apply
their original direct-light shadow attenuation once. RT1 RGB/specular and outA
beauty formulas are not overwritten, no lamps/settings are changed and PTGI is
not a consumer. Startup stops BeamRT custom beauty/capture paths to isolate the
diagnostic. Cleanup neutralizes metadata/display first, restores the leased shader
and sampler with readback/reload checks, retains failed leases for retry and
never overwrites a foreign replacement. It does not start additional scene lights
or create a complete world/vehicle BVH.

The v0.130 live test produced full-screen magenta: transport failed, but all
guards used that same color, so the failing stage cannot be inferred from it.
The v0.130.1 display retains a faint scene and shows white bars for the first
failing stage: 1 frame dimensions, 2 nonfinite metadata, 3 bad frame signature,
4 stale epoch, 5 native/prepass dimensions, 6 nonfinite alpha, 7 unavailable map.
v0.130.2 adds 8 missing snapshot, 9 invalid snapshot signature, 10 stale snapshot,
11 invalid status and 13 unscheduled early capture. Reported target sizes and
callback counts are CPU diagnostics, not GPU texture readback or success proof.
No validity check has been bypassed to obtain a plausible-looking result.

Next live evidence: matching green/red native visibility with an off-screen
caster, explicit stage 7 for `NO_SHADOW`, recovery after stop/restart and assurance
that dark-gray/missing relay output is not called native lighting success.

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
