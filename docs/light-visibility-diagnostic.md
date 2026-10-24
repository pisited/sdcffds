# Light visibility: diagnostic and integration boundary

Direct illumination and indirect transport are different responsibilities.
Native direct shading decides which receiver gets each lamp's energy after
range, cone/cookie, orientation and shadow visibility. GI then transports that
illuminated radiance between surfaces. AO must not be presented as a lamp shadow,
and a diffuse GI ray must not be presented as a receiver-to-light visibility ray.
Darkness should follow illumination/occlusion, not a global suppression preset.

## Installed native source findings

Inspected locally in the BeamNG installation. The night capture now confirms
clustered dispatch bindings (see below); usable buffer contents and a live mod
export route remain unverified. Native engine C++ source is not available here:

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

### v0.130.9: correct the clustered interface name

Installed `lua/ge/extensions/core/settings/clusteredQuality.lua` uses the global
`ClusterShading`. Earlier checks used only `ClusteredShading`, a different name;
its nil result did not establish absence of the engine's actual interface.
Native diagnostic preflight/update, mesh local-light activation/update and
availability/status now recognize either name without invoking backend getters.
The correct-name guard blocks all three probes before native material changes,
and exposure during an existing legacy lease stops/restores it. Read-only member
metadata prefers `ClusterShading` if both names exist. No backend setting changes.

Live evidence motivating this correction: the dispatch marker was absent despite
synchronized CPU PostFX callbacks; `AL_SpotLightMaterial:dumpInstances()` emitted
only a header and footer, including immediately after a successful start. That
dump does not prove shader binding, GPU dispatch or alpha-write behavior (and an
immediate dump alone need not include a subsequent render). Clustered shader
sources show a separate compute accumulation path, but its existence/exposure is
not proof that a particular view dispatched it. Native shadow export remains
unverified; correcting the guard does not integrate the compute buffers/atlas.

The first raw-key inventory returned only `___type`, `__index`, `__newindex`.
This is not evidence that properties/resources are absent. Installed
`lua/common/luaBinding.lua` explicitly stores registration tables at numeric
slots 1 (getters), 2 (setters), 3 (superclass), on the binding metatable.
Metadata inventory schema `beamrt.cluster.backend-metadata.v2` also walks those
slots on the namespace/metatable, with cycle checks, a four-edge depth bound
and a 128-member limit. It reports names and Lua types only; it never calls
accessors, reads their returned values, changes quality or installs a hook.
The live v2 inventory (log time 4357.22905, untruncated) returned eight getter
registrations and matching setters: `heatmapOverlay`, `lightFlares`,
`minLightScreenSize`, `shadowBubble`, `shadowFallbackFrames`,
`shadowInstantSettle`, `shadowMaxCasters`, `shadowOversample`. Besides the
wrapper's type/index/newindex entries, no matrix, atlas, structured-buffer or
dispatch export was listed. This establishes this namespace's visible metadata,
not the absence of every possible engine resource API.

Installed `cluster_shade.cs.hlsl` also ends its 1.5 dispatch with
`lightinfoSpecOut[pix] = float4(prevSpec.rgb + accumSpecColor, 0.0)`. A clustered
dispatch after a raster marker would erase RT1 alpha. Therefore missing relay
output cannot prove that the raster shader did not execute, even when alpha
storage exists. Actual dispatch and ordering remain unverified; do not revive
the legacy alpha relay on this backend merely by altering capture timing.

The installed editor's `renderViewBuffers.lua` uses
`getAvailableNamedTexTargets(true)` to list native texture aliases. Inspecting
already registered names is a separate, read-only discovery route; it does not
bind a shadow map, provide a light/view matrix or prove atlas freshness. Its
optional `registerAllShadowMapTargets()` call changes debug registration and
must not be described as part of a read-only inventory.

Live named-target checks: before registration, log time 4580.49825 listed only
`sunShadowMask[RT0]`. After the user ran the editor's registration step, log time
4768.04492 listed `sunShadowMask[RT0]` and `shadow_0_directional[RT0]`. No target
matching local/clustered shadows was exposed by that filtered list. The mask is
consumed by `vectorLightP.hlsl` as evaluated sun visibility; it must not stand in
for a per-lamp atlas. Absence from the named registry does not prove absence of
internal shadow resources or establish which GPU path executed. A GPU capture
of the native dispatch/resource bindings is the next evidence boundary, rather
than another guessed Lua resource alias or a replacement screen-depth shadow.

### Night capture: actual clustered bindings, invalid value readback

The saved frame `BeamRT-20261022-224948_frame3682.rdc`, event 22811, reflects
compute shader `ResourceId::45967` with `clusterLights` at t4 bound to
ResourceId::68776, `shadowAtlas` at t14 bound to ResourceId::676 (8192x8192 D16),
and `shadowViews` at t15 bound to ResourceId::70698. Camera `prepassDepth` at t0
is a different resource, ResourceId::994 (2560x1369 D24S8). Resource IDs are
capture-local evidence, never runtime identifiers or Lua resource aliases.

The captured reflection confirms column-major 4x4 projection matrices and
member offsets matching the installed ClusterLight/ShadowView declarations.
The 160/80-byte record strides remain an explicit ABI hypothesis checked
against member layout; descriptor elementByteSize=4 does not verify them.
Event 22811 exposes only u0 lightinfoOut, with no u1 lightinfoSpecOut or
prepassBaseColor. Do not infer the optional BNG_LIGHTING_1_5 branch or an RT1
alpha overwrite from its presence in the installed source.

The 2026-10-23 bounded readback returned exactly 166,560 light-buffer bytes,
960 shadow-view bytes and 272 constant-block bytes, but every byte was zero.
This includes zero screen dimensions and zero view/inverse-view matrices.
These are unusable camera/lighting inputs, not evidence that no lamps cast
shadows or that the native renderer uses screen-depth tracing. A separate
metadata-only query returned ResultCode.Succeeded and no new debug messages;
there is no confirmed fatal-device-error explanation. The replay log was empty.

`tools/beamrt_cluster_capture_records.py` decodes local capture JSON offline,
checks payload lengths/SHA-256, reflected offsets/types, matrix storage, finite
values, referenced view ranges/atlas rectangles and camera inverse consistency.
It rejects this zero-camera readback. It does not connect to the game, bind
engine-owned resources, inject a DLL, change native shaders or feed beauty/GI.
No capture-local ID, guessed matrix, zero value or stale record may bypass the
existing runtime availability guards. The next gate is trustworthy value
readback and a proven resource handoff, not another raster-material hook.

#### CPU recovery from recorded uploads, 2026-10-23

A separate fresh GPU replay with BeamNG closed still returned zero bytes in
all three payloads. It stalled during owned-controller shutdown; termination
was requested only for that helper after checking its exact command line. Later
Get-Process could not resolve that PID although CIM still listed it; clean
controller shutdown is not certified. The user's
original RenderDoc UI session and every source capture were preserved. No
fatal replay status was reported, and the zero-readback cause is unresolved.

CPU-only structured capture inspection recovered nonzero bytes from upload
resource 47072's recorded coherent mapped write (chunk 33280, buffer index
6854). The saved CopyBufferRegion at chunk 16132 copies 960 bytes from offset
129737728 into shadowViews resource 70698. Chunk 16151 copies 29760 bytes from
offset 129738752 into clusterLights resource 68776. Both use command list 782;
the saved mapped write precedes its submission. The 272-byte camera block is
recovered at its captured CBV offset 129838080. These are recorded upload
slices, NOT successful GPU readback or verified atlas depth contents.

With the reflection-checked 160/80-byte layout, the copied data contains 186
light records and 12 shadow views. Twelve spotlights reference one view each;
all ranges and atlas rectangles pass validation. disableShadows=0, dimensions
are 2560x1369, and the view/inverse-view product's maximum identity error is
5.6e-5. Algebraic checks of all twelve views put each emitter at clip w near
zero and its forward axis near the projection centre; depth decreases with
distance. This supports true world-to-light projection with column-major
storage, rather than camera UVs masquerading as light-space coordinates.

Do not call 186 lights active at every receiver: cluster selection was not
decoded. The other 174 records have no assigned shadow view in this upload,
but that does not establish their shadow-casting settings or why they lack a
map. Four of the twelve mapped lights have fractional shadowStrength. Native
map allocation/fading can therefore matter even with real light-space maps;
this capture alone does not identify the user's view-dependent-shadow cause.
Streetlamp ownerId values are zero, so that field does not identify the
selected scene streetlight. The last two mapped records share nonzero ownerId
74162; no live scene-object identity was inferred from that capture-local value.

The decoded report explicitly retains dataSource=recorded_uploads,
gpuReadbackVerified=false, runtimeBindingEstablished=false,
atlasDepthContentsVerified=false and offscreenCasterVerified=false. A safe
per-frame compute-resource export/consumer remains unimplemented; legacy
material gates and all native beauty/GI behavior remain unchanged.

The subsequent [captured compute bridge contract](clustered-shadow-bridge.md)
pins the exact shader/root blobs and SDK-decodes the eight-parameter layout.
Actual root-SRV calls bind the four structured inputs directly; the current
single-SRV-table capture prototype does not observe that mechanism. This is
an offline implementation target, not permission to activate a native hook.

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
an early capture immediately after `AL_LightBinMgr`, not in the late display.
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

One owned 1x1 RGBA32F producer emits the frame tag before `AL_LightBinMgr`. The native
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
per-draw setShaderConsts callback (corrected in v0.130.5). Unscheduled captures
report stage 13 before reading alpha.
This is a lifecycle correction, NOT proof that the live relay now succeeds.

The v0.130.2 test stopped on its first update (epoch 32) with `Native diagnostic
pass modified`. The child guard incorrectly required `isEnabled()` on on-demand
effects: their `enable()` is not a normal manager registration. v0.130.3 only
requires scheduled roots/View to be enabled, while still checking child identity,
parent attachment, timing, textures, target and current scheduling authorization.
The mock now models on-demand `enable()` as a no-op so this regression is covered.
This matches the upstream
[PostEffect implementation](https://raw.githubusercontent.com/TorqueGameEngines/Torque3D/development/Engine/source/postFx/postEffect.cpp),
but passing lifecycle checks still does not prove BeamNG GPU dispatch.

The next v0.130.3 run stopped at the attachment check. That check used direct
Lua wrapper equality for `getObject(0)`, although engine collection enumeration
can return a base SimObject wrapper. Installed editor code explicitly upcasts
enumerated objects (for example `editor/audioEventsList.lua`). v0.130.4 compares
positive registered engine IDs instead; registry ownership checks still reject
replacement objects, and the scheduler must contain exactly one expected child.
Attachment is now checked immediately after add, before changing native material
fields. Real count/ID mismatches are retained in status and included in the error.
The fixture returns distinct base wrappers so the old comparison would fail.

The v0.130.4 image showed stage 10: the snapshot signature was valid but its
epoch was stale. A later status showed normal frame-tag exhaustion, with the
old implementation having discarded pass evidence during cleanup. This is not
evidence of a successful native draw or of the exact stale-data cause.
v0.130.5 addresses a definite callback cadence error: preProcess can be cached
after initial setup, so it cannot authorize each frame. Scheduling now uses
setShaderConsts, invoked by real 1x1 RGBA32F scratch draws rather than skip-draw
parents. Frame/Capture children still own their persistent outputs. Per-draw
counters and setup counters are separate; the last pass snapshot survives stop
and timeout. One compact progress log is emitted at epoch 64. All are CPU
evidence only; a missing/unused AL_LightBin dispatch may still prevent capture.
The lifecycle test models three draws with only one preProcess and confirms
fresh authorization for each epoch, plus rejection of lazy-child authorization.

v0.130.5's scheduler guard stopped before drawing because the false `skipDraw`
native field was exposed as string "0" while direct userdata property access
returned nil. v0.130.6 uses explicit native field readback and recognized bool
representations; unknown values are still refused. Each scheduler condition
reports its exact field and actual/expected values. Readback is checked before
the native material lease, not only on the next frame.

The v0.130.6 log provided decisive CPU evidence: FrameScheduleFx and
CaptureScheduleFx had zero setup and draw calls, both on-demand children had
one lazy call, while ViewFx had hundreds of draws. Consequently the early hooks
were not firing; stage 10 was a stale lazy snapshot, not native shadow output.
The installed executable contains AL_LightBinMgr as the registered manager name,
whereas our hooks used AL_LightBin. Upstream PostEffectManager dispatch keys
events by bin->getName(), not a render-bin-type label. v0.130.7 resolves and
validates the actual AL_LightBinMgr object/class/ID, then uses its registered
name for both hooks. A callback watchdog at epoch 64 restores on either zero
early draw count. The fixture emits named bin events to distinguish the two
names and tests rejection of an absent manager before native writes. This
corrects a scheduling mismatch, not yet a claim of a live GPU visibility relay.

The v0.130.7 live log confirmed 31 callbacks each for both roots, both children
and ViewFx at epoch 64. The image was uniformly gray: the capture/display
contract reached an unknown packet, not proven light or shadow. An engine query
using the same ImTextureHandler/getFormat path as the installed
`editor/renderViewBuffers.lua` reported GFXFormatR16G16B16A16F for lightinfo RT1.
This rules out a three-channel-only format, not alpha write masks or a bypassed
native shader/material path.

v0.130.8 provides explicit dispatch and selector modes, never mixed with
visibility decoding. In dispatch mode, the private native PS writes -0.125 to
outB.a for any surviving draw of its light kind. Selector mode does so only for
the matched tuple. Both bypass the extra native frame sampler. RGB, native BRDF
and native attenuation remain unchanged. Capture accepts only negative 1/8
multiples (1..256 accumulated markers); zero is absent and all other patterns
are invalid. The negative marker avoids accepting common 0/1 fallback alpha as
successful dispatch. Snapshot epoch, scheduling and dimensions remain checked.
Cyan represents dispatch-marker coverage, orange represents tuple-marker
coverage, gray is absent, and 18 bars means unexpected alpha. These are NOT
shadow masks, and a missing marker cannot distinguish shader non-dispatch,
discarded alpha writes or another transport problem. The shaders compile in
all 144 point/spot/probe/cookie/depth/shadow permutations; execution remains a
live verification gate.

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
