# BeamRT v0.078 handoff addendum

User A/B testing established that Screen DDA looks comparable to the 32-path
linear Beauty Max trace while linear is unplayable. Inspection explains both
results: Beauty Max deliberately disables `worldGIStrength` and
`secondBounceStrength`, then uses restrained GI exposure/strength, so it is a
neutral artifact baseline rather than a conspicuous PTGI look. Its 32 x 160
linear trace budget mostly reduces noise already handled by temporal filtering.

Two gameplay presets now expose the useful DDA path. `ptgiplay` uses one
full-resolution Screen DDA path (bounded by the existing 32-step/1-path safety
cap), corrected transport, STBN, full SVGF, direct-diffuse source cleanup,
stronger receiver color transport, and a guarded 0.22 previous-GI bounce. It
keeps world surfels disabled because their coarse off-screen representation was
the source of earlier smoky/leaky artifacts. `ptgiplayreflect` copies the exact
same settings and enables the reflection overlay at 0.85 strength with a 0.46
roughness cutoff. The tuner buttons are **PTGI DDA** and
**PTGI DDA + REFL**. No shader source changed in this revision.

---

# BeamRT v0.077 handoff addendum

The reported reflection sliding was not a BeamNG velocity-sign error. BeamNG's
own GTAO reprojection documents velocity as `last_uv - cur_uv` and uses
`previousUv = uv + velocity`, matching BeamRT. The failure was treating
view-dependent SSR radiance like surface-attached diffuse history: v0.020 kept
up to 82% history after reprojecting only the receiver, even though camera motion
changes the reflected ray and therefore its hit.

The active temporal entry is now `beamrtReflectionTemporalP_v021.hlsl`. It
enables motion-aware view-history rejection in the preserved v0.020
implementation: history fades between 0.35 and 6 pixels/frame, while the blend
becomes fully current-frame dominant by 3 pixels/frame. Static-camera
accumulation and the existing edge-aware spatial filter are unchanged. This
trades some moving-camera grain for correct attachment and no long reflection
drag. Runtime validation is still required.

---

# BeamRT v0.076 handoff addendum

Runtime feedback found v0.075 reflections barely visible. The compounded
dielectric F0, squared gloss, 0.65 strength, and trace confidence commonly drove
the final replacement below 1%. The active composer is now
`beamrtReflectionComposeP_v022.hlsl`: it preserves material F0 but applies
`1-exp(-3F)` for bounded display visibility and changes gloss from squared to a
1.25 power. Beauty + Reflections now uses strength 1.0 and roughness cutoff 0.50.
Beauty Max remains reflection-free.

---

# BeamRT v0.075 handoff addendum

v0.075 integrates the existing screen-space reflection chain as an optional
overlay in lighting mode. `reflectionOverlayEnabled` defaults false, so existing
presets and saved baselines do not silently change. `beautyreflect` clones every
Beauty Max setting and then enables reflections at strength 0.65 with a 0.42
roughness cutoff.

The active compose entry is `beamrtReflectionComposeP_v021.hlsl`. It binds
`#prepass[RT1]` at slot 3 and uses its RGB specular/F0 in a colored Schlick
Fresnel term. This replaces v0.020's `lerp(0.22, 1.0, fresnel)` minimum, which
applied about a 25% reflection replacement even to head-on dielectrics. The
legacy composer remains on disk for A/B.

The pass is still screen-space and retains the v0.020 trace/temporal limitations.
It is deliberately complementary to BeamNG native probes, not a claim of
off-screen or ray-traced reflections.

---

# BeamRT v0.074 handoff addendum

The Nsight capture `BeamNG.drive.x64_2026_09_28_20_26_43.ngfx-capture`
isolated the large warm lighting jump to the final composition region. Source
inspection then exposed the underlying material error: composition treated the
traced value as ready-to-add outgoing light and only tinted it using backbuffer
chroma. It never applied a receiver reflectance magnitude.

BeamNG's material writer confirms `#prepass[RT1].rgb` is specular/F0, not
diffuse albedo, despite one decoder's historical `baseColor` field name. v0.074
therefore binds `#lightinfo[RT0]` at compose slot 5 and `#prepass[RT1]` at slot
6. It estimates bounded diffuse reflectance from final surface radiance divided
by direct lighting, uses a stable compressed-luminance fallback in weak light,
and collapses the diffuse lobe for metal-like F0. `giReceiverTint` controls hue
preservation. Existing roughness and confidence gates remain active.

Active compose entry: `beamrtLightingComposeP_v074.hlsl`.

---

# BeamRT v0.073 handoff addendum

v0.073 is an accuracy/reconstruction repair driven by the showroom `hits`,
`confidence`, and `rejection` captures. Those captures showed sparse accepted
hits concentrated on wheels, rocker panels, and silhouettes, while the temporal
and composition stages subsequently treated their reconstructed color as fully
supported GI.

- `#BeamRT_TemporalGI.a` now preserves accumulated ray-hit support/confidence.
  Reprojection depth comes from `#BeamRT_HistoryMoments.a` instead.
- Temporal spatial filtering no longer gives unsupported misses a fixed 15--20%
  vote. Neighbor support is accumulated alongside radiance.
- Final GI reconstruction normalizes against compatible geometric coverage,
  not merely the few supported radiance samples. A lone bright hit therefore
  cannot expand into a full-strength smooth coating.
- Low-roughness receivers use a more conservative diffuse response. This is not
  a replacement for true receiver albedo/metallic data, but it stops polished
  paint and wheel metal from accepting the old 35% minimum diffuse throughput.
- The bounded DDA one-path limit now applies only when screen tracing is active.
  World-only mode keeps its configured path count even if the DDA selector was
  left enabled. Lua's denoiser path-count calculation uses the same rule.
- New `BEAUTY MAX` / `beamrt_main.applyPreset("beautymax")` is an accuracy-first
  screenshot preset: 32 paths, full resolution, 160 linear steps, corrected
  estimator, BeamRT STBN, guarded temporal/SVGF reconstruction, and screen-only
  GI. It intentionally excludes experimental DDA and coarse world surfels.

Active entries are `beamrtGITraceP_v073.hlsl`, `beamrtTemporalP_v070.hlsl`, and
`beamrtLightingComposeP_v073.hlsl`. All three compile successfully as SM5 pixel
and vertex shaders under FXC strictness and warnings-as-errors. Runtime image
quality remains to be accepted in BeamNG.

First runtime gate:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); print(beamrt_main.getVersion())
beamrt_main.start()
beamrt_main.applyPreset("beautymax")
```

The version must print `0.073`, the tuner must show `BEAUTY MAX`, and status
should report screen GI plus the linear marcher. Judge the stationary image only
after history warms. Then orbit slowly and verify that the previous wheel/rocker
shine does not expand or flash. The preset is deliberately expensive.

---

# BeamRT v0.072 handoff addendum

v0.072 adds an independent BeamRT-owned spatiotemporal blue-noise experiment.
It does not copy NVIDIA STBN SDK code or textures. The reproducible generator
is `tools/generate_beamrt_stbn.py`; its checked-in output is a 1024x1024 RG
atlas containing 64 128x128 frames in an 8x8 layout:

- `shaders/beamrt/beamrtSTBN_128x128x64_rg_atlas.png`
- `shaders/beamrt/beamrtSTBN_128x128x64_rg_atlas.dds` (runtime, linear RGBA8)
- `shaders/beamrt/beamrtSTBN_128x128x64_rg_metrics.json`

The candidate is rank-uniform in both channels and uses alternating spatial
and temporal spectral projections. Its measured low/mid-frequency ratios are
about 0.0013 spatially and 0.0076 temporally, with RG correlation about 0.0011.
The active GI shader is now `beamrtGITraceP_v072.hlsl`.

The old BeamNG GTAO 2D noise path remains intact for a controlled A/B:

```lua
beamrt_main.setGIPathCount(1)
beamrt_main.setBlueNoiseStrength(1)
beamrt_main.setBlueNoiseSource("beamng")
beamrt_main.resetHistory()
-- capture the same fixed view after 64 or 128 frames
beamrt_main.setBlueNoiseSource("stbn")
beamrt_main.resetHistory()
-- capture after the same number of frames
```

Use identical camera, exposure, path count, and warm-up. At a fixed pixel the
STBN path advances through all 64 temporal slices; under motion it should still
retain spatial blue-noise behavior, but motion/reprojection can hide much of
the temporal advantage. This experiment improves sample distribution only. It
does not repair an invalid screen-space hit or add off-screen geometry.

`setBlueNoiseSource()` accepts `stbn` or `beamng`, resets temporal history, is
reported by status/settings, appears in copied tuning commands, and is exposed
in the tuner as `BEAMRT STBN` / `BEAMNG GTAO 2D`. STBN is the v0.072 default.
The shader binds the explicit linear `R8G8B8A8_UNORM` DDS rather than allowing
PNG color-space handling to warp random values. The PNG remains a convenient
preview. All 14 active shader entries compile in both SM5 stages (28/28).
Runtime image quality still requires the in-game A/B above.

NVIDIA repository triage: NRD is immediately useful as a denoiser architecture
reference (demodulation, moments, confidence, depth/normal/motion guidance),
while RTXPT is a useful future native-backend reference. RTXMG, OMM, and RTXMU
operate around native ray-tracing resources/acceleration structures and are not
drop-in facilities for the current GELua/PostFX path.

---

# BeamRT v0.071 handoff addendum

v0.071 separates two issues exposed by the v0.070 test: screen-depth coverage
and motion-time sampling noise.

- Long exposure no longer clears GI history on every moving frame. While the
  camera is moving it automatically enters `motion temporal`, keeps the
  depth/normal/outlier-guarded short history, uses the ordinary current-frame
  weight, and continues advancing the blue-noise sequence. When the camera
  stops, the first stationary batch has weight one and begins a clean
  progressive exposure.
- FOV and resolution changes still perform a hard reset. A real log audit found
  that stationary `RenderView.fov` jitters by roughly 0.00001--0.00008 degrees;
  exact equality was therefore resetting a 16-path exposure after only 32--48
  samples indefinitely. v0.071 treats changes up to 0.001 degrees as numeric
  noise. This is not a user-visible FOV tolerance: any material projection
  change still invalidates immediately.
- `direction` encodes the deterministic world ray as RGB. It should remain
  stable on a rigid surface while orbiting.
- `viewalignment` displays rear-facing rays in red, forward-facing rays in
  green, and transverse rays in blue. It explains when a stable ray loses
  access to the one-sided visible depth buffer.
- `hits` can still appear to move away from the view center even when
  `direction` is stable. That is a screen-space representation limitation, not
  necessarily a moving ray.
- The v0.070 one-path/32-step bounded DDA and preset containment remain.
- The misleading `EXPERIMENTAL WOW` tuner label is now `SCREEN DDA AUDIT`;
  `Balanced` or `Cinematic` is the intended beauty baseline.
- All 14 active entries compile in both SM5 stages (28/28), and Lua syntax
  parsing passes. Runtime validation is pending.

Test from the same camera path:

```lua
beamrt_main.setRayHitDiagnostic("direction")
beamrt_main.setRayHitDiagnostic("viewalignment")
beamrt_main.setRayHitDiagnostic("hits")
dump(beamrt_main.getProgressiveStatus())
```

During camera motion, status should say `runtimeMode = "motion temporal"`; once
stationary it should change to `stationary progressive` and samples should
begin increasing. `beamng.log` must no longer repeat `FOV changed from
65.0000...` for a stationary view.

---

# BeamRT v0.070 handoff addendum

v0.070 is a containment/correctness milestone after in-game testing showed that
the experimental Screen DDA was both prohibitively expensive and visually
untrustworthy. It does not claim to make screen-space diffuse tracing complete.

- Active GI entry: `shaders/beamrt/beamrtGITraceP_v070.hlsl`.
- v0.067 remains available as the previous unbounded DDA A/B entry.
- The live saved tuning was full resolution, 16 paths, and 128 steps. That can
  request about 4.2 billion depth traversals per 1080p frame before hit
  refinement/validation. A non-hierarchical pixel DDA cannot make that cheap.
- Screen DDA is now explicitly a bounded near-field experiment: at most one
  path and 32 real screen-pixel/world-step samples. It no longer spreads a
  small sample count across the complete projected ray, which skipped surfaces
  and promoted distant road markings into sharp reflection-like GI hits.
- The DDA cap limits both pixel traversal and world reach. Screen misses remain
  eligible for the existing world/surfel fallback in hybrid mode.
- Ray diagnostics use one deterministic world-oriented hemisphere direction.
  They no longer inherit the screen-pixel blue-noise value, so moving a surface
  to another part of the screen cannot change the ray being inspected.
- The `EXPERIMENTAL WOW` preset is now a half-resolution 1-path/32-step DDA
  audit preset with two refinement steps and one candidate retry.
- Every non-experimental beauty preset explicitly selects `linear`. Previously,
  selecting Screen DDA and then clicking Cinematic/Ultra/etc. silently retained
  DDA and could run it at 16x128 or 32x200.
- v0.069 camera-motion temporal history protection remains active.
- All 14 active entries compile as both SM5 pixel and vertex shaders with FXC
  `/Ges /WX` (28/28). Lua syntax parsing passes. Runtime acceptance is pending.

First runtime gate:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); print(beamrt_main.getVersion())
beamrt_main.start()
beamrt_main.applyPreset("experimental")
beamrt_main.setRayHitDiagnostic("hits")
```

The tuner must show v0.070. Orbit slowly: this stable diagnostic may still lose
hits when the chosen ray leaves visible screen-space depth, but its pattern must
not change merely because blue noise moved to a different pixel. Then test the
beauty baseline independently:

```lua
beamrt_main.setRayHitDiagnostic("off")
beamrt_main.applyPreset("balanced")
```

Balanced must report `linear`. Do not use Screen DDA as a beauty mode until a
real hierarchical-depth traversal or better world representation exists.

---

# BeamRT v0.067 handoff addendum

v0.067 is a controlled ray-diagnostic and experimental Screen DDA repair.
It preserves the complete v0.066 shader and shared v0.065 core on disk.

- Active GI entry: `shaders/beamrt/beamrtGITraceP_v067.hlsl`.
- `beamrtGITraceP_v066.hlsl` remains the exact immediate fallback.
- Ray diagnostics now use the already-frozen `sequence` for the true
  blue-noise/Weyl frame. Previously they used live `giFrameIndex`, so the
  supposedly fixed diagnostic direction changed every frame. Progressive
  camera-motion resets masked this while moving and exposed it while still.
- Screen DDA begins at the projected normal-biased ray origin instead of the
  un-biased source pixel.
- A ray whose far endpoint passes behind the eye is clipped at positive
  projected depth instead of being discarded completely.
- The projective line is clipped to the viewport before its iteration budget
  is calculated.
- DDA now covers the complete clipped segment while retaining the configured
  world-step budget. Its bounded samples are distributed across the whole
  segment instead of silently tracing only its beginning. An initial v0.067
  draft incorrectly expanded shorter budgets toward 512 screen samples and was
  immediately corrected after an in-game performance regression.
- Subpixel or degenerate DDA projections fall back to the existing linear
  world-step marcher rather than returning an immediate miss.
- Continuous progressive camera movement no longer writes a reset message every
  frame; the current reset reason remains available through status reporting.
- Both pixel and vertex stages compile with FXC `/Ges /WX`; BeamNG runtime and
  visual acceptance remain pending.

First runtime gate:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("VERSION " .. tostring(beamrt_main.getVersion()))
beamrt_main.start()
beamrt_main.setGIPathCount(1)
beamrt_main.setRayHitDiagnostic("rejection")
beamrt_main.setRayMarcher("linear")
-- Hold still: the diagnostic must no longer change frame to frame.
beamrt_main.setRayMarcher("screendda")
-- Compare stable rejection coverage, then inspect "hits", "steps", and "distance".
```

Do not judge final GI brightness from diagnostic modes. After acceptance, turn
the diagnostic off, reset history, and warm each marcher separately.

---

# BeamRT v0.066 handoff addendum

v0.066 preserves all v0.065 architecture and changes only primary diffuse-ray
sample generation when `giBlueNoiseStrength > 0`.

- Active GI entry: `shaders/beamrt/beamrtGITraceP_v066.hlsl`.
- `beamrtGITraceP_v065.hlsl` remains the direct fallback.
- The shared v0.065 core is conditionally extended behind
  `BEAMRT_TRUE_BLUE_NOISE`; compiling the v0.065 wrapper does not enable it.
- Full strength uses BeamNG's shipped 128x128 GTAO blue-noise channels directly
  for stratified cosine radius and azimuth rotation.
- Temporal offsets use BeamNG GTAO's two 32-bit fixed-point Weyl multipliers
  (`2447445413u`, `3242174893u`).
- Strength zero retains the exact v0.065 hash construction.
- Startup default is strength one for deliberate experimental A/B testing.
- No ray/path ceiling, hit acceptance, lighting equation, temporal equation,
  cache layout, or composer behavior changed.
- All 14 active shader entries compile with FXC `/Ges /WX` as both `ps_5_0`
  and `vs_5_0` (28/28). Runtime image quality and performance remain unclaimed
  until BeamNG testing.

Primary A/B:

```lua
beamrt_main.setGIPathCount(1)
beamrt_main.setBlueNoiseStrength(0) -- v0.065 hash
-- warm history and capture
beamrt_main.setBlueNoiseStrength(1) -- true blue noise + Weyl
-- warm fresh history and capture
```

Compare 1, 2, and 4 paths. Look for loss of pulsing/structured waves and noise
that appears finer and less clumped; do not expect it to remove noise without
temporal/variance reconstruction.

---

# BeamRT v0.065 handoff addendum

Current active changes over v0.064:

- Screen DDA and Linear can continue after recoverable rejected candidates instead of always terminating at the first candidate. `setCandidateContinuation(0)` is the v0.064 A/B control; default is 1. Retry budget defaults to four and is capped at eight.
- Clean-source screen hits split reflected and native emissive radiance. `setEmissiveSeparation(1)` removes the extra reflector-facing cosine from `Material_Emissive`; zero restores v0.064 weighting.
- The Material Debug cache bridge now publishes BaseColor, Opacity, Metallic, Roughness, AmbientOcclusion, NormalsWS, Emissive, ClearCoat, and ClearCoatRoughness. `publishMaterialV2Caches()` serializes all nine captures and aborts if the camera moves.
- `#BeamRT_EmitterClass` is a normalized diagnostic: red=emissive-dominant, green=direct-diffuse-dominant, yellow=mixed.
- Only BaseColor/Metallic/Emissive remain required for CleanRadiance. New Material V2 caches are diagnostic-only until accepted.
- Deferred intentionally: ambient SH + AO reconstruction, exposure-independent cache storage, glossy/specular transport, and clear-coat transport.

Primary first test:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("VERSION "..tostring(beamrt_main.getVersion()))
beamrt_main.start()
beamrt_main.setPTGIRadianceSource("clean") -- only after existing 3-cache CleanRadiance is valid
beamrt_main.setCandidateContinuation(1)
beamrt_main.setCandidateRetryCount(4)
beamrt_main.setEmissiveSeparation(1)
```

For the fluorescent/tank diagnosis, capture Material V2 while stationary, rebuild CleanRadiance, then inspect `emissiveCache`, `directDiffuseRadiance`, and `emitterClass` before judging beauty output.

---

# BeamRT coding handoff

Last updated: 2026-09-24

## Executive status

BeamRT is an unpacked BeamNG.drive PostFX research mod targeting BeamNG `0.39.4.0.20972` on D3D12. The accepted renderer baseline is **v0.005a / Phase 4**: screen-space one-bounce diffuse GI with temporal accumulation, velocity reprojection, depth rejection, motion-aware history clamping, and a small bilateral filter.

The files currently on disk identify as **v0.067**. Milestones through v0.012 passed their intended gates; v0.020 reflections remain optional because BeamNG already has useful car reflections. v0.030/v0.031 established the current lighting and beauty-composition path. v0.032 added the working in-game ImGui tuner, presets, tuning persistence, and command export. v0.040/v0.041 added scalable path count/resolution, cache-leak suppression, exact numeric entry, and staged 32-path/512-step laboratory ceilings. v0.050 added the current photographic lighting controls. v0.051 added diffuse-like cleanup to both live screen hits and persistent-cache input; `beamng.log` confirms clean v0.051 loads using the intended v0.051 GI/cache and v0.050 composer.

v0.052 is a **low-risk optimization-only milestone**. It deliberately leaves the Monte Carlo estimator, linear ray-step sequence, surfel count, lighting design, and progressive accumulation unchanged. The active temporal shader reuses center samples and avoids G-buffer neighborhood decoding when spatial denoise is zero. The composer selects 5/9/13 reconstruction taps for full/75%/half GI scale while preserving the old eight-sample contact grounding. Static surfel geometry uploads now use per-effect dirty/rebind flags. Screen-only GI disables the two-pass surfel-cache root. Diffuse basis/hash invariants and ray-projection intercept/slopes are hoisted out of inner loops. CPU surfel acquisition now builds a pending set at a configurable ray budget and atomically swaps it without discarding the previous completed set. All nine active v0.052 shaders compile cleanly in both stages with warnings treated as errors; BeamNG runtime and visual-equivalence testing are pending. This remains a hybrid PostFX lighting experiment, not DXR or a replacement renderer.

v0.053 adds only a **temporary native named-buffer diagnostic mode**. It registers one cache-busted fullscreen shader and six fixed-bound PostEffects for `#sunShadowMask[RT0]`, `#lightinfo[RT0]`, `#lightinfo[RT1]`, `#prepass[RT1]`, `#gtaoOutput[RT0]`, and `#ssaoMask[RT0]`. The diagnostic is mutually exclusive with all normal BeamRT output effects and never enters the GI, temporal, reflection, or surfel-cache chains. Raw display is the default, with RGB/R/G/B/A, gain, exposure, and an explicit optional BeamNG HDR interpretation. All ten registered shaders compile in both stages with warnings treated as errors; named-target availability and semantics require in-game testing.

No BeamNG base-game file has been modified.

## v0.060 conservative clean-radiance PTGI integration (current milestone)

v0.060 connects the accepted frozen `#BeamRT_CleanRadiance[RT0]` target to both radiance-consumption paths without changing the temporal filter, composer, ray-count ceilings, or Monte Carlo estimator. The active cache-busted entries are `beamrtGITraceP_v060.hlsl` and `beamrtSurfelCacheP_v060.hlsl`. `legacy` remains the startup/reload default and preserves the v0.056 beauty-derived source. `clean` samples the already-linear material-aware target directly: it is not HDR-decoded and is not multiplied by material or lighting terms again.

Public selection is explicit:

```lua
beamrt_main.setPTGIRadianceSource("legacy")
beamrt_main.setPTGIRadianceSource("clean")
beamrt_main.getPTGIRadianceSource()
```

`clean` can be selected only when CleanRadiance is valid, non-stale, backed by all four enabled frozen target owners, generation-consistent with the current BaseColor/Metallic/Emissive caches, bound to both the live GI and surfel-cache paths, and still matches the real camera snapshot from the CleanRadiance build. Camera validation ignores projection jitter and compares against the build snapshot—not the previous frame—with strict v0.060 tolerances of 0.01 m and 0.05 degrees. FOV and resolution mismatches invalidate immediately. Each individual material-cache publication also checks that the camera did not move during its one-frame capture.

Every material cache carries a monotonic generation. CleanRadiance records the three source generations plus its own generation. This rejects mixed-generation BaseColor/Metallic/Emissive combinations even when all targets still exist. `getCleanRadianceDiagnostics().feedsPTGI` is true only when the public selection is `clean` and every validity, generation, binding, ownership, and camera check passes.

If any selected-clean guard fails—camera/FOV/resolution, a source cache, a generation, a clean-target owner/binding, shader/graphics/settings changes, mission changes, or extension teardown—the public selection immediately becomes `legacy`, temporal GI history is reset, and the RGB/validity content of the persistent surfel-radiance atlas is cleared on the following cache frames. Geometry surfels are retained. The exact reason is logged as `clean PTGI source became stale: ...; falling back to legacy`. There is deliberately no automatic material recapture in this milestone.

The v0.059 clean shader and all v0.056/v0.054/v0.052/v0.051 fallback entries remain on disk. `main.lua` passes `luaparser` and remains at 198 top-level locals. All 11 active entries compile as both SM5 vertex and pixel shaders with FXC `/Ges /WX` (22/22); the two v0.056 GI/cache fallback entries also compile in both stages, for 26/26 total verification outputs. In-game runtime and visual acceptance are still required; no FPS or visual-quality claim is made from offline compilation.

SHA-256 after the v0.060 implementation pass:

```text
main.lua                               3BCE920A883D604ED42402FAEFB7644399589C1629C8D3E93A31B404647A22E8
beamrtGITrace_v051.h.hlsl              04FB8B0B44666CB20695C9EA4C9A948B5E572DF28C8EBFFF02ED451AC8B64D6B
beamrtGITraceP_v060.hlsl               4695F091069599A37DB727A8D5B6E1F90578E8DED18FE60576B01CCF2DE4D4D7
beamrtSurfelCacheP_v060.hlsl           360700432554C4CAEC2E0254A49A10AD96B80089C0A6BC9A7C7D7808CBF84525
beamrtCleanRadianceP_v059.hlsl         C115927B76C0BC54CB6C54332170AC1C0DC35F3FA9C12E2F4BFA01F536B95494
README.md                               B7BFCCFD40AA4F002F38BA423C683CA4DCFEE022181EEDBBEF6015F19CD93952
```

## v0.059 clean material-aware radiance diagnostics (accepted input milestone)

The accepted v0.058 BaseColor, Metallic, and Emissive caches now feed a separate one-frame diagnostic shader. BeamNG source inspection confirms that the Material Debug path returns `material.baseColor`, `material.metallic`, and `material.emissive` directly, while the normal final-color path applies HDR encoding later. The diagnostic therefore keeps all material/light calculations in linear working space without guessed sRGB, gamma, or HDR conversions.

One call to `beamrt_main.refreshCleanRadianceDiagnostics()` builds and freezes four full-resolution `R16G16B16A16F` named targets:

```text
#BeamRT_DiffuseAlbedo          = BaseColorCache.rgb * (1 - MetallicCache.r)
#BeamRT_DirectDiffuseRadiance = DiffuseAlbedo * #lightinfo[RT0].rgb
#BeamRT_MaskedEmissive        = validSurface ? EmissiveCache.rgb : 0
#BeamRT_CleanRadiance         = DirectDiffuseRadiance + MaskedEmissive
```

`validSurface` comes from `#prepass[Depth]`, preventing the bright sky/background seen in the native Emissive debug view from entering clean radiance. The four target owners follow the proven persistent-cache lifecycle: enabled plus `skip=true` while frozen, `oneFrameOnly=true`, and `onThisFrame=true` only while armed. They are selectable as `diffuseAlbedo`, `directDiffuseRadiance`, `maskedEmissive`, and `cleanRadiance` in existing raw buffer diagnostics.

This milestone did **not** alter `beamrtGITraceP_v056.hlsl`, `beamrtSurfelCacheP_v056.hlsl`, temporal filtering, composition, or the live PTGI radiance-source selector. v0.060 is the first milestone that consumes the accepted CleanRadiance target in PTGI.

The first v0.059 draft exceeded BeamNG LuaJIT's 200-local limit in the `main.lua` top-level chunk and could not load. The clean-radiance constants, state, and helpers are now consolidated under one internal table, with 198 top-level locals. This is a structural fix only; the diagnostic equations and lifecycle are unchanged.

SHA-256 after the v0.059 implementation pass:

```text
main.lua                               D45D994FD4B439D3DE5F76158CFC16A5FDF2D75FDED402EF492604DA766985B5
beamrtCleanRadianceP_v059.hlsl         C115927B76C0BC54CB6C54332170AC1C0DC35F3FA9C12E2F4BFA01F536B95494
beamrtCleanRadiance_v059.h.hlsl        A2B449FE2EA0F7C277E3C30AC5EE93486DC449318D2BF05DC99EC97532C79C44
```

## v0.058 persistent producer-view material caches (accepted baseline)

The cross-RenderView bridge is accepted in-game. `BeamRT_BaseColorPublishFx` reads the isolated BaseColor producer RenderView's `$backBuffer`, writes `#BeamRT_BaseColorCache`, remains enabled with `skip=true`, and leaves a frozen cache that main-view PostFX can sample. No TextureDrawPrimitive/native-copy alternative is needed.

BeamRT now creates/configures `BeamRT_BaseColorProbe` with `RenderViewManagerInstance:getOrCreateView()` using the proven `luaOwned`, non-cubemap, no-editor-icons, named-target, synchronized-camera/viewport setup. BaseColor, Metallic, and Emissive use the same serialized publication state machine. Each publisher is created enabled but dormant with `oneFrameOnly=true`, `onThisFrame=false`, and `skip=true`. Capture arms only the selected publisher with `skip=false` and `onThisFrame=true`. Completion sets `onThisFrame=false` and `skip=true` before restoring main PostFX; it never disables the publisher during normal operation, so the named target remains allocated.

Use raw RGB to inspect the producer's values without any automatic HDR decoding:

```lua
beamrt_main.publishBaseColorCache()
dump(beamrt_main.getBaseColorPublication())
beamrt_main.publishMetallicCache()
dump(beamrt_main.getMetallicPublication())
beamrt_main.publishEmissiveCache()
dump(beamrt_main.getEmissivePublication())
beamrt_main.setMode("bufferdiag")
beamrt_main.setBufferDiagnosticView("raw")
beamrt_main.setBufferDiagnosticGain(1)
beamrt_main.setBufferDiagnosticExposure(0)
beamrt_main.setBufferDiagnostic("baseColorCache", "rgb")
beamrt_main.setBufferDiagnostic("metallicCache", "rgb")
beamrt_main.setBufferDiagnostic("emissiveCache", "rgb")
```

The PTGI lighting equation and all GI/temporal/surfel/composer shaders remain unchanged. BaseColor, Metallic, and Emissive are accepted independently through their probe/cache pairs and main-view diagnostics. Cache results expose `valid`/`stale` plus publisher lifecycle state. Mission changes, settings/graphics changes, shader/material file changes, publisher loss, and extension teardown invalidate the corresponding diagnostic state.

SHA-256 at v0.058 handoff time:

```text
main.lua                              F3F06DDD56021956572D941F542F56DF63591E8A089AA538BB22D7F8D61AAC9E
```

## v0.056 direct-diffuse reconstruction correction (previous milestone)

In-game v0.054 validation rejected the original direct-diffuse material-color estimator. It normalized `cleanedSurfaceRadiance`, even though that value already contains `materialColor * lighting`, and multiplied the resulting illuminated chroma by the same colored `lightinfo0` energy again. Warm/orange direct light was therefore effectively applied twice and overwhelmed intended surface-color bounce.

The active entries are now `beamrtGITraceP_v056.hlsl` and `beamrtSurfelCacheP_v056.hlsl`. Both use the new shared `beamrtRadianceCleanup_v056.h.hlsl`, so the correction applies identically to live screen-space GI hits and to radiance entering the persistent surfel cache.

The v0.056 estimator:

1. Performs the existing roughness/depth/normal neighborhood cleanup first.
2. Samples non-specular direct-light energy from `#lightinfo[RT0].rgb`.
3. Estimates material reflectance component-wise with `cleanedDiffuseLikeRadiance / max(directLighting, 0.04)`.
4. Regularizes poorly illuminated RGB channels toward a bounded neutral scalar estimate.
5. Reconstructs `directLighting * estimatedDiffuseColor` only where direct-light luminance is trustworthy; dark/uncertain pixels retain the cleaned scene estimate.
6. Applies ordinary-opaque retroreflectivity rejection after reconstruction.

The old normalized illuminated-chroma multiplication is not used. `setRadianceSource("legacy")` still selects the v0.051 cleaned-backbuffer source for A/B, and `setRadianceCleanup(0)` still returns the exact raw decoded-backbuffer source.

The light-buffer coordinate path is also corrected. BeamNG's standard `processPostFxVert` only supplies independently transformed coordinates for texture slots 0 through 3. v0.054 bound lightinfo at slot 4 and sampled it with slot-0 prepass coordinates, so it could not honor an independent light-buffer target transform. v0.056 binds lightinfo at slot 3, converts a hit from prepass target coordinates back to viewport coordinates using `rtParams0`, and applies the engine-supplied `rtParams3` transform before sampling. The surfel atlas moves to slot 4 because its lookups are explicitly addressed and do not require screen-target UV generation. Prepass RT1 remains slot 5 and shares prepass target coordinates.

The v0.054 wrapper files, the v0.051 cleaned-backbuffer helper, and all older fallback shaders remain on disk. Offline FXC compilation passes for both active v0.056 entries as SM5 vertex and pixel stages with strictness and warnings-as-errors. Runtime color recovery and UV alignment remain the current in-game gate; do not mark this path accepted until that gate passes.

SHA-256 at v0.056 handoff time:

```text
main.lua                              29E43994878D8505833A78A7770C3911F3A739F1D08F6AA28ADC41AA62BABED5
beamrtGITrace_v051.h.hlsl             7E34554BDD208572176CB2530E9ECEB4D83F6701AF79626A7BECC9C7F7A2D539
beamrtGITraceP_v051.hlsl              07C2BBD1827953EBA8E220A5463A433FEFA85C80B56B41936FB5D8868520068B
beamrtSurfelCacheP_v051.hlsl          314D9663F8AA9CB271CA3F0AB8E48785EA7EDCE5DF7AE62AC37E06CE39EDE83D
beamrtRadianceCleanup_v056.h.hlsl     7142DBBECB0ED2F3106193EA4A4EF268DB6AB53344A97D5FE9ED3188F74DB2EB
beamrtGITraceP_v056.hlsl              AAE2EC74C3BD2B8C6C04FA4015439236388ED68F34D32F7649D8D964DCCFDDDE
beamrtSurfelCacheP_v056.hlsl          88846D666D52D36B0147487E854AE5925525EE44B45B1BACC7A1F1F61A6ECF83
```

## v0.055 verified-API provider hardening (previous milestone)

This milestone corrects the concrete gaps found when the v0.054 provider skeleton was compared with the verified runtime API inventory. It does not change the active HLSL entries or claim that provider geometry now feeds GI.

### DecalRoad correctness

- Every matched bulk record now backfills `textureLength`, `renderPriority`, `overObjects`, `detail`, `breakAngle`, `zBias`, `startEndFade`, `improvedSpline`, `useSubdivisions`, `canSave`, and `hidden` from its SceneTree object. Bulk navigation/edge data remains authoritative where present.
- Numeric Lua array positions in the bulk table are no longer treated as SceneObject IDs. Explicit record IDs/names and non-array keys remain valid aliases.
- Alias collisions are counted rather than silently replacing an earlier record.
- A cache with fallback failures, skipped fallbacks, or incomplete SceneTree coverage reports `valid=false` and returns a failed rebuild instead of claiming success.
- Stats expose `metadataBackfilled`, `coveredSceneRoads`, `coverageComplete`, and `aliasCollisions`.

### Real vehicle GPUMesh acquisition

- `vehicleProvider.lua` supports both property- and function-shaped GPUMesh bindings, checks `dataIsReady`, and uses LuaJIT FFI to copy vertex, index, normal, tangent, UV1, UV2, and packed vertex-color buffers.
- It follows the shipped `util/export.lua` ABI: count values are normally properties; flexmesh/propmesh accessors take a zero-based native index; primitive buffers use the source-confirmed `gpuPrimitive_t {startIndex,indexCount,materialId}` layout.
- Flexmesh and propmesh descriptors are enumerated. Primitive records normalize to `firstIndex`, `indexCount`, `materialIndex`, and `materialName`; propmeshes retain their own copied buffers.
- Core vertex/index acquisition failure rejects the capture. Optional-buffer/submesh problems are retained as explicit warnings.
- The copied buffers are a snapshot. A future backend must recapture/refit after deformation; no per-frame readback loop was added.

### Provider coverage and runtime safety

- Added `terrainProvider.lua`, which inventories TerrainBlock geometry metadata without inventing unresolved height/normal signatures. Sampling requires a verified caller adapter.
- Added `materialProvider.lua`, which resolves Material objects and caches the known PBR/legacy fields. DecalRoad materials are acquired automatically after a successful road build; vehicle materials are acquired after vehicle capture.
- Added `lightProvider.lua`. Its default rebuild obtains lowercase-main RenderView frustum and calls the empirically verified `findObjectListFrustum(frustum,64)`. Scene PointLight/SpotLight records retain transform, direction where available, color, brightness/intensity, reach, cones, enabled field, and shadow fields.
- Vehicle JBeam prop lights are collected separately through `core_vehicle_manager.getVehicleData(vehicleId).vdata.props`, `vehicle:getProp(pid)`, and `getLiveTransformWorld()`. Their runtime enabled/electrics state remains explicitly unverified rather than guessed.
- Forest instances now retain position, transform, scale, bounds, UID, size, radius, and materials where exposed. `rebuildNearby` no longer calls a guessed `ForestData.Circle` signature; it requires a verified query adapter or prequeried items.
- TSStatic records now retain IDs/names, transform, scale, world/object bounds, material references, and DAE keys. The default rebuild uses lowercase-main RenderView plus frustum mask 256. The undocumented `scenetree.findObjectById` fallback was removed in favor of verified `scenetree.findObject(idOrName)`.
- `sceneDatabase.lua` now registers DecalRoad, Vehicle, Forest, TSStatic, Terrain, Light, and Material providers. DecalRoad, Terrain, visible-light, and visible-TSStatic snapshots are staggered after mission start. Vehicle remains explicit because readback is large/live; Forest remains explicit until its query signature is verified.

### Honest backend routing

- `selectRayBackend("postfxHybrid")`, `postfxScreen`, and `postfxSurfels` now route to the corresponding real GI source and remain synchronized when `setGISource(...)` is called directly.
- `cpuHybrid` is marked unavailable as a standalone renderer: `Engine.castRay` is an acquisition helper inside the PostFX hybrid path, not an independent output pipeline.
- DXR remains unavailable. Provider stats explicitly report `feedsRayTracer=false` so the acquisition foundation cannot be mistaken for a completed native backend.

New/updated inspection calls:

```lua
beamrt_main.rebuildSceneDatabase("decalRoads")
beamrt_main.rebuildSceneDatabase("terrain")
beamrt_main.rebuildSceneDatabase("lights")
beamrt_main.rebuildSceneDatabase("tsStatic")
beamrt_main.captureVehicleGeometry()
beamrt_main.captureMaterial("road_asphalt_2lane")
beamrt_main.selectRayBackend("postfxHybrid")
beamrt_main.getSceneDatabaseStats()
beamrt_main.getRayBackendStatus()
```

Offline validation completed: all ten Lua files parse; mocked DecalRoad coverage verifies bulk metadata backfill plus individual fallback; mocked light, Terrain, and Material acquisitions pass; the provider registry contains all seven providers; scheduling and current PostFX backend routing pass. Vehicle FFI buffer copying and all engine-object paths still require the in-game gate.

All ten active HLSL entries remain unchanged and compile through FXC as both SM5 vertex and pixel stages with `/Ges /WX` enabled (20/20, no warnings).

SHA-256 at v0.055 handoff time:

```text
main.lua                              2D7F7F71812917AD4EE220959617D4590A6ABAE46BADC7A9C1A684707699B2F5
sceneDatabase.lua                     527BAC2E4989708F63D68483ABE11F254635463007E0781D5C1983007C161857
rayBackendRegistry.lua                442B72DB810017C0565105286FABD3567F86B21840ECF9CC0000A63F67905866
decalRoadProvider.lua                 0D0BC38A0540E9EC930AF2B4DAD6BA88E80D9F047C4996FEA783CEEFE9B9E436
vehicleProvider.lua                   F5187FB5753A4524E86E85378DE62C09C841E9F293EEC0BA35A636B1C1FC2BFD
forestProvider.lua                    D4CADB82A48F886090E0FED541A8661F7BAE85DDDF7BB1894C4B2B690A7ECDB0
tsStaticProvider.lua                  D64A781B7353C4B5406F2B2F7DE4E197891393B28F6C89EFDE1EFE06918ACD1B
terrainProvider.lua                   A8774DA126B2D9212DDA34070B53E0DFA8E989F21740C9BD6795955DF5DFE9C9
lightProvider.lua                     5E3F6AFFE7FEAC3A609082C530AC53D2099391774A5D88E37A385A32475790F5
materialProvider.lua                  8605DB90ECDB2CF80AC2E34FD66933BAD0B7E0512A861D25E514AA5BF6951D4A
```

## v0.054 implementation delta (previous milestone)

**In-game status:** the v0.054 direct-diffuse estimator below was rejected because it double-applied incident-light chroma. It remains documented as historical implementation state and preserved as a fallback shader, not as the accepted radiance formula. v0.056 supersedes it.

### Clean direct-diffuse radiance

BeamNG shader source and diagnostics established these semantics:

- `#lightinfo[RT0].rgb` is accumulated direct/diffuse lighting color.
- `#lightinfo[RT0].a` is scalar specular.
- `#lightinfo[RT1].rgb` is colored specular.
- `#prepass[RT1].rgb` is specular/F0-like material color, not diffuse albedo.
- For ordinary opaque material permutations, `#prepass[RT1].a` is retroreflectivity.

The active GI and surfel-cache entries are now `beamrtGITraceP_v054.hlsl` and `beamrtSurfelCacheP_v054.hlsl`. They define `BEAMRT_DIRECT_DIFFUSE_SOURCE` and reuse the accepted v0.052 tracer/v0.051 cache through cache-busted wrappers. The shared radiance helper conditionally binds `lightInfoTex` at slot 4 and `materialSpecTex` at slot 5.

Default source `directdiffuse` does the following at both live screen hits and before radiance enters the persistent surfel atlas:

1. Read direct-light energy only from `lightinfo0.rgb`.
2. Run the existing roughness/depth/normal neighborhood cleanup on final HDR solely to estimate bounded surface hue and reflectance.
3. Multiply direct-light energy by that bounded approximate diffuse color.
4. Downweight ordinary opaque retroreflectivity using prepass RT1 alpha.
5. Never consume RT0 alpha or lightinfo RT1 as diffuse energy.

This is explicitly approximate because ordinary PostFX has no persistent `material.diffColor` target. It preserves colorful bounce without rebouncing final-image brightness/specular energy. `setRadianceSource("legacy")` retains the v0.051 cleaned-backbuffer fallback. `setRadianceCleanup(0)` remains the exact raw backbuffer path regardless of selected source.

New controls:

```lua
beamrt_main.setRadianceSource("directdiffuse") -- aliases lightinfo/lightinfo0
beamrt_main.setRadianceSource("legacy")        -- aliases backbuffer/cleanedbackbuffer
beamrt_main.getRadianceSource()
beamrt_main.setRadianceChromaStrength(0.0)     -- neutral estimated material response
beamrt_main.setRadianceChromaStrength(1.0)     -- full bounded scene-derived hue
beamrt_main.setRetroReject(1.0)
```

Changing any source control invalidates temporal history and the persistent radiance atlas. The tuner and saved/copied settings include these controls.

### Buffer diagnostic lifecycle

Entering `setMode("bufferdiag")` now sets `enabledRequested=true` automatically. The selected diagnostic effect therefore becomes visible immediately after an extension reload. The fixed high-priority `PFXAfterDiffuse` effects and shader are otherwise unchanged. Returning with `exitBufferDiagnostic()` keeps BeamRT enabled and restores lighting mode.

### Backend-neutral scene database

`sceneDatabase.lua` owns named providers and schedules one DecalRoad build 120 frames after extension/mission start. It is intentionally separate from the PostFX ray implementation.

- `decalRoadProvider.lua` performs one `Sim.getDecalRoadData()` bulk call, indexes returned records by available key/id/name, enumerates every SceneTree DecalRoad, and automatically calls `Sim.getVerticesOfDecalRoad(id)` only for unmatched roads. A hard 256-road guard prevents a failed identity mapping from degenerating into the measured ~39-second all-road path. Records retain the native flattened 9-floats-per-edge stream plus id/name/material/navigation/layer metadata.
- `vehicleProvider.lua` lazily calls `GPUMesh.bng_getGPUMesh(vehicleID)`, retains the native live/deforming mesh object and count/material metadata, and does not duplicate the large vertex/index arrays.
- `forestProvider.lua` owns unique-asset and lightweight-instance caches and can ingest a Forest DB spatial query. It does not auto-scan all 133k items.
- `tsStaticProvider.lua` owns DAE-keyed unique-asset and instance caches and can ingest an explicit list or the empirically verified frustum-mask-256 working set. It does not yet parse DAE triangles.
- `rayBackendRegistry.lua` identifies `postfxHybrid` as active, records `cpuHybrid`, and marks `dxr.available=false`. It refuses DXR selection rather than pretending sandboxed Lua can dispatch it.

Public inspection APIs:

```lua
beamrt_main.rebuildSceneDatabase("decalRoads")
beamrt_main.getSceneDatabaseStats()
beamrt_main.getSceneProvider("decalRoads")
beamrt_main.captureVehicleGeometry() -- defaults to player vehicle
beamrt_main.getRayBackendStatus()
```

### Validation completed outside BeamNG

- Every Lua file parses successfully with `luaparser`.
- A mocked Lua runtime test built two bulk roads plus one fallback road, verified cache counts/edge counts, and confirmed lookup of the fallback record.
- The backend registry test confirmed DXR selection is rejected while unavailable.
- Active shader/sampler/texture bindings were audited: both active passes bind `#lightinfo[RT0]` at slot 4 and `#prepass[RT1]` at slot 5.
- All ten active HLSL entries compile successfully through the local FXC toolchain as both SM5 vertex and pixel stages with `/Ges /WX` enabled (20/20 compiled artifacts, no warnings).
- Previous v0.052 GI, v0.051 surfel-cache, v0.050 composer, earlier trace shaders, and accepted v0.005 composer remain on disk.

SHA-256 at handoff time:

```text
main.lua                              DED2181DC1BC63F772CDD93DC9E0245D68B4F7F34C7A0D77ADB3459344885865
beamrtGITraceP_v054.hlsl              468AEC4EFE9CE7443286523069BB9E14AD8F61ABB71D7AD348BB690092992769
beamrtSurfelCacheP_v054.hlsl          AE0C6089A4AB2F752571B3036BF8E435F18E1CD11CBF121587DFD3AC3260D9FF
beamrtRadianceCleanup_v051.h.hlsl     4553205E082AE104875CB0A97D63E147F678CD4DEC8D8C16474A69CCBD2440DE
providers/decalRoadProvider.lua       66B32A200F6CDF171891F220A9C1268B22400975A1C8FD0C6FE06064EBF1042E
```

Not yet validated: BeamNG runtime ShaderData/PostEffect creation, named-target sampling in the new active shaders, the real West Coast bulk-key identity mapping, actual image quality, runtime cost, and clean unload/reload behavior. Offline FXC compilation is clean, but it does not replace the BeamNG runtime gate. Do not claim FPS or visual improvement until those gates pass.

## Important paths

Unpacked mod root:

```text
C:\Users\ab\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\beamrt\
```

Authoritative BeamNG installation inspected:

```text
E:\SteamLibrary\steamapps\common\BeamNG.drive\
```

Active user log:

```text
C:\Users\ab\AppData\Local\BeamNG\BeamNG.drive\current\beamng.log
```

Original v0.001 architecture document:

```text
C:\Users\ab\Documents\Codex\2026-09-22\files-pasted-by-the-user-i\outputs\BeamRT-v0.001-architecture.md
```

## Exact mod file structure

```text
beamrt/
├── BEAMRT_HANDOFF.md
├── README.md
├── scripts/
│   └── beamrt/
│       └── modScript.lua
├── lua/
│   └── ge/
│       └── extensions/
│           └── beamrt/
│               ├── main.lua
│               ├── rayBackendRegistry.lua
│               ├── sceneDatabase.lua
│               └── providers/
│                   ├── decalRoadProvider.lua
│                   ├── forestProvider.lua
│                   ├── lightProvider.lua
│                   ├── materialProvider.lua
│                   ├── terrainProvider.lua
│                   ├── tsStaticProvider.lua
│                   └── vehicleProvider.lua
└── shaders/
    └── beamrt/
        ├── beamrtCompose.h.hlsl
        ├── beamrtComposeP.hlsl
        ├── beamrtComposeP_v005.hlsl
        ├── beamrtBufferDiagnostic_v001.h.hlsl
        ├── beamrtBufferDiagnosticP_v001.hlsl
        ├── beamrtCopy.h.hlsl
        ├── beamrtCopyP.hlsl
        ├── beamrtCopyP_v005.hlsl
        ├── beamrtDebug.h.hlsl
        ├── beamrtDebugP.hlsl
        ├── beamrtDebugP_v005.hlsl
        ├── beamrtDebugP_v006.hlsl
        ├── beamrtDebugP_v007.hlsl
        ├── beamrtDebugP_v008.hlsl
        ├── beamrtDebugP_v010.hlsl
        ├── beamrtDebugP_v011.hlsl
        ├── beamrtGITrace.h.hlsl
        ├── beamrtGITraceP.hlsl
        ├── beamrtGITraceP_v005.hlsl
        ├── beamrtGITraceP_v009.hlsl
        ├── beamrtGITraceP_v012.hlsl
        ├── beamrtGITraceP_v030.hlsl
        ├── beamrtGITraceP_v040.hlsl
        ├── beamrtGITraceP_v041.hlsl
        ├── beamrtGITrace_v051.h.hlsl
        ├── beamrtGITraceP_v051.hlsl
        ├── beamrtGITraceP_v052.hlsl
        ├── beamrtGITraceP_v054.hlsl
        ├── beamrtGITraceP_v056.hlsl
        ├── beamrtGITraceP_v060.hlsl
        ├── beamrtLightingCompose.h.hlsl
        ├── beamrtLightingComposeP_v030.hlsl
        ├── beamrtLightingComposeP_v031.hlsl
        ├── beamrtLightingComposeP_v050.hlsl
        ├── beamrtLightingCompose_v052.h.hlsl
        ├── beamrtLightingComposeP_v052.hlsl
        ├── beamrtRadianceCleanup_v051.h.hlsl
        ├── beamrtRadianceCleanup_v056.h.hlsl
        ├── beamrtReflectionCompose.h.hlsl
        ├── beamrtReflectionComposeP.hlsl
        ├── beamrtReflectionComposeP_v020.hlsl
        ├── beamrtReflectionTemporal.h.hlsl
        ├── beamrtReflectionTemporalP.hlsl
        ├── beamrtReflectionTemporalP_v020.hlsl
        ├── beamrtReflectionTrace.h.hlsl
        ├── beamrtReflectionTraceP.hlsl
        ├── beamrtReflectionTraceP_v020.hlsl
        ├── beamrtSurfelCacheP.hlsl
        ├── beamrtSurfelCacheP_v012.hlsl
        ├── beamrtSurfelCacheP_v051.hlsl
        ├── beamrtSurfelCacheP_v054.hlsl
        ├── beamrtSurfelCacheP_v056.hlsl
        ├── beamrtSurfelCacheP_v060.hlsl
        ├── beamrtTemporal.h.hlsl
        ├── beamrtTemporalP.hlsl
        ├── beamrtTemporalP_v005a.hlsl
        └── beamrtTemporalP_v052.hlsl
```

The versioned `*P_v*.hlsl` files are cache-busted entries used by BeamNG's `ShaderData`. Most are complete versions; v0.054 and v0.056 use tiny versioned wrappers around the preserved v0.052/v0.051 implementation with compile-time source/UV feature defines.

## File responsibilities

### `scripts/beamrt/modScript.lua`

Automatic mod bootstrap. It sets the `beamrt_main` extension to manual unload mode and loads it if missing. If automatic discovery fails, the manual fallback is:

```lua
extensions.load("beamrt_main")
```

BeamNG maps `lua/ge/extensions/beamrt/main.lua` to the extension name `beamrt_main`.

### `lua/ge/extensions/beamrt/main.lua`

Responsibilities (current version string: `0.053`):

- creates and deletes the state block, shaders, PostEffects, child passes, and callback globals;
- exposes the live GELUA control API;
- switches between the debug pass and the temporal GI chain;
- advances the temporal sample index and history validity;
- uploads all scalar shader controls;
- enumerates nearby static scene objects and uploads up to 16 AABBs plus packed OBBs to the debug shader;
- derives OBB center/half-extents/orientation from `getWorldBox()`, local `getObjBox()`, `getTransform()`, and separate `getScale()`, with an AABB fallback;
- casts a deterministic 20-ray spherical shell plus 12-ray downward grid on explicit surfel refresh, deduplicates valid detailed hits, and uploads up to 32 position/normal/radius records;
- uploads those same surfel records to the GI trace pass and exposes screen-only, surfel-only, and hybrid source selection;
- maintains a separate fixed-size surfel-radiance PostFX chain before GI, invalidating it when surfel identities change;
- disables that surfel-radiance chain entirely while `GISource == "screen"`, then invalidates and warms it when world surfels are selected again;
- uploads static surfel position/normal/radius constants only when a surfel set changes, an effect requests a rebind, or relevant geometry metadata changes;
- builds replacement surfel sets incrementally into a pending list and atomically swaps only after acquisition finishes, preserving the previous completed cache during the build;
- applies the same diffuse-like source cleanup to live screen hits and visible radiance entering the surfel atlas, with exact raw-path A/B controls that invalidate both histories;
- creates an independent four-pass reflection chain and switches it through mode aliases `reflections`, `reflection`, or `ssr`;
- creates six temporary fixed-bound native-buffer diagnostic effects sharing one cache-busted fullscreen shader, and enables exactly one only in `bufferdiag` mode;
- exposes raw/HDR diagnostic display, RGB/R/G/B/A channel selection, gain, and exposure without writing diagnostic data into any BeamRT history or cache;
- selects the primary lighting chain through `lighting`, `ptgi`, or `pathtracedlighting`, with `start()` as a one-command beauty-mode entry point;
- depends on BeamNG's shipped `ui_imgui` extension and renders a native tuning window from `onUpdate`;
- exposes live beauty, lighting-shaping, temporal, ray, GI-resolution, and world-cache controls plus User Best/Cinematic/Max/Ultra/Showcase/Balanced/Clean/Performance presets;
- saves personal values to `/settings/beamrtTuner.json` and can copy/print a complete reproducible GELUA tuning command;
- checks the camera every 120 lighting frames and refreshes the sparse surfel set after eight metres of travel;
- removes every BeamRT-created object and both callback globals on extension unload.

Unique engine object names:

```text
BeamRT_DebugState
BeamRT_DebugShader
BeamRT_GITraceShader
BeamRT_TemporalShader
BeamRT_ComposeShader
BeamRT_CopyShader
BeamRT_SurfelCacheShader
BeamRT_ReflectionTraceShader
BeamRT_ReflectionTemporalShader
BeamRT_ReflectionComposeShader
BeamRT_BufferDiagnosticShader
BeamRT_DebugFx
BeamRT_GIFx
BeamRT_TemporalFx
BeamRT_ComposeFx
BeamRT_HistoryCopyFx
BeamRT_SurfelCacheFx
BeamRT_SurfelCacheCopyFx
BeamRT_ReflectionFx
BeamRT_ReflectionTemporalFx
BeamRT_ReflectionComposeFx
BeamRT_ReflectionHistoryCopyFx
BeamRT_BufferDiag_SunShadowMaskFx
BeamRT_BufferDiag_LightInfo0Fx
BeamRT_BufferDiag_LightInfo1Fx
BeamRT_BufferDiag_Prepass1Fx
BeamRT_BufferDiag_GTAOOutputFx
BeamRT_BufferDiag_SSAOMaskFx
```

Callback globals:

```text
BeamRT_DebugFxCallbacks
BeamRT_GIFxCallbacks
BeamRT_SurfelCacheFxCallbacks
BeamRT_ReflectionFxCallbacks
BeamRT_BufferDiag_SunShadowMaskFxCallbacks
BeamRT_BufferDiag_LightInfo0FxCallbacks
BeamRT_BufferDiag_LightInfo1FxCallbacks
BeamRT_BufferDiag_Prepass1FxCallbacks
BeamRT_BufferDiag_GTAOOutputFxCallbacks
BeamRT_BufferDiag_SSAOMaskFxCallbacks
```

### Debug shader files

`beamrtDebugP.hlsl` implements modes 0 through 11. Its shared header declares the prepass, depth, backbuffer samplers, engine/PostFX uniforms, ray controls, 16 AABBs, 16 packed OBBs, and 32 packed surfels.

Modes:

```text
0 off/pass-through
1 decoded world-space normals
2 eye-linear depth visualization
3 roughness from #prepass[RT0].b
4 reconstructed world-position color ramps
5 screen-space reflection-ray hit diagnostic
6 legacy single-pass diffuse GI path (normally the separate temporal chain is used)
7 visible-depth versus world AABB proxy diagnostic
8 visible-depth versus oriented proxy diagnostic, with AABB-excess classification
9 detailed world-surfel hit-normal diagnostic
10 visible-depth versus detailed world-surfel comparison
11 surfel-radiance projection/depth/normal validation classifier
```

Mode 7 colors:

```text
cyan        visible-depth hit only
magenta     GELUA-provided world proxy hit only
white       both hit
dark purple both miss
```

Mode 8 colors:

```text
cyan        visible-depth hit only
magenta     OBB hit only
white       visible-depth and OBB hit
orange      AABB hit but OBB miss (coarse AABB excess)
dark purple all three miss
```

### GI trace shader files

`beamrtGITraceP_v060.hlsl` is the active cache-busted entry. It preserves the complete v0.052 optimized marcher and v0.056 legacy source, adding one runtime selector: mode 0 calls the existing v0.056 diffuse-like estimator; mode 1 samples frozen linear `#BeamRT_CleanRadiance[RT0]`. The selector is used for accepted live screen-space hits and the visible-screen fallback for uncached world surfels. `beamrtGITraceP_v056.hlsl`, v0.054/v0.052/v0.051, v0.041, v0.040, v0.030, and v0.012 remain fallbacks. The Monte Carlo receiver-cosine estimator is intentionally unchanged.

### Surfel radiance-cache shader files

`beamrtSurfelCacheP_v060.hlsl` is the active persistent-cache entry. It preserves v0.051's `32 4` atlas/projection/update behavior and uses the same v0.060 legacy/clean selector as live GI before radiance enters the cache. A source switch or clean-source invalidation raises `surfelCacheReset` for at least two frames, clearing source-dependent RGB/validity while leaving the CPU geometry surfel set intact. `beamrtSurfelCacheP_v056.hlsl`, v0.054/v0.051/v0.012 remain fallbacks. The copy child still ping-pongs current atlas data to history without a read/write feedback loop.

### Temporal shader files

`beamrtTemporalP_v052.hlsl` performs:

- 3×3 depth/normal-aware spatial filtering of the current sample;
- history reprojection using `#VelocityBuffer`;
- previous-depth rejection using history alpha;
- neighborhood AABB clamping;
- a loose history clamp at rest and tighter clamp under motion;
- temporal blending into `#BeamRT_TemporalGI`.

It reuses the initially decoded center depth/normal and center GI sample when the 3x3 loop reaches `(0,0)`. When `denoiseStrength == 0`, it still reads the eight neighboring GI values needed for history min/max clamping but skips all eight neighboring G-buffer decodes and spatial-filter weighting. `beamrtTemporalP_v005a.hlsl` and its canonical implementation remain untouched as the accepted fallback.

### Compose and copy shader files

`beamrtLightingComposeP_v052.hlsl` preserves v0.050's photographic shaping and eight-sample contact grounding. Reconstruction now uses 5 taps at `giRenderScale >= 0.875`, 9 taps from `0.625` through `0.874`, and the complete legacy 13-tap kernel below `0.625`. This maps the supported full/75%/half settings to 5/9/13 taps. Invalid/sky depth and `giStrength <= 0` still return the original backbuffer exactly. `beamrtLightingComposeP_v050.hlsl`, v0.031, v0.030, and the v0.005 additive composer remain on disk as fallbacks.

`beamrtCopyP.hlsl` copies temporal RGB plus current normalized eye-linear depth in alpha to `#BeamRT_HistoryGI`.

### Reflection shader files

`beamrtReflectionTraceP.hlsl` reconstructs each visible point, reflects the camera-to-surface ray around the world normal, marches up to 64 depth-buffer steps (0.4 world units, 24-unit cap), and samples decoded HDR scene radiance at an accepted hit. It skips surfaces at or above the default 0.58 roughness cutoff and applies hit-facing, distance, and screen-edge confidence.

`beamrtReflectionTemporalP.hlsl` performs normal/depth-aware 3×3 filtering, velocity reprojection, history-depth rejection, motion-aware neighborhood clamping, and temporal blending. Alpha packs normalized eye depth plus 2 when a valid reflected result exists, preserving both rejection depth and a compose-time hit bit in one `R16G16B16A16F` target.

`beamrtReflectionComposeP.hlsl` reads current roughness and normal, evaluates a Schlick-style Fresnel response, and energy-conservatively lerps from base HDR radiance to reflected HDR radiance. It deliberately does not use unrestricted additive blending, which would worsen the already bright showroom scene.

## Render architecture

Debug modes use one fullscreen pass:

```text
BeamRT_DebugFx
  #prepass[RT0]
  #prepass[Depth]
  $backBuffer
  -> $backBuffer
```

`lighting`/`ptgi` (and legacy alias `diffusegi`) uses six BeamRT-only passes split across two ordered roots in hybrid/surfel mode:

```text
BeamRT_SurfelCacheFx (PFXAfterDiffuse, priority 9998)
  -> #BeamRT_SurfelRadianceCurrent (32x4)
    BeamRT_SurfelCacheCopyFx
      -> #BeamRT_SurfelRadianceHistory (32x4)

BeamRT_GIFx
  -> #BeamRT_CurrentGI
    BeamRT_TemporalFx
      -> #BeamRT_TemporalGI
        BeamRT_ComposeFx
          -> $backBuffer
          BeamRT_HistoryCopyFx
            -> #BeamRT_HistoryGI
```

When `GISource == "screen"`, v0.052 disables `BeamRT_SurfelCacheFx` and its copy child, leaving only the four-pass GI/temporal/compose/history chain.

All five BeamRT named targets use `GFXFormatR16G16B16A16F`.

Reflection mode is an independent four-pass chain at priority 10000:

```text
BeamRT_ReflectionFx
  -> #BeamRT_CurrentReflection
    BeamRT_ReflectionTemporalFx
      -> #BeamRT_TemporalReflection
        BeamRT_ReflectionComposeFx
          -> $backBuffer
          BeamRT_ReflectionHistoryCopyFx
            -> #BeamRT_HistoryReflection
```

The three reflection targets also use `GFXFormatR16G16B16A16F`. GI, reflection, and debug roots are mutually exclusive through mode selection; v0.020 does not yet compose GI and SSR simultaneously.

All roots run at `PFXAfterDiffuse` and are created disabled. `diffusegi` enables the priority-9998 surfel cache plus priority-9999 GI root. `reflections` enables only priority-10000 `BeamRT_ReflectionFx`. Diagnostic modes enable only `BeamRT_DebugFx`.

## Public GELUA API

Core lifecycle and version:

```lua
beamrt_main.enable()
beamrt_main.disable()
beamrt_main.toggle()
beamrt_main.getVersion()
beamrt_main.start() -- selects lighting, enables it, and opens the tuner
beamrt_main.openTuner()
beamrt_main.closeTuner()
beamrt_main.toggleTuner()
```

Modes:

```lua
beamrt_main.setMode("off")
beamrt_main.setMode("normals")
beamrt_main.setMode("depth")
beamrt_main.setMode("roughness")
beamrt_main.setMode("position")
beamrt_main.setMode("raymarch")
beamrt_main.setMode("diffusegi")
beamrt_main.setMode("lighting") -- aliases: ptgi, pathtracedlighting
beamrt_main.setMode("reflections")
beamrt_main.setMode("geometry")
beamrt_main.setMode("orientedgeometry")
beamrt_main.setMode("surfels")
beamrt_main.setMode("surfelcompare")
beamrt_main.setMode("surfelradiance")
beamrt_main.setMode("hybridcoverage")
```

Aliases also exist for world position, rays/hits, GI/bounce, proxy/proxies/worldgeometry, oriented/obb, radiance validation, and GI coverage.

Reflection aliases and controls:

```lua
beamrt_main.setMode("ssr")
beamrt_main.setReflectionStrength(value)       -- 0 through 2
beamrt_main.setReflectionMaxRoughness(value)   -- 0.05 through 1
beamrt_main.resetReflectionHistory()
```

Screen-space tracing/GI controls:

```lua
beamrt_main.setDepthGain(value)
beamrt_main.setPositionScale(value)
beamrt_main.setRayStepSize(value)
beamrt_main.setRayThickness(value)
beamrt_main.setRayNormalBias(value)
beamrt_main.setRaySteps(value)
beamrt_main.setGIPathCount(value)          -- integer 1 through 32
beamrt_main.setGIRenderScale(value)        -- 0.5 through 1
beamrt_main.setGIStrength(value)
beamrt_main.setGIClamp(value)
beamrt_main.setContactShadowStrength(value) -- 0 through 1
beamrt_main.setBounceSaturation(value)      -- 0 through 4
beamrt_main.setGIExposure(value)            -- -8 through 8 photographic stops
beamrt_main.setGIShadowFocus(value)         -- 0 through 1
beamrt_main.setGIReceiverTint(value)        -- 0 through 1
beamrt_main.setGIContrast(value)            -- 0.25 through 4
beamrt_main.setGIEnergyLimit(value)         -- 0.1 through 32
beamrt_main.setGIHighlightRolloff(value)    -- 0 through 1
```

Temporal controls:

```lua
beamrt_main.setGICellSize(value)
beamrt_main.setTemporalBlend(value)
beamrt_main.setHistoryDepthTolerance(value)
beamrt_main.setDenoiseStrength(value)
beamrt_main.resetHistory()
```

Phase 5 proxy controls:

```lua
beamrt_main.refreshGeometry()
beamrt_main.setGeometryRadius(value)             -- 5 through 500 m
beamrt_main.setGeometryMaxObjectExtent(value)    -- 1 through 1000 m
beamrt_main.getGeometryProxyCount()
beamrt_main.getOrientedGeometryProxyCount()
beamrt_main.dumpGeometry()
beamrt_main.refreshSurfels()
beamrt_main.setSurfelTraceDistance(value)         -- 5 through 250 m
beamrt_main.setSurfelRadius(value)                -- 0.1 through 20 m
beamrt_main.getSurfelCount()
beamrt_main.dumpSurfels()
beamrt_main.setGISource("hybrid")                -- hybrid, screen, or surfels
beamrt_main.getGISource()
beamrt_main.setWorldGIStrength(1.0)              -- 0 through 4
beamrt_main.setWorldLeakSuppression(0.85)        -- 0 through 1
beamrt_main.setRadianceCleanup(1.0)              -- 0 raw legacy, 1 full cleanup
beamrt_main.setSpecularReject(0.85)               -- 0 through 1
beamrt_main.setSurfelVisibilityTolerance(1.5)    -- 0.05 through 10 world units
beamrt_main.setSurfelCacheBlend(0.15)            -- 0.01 through 1
beamrt_main.setSurfelRefreshDistance(8)          -- 2 through 100 m
beamrt_main.setSurfelRefreshRaysPerFrame(4)      -- integer 1 through 32
```

Tuner/preset persistence and exact-value export:

```lua
beamrt_main.applyPreset("cinematic") -- userbest, maxquality, ultra, showcase, balanced, clean, performance
beamrt_main.getSettings()
beamrt_main.saveTuning()             -- /settings/beamrtTuner.json
beamrt_main.loadTuning()
beamrt_main.printSettings()          -- logs a complete reproducible command
```

## Milestone history and test results

### Phase 1: accepted

Implemented v0.001 G-buffer access and live modes for pass-through, decoded normals, depth, and roughness. The user verified:

- extension loaded;
- `BeamRT_DebugShader`, `BeamRT_DebugState`, and `BeamRT_DebugFx` existed;
- all requested debug modes visibly worked;
- disable restored the scene;
- Ctrl-L did not produce duplicate-object errors.

### Phase 2: accepted

World position reconstruction uses the shipped convention:

```hlsl
worldPosition = eyePosWorld + IN.wsEyeRay * decoded.w;
```

The user rotated/moved the camera and confirmed the colored position field stayed attached to world objects.

### Phase 3: accepted

Added screen-space ray marching and one-bounce diffuse GI. The user tested multiple ray settings and camera angles. The initial fixed 0.25 m world-cell sampling produced obvious square/checker regions; this was understood as sampling quantization rather than failed position reconstruction.

### Phase 4: accepted as v0.005a

Added temporal accumulation, velocity reprojection, depth rejection, motion-aware clamping, and spatial filtering. Accepted settings included:

```lua
beamrt_main.setRayStepSize(0.75)
beamrt_main.setRayThickness(1.0)
beamrt_main.setRayNormalBias(0.05)
beamrt_main.setRaySteps(32)
beamrt_main.setGIClamp(5.0)
beamrt_main.setGICellSize(0.015625)
beamrt_main.setTemporalBlend(0.12)
beamrt_main.setHistoryDepthTolerance(0.01)
beamrt_main.setDenoiseStrength(0.75)
beamrt_main.setGIStrength(0.7)
```

Observed acceptance evidence:

- the large square/checker artifact was removed;
- remaining fine grain was consistent with a one-ray prototype;
- accumulated GI stayed attached across several camera views;
- no obvious frozen screen-space pattern, persistent retained silhouette, or long bright history trail was visible;
- repeated Ctrl-L/unload/load recreated the objects cleanly;
- the log contained no BeamRT shader/Lua/duplicate-object errors;
- the user confirmed `getVersion()` returned `0.005a`.

The last accepted in-game log shows v0.008 completing its visual, data, cleanup, and reload gates.

### Phase 5: v0.006 through v0.011 accepted for continued development

v0.006 adds a geometry-bridge diagnostic only. GELUA scans these classes:

```text
TSStatic
MeshRoad
ProceduralMesh
GroundPlane
```

It rejects invalid bounds, bounds larger than the configurable maximum extent, and objects outside the radius. Nearly flat bounds are padded to 5 cm. Candidates are sorted by distance to the camera and the nearest 16 are uploaded as individual float4 constants.

The HLSL ray/AABB implementation and v0.006 entry point compile successfully using both `ps_5_0` and `vs_5_0` with Microsoft's `fxc.exe` and compiled successfully in BeamNG.

In-game acceptance evidence:

- v0.006 loaded and created `BeamRT_DebugShader` from `beamrtDebugP_v006.hlsl`;
- six real `TSStatic` proxies were uploaded in the test scene, including `simple_lightplane`, `neontube_vertical`, `panelsmall`, `neontube`, `panelbig`, and `207509`;
- every dumped bound was finite and world-space;
- the geometry diagnostic showed cyan, magenta, white, and dark-purple regions; magenta confirmed proxy-only hits beyond the visible-depth result;
- changing the radius from 100 m to 5 m reduced the selection from six proxies to four in one position and two in another; restoring 100 m restored all six;
- returning to `diffusegi` restored the filtered temporal image without disturbing the accepted Phase 4 path;
- explicit unload/reload recreated v0.006 cleanly;
- no BeamRT shader, Lua, or duplicate-object errors appeared in the log.

v0.007 changes now on disk:

- version and active debug entry point bumped to `0.007` / `beamrtDebugP_v007.hlsl`;
- local mesh boxes are converted to OBBs with the exact conventions used by BeamNG's editor: world-box center, local-box extents multiplied by separate object scale, transform columns 0/1 as X/Y axes;
- each OBB is packed into three float4 constants (`center.xyz/halfX`, `axisX.xyz/halfY`, `axisY.xyz/halfZ`); HLSL reconstructs Z with `cross(axisX, axisY)`;
- ray/OBB intersection transforms the world ray into the box's orthonormal local frame and reuses the accepted slab ray/AABB function;
- mode 8 (`orientedgeometry`, aliases `oriented` and `obb`) classifies AABB-only excess as orange while preserving cyan/magenta/white/dark-purple categories;
- `dumpGeometry()` now prints `OBB=local-box` versus `OBB=AABB-fallback`, center, half-extents, and axes;
- `getOrientedGeometryProxyCount()` reports how many uploaded proxies use genuine local boxes.

`beamrtDebugP_v007.hlsl` compiled successfully as `vs_5_0` and `ps_5_0` with the Windows SDK `fxc.exe` using both the mod and BeamNG installation as include roots.

In-game v0.007 acceptance evidence:

- v0.007 loaded `beamrtDebugP_v007.hlsl` without shader or Lua errors;
- six of six uploaded proxies were genuine local-space OBBs and zero used the AABB fallback;
- the dump showed finite centers, half-extents, and axes, including rotated panel/tube axes;
- modes 7 and 8 rendered stably and remained world-attached;
- the tested thin panels, planes, and tubes produced nearly equal AABB/OBB screen results from the chosen view, so no large orange AABB-only region was expected or required;
- `diffusegi` resumed normally;
- disable, explicit unload, and reload recreated v0.007 cleanly with no duplicate-object errors.

v0.008 accepted implementation:

- version and active debug entry point bumped to `0.008` / `beamrtDebugP_v008.hlsl`;
- `refreshSurfels()` performs 32 detailed `Engine.castRay` queries only on demand or when entering modes 9/10, never per frame;
- 20 Fibonacci-shell rays cover the full sphere, including directions outside the camera frustum; a 4×3 downward grid improves floor/terrain coverage;
- each retained sample stores true world position, normalized hit normal, disc radius, and source kind; nearby nearly coplanar duplicates are rejected;
- mode 9 visualizes the hit normal from the nearest intersected surfel disc;
- mode 10 compares reflected-ray surfel hits with the accepted screen-depth tracer: cyan depth-only, green surfel-only, white both, dark miss;
- the accepted temporal GI chain remained unchanged and did not consume surfels.

Offline result: v0.008 compiles successfully as both `vs_5_0` and `ps_5_0` with the Windows SDK `fxc.exe` and BeamNG/mod include roots.

In-game v0.008 acceptance evidence:

- refreshes from two camera positions retained 23 and 28 samples from 32 detailed rays, both with zero call failures;
- every dumped sample had finite position/radius and an approximately unit-length normal;
- normal-colored mode-9 patches remained attached to their world surfaces across camera movement;
- mode 10 showed green surfel-only regions in addition to cyan visible-depth regions;
- returning to `diffusegi` restored the temporal renderer;
- the final lifecycle test printed `Debug removed: true`, `GI removed: true`, and `BeamRT reloaded: true` after disable/unload/reload;
- no current BeamRT shader, Lua, duplicate-object, or raycast errors were observed.

v0.009 changes now on disk:

- version bumped to `0.009`; the active GI trace entry point is cache-busted as `beamrtGITraceP_v009.hlsl` while the unchanged debug shader remains `beamrtDebugP_v008.hlsl`;
- the GI cbuffer now receives all 32 surfel position/radius and normal/source records;
- `setGISource("screen")` preserves the accepted v0.005a screen-depth path exactly;
- `setGISource("surfels")` isolates surfel lighting; `setGISource("hybrid")` prefers a screen hit and uses surfels only after a screen miss;
- a surfel hit is assigned real scene radiance only if its center projects inside the current viewport, differs from current depth by no more than `surfelVisibilityTolerance`, and agrees with the visible G-buffer normal;
- valid surfel radiance is clamped by the existing `giClamp`, weighted by receiver cosine, emitter cosine, world distance, projection confidence, surface roughness, and `worldGIStrength`, then enters the existing temporal/filter/compose chain;
- selecting a GI source, changing world strength/tolerance, or refreshing surfels resets temporal history;
- entering `diffusegi` or a non-screen source auto-refreshes the cache only when it is empty; detailed CPU rays are still never cast per frame.

Offline result: the canonical and v0.009 GI pixel files have matching SHA-256 hashes. `beamrtGITraceP_v009.hlsl` compiles successfully as `vs_5_0` (`mainV`) and `ps_5_0` (`main`) with Windows SDK `fxc.exe` using the mod and BeamNG install as include roots.

Partial in-game v0.009 evidence:

- v0.009 loaded `beamrtGITraceP_v009.hlsl` without a BeamRT shader or Lua error;
- the test snapshot uploaded 23 surfels from 32 detailed rays with zero call failures;
- the log confirms screenshot order `screen` (source 1), `surfels` (source 2), then `hybrid` (source 0);
- screen-only retained the familiar temporally filtered fine grain, surfel-only was visually clean/sparse, and hybrid stayed close to the accepted screen baseline;
- this does not yet prove a nonzero surfel-light contribution because a clean surfel-only frame could be the base scene after every candidate failed radiance validation;
- at that point acceptance was pending a stationary surfel-only `worldGIStrength=0` versus `4` A/B, followed by strict `giStrength=0` and lifecycle checks; the later v0.010 diagnostic and final tests resolved those gates.

The requested `worldGIStrength=0` versus `4` A/B showed a possible stronger blue lift at `4`, but the captured viewport/framing changed enough that it was not accepted as definitive proof. No new BeamRT runtime error was reported. v0.010 was added to remove this ambiguity rather than tuning against an uncertain image comparison.

v0.010 changes now on disk:

- version and active debug entry point bumped to `0.010` / `beamrtDebugP_v010.hlsl`; the v0.009 GI entry remains unchanged;
- mode 11 aliases are `surfelradiance`, `radiancevalidation`, and `surfelvalidation`;
- it traces the already validated reflected-ray surfel diagnostic, then applies the same viewport projection, 1.5-world-unit default depth tolerance, and `dot(visibleNormal, surfelNormal) > 0.2` test used by the GI radiance lookup;
- classification colors are dark purple=no surfel-disc intersection, magenta=projection/outside viewport, orange=depth rejection, red=normal rejection, green=fully accepted radiance source;
- the debug effect now receives `surfelVisibilityTolerance` so changing the public tolerance control affects both GI and the classifier.

Offline result: canonical and v0.010 debug pixel files have matching hashes. `beamrtDebugP_v010.hlsl` compiles successfully as `vs_5_0` (`mainV`) and `ps_5_0` (`main`) with the Windows SDK `fxc.exe` and the BeamNG/mod include roots.

In-game v0.010 acceptance result:

- BeamNG loaded extension `v0.010` and created `BeamRT_DebugShader` from `beamrtDebugP_v010.hlsl` with no BeamRT shader or Lua error;
- the captured mode-11 frame contained extensive stable green regions on the floor, vehicle, and overhead geometry, directly proving accepted radiance lookups;
- orange, red, magenta, and dark-purple regions were also visible, demonstrating that depth, normal, projection, and miss classification branches remained active rather than collapsing to one output;
- unrelated unicycle Collada and input/FFB messages in `beamng.log` are not BeamRT failures.

Strict GI no-op result:

- the user captured mode `off`, then `diffusegi` with source `hybrid`, world strength `1`, and `giStrength=0` without moving the camera;
- the rendered scene was visually unchanged, and `beamng.log` confirms the intended state transitions with no BeamRT error;
- the screenshots differed in overall width by 8 pixels, preventing a meaningful literal pixel diff, but the compose shader's zero-strength branch returns the untouched encoded backbuffer before decoding or sampling accumulated GI;
- this gate is accepted. The lifecycle cleanup result immediately below subsequently passed as well.

Final v0.010 lifecycle result:

- `beamrt_main.disable()` followed by `extensions.unload("beamrt_main")` removed both `BeamRT_DebugFx` and `BeamRT_GIFx`;
- the console printed `Debug removed: true`, `GI removed: true`, and `BeamRT reloaded: true`;
- the log confirms a clean v0.010 reload and recreation of the cache-busted debug shader plus the v0.009 GI, temporal, compose, and history-copy chain;
- there was no BeamRT compile, Lua, NaN, or duplicate-object error. The later unicycle Collada error is unrelated;
- v0.009/v0.010 are accepted for progression to measured coverage work.

v0.011 changes now on disk:

- version and active debug entry point bumped to `0.011` / `beamrtDebugP_v011.hlsl`; the accepted v0.009 GI entry remains unchanged;
- mode 12 aliases are `hybridcoverage`, `gicoverage`, `coverage`, and `exacthybrid`;
- the debug shader's diffuse sampler was consolidated to the exact v0.009 temporal-GI hash, cell-size, frame-sequence, and cosine-hemisphere formula;
- mode 12 follows the hybrid source order using that diffuse ray: it checks visible-depth first and returns cyan on a hit, then tests the surfel discs and applies the same projection, depth, normal, edge-confidence, and world-strength gates as the GI fallback before returning green;
- dark purple means neither path can supply a source. Unlike mode 11, mode 12 intentionally collapses individual surfel rejection causes because its purpose is to measure final useful fallback coverage;
- the debug constant block now receives `worldGIStrength`, so zero strength correctly suppresses green fallback coverage.
- temporal-history resets now resynchronize both the GI and debug constant blocks; changing ray, cell-size, world-strength, or visibility-tolerance controls while a diagnostic is active no longer leaves the diagnostic with stale values.

Offline result: canonical and v0.011 debug pixel files have matching SHA-256 hashes. `beamrtDebugP_v011.hlsl` compiles successfully as `vs_5_0` (`mainV`) and `ps_5_0` (`main`) with Windows SDK `fxc.exe` and the BeamNG/mod include roots.

In-game v0.011 acceptance result:

- BeamNG loaded extension `v0.011` and created `BeamRT_DebugShader` from `beamrtDebugP_v011.hlsl`; no BeamRT shader/Lua error is present in the available log;
- the captured mode-12 frame contained cyan throughout visible scene geometry and stable green fallback samples on the car, floor, walls, and overhead surface;
- a thresholded every-other-pixel screenshot sample counted 68,904 cyan, 28,178 green, and 717,846 dark-purple samples in the cropped game area. This is an approximate visual metric, not GPU instrumentation: green was about 29.0% of cyan-plus-green usable hits and 3.46% of all classified samples;
- the result proves surfels materially extend the exact hybrid GI decision path, so v0.011 is accepted and brightness should still remain untuned until an actual temporal screen-versus-hybrid comparison is captured.

v0.012 changes and implementation acceptance:

- version bumped to `0.012`; active GI entry is `beamrtGITraceP_v012.hlsl`;
- added `beamrtSurfelCacheP.hlsl` plus cache-busting `beamrtSurfelCacheP_v012.hlsl`;
- added `BeamRT_SurfelCacheShader`, a priority-9998 `BeamRT_SurfelCacheFx`, and child `BeamRT_SurfelCacheCopyFx` before the priority-9999 GI root;
- the current/history atlas targets are explicitly `32 4`, `GFXFormatR16G16B16A16F`; column equals surfel index and alpha is validity;
- visible entries update from depth/normal-validated HDR backbuffer radiance with a default 0.2 current-frame blend; invisible entries preserve history;
- GI reads the persistent cache first and retains the v0.009 projection validator only as a cold-entry fallback;
- cache reset is requested only when surfel slot identity can become stale: surfel refresh, mission start, cache enable, and unload/reload. Ordinary GI-history resets preserve learned radiance. A two-callback-frame flag avoids clearing it before BeamNG applies constants;
- root and copy pass are separate targets, avoiding same-texture read/write feedback;
- user feedback explicitly rejected further nearly identical stationary A/B loops, motivating this architectural pivot.

Offline result: both v0.012 shaders compile successfully with Windows SDK FXC as `vs_5_0` and `ps_5_0`, entry `main`. Canonical/versioned SHA-256 pairs match: GI `005563AA159B0F4BBDE9F45896652B2F03113523E6E4BA192E55151B1CBF13AA`; cache `41AE62A62592FEC0596E79E44E2EA249F8DC8233EB246EEBD9CF2E17E410EA1F`. In game, v0.012 loaded both active shaders, produced 25 surfels from 32 detailed rays with zero call failures, enabled the persistent cache, and printed `Cache FX: true`; no BeamRT error was visible. This accepts the v0.012 implementation gate, though long-motion quality remains experimental.

v0.020 staged changes:

- version bumped directly to `0.020` to mark a new capability rather than another surfel tuning increment;
- mode 13 aliases `reflections`, `reflection`, and `ssr` select an independent reflection root;
- trace defaults: 0.4-unit step, 0.55 thickness, 0.08 normal bias, 64 steps, 24-unit distance cap, and 0.58 maximum roughness;
- temporal defaults: 0.18 current-frame blend, 0.01 relative history-depth tolerance, and 0.35 bilateral filter strength;
- compose default strength is 0.85, with public strength/cutoff/reset controls;
- GI/cache and reflection pipelines are mutually exclusive, preserving accepted GI as a fallback while isolating reflection failures;
- canonical/versioned SHA-256 pairs match: trace `8F5B2690024F4CC277F935263096B9550A9B9179DC086E388A3ECB1D2BCBB976`, temporal `8E11268B82AF8068789A6D47079B8527BE0F6D6639421F48BB15AB1BDBF8C83F`, compose `1DC593E278A9945D2C2313D2E49900CDFEF400A953380D3D0E11227F5A9E88F9`;
- all three new shaders pass offline FXC compilation as `vs_5_0` and `ps_5_0`, entry `main`.

In-game v0.020 status is pending. The acceptance gate is one clean reload, `Reflection FX: true`, visible world-attached glossy reflections, border fade, tolerable slow-orbit stability, strict no-op at strength zero, and clean unload. Do not call v0.020 accepted before that gate.

v0.030 staged changes:

- version bumped to `0.030`; active GI entry is `beamrtGITraceP_v030.hlsl` and active composer is `beamrtLightingComposeP_v030.hlsl`;
- user-facing aliases `lighting`, `ptgi`, and `pathtracedlighting` select mode 6; `start()` selects and enables it in one command;
- each half-resolution lighting pixel traces four stratified cosine-weighted diffuse paths rather than the old single path; the four strata and golden-ratio azimuth offsets rotate with the temporal frame sequence;
- trace, temporal, and history targets run at `0.5 0.5` scale to keep four-path cost practical; the full-resolution composer uses current G-buffer depth and five point samples to avoid blocky silhouette upscaling;
- each path uses visible depth first and the persistent world-surfel cache as its off-screen fallback; results remain actual decoded HDR scene radiance rather than debug colors;
- the estimator divides by the fixed four-path count so misses remain zero-energy occlusion instead of causing brightness inflation;
- the composer caps indirect luminance relative to existing HDR luminance and emphasizes shadow response, reducing washout while preserving visible color bleed;
- default beauty settings changed to 0.65-unit steps, 0.85 thickness, 28 steps, 0.55 GI strength, 0.18 current-frame temporal blend, and 0.85 denoise strength;
- while lighting is active, the callback checks camera displacement every 120 frames and rebuilds the 32-ray surfel snapshot after eight metres, resetting temporal history and invalidating the radiance atlas through the existing two-frame reset path;
- the optional v0.020 reflection chain remains present but is not combined with lighting and is no longer the primary milestone.

Offline result: both active v0.030 shaders compile cleanly with Windows SDK FXC as `vs_5_0` and `ps_5_0`, entry `main`, using the mod and BeamNG include roots. SHA-256: GI `16DD1A8D51D5769A40BAF41020A5C837833F38EA8A0E02AF98B1C22A58C33D0F`; composer `A199C8CE275D06D8D1E726835A0144E367E0E20E40336E3A183FB37A4788B1B9` (recompute if either source changes).

Initial in-game v0.030 gate passed on 2026-09-23. The log names both active v0.030 shaders, reports 22 uploaded surfels from 32 detailed rays with zero call failures, selects `lighting (6)`, and enables both the persistent cache and multi-ray PTGI effect. The supplied frame is an ordinary outdoor beauty view with intact materials and silhouettes, not a diagnostic classifier or block overlay. No BeamRT shader/Lua error follows the successful GELUA reload. The earlier `extensions`-nil console error came from executing a reload expression in the wrong console context; the later GELUA command completed normally. The screenshot omitted the FPS counter and does not demonstrate motion, so GPU cost, automatic recentering during travel, and temporal trail quality are still pending.

v0.031 staged changes:

- version bumped to `0.031`; the active trace entry remains `beamrtGITraceP_v030.hlsl` and the active composer is cache-busted as `beamrtLightingComposeP_v031.hlsl`;
- full-resolution reconstruction expands from five depth-only taps to 13 depth/normal-aware taps: center, near axial/diagonal neighbors, and wider axial support;
- the compositor evaluates eight nearby G-buffer samples for short-range horizon/crease contact grounding; this is deliberately restrained and does not run when GI strength is zero;
- bounce color is separated around luminance with default saturation `1.20`, and the indirect energy budget increases from `0.20 + 0.65 * baseLuminance` to `0.35 + 0.85 * baseLuminance`;
- default GI strength rises from `0.55` to `0.75`, temporal current-frame blend falls from `0.18` to `0.10`, and denoise strength rises from `0.85` to `1.0`;
- new controls are `setContactShadowStrength(0..1)` and `setBounceSaturation(0..2)`;
- v0.031 intentionally changes only the beauty compositor and defaults. Geometry, surfel acquisition, cache layout, four-path trace, and temporal implementation are unchanged, keeping the risk boundary clear.

Offline result: all nine shader entries selected by `main.lua` compile cleanly in both `vs_5_0` and `ps_5_0` (18/18 outputs), entry `main`, with the BeamNG/mod include roots. SHA-256 at staging: GI `16DD1A8D51D5769A40BAF41020A5C837833F38EA8A0E02AF98B1C22A58C33D0F`; v0.031 composer `BF43F8AE47B04E7E44302294BE1B41147AD56412BE49CE49A3CF500EB7A8FEF7`. In-game v0.031 testing is pending.

v0.032 staged changes:

- `main.lua` now declares `M.dependencies = {"ui_imgui"}` and renders `BeamRT PTGI Tuner v0.032` from `onUpdate` only while its window is open;
- `start()` selects/enables lighting and opens the tuner; explicit `openTuner`, `closeTuner`, and `toggleTuner` functions are also public;
- the panel groups live controls into Beauty and lighting, Noise and temporal stability, Ray quality and cost, and Persistent world cache;
- every control has a hover explanation describing the visual benefit and likely failure mode;
- four presets are built in: `showcase`, `balanced` (v0.031 defaults), `clean`, and `performance`;
- current values can be saved to and loaded from `/settings/beamrtTuner.json`; `Copy Values`, `settingsCommand()`, and `printSettings()` produce a complete reproducible GELUA command;
- new public controls expose surfel-cache update blend and automatic cache-refresh travel distance;
- Showcase is the new startup default: 36 steps at 0.55 m, GI 0.90, world GI 1.15, bounce saturation 1.25, contact grounding 0.58, temporal current weight 0.07, 75 m surfel reach, and 1.75 m base surfel radius;
- no shader source or render-target architecture changed from v0.031, so the existing 18/18 offline active-shader compilation result remains applicable.

Current test status: source/API inspection passed and all nine selected shaders were recompiled successfully in both stages (18/18) after the v0.032 integration. `main.lua` SHA-256 is `066145C05B2C6125D5EB520E70525DCABA8855B6CA4E17132A242B615E0011B9`. BeamNG has not yet loaded v0.032. The next gate is one clean GELUA reload, confirm version `0.032`, verify the ImGui window opens and responds, click each preset once, save/load once, copy values once, and check the log for Lua errors. Appearance, motion stability, and GPU cost should be judged from normal gameplay rather than diagnostic modes.

Subsequent user evidence confirms the v0.032 tuner rendered and its controls/export path worked. The user visually searched the available ranges and copied this exact pre-v0.040 configuration:

```lua
beamrt_main.setGIStrength(0.81); beamrt_main.setWorldGIStrength(2.5); beamrt_main.setBounceSaturation(2); beamrt_main.setContactShadowStrength(0.33); beamrt_main.setGIClamp(12); beamrt_main.setTemporalBlend(0.137); beamrt_main.setDenoiseStrength(1); beamrt_main.setHistoryDepthTolerance(0.001); beamrt_main.setGICellSize(0.0056); beamrt_main.setRayStepSize(0.2); beamrt_main.setRayThickness(2); beamrt_main.setRayNormalBias(0); beamrt_main.setRaySteps(64); beamrt_main.setSurfelTraceDistance(150); beamrt_main.setSurfelRadius(5.59); beamrt_main.setSurfelVisibilityTolerance(2.6); beamrt_main.setSurfelCacheBlend(0.28); beamrt_main.setSurfelRefreshDistance(23); beamrt_main.refreshSurfels()
```

The image changed very little in performance because the actual workload was still hard-coded to four paths at half resolution and depth rays can exit early. The reported smokey/steamy indirect light is consistent with sparse 5.59 m cache discs contributing at 2.5× world strength and loose 2.6 m visibility tolerance; that is a cache-leak failure, not desirable PTGI haze.

v0.040 staged changes:

- version bumped to `0.040`; the active trace entry is cache-busted as `beamrtGITraceP_v040.hlsl`;
- `giPathCount` is a real shader loop count from 1 through 16 instead of a fixed four paths; stratification and output normalization use the selected count;
- `rayMaxSteps` now supports 1–128 and the shader's static loop ceiling is 128;
- `giRenderScale` can be changed live from 0.5 through 1.0 and updates trace, temporal, and history target scales together; the tuner gives explicit Half/75%/Full buttons;
- `worldLeakSuppression` fades hits near each surfel-disc edge and reduces confidence for oversized radii. At zero it preserves v0.032 behavior; the beauty presets use 0.7–0.92;
- shader reads inside the variable path loop use explicit LOD 0 rather than implicit derivatives, avoiding undefined gradients in a varying loop;
- the tuner increases the step ceiling to 128, adds a 1–16 Paths per pixel slider, shows current GI resolution, exposes leak suppression, and expands GI/world intensity, bounce saturation, and radiance-clamp ranges;
- the new `ultra` preset selects 16 paths, full resolution, 96 steps at 0.24 m, GI strength 1.25, world GI 1.80, bounce saturation 1.80, a 1.35 m surfel radius, and 0.92 leak suppression. Compared with v0.030's four paths at half resolution and 64-step ceiling, its maximum theoretical trace work is roughly 32× when the doubled step ceiling is included; real cost depends on early exits;
- `showcase` now selects eight paths at 75% resolution; `clean` also uses eight at 75%, `balanced` remains four at half resolution, and `performance` uses two at half resolution;
- settings save/load/export now include path count, render scale, and leak suppression.

Offline v0.040 result: all nine shader entries selected by `main.lua` compile cleanly in both `vs_5_0` and `ps_5_0` (18/18). The active v0.040 GI shader separately compiled without warnings after implicit-gradient reads were removed. SHA-256: `main.lua` `30746D53167704958D1DC89A8CDB770923AF174756A9B2ADA6956A838A512ACE`; shared GI header `06C79FE5BDC6BA1E25D1D1227D7DA2258D631044C7F2E2ED86C9A3DBF0EB71C5`; v0.040 GI entry `9090B3218C095FF333B738F7038559C23EB7F460B8913AF8941A8D1292D0DECC`. BeamNG has not yet loaded v0.040. The current milestone gate is one clean reload, confirm `0.040`, apply Ultra, confirm all three new controls work, compare Half versus Full resolution, and capture FPS/GPU timing plus any Lua/shader errors.

v0.041 staged changes:

- version bumped to `0.041`; the cache-busted active trace entry is `beamrtGITraceP_v041.hlsl`;
- the compiled ray-step loop ceiling rises from 128 to 512 and the path loop ceiling rises from 16 to 32; the Lua setters enforce the same finite limits;
- the normal ray-quality sliders intentionally remain at 1–16 paths and 8–128 steps, preventing a huge range from making ordinary tuning overly sensitive;
- every float and integer tuner control now renders an exact-entry box to the right of its practical slider. The value is committed on Enter and can exceed the slider range whenever that setter permits it;
- the `maxquality` / `MAX 32x200` preset selects 32 paths, full resolution, 200 steps at 0.15 m, reduced spatial denoise, 1.25 m surfels, and 0.94 leak suppression. Its trace workload is about 100× v0.030's four-path half-resolution 64-step maximum before early exits;
- the console and GUI call the same setters. `beamrt_main.setRaySteps(200)` and `beamrt_main.setGIPathCount(32)` now work; values above 512/32 are rejected because the HLSL loops require finite compiled ceilings;
- the GUI labels Ultra as the sane maximum and the 32×200 preset as a potentially GPU-stalling laboratory stress test.

Offline v0.041 result: the active shader compiles cleanly and without warnings as both `ps_5_0` and `vs_5_0`. All nine shader entries selected by `main.lua` also compile cleanly in both stages (18/18). SHA-256: `main.lua` `73DE819E2FF415A68D749D34BFDC4232939D9C1903658A6A30B33C061433A289`; v0.041 GI entry `F6FD77E5FF3BAD0E9823303E549BCEEC9C1649556F6CE4A3557220E8AC26988B`. In-game v0.041 testing is pending.

v0.050 staged changes and current milestone:

- the user's latest closest-looking command requested GI/world strength `4`, 32 paths, full resolution, 512 steps, 0.2 m steps, 0.55 m thickness, 0.039 m bias, 1.83 m surfels, visibility tolerance `5`, cache blend `1`, and the other exact values preserved below;
- the active log confirms `GI path count set to 32` and `ray steps set to 512`, but the only created GI shader was `beamrtGITraceP_v040.hlsl`. Its compiled loops stop at 16 paths/128 steps, so the accepted uniforms did not increase actual work beyond those limits. This explains the negligible FPS change;
- path count remains useful for reducing speckle after a clean v0.050 reload, but it cannot create missing geometry, directional irradiance, or better light transport. The final composer and sparse directionless cache are the larger visual bottlenecks;
- the v0.031 composer silently capped indirect luminance to `0.35 + 0.85 * baseLuminance`, so raising GI strength toward `4` could stop producing a proportional visual change;
- active composer is now cache-busted as `beamrtLightingComposeP_v050.hlsl`; invalid/sky pixels return the original frame, and `giStrength <= 0` remains a strict no-op;
- new shaping controls are exposure in stops, shadow focus, approximate receiver-color tint, an 18%-pivot contrast curve, adjustable energy ceiling, and hard-to-soft highlight rolloff;
- `userbest`/`YOUR BEST` preserves all visually active supplied settings but pins path/step count to the 16/128 that v0.040 actually rendered; the raw requested 32/512 command remains documented. `cinematic`/`CINEMATIC` is the recommended first v0.050 test at 16 paths, 128 steps, full resolution, and stronger shaped bounce;
- settings save/load/export includes every new value, and the tuner provides both sliders and exact typed entry for them.

Exact user-requested command (its 32/512 fields were compiled-capped to 16/128 by the live v0.040 shader):

```lua
beamrt_main.setGIStrength(4); beamrt_main.setWorldGIStrength(4); beamrt_main.setWorldLeakSuppression(0.94); beamrt_main.setBounceSaturation(0.9); beamrt_main.setContactShadowStrength(0.06); beamrt_main.setGIClamp(10.25); beamrt_main.setTemporalBlend(0.093); beamrt_main.setDenoiseStrength(1); beamrt_main.setHistoryDepthTolerance(0.05); beamrt_main.setGICellSize(0.005); beamrt_main.setGIPathCount(32); beamrt_main.setGIRenderScale(1); beamrt_main.setRayStepSize(0.2); beamrt_main.setRayThickness(0.55); beamrt_main.setRayNormalBias(0.039); beamrt_main.setRaySteps(512); beamrt_main.setSurfelTraceDistance(150); beamrt_main.setSurfelRadius(1.83); beamrt_main.setSurfelVisibilityTolerance(5); beamrt_main.setSurfelCacheBlend(1); beamrt_main.setSurfelRefreshDistance(30); beamrt_main.refreshSurfels()
```

Offline v0.050 result: all nine shader entries selected by `main.lua` compile cleanly as both `vs_5_0` (with `SHADER_STAGE_VS=1`) and `ps_5_0`, 18/18. SHA-256: `main.lua` `27397F8D384993D41E147B3F06C3E7EC80730345F1181704C7C8D60ACF4DD012`; shared compose header `5B61942D8BBE8A7BAE6438BC006B630A92481040937BD74E0DF59C0CDAC9DD96`; v0.050 composer `0B69D1267F38B6A3F86DF2C20DF9623877B9BEFC710BE2217939411ECCBACAAF`. A later `beamng.log` confirms a clean v0.050 load, intended v0.041/v0.050/v0.012 shader entries, and lighting/cache enable with no filtered BeamRT shader/Lua/constant-binding errors. Same-camera appearance and strict no-op checks remain manual.

v0.051 staged changes and current milestone:

- active GI and cache entries are cache-busted as `beamrtGITraceP_v051.hlsl` and `beamrtSurfelCacheP_v051.hlsl`; the v0.050 composer remains active and unchanged;
- `beamrtRadianceCleanup_v051.h.hlsl` decodes the raw hit plus four cardinal samples two pixels away, rejects neighbors across depth/normal discontinuities, and estimates a coherent local radiance mean;
- bright center luminance is winsorized against that mean, while G-buffer roughness and local luminance gradient control how strongly view-dependent energy is distrusted. This is a practical diffuse-source heuristic, not material-perfect specular separation;
- cleanup is applied both at live screen-space GI hits and immediately before visible radiance enters the persistent surfel atlas. A cold projected-surface fallback uses the same path;
- `setRadianceCleanup(0..1)` and `setSpecularReject(0..1)` are live API/tuner controls. Zero cleanup exits through the exact legacy decoded-radiance path. Changing either setting resets temporal history and clears two cache frames so an old reflection cannot contaminate the A/B;
- every preset, saved tuning table, loaded tuning table, pointer sync, and exported command includes both settings. The tuner has one-click `CLEAN DIFFUSE SOURCE` and `RAW SOURCE (A/B)` actions;
- no ray-count increase or reflection-chain combination was made. All requested legacy GI/composer files remain on disk.

Offline v0.051 result: all nine shader entries selected by `main.lua` compile cleanly as both `vs_5_0` (with `SHADER_STAGE_VS=1`) and `ps_5_0`, 18/18. The new GI and cache shaders also compile independently in both stages. A system Lua/luac interpreter was not available, so the Lua syntax/load gate must be completed by BeamNG. The current on-disk `beamng.log` still validates the prior v0.050 load only; it cannot validate files written afterward. SHA-256: `main.lua` `366EC37C47994E0BACBDADE45FBFEECAA0231C342D7E8B014F01A08A989D8D16`; v0.051 GI header `34434C1E4E613E61EE971366D508150DEFA7B7C16C2744FAE8F2F96C40DA6B5C`; cleanup header `28DDA31AC2686C175F7243241772485D89FC7552B6EAE0234D12FB69FE4DC2B3`; v0.051 GI entry `38E2E95C222D8475205F724E4B0BC03BC3C5239F0614466245E72BBC2DCDBEA8`; v0.051 cache entry `A50C209D9724A1D2CE7DADEE3A6D3332A9E4FD62AA330FB758958CD644CDD3A7`; unchanged v0.050 composer `0B69D1267F38B6A3F86DF2C20DF9623877B9BEFC710BE2217939411ECCBACAAF`.

### v0.052 low-risk optimization pass

- Active entries are `beamrtGITraceP_v052.hlsl`, `beamrtTemporalP_v052.hlsl`, `beamrtLightingComposeP_v052.hlsl`, and the unchanged `beamrtSurfelCacheP_v051.hlsl`. All prior versioned shaders remain untouched.
- Temporal filtering retains its 3x3 neighborhood and identical history min/max clamp. Reusing the center removes one GI read and one repeated `decodeGBuffer` (two texture reads), approximately three texture reads per temporal pixel. At `denoiseStrength=0`, eight neighboring GI reads remain for history clamping, but eight neighboring G-buffer decodes are skipped; total reduction is approximately nineteen texture reads per temporal pixel versus v0.005a.
- Composer reconstruction uses 5/9/13 taps at full/75%/half scale. Each removed tap saves one temporal-GI and one prepass-normal read: about 16 reads per full-resolution output pixel, 8 at 75%, and 0 at half. The existing eight contact-grounding decodes and every v0.050 shaping equation are unchanged.
- Unchanged surfel geometry no longer issues 32 position/radius plus 32 normal/source constant calls to each of the GI and cache effects every frame. This removes 128 vector constant calls plus three geometry metadata calls per unchanged frame; dirty swaps/rebinds still upload all data once.
- Screen-only source mode disables both the 32x4 cache update and its copy child. Their targets are tiny, so the expected GPU gain is low, but it also avoids cache callbacks and constant updates.
- Diffuse-basis setup is hoisted from every path to once per GI pixel. Ray projection removes repeated cross/dot/determinant construction from every step and replaces it with per-path intercept/slopes plus per-step multiply-add evaluation. Exact post-compiler ALU savings are hardware/compiler dependent; the saving scales with `pathCount * rayMaxSteps`.
- Surfel acquisition defaults to four detailed `Engine.castRay` calls per frame, so the normal 32-ray request spans up to eight update frames instead of one hitch-prone frame. Total raycast work is unchanged. The previous completed set and atlas remain active until atomic replacement.
- Excluded by design: spatial surfel acceleration, coarse-to-fine marching, cosine-estimator correction, progressive screenshot accumulation, more surfels, and any ray/path ceiling increase.

Offline v0.052 result: all nine shaders selected by `main.lua` compile as both `vs_5_0` and `ps_5_0`, 18/18, using FXC `/Ges /WX`; there are no compiler warnings. `main.lua` passes an independent `luaparse` syntax parse. BeamNG must still perform the engine-specific load/runtime gate. No FPS improvement is claimed before that in-game test. SHA-256: `main.lua` `22C060A6E9B49181509F9949B91E42FF5A6A63CDDE868705F59F74047E463470`; GI `87BEB54CA14F4E1540940680E3A8E64958ED24F3151B8D594F328AD2608C760A`; temporal `59ED750C4568A05EB104015DCCE85BC1E1A07CCC9ECC4F92A524F9EF1D4DA414`; compose header `E9213F3391BCDA3F68E649EFE75F98F0C3A4D4F85843F1DFE76D9837CF504BB1`; composer `7EB99786CA3EE9514F1359B3141A866F731608D3B97A1E93D6A14C5D85720F5E`.

### v0.053 temporary native-buffer diagnostic

- `beamrtBufferDiagnosticP_v001.hlsl` is a cache-busted, single-texture fullscreen probe. `beamrtBufferDiagnostic_v001.h.hlsl` contains its isolated sampler/constants. No v0.052 GI, temporal, composer, cache, debug, copy, or reflection shader was edited.
- GELUA creates one fixed PostEffect per named source rather than rebinding a texture dynamically: `#sunShadowMask[RT0]`, `#lightinfo[RT0]`, `#lightinfo[RT1]`, `#prepass[RT1]`, `#gtaoOutput[RT0]`, and `#ssaoMask[RT0]`.
- v0.057 added `#BeamRT_BaseColorProbe[RT0]`. The completed v0.058 lifecycle adds fixed diagnostics for BaseColor/Metallic/Emissive probe and cache targets: `baseColorProbe`, `baseColorCache`, `metallicProbe`, `metallicCache`, `emissiveProbe`, and `emissiveCache`. The v0.053 diagnostic shader remains unchanged.
- `bufferdiag` is mutually exclusive with normal BeamRT output. Entering it disables debug, GI/cache, and reflection effects; returning to `lighting` immediately restores the normal v0.052 lighting chain. The probe writes only to `$backBuffer` and owns no history target.
- `setBufferDiagnostic(source, channel)` supports `rgb`, `r`, `g`, `b`, and `a`. `setBufferDiagnosticGain(0..1000000)` and `setBufferDiagnosticExposure(-20..20)` expose dim values. `setBufferDiagnosticView("raw")` is the default and makes no encoding assumption; `"hdr"` explicitly applies BeamNG `hdrDecode`, adjusts in linear space, and re-encodes for the HDR backbuffer.
- Invalid source/channel/range requests return `false` and log a specific error. GELUA cannot reliably preflight all renderer-owned named targets. A setting-dependent unavailable target therefore remains isolated to the diagnostic effect; a black result can mean unavailable or legitimately zero data, and the selector logs the exact target plus a reminder to inspect `beamng.log` for binding warnings.
- Lifecycle discovery: `setMode(...)` selects an output but does not change the extension-wide `enabledRequested` gate. After a clean extension reload, call `beamrt_main.enable()` (or `start()` before selecting the diagnostic). v0.053 now logs `bufferdiag selected but BeamRT is disabled; call beamrt_main.enable()` when this state is detected. The original report that the diagnostic did not reach the framebuffer was caused by this disabled gate, not PostFX scheduling.
- The priority interpretation order is `sunShadowMask`, `lightinfo0`, `lightinfo1`, then `prepass1`. GTAO/SSAO are secondary probes.

Offline v0.053 result: `main.lua` passes `luaparse`. All ten shaders registered by `main.lua`, including the diagnostic shader, compile as both `vs_5_0` and `ps_5_0`, 20/20, using FXC `/Ges /WX`; there are no compiler warnings. BeamNG runtime target binding and visual semantics are still untested. SHA-256: `main.lua` `2DD4831930632F886D23C543CB47EAE1D0FDBF780958510F9F4EB874A74C7978`; diagnostic header `10DEB1B757F62FC745A62AD0FB9E74FA311CB3B12CF3AF838B71A3D2E34DFD92`; diagnostic entry `224A099D48890CEACE0E1E2B643FB31D6B7E7F2B0386B5A30DDC0527ABD30930`.

## v0.008 acceptance test reproduction

Press Ctrl-L, select GELUA, then run:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
print("BeamRT surfel count: " .. tostring(beamrt_main.getSurfelCount()))
beamrt_main.dumpSurfels()
beamrt_main.setMode("surfels")
```

Expected:

1. Version prints `0.008` and the log names `beamrtDebugP_v008.hlsl`.
2. A normal scene reports nonzero surfels and zero raycast call failures; an empty scene may legitimately produce zero hits.
3. Every dumped position/normal/radius is finite, normals are approximately unit length, and sources are `fibonacci-shell` or `ground-grid`.
4. Mode 9 shows normal-colored disc coverage that remains attached to world surfaces while the camera rotates.
5. Run `beamrt_main.setMode("surfelcompare")`; green surfel-only regions are the proof that detailed world data contributes beyond visible depth.
6. Move the camera, call `refreshSurfels()`, and confirm the cache recenters without errors.
7. Run a surfel-radius comparison from the same snapshot:

```lua
beamrt_main.setSurfelRadius(0.75)
beamrt_main.refreshSurfels()
beamrt_main.setMode("surfelcompare")
beamrt_main.setSurfelRadius(3.0)
beamrt_main.refreshSurfels()
beamrt_main.setMode("surfelcompare")
```

Smaller discs should create more holes; larger discs should increase coverage but also make the approximation visibly coarser.

8. Return to the accepted renderer and verify it still behaves normally:

```lua
beamrt_main.setMode("diffusegi")
```

9. Verify disable and cleanup:

```lua
beamrt_main.disable()
extensions.unload("beamrt_main")
print("BeamRT Debug removed: " .. tostring(scenetree.findObject("BeamRT_DebugFx") == nil))
print("BeamRT GI removed: " .. tostring(scenetree.findObject("BeamRT_GIFx") == nil))
extensions.load("beamrt_main")
```

After testing, inspect `beamng.log` for `BeamRT`, `beamrtDebugP_v008`, `world surfels`, `compile`, `error`, and `duplicate`.

## v0.009 acceptance test reproduction

Press Ctrl-L, select GELUA, then run:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
beamrt_main.setWorldGIStrength(1.0)
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setGIStrength(0.7)
beamrt_main.setMode("diffusegi")
beamrt_main.setGISource("screen")
```

Hold the camera still for at least 16 frames and capture the screen baseline. Without moving the camera, run these separately, waiting at least 16 frames after each history reset:

```lua
beamrt_main.setGISource("surfels")
beamrt_main.setGISource("hybrid")
```

Expected:

1. Version prints `0.009`; the log names `beamrtGITraceP_v009.hlsl` and reports a nonzero surfel count with zero raycast call failures in a nonempty scene.
2. `screen` visually reproduces the accepted v0.005a path.
3. `surfels` is sparse but shows stable scene-colored indirect light, not mode-9 normal colors and not geometry behind obvious foreground occluders.
4. `hybrid` retains screen hits and may add stable lighting where the screen ray missed but a visible validated surfel was hit.
5. `beamrt_main.setGIStrength(0)` is a strict no-op; restore `0.7` afterward.
6. Source switches, strength/tolerance changes, and refreshes reset history, so comparisons require reconvergence.
7. Repeat the v0.008 disable/unload/reload commands. Both effect-removal checks and the extension reload check must print `true`.

After testing, inspect `beamng.log` for `BeamRT`, `beamrtGITraceP_v009`, `world surfels`, `compile`, `error`, `NaN`, and `duplicate`.

## v0.010 radiance-validation test

Press Ctrl-L because the version and debug shader entry changed, select GELUA, then run:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setMode("surfelradiance")
```

Expected:

1. Version prints `0.010`, the log names `beamrtDebugP_v010.hlsl`, surfel count is nonzero, and raycast failures remain zero.
2. Dark purple is a geometric surfel miss.
3. Magenta is a hit whose surfel center is outside/unprojectable.
4. Orange is a projected hit rejected by current-frame depth.
5. Red passes depth but fails visible-normal agreement.
6. Green passes every check and directly proves that v0.009 has at least one valid HDR radiance input. Stable green is the primary gate.
7. After the classification screenshot, return to `diffusegi`, run the strict `setGIStrength(0)` no-op check, then repeat disable/unload/reload cleanup.

## v0.011 exact hybrid-coverage test

Press Ctrl-L because both the extension version and cache-busted debug shader entry changed, select GELUA, then run:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
beamrt_main.setWorldGIStrength(1)
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setMode("hybridcoverage")
```

Expected:

1. Version prints `0.011`, the log names `beamrtDebugP_v011.hlsl`, surfel count is nonzero, and detailed-raycast failures remain zero.
2. Cyan pixels are diffuse rays satisfied by the visible-depth tracer; this is the first-choice hybrid source.
3. Green pixels are the important measurement: the visible-depth ray missed, but a surfel hit passed every radiance-validation gate and would supply the hybrid fallback.
4. Dark purple pixels have no usable source for this frozen diffuse sample.
5. The diagnostic is intentionally frozen while debug mode is active; switching through `diffusegi` advances the temporal sample sequence.
6. Any stable green region proves useful hybrid coverage. Its approximate share relative to cyan and purple determines whether to improve cache density/representation before tuning brightness.

## Known problems and limitations

### Phase 5 proxy-specific

- AABB proxies over-occlude the empty corners around rotated, concave, or irregular meshes. They are intentionally diagnostic, not final tracing geometry.
- Only 16 proxies are uploaded because this proof uses individual constant-buffer values, not a scalable GPU data structure.
- Proxies are a snapshot. They refresh when entering `geometry`, changing a geometry setting, or calling `refreshGeometry`; they do not continuously follow the camera.
- Deforming vehicles are intentionally excluded. Vehicle geometry requires a separate dynamic/refittable strategy.
- Forest items are not represented by the four scanned scene classes.
- Huge ground/terrain objects are commonly rejected by the maximum-extent filter. Terrain needs a height-field/voxel/probe representation rather than one giant box.
- A proxy hit has geometry only. It has no triangle normal, material, albedo, emissive value, or hit radiance. For that reason proxy hits are not yet mixed into GI.
- The HLSL skips a proxy which contains the ray origin to reduce self-hits. This can miss a valid exit intersection from a large enclosing box.
- OBBs remain bounding boxes: they reduce rotated-box corner excess but still over-occlude concave or irregular meshes.
- OBB center uses `getWorldBox():getCenter()` because BeamNG's own editor selection-box implementation does the same; local extents use `getObjBox()` and separate `getScale()`.
- HLSL reconstructs axis Z from X×Y. This assumes the transform columns are an orthonormal rotation basis, matching BeamNG's editor convention.
- v0.008 surfels are sparse finite discs, not triangles. Their radius trades holes against false coverage.
- The detailed CPU query is deliberately refresh-only because shipped `ge_utils.lua` labels it slow.
- `renderGeometry=true` may sample dynamic rendered objects as well as static scenery; v0.008 logs samples but does not yet have a reliable hit-object classification channel from this API.
- Surfel records still contain only geometry and normals. v0.012 adds one persistent RGB radiance value per surfel, but it can only retain a value after that surfel has been observed in a rendered frame.
- Because one radiance sample is taken at each surfel center rather than at the exact disc intersection point, large surfel radii can smear lighting across a coarse patch. Keep radius comparisons part of the acceptance gate.
- Cache radiance has no directional lobes, material/albedo separation, relocation, or automatic expiry. Dynamic lighting changes converge at the fixed 0.2 update blend only while the surfel is visible.
- `32x4` is intentionally tiny. It proves persistence without pretending that 32 coarse discs are a scalable world representation.
- v0.051's cleanup infers diffuse-like radiance from five already-lit backbuffer samples. It has roughness but no clean diffuse albedo, specular color, light list, or material ID. It can suppress a legitimate tiny emissive highlight or slightly dim coherent glossy energy; use the raw-source A/B rather than compensating by lowering GI strength.
- The cleanup samples four additional backbuffer/prepass/depth locations for every evaluated live or visible-cache hit. It is cheaper than increasing path count but is not free.

### Existing renderer

- v0.020 reflections are screen-space: they cannot reflect sky or geometry outside the current frame, and disocclusions can leave temporary gaps.
- Roughness is available but metallic/specular color is not consumed by the v0.020 PostFX, so the Fresnel base reflectance is a neutral approximation rather than the exact material BRDF.
- The depth marcher uses fixed linear steps. Thin objects, grazing angles, and large depth discontinuities can miss or produce short streaks; the edge confidence intentionally fades results near the viewport boundary.
- GI and reflections are mutually exclusive modes in v0.020. Combining them safely requires explicit pass ordering and an energy budget after both individual paths pass.
- Lighting radiance remains screen-derived, but v0.012 retains already observed samples when they become off-screen or temporarily occluded. Never-observed surfaces still have no radiance.
- The result is a lighting experiment layered over BeamNG rasterization, not a replacement renderer and not genuine path tracing.
- Variable 1–32 rays per GI pixel plus temporal reuse reduces the old square/single-ray look, but fine stochastic grain, screen-edge loss, and temporal shimmer can remain. More paths reduce current-frame Monte Carlo noise but do not add off-screen geometry.
- v0.052 retains the v0.041 ceiling of 32 depth marches per lighting pixel, each with as many as 512 linear steps. Reconstruction is 5/9/13 taps at full/75%/half scale and contact grounding remains eight samples. Windows may reset the graphics driver if a frame exceeds the TDR timeout; treat 32×512 as a preserved comparison baseline, not a recommended play setting.
- v0.031 contact grounding is a screen-space approximation. It can halo at depth discontinuities or darken tight creases too strongly; use `setContactShadowStrength(0)` to isolate it.
- Increased bounce saturation can exaggerate already saturated emissive/neon surfaces; `setBounceSaturation(1)` restores neutral chroma.
- The v0.052 tuner is an ImGui development window, not a polished Vue/CEF BeamNG app. It is intentionally lightweight and may capture mouse/keyboard focus while hovered. Exact fields commit on Enter; typing without Enter only changes the temporary UI pointer.
- Receiver tint derives approximate chroma from the already lit backbuffer because the PostFX does not have a clean material-albedo buffer. At high values it can double-tint strongly lit paint; reduce `setGIReceiverTint` if that occurs.
- Shadow focus is intentionally an artistic screen-space control, not a physically exact visibility term. It suppresses GI on bright pixels to avoid the smoky full-frame overlay; too much can make bounce vanish outdoors.
- The energy ceiling is now explicit rather than hidden. Very high values combined with GI exposure/strength can still wash out the HDR frame; highlight rolloff controls the shoulder but does not make unlimited energy physical.
- Live `targetScale` changes are implemented by updating the three PostEffect fields together, but BeamNG v0.040 testing must confirm that existing named render targets resize immediately. If not, recreate only the GI effect chain after a resolution change.
- World leak suppression reduces oversized-disc haze; it cannot turn 32 sparse, directionless cache records into dense scene geometry. Radii around 5–8 m and large visibility tolerances remain fundamentally unsafe for clean lighting.
- Sliders that change tracing or history parameters reset/reconverge temporal lighting. Judge a value after briefly holding the camera still, not on the exact adjustment frame.
- `saveTuning()` writes to the BeamNG user settings path `/settings/beamrtTuner.json`; this path is outside the unpacked mod and therefore survives mod source replacement.
- Automatic surfel recentering is deliberately coarse (120-frame checks, eight-metre threshold) because `Engine.castRay(..., renderGeometry=true)` is a slow CPU query. v0.052 keeps the previous set active while the replacement is built, so a fast-moving camera can temporarily see stale rather than missing cache data.
- The v0.052 projection form is algebraically equivalent to v0.051 but changes floating-point operation ordering. In-game testing must check thin silhouettes and viewport edges for any rare hit-boundary difference.
- Crossing composer scale thresholds changes the reconstruction footprint immediately: 5 taps at full, 9 at 75%, and 13 at half. This may produce a small blur/noise transition while dragging the resolution control.
- A pending surfel refresh snapshots camera origin, trace distance, and base radius. Changing those controls during acquisition does not mutate the in-flight request; call `refreshSurfels()` again to replace it with a new snapshot.
- v0.053 cannot distinguish a valid all-zero render target from a target that BeamNG did not allocate for the active graphics settings. A black diagnostic is inconclusive by itself; test gain/channel choices and inspect `beamng.log` for named-texture binding warnings. Raw mode is intentionally not a promise that values are display-linear.
- Dynamic-object velocity quality limits temporal reprojection on fast/deforming vehicle pieces.
- Transparent objects and sky do not provide complete G-buffer geometry.
- `setGIStrength(0)` is the required no-op comparison; keep checking it after future changes.
- The screen sometimes shows `Unknown app: pgMechanicalFailures`. This is unrelated to BeamRT.
- BeamNG's console `print` may display only the first argument. Prefer concatenation, for example:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
```

## BeamNG-specific discoveries

These details were established from the shipped 0.39.4 files and/or in-game testing and are easy to miss when reading only the BeamRT source.

### PostFX/G-buffer conventions

- `PFXVert` plus `processPostFxVert` is the correct fullscreen path.
- Shipped `lua/ge/client/postFx/ssao.lua` proves `PostEffect.targetSize` supports explicit fixed dimensions (`256 1` there). BeamRT v0.012 uses this facility for its `32 4` atlas.
- `POSTFX_UNIFORMS` supplies BeamNG's expected viewport/projection parameters.
- `decodeGBuffer` returns decoded world normal in XYZ and normalized eye-linear depth in W.
- Advanced Lighting prepass RT0 stores encoded normal in RG and roughness in B.
- The working inputs are exactly `#prepass[RT0]`, `#prepass[Depth]`, and `$backBuffer`.
- `eyePosWorld + wsEyeRay * decoded.w` matches the shipped fog/caustics reconstruction convention.
- The projective screen-space ray helper derives projection from the affine `wsEyeRay` field using derivatives. It does not require a private inverse matrix.
- BeamNG velocity follows `previousUV - currentUV`; history lookup is therefore `currentUV + velocity`.
- HDR backbuffer values must use shipped `hdrDecode`/`hdrEncode` helpers.
- HLSL texture reads reached from a runtime-variable path loop should use `tex2Dlod(..., lod=0)` rather than implicit-gradient `tex2D`; FXC warns that derivatives are undefined in varying loops even though the shader compiles.

### Engine object and lifecycle behavior

- `ShaderData.samplerNames` and `PostEffect.texture` slots are zero-based even though Lua tables are normally one-based.
- Vector shader constants work as space-separated strings through `setShaderConst`; shipped SMAA/DOF code uses this convention.
- Child PostEffects are registered scene objects and should be explicitly deleted on unload even when attached to a parent.
- Callback tables are globals named from the PostEffect object plus `Callbacks`; clear them with `rawset(_G, name, nil)` on unload.
- Ctrl-L reload safety depends on disabling/deleting every BeamRT object before recreating it.
- Shader entry filenames should be versioned during development because BeamNG may reuse cached programs after source changes.

### Scene geometry access

- `scenetree.findClassObjects("TSStatic")` is a shipped pattern used by `core/environment.lua`.
- Scene objects expose `getWorldBox()` with `minExtents` and `maxExtents`; BeamNG editor code explicitly validates these against infinities and invalid ordering.
- `getObjBox()` is explicitly documented in shipped assembly-spline code as a local mesh-space box.
- Shipped `editor/objectTool.lua` forms its oriented selection box by scaling `getTransform()` first by `getScale()` and then by local-box extents, while positioning it at `getWorldBox():getCenter()`. `getTransform()` columns 0, 1, 2, and 3 correspond to local X/right, Y/forward, Z/up, and translation respectively.
- `Engine.castRay(origin, target, includeTerrain, renderGeometry)` returns detailed point/normal data but is labelled slow in shipped `ge_utils.lua`.
- `castRayStatic(origin, direction, distance)` is widely used for cheaper distance-only static collision tests.
- `TerrainBlock` exposes `getHeight`, `getNormal`, and `getSmoothNormal` through shipped `core/terrain.lua`.
- `GBitmap` can be allocated, filled, and saved from GELUA. This makes a cached height/occupancy atlas plausible, but no inspected shipped Lua API directly exposes a per-frame structured GPU buffer, source mesh vertex/index buffers, UAV voxelization, BLAS/TLAS creation, or DXR dispatch to a normal mod.
- D3D12 renderer availability does not imply mod-level DXR access.

### BeamNG light representation

- Static scene lights can be enumerated with `scenetree.findClassObjects("PointLight")`, `scenetree.findClassObjects("SpotLight")`, or the shared `LightBase` class. Runtime fields can be inspected through `obj:getFields()` and `obj:getField(name, "0")`; position and transform are available through `getPosition()` and `getTransform()`.
- Shipped `lua/ge/extensions/util/photomodeFlash.lua` creates a `SpotLight` and sets `innerAngle`, `outerAngle`, `range`, `color`, `isEnabled`, `intensity`, `attenuationRatio`, `castShadows`, and `texSize`. Shipped Flowgraph `scene/spawnLight.lua` additionally demonstrates `brightness`, position, and rotation.
- Shipped `editor/lightClassConverter.lua` establishes the important class split: PointLight reach is `radius`, SpotLight reach is `range`, and `brightness` is the render-facing value. `intensity` is linked but uses class-specific photometric units (lumens for PointLight, candelas for SpotLight). Do not rank mixed light classes by raw `intensity` without conversion.
- A static spotlight's world direction can be derived from transform local +Y (matrix column 1), matching BeamNG's own vehicle-light debug convention. Cone angles still need an in-game value/unit check before shader upload.
- Vehicle headlights are a separate representation and must not be assumed to be ordinary scenetree lights. Shipped `lua/common/jbeam/sections/meshs.lua` creates JBeam `SPOTLIGHT`/`POINTLIGHT` props and calls each prop light's `setLightArgs(...)`. Relevant JBeam fields include `lightInnerAngle`, `lightOuterAngle`, `lightBrightness`, `lightRange`, `lightCastShadows`, `lightColor`, `lightAttenuation`, `lightIntensityCd`, and `lightIntensityLm`.
- Shipped `vehicleEditor/liveEditor/veLightsDebug.lua` obtains those lights from `core_vehicle_manager.getVehicleData(vehId).vdata.props`, retrieves the live prop with `vehicle:getProp(prop.pid)`, and uses `propObj:getLiveTransformWorld()` for position/direction; local +Y is the light forward axis. The actual runtime enabled/electrics state still needs verification before vehicle lamps are uploaded.

## Next planned work

1. Clean-reload the extension and confirm `beamrt_main.getVersion() == "0.060"` and `beamrt_main.getPTGIRadianceSource() == "legacy"`. Inspect `beamng.log` for errors involving `beamrtGITraceP_v060.hlsl`, `beamrtSurfelCacheP_v060.hlsl`, `cleanRadianceTex`, or `ptgiRadianceSourceMode`.
2. From one completely stationary camera, publish BaseColor, Metallic, and Emissive in sequence, allowing each one-frame capture to finish. Confirm all three status records are valid/non-stale, use the same resolution, and show the same generation number. Any camera-change rejection is intentional; recapture all three without moving.
3. Run `beamrt_main.refreshCleanRadianceDiagnostics()`, wait for completion, and inspect `beamrt_main.getCleanRadianceDiagnostics()`. Before selecting clean it should report `valid=true`, `stale=false`, generation/source-generation data, both bindings true, and `feedsPTGI=false`.
4. Set `beamrt_main.setGISource("screen")`. Select `legacy`, let temporal history warm for several frames, and capture the same camera. Select `clean`, let it warm again, and capture. Confirm the material-aware source preserves colored diffuse bounce without reflection-shaped beauty-buffer echoes.
5. Repeat the A/B separately in `hybrid` or `surfels` mode. Source switching deliberately resets temporal history and clears persistent surfel radiance, so never judge the first frame. This test proves clean radiance reaches the cache path rather than only live screen hits.
6. While `clean` is selected, move more than 0.01 m or rotate more than 0.05 degrees. Confirm the log states the exact reason, `getPTGIRadianceSource()` returns `legacy`, temporal history resets, and surfel radiance clears while geometry surfels remain. Repeat for FOV and resolution changes where practical.
7. Republish one material cache after rebuilding CleanRadiance and selecting clean. Confirm its generation change immediately falls back to legacy. Also confirm settings/graphics, shader/material, and mission invalidations fall back rather than leaving the public state as clean.
8. Do not add automatic recapture yet. Returning to clean remains the explicit sequence: publish all three material caches, refresh CleanRadiance, then call `setPTGIRadianceSource("clean")`.
9. After the v0.060 acceptance gate, resume provider validation and direct hit-light evaluation. Forest/TSStatic DAE parsing and Terrain material layers remain unresolved scene-data work. Native DXR remains a real future backend milestone, not Lua emulation.

## Scope guardrails

Do not silently add ReShade, native C++, DXR, voxel tracing, or a replacement renderer to the current mod. Those require an explicit milestone decision. Preserve the unpacked-mod workflow and never edit base-game files. Keep the accepted v0.005a path recoverable while experimenting with Phase 5.

## 86. Verified callable API / function inventory

This section is intentionally explicit. These are actual runtime calls and methods observed during BeamRT research, not merely conceptual discoveries. Where exact argument semantics remain unknown, that is stated explicitly.

### 86.1 BeamRT current public debug API

```lua
beamrt_main.enable()
beamrt_main.setMode("bufferdiag")

beamrt_main.setBufferDiagnostic("sunShadowMask", "r")
beamrt_main.setBufferDiagnostic("lightinfo0", "rgb")
beamrt_main.setBufferDiagnostic("lightinfo0", "r")
beamrt_main.setBufferDiagnostic("lightinfo0", "g")
beamrt_main.setBufferDiagnostic("lightinfo0", "b")
beamrt_main.setBufferDiagnostic("lightinfo0", "a")
beamrt_main.setBufferDiagnostic("lightinfo1", "rgb")
beamrt_main.setBufferDiagnostic("prepass1", "rgb")
beamrt_main.setBufferDiagnostic("prepass1", "a")
beamrt_main.setBufferDiagnostic("baseColorProbe", "rgb")
beamrt_main.setBufferDiagnostic("baseColorCache", "rgb")
beamrt_main.setBufferDiagnostic("metallicProbe", "rgb")
beamrt_main.setBufferDiagnostic("metallicCache", "rgb")
beamrt_main.setBufferDiagnostic("emissiveProbe", "rgb")
beamrt_main.setBufferDiagnostic("emissiveCache", "rgb")
beamrt_main.setBufferDiagnostic("gtaoOutput", "r")
beamrt_main.setBufferDiagnostic("ssaoMask", "r")

beamrt_main.setBufferDiagnosticGain(value)
beamrt_main.setBufferDiagnosticExposure(value)
beamrt_main.setBufferDiagnosticView("raw")
beamrt_main.setBufferDiagnosticView("hdr")
beamrt_main.getBufferDiagnostic()
beamrt_main.exitBufferDiagnostic()
```

The observed implementation range for diagnostic gain is approximately 0 through 1,000,000. Exposure is approximately -20 through +20. Supported diagnostic channels are RGB, R, G, B, and A. `exitBufferDiagnostic()` switches back to lighting mode.

As of v0.054, selecting `bufferdiag` automatically enables BeamRT. The explicit `enable()` call remains valid but is no longer required to make the selected diagnostic pass visible after a clean reload.

### 86.2 File/VFS access from GE Lua

Verified globals and methods:

```lua
readFile(path)
FS
FS:findFiles(...)
```

Examples used during research:

```lua
local shaderFiles = FS:findFiles("/shaders", "*.hlsl", -1, true, false)
local luaFiles = FS:findFiles("/lua", "*.lua", -1, true, false)
local text = readFile(path)
```

This allowed direct inspection of BeamNG HLSL and Lua source at runtime.

### 86.3 SceneTree basic access

Class enumeration:

```lua
scenetree.findClassObjects("DecalRoad")
scenetree.findClassObjects("MeshRoad")
scenetree.findClassObjects("TSStatic")
```

Object resolution:

```lua
scenetree.findObject(id)
scenetree.findObject(name)
```

Common object methods used successfully:

```lua
obj:getID()
obj:getName()
obj:getClassName()
obj:getWorldBox()
obj:getObjBox()
obj:getPosition()
obj:getGroup()
obj:getField(fieldName, arrayIndex)
```

Ordinary scalar/non-array fields were read with `obj:getField("fieldName", "")`; some material probes used array index `"0"`.

### 86.4 Scene frustum query

Verified native callable:

```lua
findObjectListFrustum(frustum, mask)
```

Observed useful masks on West Coast:

- `64`: PointLight and SpotLight objects in the current frustum.
- `256`: TSStatic objects only.

These meanings are empirical observations, not a documented universal bitmask contract. The frustum comes from the current RenderView.

### 86.5 RenderView manager

Verified object and methods:

```lua
RenderViewManagerInstance:getView(name)
RenderViewManagerInstance:getOrCreateView(name)
RenderViewManagerInstance:destroyView(...)
RenderViewManagerInstance:cameraNameEquals(...)
```

Both `getView("main")` and `getView("Main")` returned live userdata during testing. Use lowercase `main` as the canonical choice for now.

Observed readable RenderView properties:

```text
cameraMatrix
frustum
fov
resolution
viewPort
namedTexTargetColor
renderMode
usePostEffects
renderShadows
renderCubemap
manualEV
clearColor
active
```

### 86.6 GFX device / named-resource discovery

Verified global and useful call:

```lua
GFXDevice.describeResources(query)
```

Examples:

```lua
GFXDevice.describeResources("lightinfo")
GFXDevice.describeResources("prepass")
GFXDevice.describeResources("decal")
GFXDevice.describeResources("road")
GFXDevice.describeResources("vertex")
GFXDevice.describeResources("index")
GFXDevice.describeResources("buffer")
```

Some searches return nil even when a resource exists under a different registered name. Other observed methods include `GFXDevice.devicePresent` and `GFXDevice.setDisplayDevice`. No public Lua D3D12 device pointer, BLAS, TLAS, or dispatch API was found.

### 86.7 Vehicle identification

Current player vehicle ID:

```lua
local vehicleId = be:getPlayerVehicleID(0)
```

Vehicle mesh material table:

```lua
local names = veh:getMeshMaterialNames()
local materialName = names[primitive.materialIndex + 1]
```

### 86.8 GPUMesh entry point

Verified native entry point:

```lua
local id = be:getPlayerVehicleID(0)
local mesh = GPUMesh.bng_getGPUMesh(id)
```

Vehicle IDs return a GPUMesh object. Tested TSStatic and DecalRoad IDs returned nil. Do not assume arbitrary SceneTree IDs work.

### 86.9 GPUMesh object methods

Returned GPUMesh objects exposed:

```lua
mesh:dataIsReady()
mesh:verticesCount()
mesh:indicesCount()
mesh:verticesGet(...)
mesh:indicesGet(...)
mesh:normalsGet(...)
mesh:tangentsGet(...)
mesh:uv1Get(...)
mesh:uv2Get(...)
mesh:vertColorsGet(...)
mesh:indicesMinMax(...)
mesh:flexmeshes()
mesh:propmeshes()
```

Take exact accessor arguments from the currently working BeamRT implementation or verified probe code rather than inventing them.

Verified element layouts:

- vertices: `float3`
- normals: `float3`
- indices: `uint32`
- tangents: `float4`
- UV1: `float2`
- UV2: `float2`
- vertex colors: `float4`

### 86.10 GPUMesh static namespace

Observed namespace members:

```text
GPUMesh.bng_getGPUMesh
GPUMesh.gpuMesh
GPUMesh.gpuFlexMesh
GPUMesh.gpuPropMesh
```

No sibling equivalent of `getStaticMesh`, `getRoadMesh`, or `getSceneMesh` was discovered.

### 86.11 Flexmesh descriptors

Flexmesh descriptors expose:

```lua
flex.meshName
flex:primitivesCount()
flex:primitivesGet(...)
```

Discovered primitive layout:

```cpp
struct Primitive
{
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t materialIndex;
};
```

Use `materialIndex + 1` for Lua-side vehicle material-name indexing.

### 86.12 Forest root access

Verified:

```lua
local forest = core_forest.getForestObject()
local db = forest:getData()
```

The West Coast object was `theForest`. Observed database capabilities/method names include:

```lua
db:getItems(...)
db:Circle(...)
db:Box(...)
db:Polygon(...)
db:Frustum(...)
db:getItem(...)
```

UID-related methods were also present. The precise argument signatures for every Forest DB spatial method were not fully preserved. Do not invent them; inspect the runtime object or existing verified probe code first.

Observed ForestItem data includes position, transform, scale, asset/data, bounds, UID, size, radius, and materials.

### 86.13 DecalRoad object methods

Verified on live DecalRoad objects:

```lua
road:getNodeCount()
road:getNodePosition(index)
road:getNodeWidth(index)
road:getEdgeCount()
road:getLeftEdgePosition(index)
road:getMiddleEdgePosition(index)
road:getRightEdgePosition(index)
road:getEdgesTable()
```

Indices may follow engine-specific rules; use verified probe behavior rather than assuming C or Lua indexing.

`getEdgesTable()` returns generated edge entries where `edge[1]` is the left vec3, `edge[2]` is the middle vec3, and `edge[3]` is the right vec3.

### 86.14 DecalRoad important fields

Fields/properties successfully read include:

```text
material
drivability
textureLength
detail
breakAngle
zBias
renderPriority
startEndFade
improvedSpline
useSubdivisions
overObjects
```

Bulk navigation metadata additionally includes `lanesLeft`, `lanesRight`, `oneWay`, and `inverted`.

### 86.15 Native DecalRoad bulk API

This is the preferred map-scale extraction call:

```lua
local roads = Sim.getDecalRoadData()
```

No argument is required. Calls with arbitrary numeric arguments happened to return the same dataset, but do not use a fake argument.

Observed West Coast result:

- 12,752 records
- approximately 0.17 to 0.31 seconds
- approximately 2,643,381 numeric edge values
- approximately 10 MB raw float-equivalent payload
- approximately 59 materials

Record fields include `drivability`, `inverted`, `lanesLeft`, `lanesRight`, `material`, `oneWay`, and `vertices`.

### 86.16 Native DecalRoad per-object fallback

Verified:

```lua
local values = Sim.getVerticesOfDecalRoad(decalRoadObjectId)
```

This returns a flat numeric Lua table. Per generated edge the layout is:

```text
L.x L.y L.z
M.x M.y M.z
R.x R.y R.z
```

That is nine numbers per edge. A road with 85 edges returned 765 numbers, matching `road:getEdgesTable()`.

Do not confuse this with the stale shipped name `Sim.getDecalRoadVertices`. The current runtime function is `Sim.getVerticesOfDecalRoad`.

### 86.17 DecalRoad complete-coverage algorithm

1. Call `Sim.getDecalRoadData()`.
2. Enumerate `scenetree.findClassObjects("DecalRoad")`.
3. Resolve each road with `scenetree.findObject(idOrName)`.
4. Match it against the bulk result.
5. For an unmatched road, call `Sim.getVerticesOfDecalRoad(road:getID())` and collect the remaining metadata from the object.

Observed West Coast coverage was 12,752 bulk records plus 12 fallback objects, totaling all 12,764 SceneTree DecalRoads.

### 86.18 Known bulk DecalRoad omission condition

The 12 missing roads all lived under the detached `p_moviestudio_terrain_lot_group`:

```text
DecalRoad
└─ p_moviestudio_terrain_lot_group
   └─ nil parent
```

A typical included hierarchy was:

```text
DecalRoad
└─ DecalRoads
   └─ MissionGroup
      └─ RootGroup
```

This strongly suggests that `Sim.getDecalRoadData()` enumerates mission/root-managed roads rather than every globally reachable SceneTree DecalRoad. It is not C++ source-confirmed.

### 86.19 Material object access

Material lookup:

```lua
local mat = scenetree.findObject(materialName)
local className = mat:getClassName()
local value0 = mat:getField(fieldName, "0")
local scalar = mat:getField(fieldName, "")
```

The class commonly reports `Material`. Useful observed field names include:

```text
baseColorMap
diffuseMap
normalMap
roughnessMap
metallicMap
ambientOcclusionMap
opacityMap
baseColorFactor
roughnessFactor
metallicFactor
translucent
translucentBlendOp
alphaRef
doubleSided
emissive
emissiveMap
emissiveFactor
emissiveIntensityNits
```

Not every material defines every field.

### 86.20 Terrain

TerrainBlock can be enumerated through SceneTree. The observed West Coast object was `theTerrain`. Known properties include `squareSize`, `maxHeight`, `baseTexSize`, `lightMapSize`, `terrainFile`, and `materialTextureSet`.

Terrain height and normal querying worked during research, but the exact function signatures were not preserved in this note. Do not invent them; recover them from verified probe code or the runtime before implementation.

### 86.21 Light objects

Scene classes can be enumerated directly:

```lua
scenetree.findClassObjects("PointLight")
scenetree.findClassObjects("SpotLight")
```

Alternatively, use the empirically observed frustum mask 64 for currently visible lights.

Observed PointLight properties include position, brightness, color, radius, castShadows, and shadowType. Observed SpotLight properties include position, brightness, color, innerAngle, outerAngle, range, castShadows, and shadowType. Retrieval may use direct properties or `getField()` depending on the binding.

### 86.22 Vehicle light data

Vehicle prop/electrics light structures exposed type/SPOTLIGHT, brightness, range, candela value, inner/outer cone, shadows, color, and transform. These should eventually enter LightDatabase separately from ordinary SceneTree PointLight and SpotLight objects.

### 86.23 Raycasts

Verified engine APIs:

```lua
Engine.castRay(...)
castRayStatic(...)
```

`Engine.castRay` can return detailed hit data such as point and normal but is relatively expensive. `castRayStatic` is cheaper and useful for static distance/occlusion work. Take exact signatures from the currently working BeamRT code or verified probes rather than guessing.

### 86.24 Tech extensions

Verified loading/check calls:

```lua
extensions.load("tech_techCore")
extensions.load("util_export")
extensions.isExtensionLoaded(...)
```

Loading `tech_techCore` did not make `Sim.getDecalRoadVertices` appear. The useful runtime APIs remained `Sim.getVerticesOfDecalRoad` and `Sim.getDecalRoadData`.

### 86.25 TechCore mesh handlers

Loaded `tech_techCore` exposed names including:

```text
handleGetFullTriangleData
handleGetMeshId
handleOpenMesh
handlePollMesh
handleSendAdHocRequestMesh
handleIsAdHocPollRequestReadyMesh
handleSetMeshRequestedUpdateTime
```

Research showed that this path belongs to BeamNG's vehicle mesh sensor system. Do not use it as though it were generic world-geometry extraction.

### 86.26 Lua environment / FFI

FFI exists and can be used for typed memory, casts, GPUMesh buffer reading, and memory copies. Dynamic DLL loading is sandbox-blocked. These failed with sandbox denial:

```lua
ffi.load("kernel32")
ffi.load("d3d12")
ffi.load("dxgi")
package.loadlib(...)
```

Do not plan a normal GE Lua extension that simply loads `BeamRTNative.dll` through FFI.

### 86.27 Useful runtime introspection pattern

For ordinary Lua table namespaces:

```lua
for k, v in pairs(SomeTable) do
  print(k, type(v))
end
```

This worked for namespaces such as GPUMesh, Sim, and tech_techCore. Torque/engine userdata proxies may not behave like ordinary tables under `pairs()` or `getmetatable()`. Probe uncertain calls with `pcall()` and prefer known object APIs.

### 86.28 Safe probe style

BeamNG's GE console frequently flattens pasted multiline Lua into one line. Never put Lua `--` comments inside console probe snippets because a comment may consume the rest of the pasted command.

Prefer semicolon-separated statements and `pcall()` around uncertain engine calls:

```lua
local x = ...; local y = ...; print(...)
```

## 87. Verified shader files / source locations

Important BeamNG shader files examined:

```text
/shaders/common/lighting.hlsl
/shaders/common/lighting/advanced/pointLightP.hlsl
/shaders/common/lighting/advanced/spotLightP.hlsl
/shaders/common/lighting/advanced/vectorLightP.hlsl
/shaders/common/lighting/advanced/farFrustumQuad.h.hlsl
/shaders/common/lighting/clustered/cluster_shade.cs.hlsl
/shaders/common/lighting/clustered/cluster_flare.ps.hlsl
/shaders/common/lighting/shadowMap/shadowMapPSSM.hlsl
/shaders/common/postFx/sunShadowMask/sunShadowMask.cs.hlsl
/shaders/common/postFx/sunShadowMask/sunShadowMaskCommon.h.hlsl
/shaders/common/material/shadergen/permutations.h.hlsl
/shaders/common/material/shadergen/v0/permutationsV0.h.hlsl
/shaders/common/material/shadergen/vertexIA.h.hlsl
/shaders/common/gbuffer.hlsl
```

Re-check these source files when implementing BeamNG formulas instead of relying only on summarized interpretations.

## 88. Important Lua source files discovered

Relevant shipped Lua sources:

```text
/lua/ge/extensions/tech/techCore.lua
/lua/ge/extensions/util/export.lua
/lua/ge/map.lua
/lua/ge/extensions/editor/api/roadRiver.lua
/lua/ge/extensions/editor/roadSpline/layerMgr.lua
/lua/ge/extensions/editor/tech/roadArchitect/decals.lua
```

These helped establish DecalRoad APIs, stale versus current Sim naming, road-editor semantics, vehicle mesh handlers, and export behavior.

## 89. Verified call versus observed capability

Classify findings before using them:

### A. Exact verified callable API

Examples:

```text
Sim.getDecalRoadData()
Sim.getVerticesOfDecalRoad(id)
GPUMesh.bng_getGPUMesh(vehicleId)
road:getEdgesTable()
scenetree.findClassObjects("DecalRoad")
readFile(path)
FS:findFiles(...)
```

### B. Method name discovered, argument contract not fully preserved

Examples include Forest DB Circle/Box/Polygon/Frustum methods, some Terrain height/normal methods, and some GPUMesh raw-buffer accessor details.

### C. Concept or behavior inferred from runtime testing

Example: `Sim.getDecalRoadData()` appears to omit DecalRoads inside detached SimGroups.

### D. Future architectural target, not an existing API

Examples:

```text
DXRBackend
BLAS builder
TLAS builder
native D3D12 bridge
```

Do not turn categories B, C, or D into invented API calls.
+

============================================================
94. V0.067-V0.068 RAY / TEMPORAL VALIDATION ADDENDUM
============================================================

Current implementation version:

BeamRT v0.068

v0.067 repaired the experimental screen-space DDA path:

- The ray begins from the biased projected start rather than the un-biased surface.
- Segments are clipped against the eye plane and screen viewport.
- The configured DDA budget covers the full clipped segment.
- Screen stride caps the number of useful samples instead of accidentally expanding every ray to roughly one step per pixel (which caused the severe slowdown).
- The linear marcher remains an explicit fallback.
- Frozen diagnostic rays use a fixed sequence instead of the advancing GI frame index, so debug views no longer flash simply because time advances.
- Both the pixel and vertex shader entries compiled successfully with FXC /Ges /WX.

Manual A/B on 2026-09-27:

```lua
beamrt_main.setTemporalBlend(1); beamrt_main.resetHistory()
beamrt_main.setTemporalBlend(0.1); beamrt_main.resetHistory()
```

showed:

- current-frame-only rendering contains a few brief warm samples from the orange road marking;
- the large coherent orange band on the dark vehicle side is primarily created and prolonged by temporal reprojection;
- the artifact appears during camera/view movement and largely disappears after motion stops;
- therefore it is not a BeamNG reflection feature and is not primarily a raw marcher flash.

v0.068 adds `beamrtTemporalP_v068.hlsl` and
`BEAMRT_COMPATIBLE_HISTORY_CLAMP`:

- Temporal neighborhood bounds now include only samples compatible with the receiver's depth and normal.
- The previous implementation included all 3x3 colors before geometry checks, so a bright road marking could widen the history clamp for adjacent dark vehicle pixels.
- Compatible samples also produce per-channel mean/variance.
- During motion, history is clamped toward a receiver-compatible sigma envelope.
- Large color outliers lose history confidence rather than being smeared across the receiver.
- The clamp is per color channel; it does not desaturate valid colored bounce.
- `echoHistoryGuard=0` retains the previous loose clamp as an A/B fallback.
- FXC /Ges /WX compilation succeeded for both ps_5_0 and vs_5_0.

First v0.068 in-game validation:

```lua
beamrt_main.disable()
extensions.unload("beamrt_main")
extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.setTemporalBlend(0.1)
beamrt_main.setEchoHistoryGuard(0.8)
beamrt_main.resetHistory()
```

Repeat the same orbit/movement around the dark vehicle over the orange road line.

A/B:

```lua
beamrt_main.setEchoHistoryGuard(0); beamrt_main.resetHistory()
beamrt_main.setEchoHistoryGuard(0.8); beamrt_main.resetHistory()
```

Expected result:

- guard 0 reproduces the v0.067 temporal orange band;
- guard 0.8 sharply reduces persistence/smearing while retaining brief legitimate warm bounce;
- any remaining isolated one-frame orange sample belongs to the current ray estimator and should be handled later by hit confidence / variance filtering rather than global desaturation.
+

### 94.1 v0.069 whole-frame camera-motion guard

Additional screenshots showed that the orange vehicle band was one symptom of a
broader failure: while the camera moved, an entire stale GI image could remain
visible as translucent copies of pipes, walls, lights, and the vehicle. Once the
camera stopped, the image converged cleanly. The captures still displayed v0.067,
so they predate both the v0.068 receiver-compatible clamp and this addition.

v0.069 adds a real-camera motion signal independent of the sampled velocity
buffer:

- The jitter-free camera position/orientation is compared with the immediately
  preceding frame.
- Translation ramps from zero at 1 mm/frame to full at 3 cm/frame.
- Rotation ramps from zero at 0.01 degrees/frame to full at 0.25 degrees/frame.
- FOV or resolution changes count as full motion.
- During real camera motion, old GI history confidence is reduced to as little as
  8% at the default echo guard.
- Receiver-compatible sigma clamping and current-hit support also use the global
  motion signal when the velocity texture reports near-zero motion.
- Stationary accumulation is unchanged: cameraMotion returns to zero and temporal
  convergence resumes.
- echoHistoryGuard=0 disables the new rejection for a strict A/B.
- cameraMotion is exposed through beamrt_main.getSettings().
- beamrtTemporalP_v069.hlsl compiled successfully as ps_5_0 and vs_5_0 with FXC
  /Ges /WX.

First v0.069 test:

```lua
if beamrt_main then beamrt_main.disable() end; extensions.unload("beamrt_main"); extensions.load("beamrt_main"); print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.setProgressiveAccumulation(false)
beamrt_main.setTemporalBlend(0.1)
beamrt_main.setEchoHistoryGuard(0.8)
beamrt_main.resetHistory()
```

Orbit the camera, then stop. During motion the GI may look noisier because stale
history is deliberately rejected, but pipes/walls/vehicle silhouettes should no
longer drag translucent copies through the frame. After stopping, long-exposure
convergence should resume.



## 90. v0.061 experimental long-exposure milestone

v0.061 was added after fixed-camera direct/legacy/clean/raw/base-game comparisons showed that all v0.060 PTGI sources mostly produced a broad ambient lift. Source cleanup was no longer the dominant visual limitation; transport sampling and accumulation were.

Active cache-busted shaders:

```text
shaders/beamrt/beamrtGITraceP_v061.hlsl
shaders/beamrt/beamrtTemporalP_v061.hlsl
shaders/beamrt/beamrtSurfelCacheP_v061.hlsl
```

The accepted v0.060 GI/surfel shaders and v0.052 temporal shader remain on disk as fallbacks.

New independently switchable experiments:

- Long-exposure PTGI performs an exact running average of per-frame path batches. The default ceiling is 4,096 accumulated samples; the API accepts up to 65,536. It does not increase per-frame path count.
- The accumulation snapshot uses the real camera transform and resets on cumulative movement beyond 0.01 m, rotation beyond 0.05 degrees, FOV change, resolution change, relevant source/transport setting changes, mission changes, graphics changes, or shader changes. Projection jitter is ignored.
- The sampling sequence uses the full 4,096-frame index instead of repeating after 64 frames.
- `legacy` estimator exactly preserves the v0.060 receiver/emitter cosine behavior.
- `corrected` estimator removes receiver NdotL because the generated hemisphere directions are already cosine weighted. A soft emitter-facing gate remains for screen-space hit validity.
- Localization blends the broad v0.060 distance confidence toward a strong near-hit preference. This is deliberately artistic/experimental, not a physical inverse-square diffuse law.
- Optional previous-GI feedback supplies a depth-validated approximate second bounce. It is gated by temporal-history validity and defaults to zero outside the experimental preset.
- Clean-source `#BeamRT_MaskedEmissive[RT0]` can be scaled independently from diffuse radiance. A value of 1 preserves native emissive energy, 0 removes it, and values up to 32 are accepted for deliberate stress testing.
- The tuner now distinguishes the PTGI radiance input (`legacy` versus frozen `clean`) from the Monte Carlo estimator (`legacy` versus `corrected`).

Public controls:

```lua
beamrt_main.applyExperimentalPreset()
beamrt_main.setProgressiveAccumulation(true)
beamrt_main.setProgressiveMaxSamples(4096)
beamrt_main.setProgressiveClampStrength(0.10)
beamrt_main.setGIEstimator("corrected")
beamrt_main.setGILocalization(0.55)
beamrt_main.setSecondBounceStrength(0.25)
beamrt_main.setEmissiveBoost(4.0)
dump(beamrt_main.getProgressiveStatus())
```

Recommended in-game isolation order:

1. Start with PTGI source `legacy`, estimator `legacy`, localization 0, second bounce 0, progressive off. This is the v0.060 transport baseline.
2. Enable progressive accumulation with 1–4 paths/frame and let it reach at least 256 samples.
3. Switch only the estimator to `corrected`, restart accumulation, and compare indirect brightness/local structure.
4. Raise localization from 0 to 0.35, then 0.55, then 0.8.
5. Only after the one-bounce result is stable, try second-bounce strength 0.15, 0.25, 0.5. Values above 1 are intentionally permitted but can glow or diverge.
6. Test frozen `clean` and live `legacy` radiance separately from the estimator A/B.

Offline validation at implementation time:

- v0.061 GI and temporal shaders compile as SM5 vertex and pixel stages with strictness and warnings-as-errors.
- all BeamRT Lua files parse successfully.
- no BeamNG base file was modified.

Do not claim an FPS or visual improvement until the new controls are tested in BeamNG. Long exposure improves a stationary result over time; it is not intended to make a moving camera converge without future reprojection/reservoir work.

## 91. v0.062 adaptive reach / low-path experiment

In-game feedback found four paths visibly grainy while sixteen paths looked cleaner but was substantially slower. The dominant cost is not world triangle complexity: the current screen-space path repeatedly samples prepass depth, potentially hundreds of times per ray. Sixteen paths therefore approaches four times the trace work of four paths when rays do not exit early.

v0.062 adds two cache-busted active entries:

```text
shaders/beamrt/beamrtGITraceP_v062.hlsl
shaders/beamrt/beamrtTemporalP_v062.hlsl
```

The v0.061 GI and temporal entries remain exact full-reach/3x3 fallbacks. The v0.061 surfel-cache shader remains active because surfel ingestion itself did not need this change.

New controls:

```lua
beamrt_main.setRayReach(0.45)
beamrt_main.setRearRayReach(0.18)
beamrt_main.setLowPathRescue(0.80)
```

- Overall ray reach multiplies the configured screen-ray step budget and the usable persistent-surfel distance. It accepts 0.05 through 1.0.
- Rear/camera-facing reach is an additional direction-dependent multiplier. Rays pointing back toward the eye retain a short near-field bounce reach rather than the full radius. It accepts 0.02 through 1.0.
- Low-path rescue adds a 16-tap outer bilateral ring around the existing 3x3 temporal reconstruction. The ring is strongest at four paths and fades completely by twelve paths. It accepts 0 through 1.
- `rayReach=1`, `rearRayReach=1`, and `lowPathRescue=0` restore the v0.061 behavior.

The revised `EXPERIMENTAL WOW` preset uses eight paths, 160 configured steps, 45% overall reach, 18% rear reach, 0.80 low-path rescue, and 0.85 spatial-denoise strength. For max-step rays, eight paths at 45% reach have a lower theoretical marching budget than four paths at 100% reach, while providing twice as many independent directions. Early screen exits and the fixed 32-surfel fallback mean measured GPU cost must still be established in BeamNG.

Recommended A/B:

1. `setGIPathCount(4); setRayReach(1); setRearRayReach(1); setLowPathRescue(0)` for the reported grainy baseline.
2. Keep four paths and set only `setLowPathRescue(0.8)` to judge reconstruction softness/noise.
3. Use eight paths with `setRayReach(0.45); setRearRayReach(0.18); setLowPathRescue(0.8)` for the intended compromise.
4. Use sixteen paths with reach 1 and rescue 0 only as the expensive reference.

Do not claim the intended performance or noise improvement until this A/B is captured in-game.

## 92. v0.063 ray correctness first + temporary sampling/DDA labs

The requested ordering changed after inspection of BeamNG's shipped `shaders/common/dda.h.hlsl`, GTAO blue-noise path, and GTAO temporal/à-trous code. v0.063 therefore treats ray intersection correctness—not denoising—as the acceptance milestone. Sampling and voxel work are deliberately switchable research aids.

Active cache-busted entries:

```text
shaders/beamrt/beamrtGITraceP_v063.hlsl
shaders/beamrt/beamrtTemporalP_v063.hlsl
shaders/beamrt/beamrtLightingComposeP_v063.hlsl
shaders/beamrt/beamrtMomentsP_v001.hlsl
shaders/beamrt/beamrtVoxelAtlasP_v001.hlsl
shaders/beamrt/beamrtVoxelDDAP_v001.hlsl
```

All v0.062/v0.061/v0.060 entries remain on disk as fallbacks.

### 92.1 Production ray-hit audit

The v0.063 linear marcher preserves v0.062 projection math and thickness hits, then adds a front-to-behind depth-crossing bracket. A bracket is bisected up to six times. A silhouette/depth discontinuity is rejected when the refined behind sample never approaches the configured surface-thickness band. Invalid/sky depth clears the bracket so a crossing cannot span a hole in the depth buffer.

Controls:

```lua
beamrt_main.setHitRefinementSteps(-1) -- exact legacy thickness-only test
beamrt_main.setHitRefinementSteps(0)  -- bracket, no bisection
beamrt_main.setHitRefinementSteps(5)  -- validation default

beamrt_main.setRayMarcher("linear")
beamrt_main.setRayMarcher("screendda")
beamrt_main.setScreenRayStride(1.0)

beamrt_main.setRayHitDiagnostic("hits")
beamrt_main.setRayHitDiagnostic("steps")
beamrt_main.setRayHitDiagnostic("distance")
beamrt_main.setRayHitDiagnostic("normals")
beamrt_main.setRayHitDiagnostic("off")
```

The screen marcher is a controlled BeamNG-convention experiment inspired by the shipped DDA code; it is not a verbatim copy. It projects the configured world-space endpoint, advances by screen-pixel stride along the projected segment, analytically solves each sample back to travel distance on the original world ray, and uses the same thickness/bracket/refinement test as the linear marcher. It defaults to `linear` until the A/B is accepted.

Raw diagnostics use the exact active production trace function. They freeze the sample sequence for stable screenshots, bypass temporal filtering and photographic composition, and disable the surfel-cache root while active. `hits` is green for the first cosine ray's screen-depth hit and black for miss; the other modes show step cost, normalized travel, or the hit G-buffer normal.

Required first test:

1. Select screen-only GI so surfels cannot hide a miss: `beamrt_main.setGISource("screen")`.
2. Disable later beauty experiments: `setBlueNoiseStrength(0); setSVGFStrength(0)`.
3. From one fixed camera near thin geometry, compare linear `-1`, linear `5`, then screen DDA `5` at one-pixel stride in `hits`, `steps`, and `normals` views.
4. Look specifically for false hits across silhouettes, missed thin rails/poles/car edges, discontinuous hit normals, and unbounded step cost.
5. Return with `setRayHitDiagnostic("off")`. Do not evaluate beauty until this gate is understood.

### 92.2 Blue noise staged behind the hit gate

The GI shader binds BeamNG's shipped `/shaders/common/postFx/gtao/noiseBlue.png` at sampler 9 using point/wrap sampling. It combines the 128×128 pixel tile with a golden-ratio temporal phase, following the architecture demonstrated by BeamNG GTAO. Startup strength is zero, which leaves the pre-v0.063 hash sequence unchanged. Enable only after the raw hit test:

```lua
beamrt_main.setBlueNoiseStrength(1)
```

Then compare 1, 2, and 4 paths at the same camera. Do not reduce the default path budget permanently until motion and convergence demonstrate that 1–2 paths are actually comparable.

### 92.3 SVGF-style moments prototype, not full SVGF

`BeamRT_MomentsFx` maintains reprojected first and second luminance moments, per-pixel history length, and depth. The temporal shader can use their variance to guide luminance-aware bilateral weights, effective denoise strength, and history-clamp extent. It starts at strength zero. This is not yet BeamNG GTAO's full history gather or a multi-iteration à-trous pipeline.

```lua
beamrt_main.setSVGFStrength(1)
beamrt_main.setSVGFVarianceScale(4)
beamrt_main.setSVGFMaxHistory(32)
beamrt_main.setSVGFDenoiser(false) -- exact control alias for strength zero
```

Exposure normalization, history exposure storage, per-pixel roughness/AO guidance, multi-pass à-trous filtering, and robust dynamic-object history remain future work. The archive finding that `#lightinfo[RT0]` is pre-exposed and that CleanRadiance omits BeamNG ambient-sky SH is recorded as the next lighting-correctness problem; v0.063 does not guess at either fix.

### 92.4 Occupancy-only world DDA lab

The `voxeldda` mode is isolated from normal BeamRT output. A synthetic 32³ occupancy volume is packed as 32 slices in an 8×4 layout inside `#BeamRT_VoxelAtlas` (256×128, half-float target). It intentionally stores only occupancy—no material, normal, or radiance—and a world-space 3D DDA traverses it. This answers only whether packing, addressing, stepping, and bounded cost work in BeamNG PostFX.

```lua
beamrt_main.setVoxelDDADiagnostic("hit")
beamrt_main.setVoxelDDADiagnostic("normal")
beamrt_main.setVoxelDDADiagnostic("steps")
beamrt_main.setVoxelDDADiagnostic("occupancy")
beamrt_main.setVoxelCellSize(1.0)
beamrt_main.setVoxelMaxSteps(96)
beamrt_main.setMode("lighting")
```

It is camera-centered synthetic geometry and must not be interpreted as matching the BeamNG scene. No world voxelization, CPU upload, materials, radiance injection, or PTGI fallback is implemented. The next decision is whether a real occupancy builder can be refreshed cheaply enough; do not expand this into a production backend before that measurement.

### 92.5 Offline status and continuation checkpoint

- `main.lua` parses as Lua 5.1 and remains at 199 top-level locals, under LuaJIT's 200-local chunk limit.
- all 14 active ShaderData entries compile as both SM5 vertex and pixel shaders with FXC `/Ges /WX` (28/28 stages).
- the settings command has 50 format placeholders and 50 values.
- no BeamNG base file was changed.
- no runtime/FPS/visual claim is made until BeamNG loads v0.063 and the ray diagnostic is inspected.

After the ray gate, the intended order is: blue-noise A/B; 1–2 spp trials; mature temporal history with exposure compensation; material/roughness/AO inputs; multi-pass à-trous; then decide whether a real world occupancy atlas is worth pursuing. Preserve the v0.063 experimental controls and this section if work is resumed after context loss.


## 93. v0.064 echo-isolation / confidence milestone

v0.064 is deliberately narrow: it targets the remaining offset/duplicate-image ("echo") artifact without changing BeamRT's radiance source, surfel layout, path-count ceilings, photographic composer, voxel lab, or material-cache architecture.

Active cache-busted entries:

```text
shaders/beamrt/beamrtGITraceP_v064.hlsl
shaders/beamrt/beamrtTemporalP_v064.hlsl
shaders/beamrt/beamrtLightingComposeP_v063.hlsl
shaders/beamrt/beamrtSurfelCacheP_v061.hlsl
```

The v0.063 entries remain on disk. The new controls can reproduce the v0.063 acceptance behavior at runtime: set hit-validation strength and echo-history guard to zero.

### 93.1 Confidence-scored candidate screen hits

`BEAMRT_HIT_VALIDATION` is now active through `beamrtGITraceP_v064.hlsl`. Every candidate screen-depth hit can be checked for:

- minimum projected/world travel (self-hit rejection),
- valid non-background depth,
- refined linear depth error,
- hit-normal facing against the incoming ray,
- screen-edge confidence,
- local 4-neighbour normal continuity,
- local relative depth continuity.

The checks produce a continuous hit confidence. Accepted screen-lighting samples multiply their previous transport confidence by this value. Very weak candidates fall through to the existing world/surfel representation rather than becoming authoritative screen hits. This is aimed directly at the case where a wrong depth crossing becomes a visibly offset second copy after accumulation.

Controls:

```lua
beamrt_main.setHitValidationStrength(1.0) -- 0 = v0.063 acceptance, 1 = full v0.064 validation
beamrt_main.setMinHitTravelPixels(1.0)    -- near-origin/self-hit screen threshold
```

### 93.2 Echo-specific raw diagnostics

The existing frozen production-ray diagnostic now adds:

```lua
beamrt_main.setRayHitDiagnostic("confidence") -- grayscale, white = trusted
beamrt_main.setRayHitDiagnostic("error")      -- green -> red refined depth error
beamrt_main.setRayHitDiagnostic("rejection")  -- categorical rejection colors
```

Rejection colors:

```text
green   accepted
black   no crossing
red     near-origin/self
blue    background/hole
magenta backface
orange  depth error
yellow  screen-edge confidence
cyan    local depth/normal discontinuity
purple  outside viewport
```


These modes inspect the exact production ray function and remain meaningful even when the candidate is rejected. As with v0.063 diagnostics, temporal reconstruction and photographic composition are bypassed while the raw ray diagnostic is active.

### 93.3 Motion-only temporal echo guard

`beamrtTemporalP_v064.hlsl` adds `BEAMRT_ECHO_HISTORY_GUARD`. It uses the current tracer alpha (coverage/confidence) only while screen motion is present. Stationary stochastic misses are deliberately left alone so long-exposure/SVGF-style accumulation can still converge.

During motion, weak current GI support downweights old reprojected history. History clamping also begins at smaller pixel velocities. Both behaviors interpolate from the exact v0.063 thresholds:

```lua
beamrt_main.setEchoHistoryGuard(0.80) -- startup default
beamrt_main.setEchoHistoryGuard(0.00) -- exact v0.063 temporal A/B
```

This is not a substitute for storing previous-frame normals or full GTAO/NRD-style disocclusion metadata. It is a low-risk guard using data BeamRT already has.

### 93.4 First in-game echo test

Start with the source of the artifact isolated:

```lua
beamrt_main.setMode("lighting"); beamrt_main.enable()
beamrt_main.setGISource("screen")
beamrt_main.setRayMarcher("screendda")
beamrt_main.setScreenRayStride(1.0)
beamrt_main.setHitRefinementSteps(5)
beamrt_main.setBlueNoiseStrength(0)
beamrt_main.setSVGFStrength(0)
beamrt_main.setHitValidationStrength(0)
beamrt_main.setEchoHistoryGuard(0)
```

Capture/move around the problem vehicle as the v0.063-compatible baseline. Then change only:

```lua
beamrt_main.setHitValidationStrength(1)
beamrt_main.setMinHitTravelPixels(1)
```

If the duplicated shape is reduced immediately, the dominant source was a spatial screen-hit error. If it remains, keep validation enabled and test:

```lua
beamrt_main.setEchoHistoryGuard(0.8)
```

If that mainly removes the trail during camera/object movement, temporal reuse was the second contributor.

For diagnosis, use the same camera and run:

```lua
beamrt_main.setRayHitDiagnostic("confidence")
beamrt_main.setRayHitDiagnostic("error")
beamrt_main.setRayHitDiagnostic("rejection")
beamrt_main.setRayHitDiagnostic("off")
```

Then repeat with hybrid GI if screen-only is clean:

```lua
beamrt_main.setGISource("hybrid")
```

If the echo appears only after hybrid/world surfels are re-enabled, the next target is stale/spatially broad surfel radiance rather than the screen marcher.

### 93.5 Validation status

This environment did not have BeamNG's FXC runtime/toolchain, so v0.064 is **not marked runtime-accepted** here. Static checks performed during the edit:

- active shader entry paths exist,
- the v0.064 hit-validation call sites use the expanded ray-trace signature,
- v0.064 temporal constants are bound only behind the new wrapper macro,
- settings-command placeholder and argument counts both equal 53,
- no new top-level Lua locals were introduced (important because v0.063 was already at 199/200),
- the v0.063 behavior remains selectable with validation/history guard set to zero.

The first BeamNG load and `beamng.log` shader-compile result are the acceptance gate.

## 94. v0.082 reconstruction, second-bounce, and scene-volume milestone

v0.082 turns three previously partial experiments into testable, isolated paths while preserving the prior presets and shader entries on disk.

### 94.1 Three-pass edge-aware SVGF reconstruction

The lighting chain is now:

```text
trace -> moments -> temporal -> atrous step 1 -> step 2 -> step 4 -> compose -> history copy
```

`beamrtAtrousP_v001.hlsl` is a nine-tap edge-aware filter executed at three increasing scales. It weights samples with current depth, decoded normal, luminance variance, moments history length, and ray-hit confidence. Raw ray diagnostics bypass it. A zero SVGF strength remains a color pass-through, while strength one activates the full reconstruction.

### 94.2 Repaired motion-valid second bounce

The tracer previously compared `previousGI.a` to eye depth even though GI alpha became hit confidence in the newer temporal path. This made `secondBounceStrength` reject almost all reused light. `beamrtGITraceP_v074.hlsl` now binds `#BeamRT_HistoryMoments` and `#VelocityBuffer`, reprojects the lookup, validates with the moments depth channel, rejects excessive motion, and uses GI alpha only as confidence.

### 94.3 Scene-fed voxel coverage diagnostic

`beamrtVoxelAtlasP_v002.hlsl` replaces the synthetic room with a camera-centered 32³ occupancy atlas generated from the real nearby oriented proxy boxes and detailed raycast surfels. Box interiors are not filled; only shells are rasterized, reducing the worst false-occlusion case. Surfels are voxelized as normal-oriented discs. This remains isolated under `voxeldda` until coverage and leak behavior are observed in BeamNG.

### 94.4 PTGI DDA MAX preset

The new `PTGI DDA MAX` button selects `ptgimax`: two full-resolution Screen DDA paths, 48 screen steps, three-pass SVGF, repaired second bounce at 0.35, and no reflection overlay. The original `PTGI DDA`, `PTGI DDA + REFL`, and prior beauty presets remain available for A/B testing.

### 94.5 Offline validation

- `main.lua` parses successfully with `luaparse`.
- All 15 active shader entries compile as both `ps_5_0` and `vs_5_0` using the Windows SDK FXC and the BeamNG/mod include roots: 30/30 stages, zero failures.
- No BeamNG base file was modified.
- Runtime visual quality, frame time, named-target allocation, and engine constant binding still require a BeamNG reload and in-game test.

## 95. v0.083 material-correct reflection milestone

v0.083 replaces the earlier reflection overlay's permissive hit/reuse behavior.
The goal is correctness before extra reflection reach: an uncertain or missing
screen-space hit now falls back to BeamNG's original pixel instead of tinting,
darkening, or polishing the receiver.

Active cache-busted reflection entries:

```text
shaders/beamrt/beamrtReflectionTraceP_v021.hlsl
shaders/beamrt/beamrtReflectionTemporalP_v022.hlsl
shaders/beamrt/beamrtReflectionComposeP_v023.hlsl
```

### 95.1 Trace and material corrections

- The trace stores a confidence-premultiplied signed delta from the receiver
  color instead of a confidence-darkened replacement color.
- A hit requires a front-to-behind depth crossing and five binary refinement
  steps. The first physical crossing terminates the ray, preventing a weak
  foreground surface from being skipped for occluded geometry behind it.
- Defaults are narrower and less permissive: `0.30 m` step, `0.25 m` thickness,
  `0.045 m` normal bias, and `0.34` roughness cutoff.
- Composition uses RT1's live specular/F0 with unmodified Schlick Fresnel. The
  old `1-exp(-3F)` remap that inflated ordinary dielectric F0 was removed.
- Roughness now broadens a material-aware Poisson reconstruction; it no longer
  merely dims the same sharp mirror image.

### 95.2 Finite, precision-safe reflection history

The temporal alpha channel stores normalized receiver depth at its original
magnitude: positive is a fresh center-pixel hit, negative is its one permitted
grace frame, and zero is invalid. History is fetched with an exact texel load,
so linear filtering cannot invent an age state. This preserves useful R16F
relative depth precision near the camera and guarantees a miss cannot survive
indefinitely through neighboring filtered hits.

History bounds now use only depth/normal/roughness/F0-compatible hit samples.
The temporal pass has its own point-sampled state so those material values and
depth always describe the same texel at fractional Poisson offsets.
An always-on clamp also covers moving reflected objects on a static receiver,
which receiver motion vectors alone cannot detect.

### 95.3 Presets and controls

`PTGI MAX + REFL` selects `ptgimaxreflect`: the v0.082 two-path DDA quality
preset plus the corrected reflection overlay. `PTGI DDA MAX` remains the clean
no-reflection control. Contact grounding is zero in the beauty/PTGI play family
to avoid the halo, light bleed, and polygon-outline artifact reported in the
vehicle tests.

The tuner now exposes reflection step length, hit thickness, normal bias,
temporal current-frame weight, and rough-reflection reconstruction. They are
included in save/load and copied settings commands. Hot-retained ShaderData is
retargeted during extension reload, and reflection history is reset when a live
overlay begins sampling the GI-composed backbuffer.

### 95.4 Reload and single acceptance test

Use one clean reload, then select the new preset:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); print("BeamRT " .. beamrt_main.getVersion()); beamrt_main.start(); beamrt_main.applyPreset("ptgimaxreflect")
```

Expected version: `0.083`. Compare only against `ptgimax` from the same camera.
No Nsight capture is required for this acceptance test. Screen-space
reflections still cannot represent off-screen or hidden geometry; this update
fixes material response, intersection ordering, and history behavior rather
than claiming to remove that architectural limit.

### 95.5 Offline validation

- `main.lua` parses successfully with `luaparse`.
- All 15 active ShaderData entries compile as both strict SM5 pixel and vertex
  shaders with FXC `/Ges /WX`: 30/30 stages, zero failures.
- Reflection settings-command placeholder/value counts are matched, including
  the newly exposed controls, mode, and PTGI radiance source.
- No BeamNG base file was modified.
- The remaining acceptance gate is the single in-game reload/test above; no
  runtime visual or performance claim is made from offline compilation alone.

## 96. v0.084 bounded-DDA reach-continuity milestone

v0.084 fixes the straight lighting frontier visible on sloped pavement. It was
not a reflection, native shadow, or contact-grounding artifact. The bounded
Screen DDA physically stopped after its local pixel budget, while the active
screen-only presets supplied no world/surfel fallback. A hit at the final step
kept substantial energy; a receiver needing one more pixel became a zero miss.
The same cutoff appeared much farther away with the long linear marcher.

Active cache-busted GI entries:

```text
shaders/beamrt/beamrtGITraceP_v075.hlsl
shaders/beamrt/beamrtLightingComposeP_v075.hlsl
```

### 96.1 Reach and confidence corrections

- Screen DDA now retains the preset's overall reach scalar but does not apply
  the camera-facing/rear-ray shrink to its screen-pixel work budget. PTGI DDA
  therefore uses its full 32-step cap, and PTGI DDA MAX sets `rayReach=0.75`
  so its `64 * 0.75` reach matches the advertised 48-step cap.
- Accepted DDA hits fade over the final 45 percent of the effective step
  budget. The fixed endpoint becomes a broad continuous falloff instead of a
  one-pixel bright/dark contour; no additional trace samples are introduced.
- Trace alpha is the averaged continuous path confidence. The prior
  `max(binary hit coverage, confidence)` forced one-path support to 0/1 and
  two-path support to 0/0.5/1, erasing the endpoint fade.
- Trace RGB is already confidence-premultiplied expected radiance. Composition
  no longer multiplies it by support a second time, and second-bounce reuse no
  longer squares the previous GI alpha. Alpha remains available to temporal
  and edge-aware reconstruction as a guide.

This keeps the PTGI presets screen-only and leaves world-cache contribution at
zero. It therefore avoids hiding the seam with the coarse surfel fallback and
does not reintroduce that fallback's leaks or broad smearing. A future Hi-Z or
dense-near/sparse-far marcher is still required for cheap full-screen reach.

### 96.2 Reload and acceptance test

Use one clean reload, select the no-reflection control first, and revisit the
same sloped sidewalk:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); print("BeamRT " .. beamrt_main.getVersion()); beamrt_main.start(); beamrt_main.applyPreset("ptgimax")
```

Expected version: `0.084`. The old ruler-straight cutoff should be replaced by
a wider, softer GI transition. Then rotate the camera around the same receiver:
the DDA reach should no longer shrink merely because a sampled ray points back
toward the camera. `ptgimaxreflect` uses the same corrected GI path if a second
comparison with reflections is wanted.

### 96.3 Offline validation

- `main.lua` parses successfully with `luaparse` in Lua 5.1 mode.
- All 15 active ShaderData entries compile as strict SM5 pixel and vertex
  shaders with FXC `/Ges /WX`: 30/30 stages, zero failures.
- The new trace and compose entries also pass independent strict pixel/vertex
  compilation.
- No BeamNG base file was modified. Visual continuity and real frame time still
  require the in-game reload/test above.

## 97. v0.085 crossing correctness, accumulation stability, and automatic audit

The user reported no visible improvement from v0.084. `beamng.log` confirms
v0.084 and both new GI entries were created and the intended preset applied.
The earlier statement that the visible sidewalk seam was conclusively the DDA
reach boundary was therefore too strong. The following independently verified
defects were corrected; the actual beauty seam remains a runtime acceptance
question rather than a claimed success.

### 97.1 Verified tracer defects

- The positive thickness-band test accepted samples already behind a surface
  without requiring a front-to-behind crossing. The new trace seeds front-depth
  state from the projected normal-biased origin and requires a bracket for every
  accepted candidate. Behind-start samples and penetration samples following a
  rejection no longer count as physical intersections.
- The former tangent basis switched axes at `abs(normal.z)=0.999`. Two ground
  normals differing by about 0.026 degrees could change the fixed diagnostic
  direction by 59 degrees. A Duff orthonormal basis removes that shallow-slope
  switch. A numerical check of 10,006 normals, including both poles, passed.
  Its relevance to the beauty seam remains to be established by captured output.
- v0.084 applied its DDA fade to actual linear fallback rays whenever the selected
  marcher was DDA. Hits now carry confidence calculated from their actual DDA
  UV travel and full artificial pixel budget. Actual linear fallbacks retain
  confidence one; short naturally clipped segments are not normalized as though
  they exhausted the full budget.
- Receiver roughness response was applied in both tracing and composition.
  It is now applied once in compose, retaining material reflectance and metal
  suppression while removing the duplicated roughness dimming.

Active trace/compose entries are `beamrtGITraceP_v076.hlsl` and
`beamrtLightingComposeP_v076.hlsl`. New behavior is guarded so older wrappers
remain usable for comparison.

### 97.2 Accumulation fixes backed by the live log

The v0.084 log repeatedly resets progressive history after 4-16 samples for
FOV fluctuations around 0.001-0.025 degrees. Progressive accumulation now judges
these changes by projected edge displacement instead of the material-capture
path's strict 0.001-degree tolerance. Stationary history tolerates 0.75 pixels
of cumulative FOV displacement; deliberate gradual zoom uses guarded temporal
history, while large projection jumps and resolution changes still invalidate
history. The stricter frozen material-cache comparison is unchanged.

Progressive sample accounting also uses the actual DDA path cap, so requesting
32 paths with a two-path DDA budget records two new samples per frame.

### 97.3 Local six-stage capture

`beamrt_main.runLightingAudit()` invokes the isolated `lightingAudit.lua` helper.
It saves native BeamNG, GI beauty without the reflection overlay, raw GI,
filtered GI, the exact visible indirect term, and receiver material response.
Raw/filtered/indirect displays use fourfold exposure for inspection and do not
modify the underlying GI buffers. The receiver view has unity exposure.

Captures use BeamNG's tracked native-resolution PNG API, wait for successful
job completion plus file existence, and write a settings/accumulation manifest
under `/screenshots/beamrt-audit/<timestamp>/`. Nothing is uploaded. The helper
restores mode, settings, enabled state, tuner visibility, ray-hit diagnostics,
and lighting diagnostics after completion, cancellation, or errors. Camera
movement cancels the capture; graphics changes, mission changes, and extension
unload also cancel it. GI history remains active between diagnostic stages.

The tuner includes `Capture Lighting Audit`, and `cancelLightingAudit()` and
`getLightingAuditStatus()` expose cancellation/status. Close the console after
starting a capture and keep the camera stationary for roughly 10-20 seconds.

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.start(); beamrt_main.applyPreset("ptgimax"); beamrt_main.runLightingAudit()
```

### 97.4 Verification and remaining gate

- All 15 active shader entries pass strict FXC pixel and vertex compilation:
  30/30 stages. Prior v074/v075 trace/compose wrappers also compile in both
  stages after the guarded changes: 8/8 stages.
- `main.lua` and `lightingAudit.lua` pass Lua 5.1 parsing. Main retains its
  existing 200 top-level locals; no extra top-level local was introduced.
- Both files also compile with the native Lua 5.1 and LuaJIT 2.1 loaders, without
  executing the engine-specific chunk; there are no local/register-limit errors.
- Tests of the actual accumulation functions preserve history during deliberate
  gradual zoom and invalidate a large discontinuity. At 2560 pixels, a
  0.025-degree FOV fluctuation moves the edge by about 0.616 pixels, whereas a
  0.1-degree change moves it by about 2.462 pixels.
- The capture helper passes mocked save completion, error/timeout, cancellation,
  busy/unavailable API, state restoration, diagnostic restoration, and FOV
  breathing checks. The real capture API signatures and job schema were read
  from BeamNG's installed `lua/ge/screenshot.lua`.
- In-game images are required to identify the persistent beauty edge. Compiler
  and mock checks do not establish that it has disappeared.

## 98. v0.086 audit directory repair

The first real audit failed before any capture with `could not create local
audit directory`. The user screenshot and disk inspection showed the existing
`screenshots` root but no `beamrt-audit` parent. The helper called
`FS:directoryCreate(directory)` on a nested dated path. BeamNG's second argument
is the recursive flag; the helper now calls `FS:directoryCreate(directory, true)`
and retains the existence postcondition rather than interpreting the native
return code as a boolean. Creation errors include the resolved output path.

The parent folder was also created directly at the known current user-directory
path. Main clears only the companion helper's `package.loaded` entry before
requiring it, so reloading the extension cannot retain the broken old helper.
No GI/reflection shader or tuning value changed in this repair.

The mock directory implementation previously succeeded without checking parents
and therefore missed the bug. It now rejects nonrecursive nested creation and
models native zero-as-success. The original helper fails this regression; the
repaired helper passes fresh-parent creation, denied creation without state
mutation, timestamp collision avoidance, and the existing six-stage capture and
restoration tests. Main/helper also compile with native Lua 5.1 and LuaJIT 2.1.

Expected reload version is `0.086`; real PNG generation remains the next gate.

## 99. First completed audit and v0.087 diagnostic validity repair

The user completed `/screenshots/beamrt-audit/2026-10-07_21-18-11/` on v0.086.
The manifest records six successful captures and `restored=true`. The earlier
21-17-50 attempt cancelled for camera movement before saving any image.

The six images were read directly. Compared with native BeamNG, added light is
mainly in bright narrow bands along wall bases, curbs, and object edges. It does
not broadly change the road/car. Stationary accumulation records 182, 408, 610,
810, and 1,010 samples through the GI stages without another reset: the FOV
accumulation repair is runtime-supported in this scene.

Raw-GI capture is exactly black in every RGB channel across a 2,099,200-pixel
scene rectangle, while filtered GI has 191,140 nonzero pixels in that rectangle.
This makes the separate raw sampler read untrustworthy as evidence of tracer
failure. It does not prove the filter fabricated lighting: valid history can
remain when one current read is unavailable or unrepresentative. The receiver
response image independently shows a broad road brightness transition even
though that view contains no traced GI term. Its inputs need isolation before
attributing the persistent line solely to DDA reach.

### 99.1 Targeted changes

v0.087 routes raw inspection through compose's established GI texture slot 1,
binding CurrentGI only in raw mode and restoring AtrousGI3 in all other modes.
It removes the unverified slot-7 raw sampler from the active compose entry.
The active compose wrapper is `beamrtLightingComposeP_v077.hlsl`; the production
tracer remains v076 and production light transport/tuning are unchanged.

Surface diagnostics now render invalid/sky pixels black instead of showing
native sky as though it were captured indirect light. New diagnostic names are
`direct`, `roughness`, `f0`, and `reflectance` (estimated reflectance before metal
and roughness gates). These images still pass through engine display processing
and must not be interpreted as linear numeric buffer exports or true albedo.

`runLightingAudit(true)` adds those four input captures to the original six.
The ordinary no-argument audit remains six views. The expanded list is per run,
does not mutate the default, and restores the same original state.

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.start(); beamrt_main.applyPreset("ptgimax"); beamrt_main.runLightingAudit(true)
```

### 99.2 Verification

The new and prior compose wrappers compile as strict SM5 pixel and vertex
stages. Main/helper compile under native Lua 5.1 and LuaJIT 2.1. Mock captures
pass both six- and ten-stage runs, default-list preservation, extra-stage
warmups, save completion, state restoration, cancellation/error/timeout, and
the directory regressions. Raw display validity and the input responsible for
the broad brightness boundary require the expanded runtime capture.

## 100. v0.088 six-texture PostEffect compatibility repair

The expanded v0.087 audit completed at
`/screenshots/beamrt-audit/2026-10-07_21-42-59/`, with all ten images saved and
original settings restored. Raw GI became visible after moving its read from
slot 7 to the established slot 1. Specular/F0 inspection through slot 6 remained
exactly black throughout the scene; roughness and direct light at supported
lower slots were visible. The bright wall/curb strips are already in raw GI,
so filtering alone does not originate them.

BeamNG's published Torque3D `PostEffect` declares `NumTextures = 6`, registers
the texture array with that size, and binds only those slots:

- https://github.com/BeamNG/Torque3D/blob/master/Engine/source/postFx/postEffect.h#L79
- https://github.com/BeamNG/Torque3D/blob/master/Engine/source/postFx/postEffect.cpp#L305

The old GI effect requested thirteen textures. Slots 6-12 included frozen clean
source, previous GI, emissive, native noise, STBN, history moments, and velocity.
Temporal requested historical moments at slot 6, and compose requested material
specular at slot 6. This unsupported layout explains the observed black reads
and means prior CPU sample counters did not establish successful GPU temporal
reuse or actual STBN sampling. The current proprietary runtime capacity is also
reported automatically on reload and in future audit manifests rather than
assuming the published fork matches every engine build.

### 100.1 Bounded pass layout

Every active ShaderData and PostEffect now uses at most slots 0-5:

- Trace: normal/roughness, depth, backbuffer, direct lighting, auxiliary atlas,
  material specular.
- Temporal: current GI, normal/roughness, depth, velocity, history GI, history
  moments. Previous-frame moments supply the variance guide, keeping depth
  validation available without a seventh texture.
- Compose: backbuffer, GI/diagnostic input, normal/roughness, depth, current
  moments, precomputed receiver response.
- Receiver preparation: backbuffer, normal/roughness, direct lighting, material
  specular, depth. RGB contains the same existing complete material response;
  alpha contains scalar reflectance before the material gates.
- Auxiliary preparation: history GI, history moments, velocity, STBN, native
  blue noise, current surfel radiance.

The auxiliary RGBA16F target is `max(GIw,1152) x (2*GIh+1028)`: a GI-sized history
region with validated depth in alpha, a GI-sized velocity region, a 1024-square
STBN slab plus the native 128-square tile, and a 32x4 surfel region. All reads
use exact texel loads; noise channels are copied without HDR transformation.
It resizes with GI/main-view dimensions and is freed with the other BeamRT
objects. Two integration regressions cover missing-view extent stability and
partial preparation-object recovery.

### 100.2 Ordering, diagnostics, and guards

The descending render priorities are surfel cache 10004, receiver/auxiliary
preparation 10003, GI 10002, and reflection overlay 10001. The prior overlay
preceded GI, letting diffuse source sampling include the added reflection;
the corrected order lets reflections see the GI-composed scene instead.

Raw and individual input diagnostics all use the known supported slot 1. F0
inspection now binds native prepass RT1 there directly. Frozen-clean production
selection is explicitly rejected as diagnostic-only until that optional source
can be supplied within the six-input layout; live direct-diffuse cleanup remains
active. Shader creation rejects any future sampler list longer than six.

`getTextureBindingStatus()` reads native PostEffect field metadata, records the
native capacity when available, and lists the actual six input targets. Reload
logs that status; the audit manifest includes it automatically.

Active changed entries are GI v077, temporal v071, compose v078, surfel cache
v062, auxiliary preparation v001, and receiver preparation v001. Previous
wrappers retain their prior behavior behind compile guards.

### 100.3 Verification and runtime gate

- All 17 active shaders compile in strict pixel and vertex stages: 34/34.
- Native Lua 5.1 and LuaJIT 2.1 compile main/helper without executing engine
  bindings. Main remains within its existing top-level local limit.
- Thirteen tests execute the real Lua module against a renderer mock: actual
  effect creation, six-slot bounds, sampler names matched to compiled DXBC
  resources, descending order, callback installation, enable/disable/teardown,
  diagnostic routing, all 64 STBN slice addresses, exact-load history, resolution
  changes, and partial object recovery.
- Six- and ten-image audit/restoration tests still pass.
- Native GPU sampling, temporal convergence, material response, visual quality,
  and frame time require a v0.088 reload. The old captures validate the failure
  pattern, not the new renderer's final appearance.

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.start(); beamrt_main.applyPreset("ptgimax"); beamrt_main.runLightingAudit(true)
```

## 101. v0.088 runtime verification and v0.089 geometric ray guards

The ten-view v0.088 audit completed at
`/screenshots/beamrt-audit/2026-10-07_22-40-37/`, with settings restored and
stationary samples increasing from 180 to 1,568. The actual input lists now
occupy only slots 0-5. Specular data is visibly restored: the scene-only F0 view
was all zero on v0.087 and is about 96.85 percent nonzero on v0.088. Raw GI was
already visible after the v0.087 diagnostic repair, so this is not a claim that
v0.088 first created all visible GI.

Filtered GI now visibly smooths the raw noise into continuous light, while most
added light remains local to curbs and wall bases. Broad road regions still have
zero traced GI; this cannot be explained solely by a receiver material gate.
The bright bands remain present in raw trace output, so the next correction
addresses surface intersection rather than stronger denoising or brightness.

The car paint's diffuse response is nearly zero under its large F0 gate. This is
not automatically a classification bug: the installed vanilla Scintilla paint
uses material version 1.5 and metallic stages. No material response was loosened
to force diffuse GI onto that paint. Legacy materials may still require separate
classification because their arbitrary specular strength is not a metallic bit.

### 101.1 Geometric surface protection

`beamrtGITraceP_v078.hlsl` enables a guarded depth-geometric normal reconstruction
using four native depth neighbors. It chooses the closer side of each axis to
avoid reconstructing across large depth discontinuities, keeps calculations in
camera-relative coordinates, orients the plane toward the camera, and falls back
to the shading normal for missing/degenerate neighborhoods.

Ray origins are biased along that geometric plane. A normal-map direction below
the plane contributes zero with the original path-count divisor unchanged.
Candidates on/behind the receiver plane and geometric backfaces are rejected.
Crossed opaque backfaces terminate traversal and cannot acquire world-cache
light as a fallback. Existing shading-normal and depth/continuity validation is
retained; its continuity footprint also uses native depth pixel spacing.

This is a correctness guard, not a claim that every contact-band pixel is false.
Real perpendicular walls, recessed frames, and ceilings can exchange bounce
light. The configured screen reach, path budget, material gates, and source
remain unchanged. Four receiver depth reads plus up to eight candidate reads
are added; in-game visual and frame-time validation remains required.

### 101.2 Metadata reporting and short comparison

The v0.088 audit could not report native capacity because `getFields()` did not
return the requested `elementCount`. v0.089 uses the installed editor's
`getFieldsForEditor()` descriptor API first, falls back to basic descriptors,
and supports `elementCount` or `arraySize`. Missing data remains unknown rather
than being reported as a verified six-slot engine limit.

`runLightingAudit("compare")` now captures just native BeamNG and GI beauty,
with the same save gating and automatic state restoration. Ordinary six-view
and expanded ten-view modes are unchanged. The short mode takes roughly five
seconds after closing the console; it avoids another full input audit for this
geometry check.

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.start(); beamrt_main.applyPreset("ptgimax"); beamrt_main.runLightingAudit("compare")
```

### 101.3 Verification

- All 17 active shader entries pass strict pixel and vertex compilation: 34/34.
- Eight geometry tests cover analytical flat/sloped planes, native pixel
  spacing, discontinuity/fallback cases, coplanar self-return rejection, real
  perpendicular walls/ceilings, backfaces, and unchanged sample normalization.
- Fourteen binding/metadata tests pass against the real Lua module and compiled
  resource reflection; editor descriptor preference and basic-array fallback are
  covered. Earlier wrappers remain guarded from the new geometry behavior.
- Two-, six-, and ten-view capture/restoration regressions pass, including
  failures and cancellation. Native Lua 5.1 and LuaJIT compilation pass.
- v0.088 material-input restoration is runtime-supported. v0.089 geometric
  appearance and performance are pending the short comparison above.

## 102. v0.090 contained sampling correction

The v0.089 two-image comparison completed at
`/screenshots/beamrt-audit/2026-10-08_13-06-12/` with state restoration and actual
native texture capacity six recorded. It is a different view from the earlier
v0.088 audit; do not compare those directories as an identical-camera A/B or
claim that every historical bright line is solved.

The user approved the immediate sampling correction after the source/noise and
broader installation audits. This release changes sampling only. Linear-light
stage integration, material hooks, SSR lobe replacement, geometry-provider
integration and the optional wide-DDA v079 remain separate work.

### 102.1 Production sampling

- Main version is 0.090; active GI wrapper is `beamrtGITraceP_v080.hlsl`. It
  enables `BEAMRT_VALIDATED_SAMPLING` and includes v078, preserving the six-input
  architecture and geometric guards without enabling v079 wide traversal.
- Startup, Beauty Max and PTGI Play now select `blueNoiseSource="beamng"` /
  mode zero. Their copied reflection and PTGI Max variants inherit this. The
  native mask is centered UNORM8 data plus existing integer Weyl phases; its
  existing 4096-frame wrap remains. This is not an unbounded sequence.
- Fractional strength now chooses one complete legacy or blue coordinate pair
  using a separately salted uint hash of full pixel, frozen frame and path.
  Coordinate interpolation had changed the sampling distribution and crossed
  the azimuth wrap incorrectly. Strength zero retains the historical legacy
  math; strength one selects only blue primary directions.
- Recover UNORM8 bytes after their R16F auxiliary copy, decode byte centers,
  and clamp final blue direction coordinates strictly inside (0,1), after
  Weyl wrapping, stratification and azimuth construction. Final clamping is
  necessary because float32 stratum addition can still round to one.
- The custom `stbn` API and aliases remain compatible, but the UI labels it
  `EXPERIMENTAL ATLAS` and selecting it logs a quality warning. It now applies
  a different wrapped phase every 64 slices to avoid identical 64-frame primary
  direction repetition. This does not repair its poor transformed directional
  spectra or establish genuine optimized vector-STBN quality.
- All phases and the strategy selector use the existing frozen sequence during
  diagnostics. No noise texture/filter/layout or sampler count was changed.

### 102.2 Verification and unchanged scope

- v080 pixel and vertex shaders compile with FXC `/Ges /WX` (ps_5_0/vs_5_0).
- Recompiled v078 and v079 pixel/vertex bytecode is exactly equal to prepatch
  baselines. Shared changes are guarded; historical traversal is unchanged.
- Twenty sampling tests pass: half-storage byte recovery, the 23-bit selector
  domain, final endpoints for path counts 1-32, complete strategy selection,
  fractional distribution checks, shipped texture sequence probes and actual
  Lua default/preset comparisons.
- Actual Lua settings comparison covers startup plus all fifteen presets. All
  seventy other settings match v0.089 exactly; only version and default noise
  source differ. Lighting, reflections, GI source, render scale, history/filter
  settings, ray counts/reach/budgets and render stages are not retuned.
- Fourteen graph/six-slot/reflected-binding tests, eight geometry tests, eight
  optional wide-traversal tests, native Lua 5.1/LuaJIT/Lua 5.5 compilation/FOV
  checks and two/six/ten-view capture-helper regressions pass.
- These are compile, CPU math, resource reflection and renderer-mock checks.
  Running-game visual quality and performance remain unverified for v0.090.
  Native mode saves the extra atlas read in the trace, but the auxiliary pass
  still copies the atlas. Do not claim a measured frame-rate improvement.

Tests: workspace `work/sampling-sequence-check.py`. Prepatch main/shared-core
backups: workspace `.beamrt-compile/sampling-v089-backup/`. Compilation
baselines: `.beamrt-compile/beamrtGITraceP_v07{8,9}.hlsl.samplingbaseline.*.bin`.

### 102.3 Off-screen support clarification

The mod already has a persistent world-surface fallback with at most 32 samples,
acquired via staged rendered-geometry CPU rays. Samples learn lighting while
visible and depth/normal-valid, retaining previous radiance while offscreen or
occluded. A geometry refresh replaces the set and clears its radiance. This is
not complete offscreen mesh/material tracing, and it cannot reliably shade a
previously unseen emitter.

Hybrid/world modes can use it. Beauty Max and PTGI Play/Max and their reflection
variants explicitly select screen-only GI and world strength zero. This patch
does not change or enable that fallback. The newer Scene Database remains
acquisition-only and is not a production-tracer input.

Reload with current appearance settings preserved and the new native baseline:

```lua
local samplingSettings = beamrt_main.getSettings()
samplingSettings.blueNoiseSource = "beamng"
beamrt_main.disable()
extensions.unload("beamrt_main")
extensions.load("beamrt_main")
beamrt_main.start()
beamrt_main.applySettings(samplingSettings)
print(beamrt_main.getVersion())
```

The printed version should be `0.090`. The newly named shader entry forces a
fresh production wrapper; histories reset on reload as expected. No automatic
in-game reload or visual verification has been performed by the agent.

## 103. v0.091 close-range, motion and reflection safety repair

User authorized the discussed fixes. This release contains real implementation
changes, not only diagnostic tests. It does not replace BeamNG's native cubemap
or repair the missing live albedo/emissive contract.

### 103.1 Reflection contract: bounded augmentation, not replacement

Active SSR shaders are trace v024, temporal v025 and compose v026. Trace stores
nonnegative hit radiance premultiplied by confidence. It no longer subtracts
the complete receiver beauty pixel. Compose adds the filtered weighted term
without reducing native diffuse/direct/emissive/GI lighting; invalid lifetime,
zero strength and roughness cutoff pass the original pixel through unchanged.

Native environment reflection remains in the base. This is SSR augmentation,
not exact specular-lobe replacement, and can double count native environment
specular. UI descriptions now say so. A same-frame isolated native environment
term, matching BRDF/AO/clearcoat/exposure/fog, is still needed for replacement.
No native reflection graphics setting or material reflection feature is removed.

Temporal alpha stores signed receiver forward depth in metres: fresh positive,
one grace frame negative, invalid zero. This avoids the old far-normalized
0.0001 depth floor that distorted close-up history. Spatial depth comparison
still uses normalized depth; historical comparison uses physical metres.
RGBA16F depth capacity is bounded conservatively. Current-pixel hit lifetime,
material-guided filtering, disocclusion and finite grace rules remain.

SSR history also receives real-camera motion when the native velocity buffer
is zero/stale. GI+SSR shares one camera measurement; SSR-only measures it once.
Cuts invalidate both applicable histories, and missing camera data invalidates
history without advancing the warmup/sample clock. Recovery starts fresh.

### 103.2 Close-range traversal

Active GI v081 includes v080 and enables a native-near cutoff using
`projParams.x / projParams.y`, rather than fixed far-normalized 0.0001. It retains
sampling, six-input packing and geometric guards, without activating wide DDA.

SSR v024 analytically clips its visible segment to the native near/far and
viewport bounds. It samples actual depth at its start and a small positive
physical probe, then distributes the remaining configured samples across that
segment. The probe is important with zero normal bias: depth equality at the
receiver is not invented as a front slab. Seed, probe and remaining samples
stay within the original maximum sample budget. Binary refinement, minimum
screen travel, backface and opaque/slab rejection remain conservative.

This does not move the camera. The 48-pixel narrow-DDA reach/fade and ordinary
screen-space visibility limitations remain; not every historical cutoff is
claimed fixed. GI origin bias and preset strengths/budgets are unchanged.

### 103.3 Slow motion and diagnostic isolation

Coherent slow camera drift now selects guarded temporal history instead of
periodically clearing a stationary exposure after 0.05 degrees. An eight-frame
reference window distinguishes drift from bounded jitter. Settling reuses a
finite effective history rather than popping to a full-weight noise frame.
Actual cuts, resolution changes, large FOV discontinuities and explicit resets
still clear history. Very small configured sample ceilings can limit settling.

Manual GI ray and lighting diagnostics are mutually exclusive. Both suppress
downstream SSR while preserving the user's reflection preference. Returning
to normal lighting re-enables SSR with clean reflection history. Lighting
diagnostics can select/enable the GI mode from other modes, while switching
between already-active audit views preserves the warmed GI history. HITS also
shares the beauty path's receiver-geometric hemisphere rejection; its fixed
single GI ray is still not an SSR hit map or aggregate beauty coverage.

### 103.4 Experimental atlas continuation

GI v081 continues the scalar atlas using a toroidal XY lookup translation:
`(37*cycle,73*cycle) mod 128`, constant over each 64-slice cycle. It does not
remap the stored RG values. Cycle zero remains identical. Full-tile scalar and
transformed distributions and within-cycle spatial/temporal spectra are
preserved by permutation. Boundary behavior in actual game lighting is still
unverified, and the atlas is not validated jointly optimized directional STBN.

Native noise/Weyl remains the default. Checked atlas probes produce 3962-3983
distinct byte pairs over 4096 frames, not a guarantee of 4096 distinct directions.
The old v080 value-phase behavior stays guarded for source compatibility.

### 103.5 Verification and remaining work

- All 17 active shader entries compile in strict FXC VS/PS 5.0 mode (34 stages).
- 20 sampling, 5 atlas, 18 full-module motion/debug/SSR, 10 analytic close-range,
  19 reflection radiance/lifetime, 14 graph/binding, 8 geometry and 8 optional
  wide-traversal regressions pass (102 total).
- Close-range tests include 576 camera/near/far geometry cases and zero-bias
  receiver/wall intersections at 2.5-10 cm. Tests preserve budgets and rejection
  guards. Camera tests exercise unavailable-view and transform-read recovery,
  both progressive states, SSR-only/shared modes and one camera update/frame.
- Native Lua 5.1/LuaJIT/Lua 5.5 source compilation and FOV checks pass. Audit
  capture/restoration tests pass; independent actual-module/real-helper review
  checks disabled-state restoration and all eight warmed ten-view transitions.
- Recompiled historical v080 VS/PS bytecode exactly matches the v0.090 baseline.
  Historical SSR v021/v022/v023 source files remain unchanged.
- Default and fifteen presets retain all seventy unaffected saved settings;
  no brightness, material gate, render stage, source mode, scale or ray budget
  was retuned. No performance or running-game beauty claim follows from tests.

Unresolved: exact native environment-specular replacement, linear-stage/SDR-HDR
integration, live albedo/emissive data and the weak night-GI findings. Preserve
native material behavior while those contracts are investigated. Do not use
this release to claim complete PTGI or an all-native-reflections-disabled mode.

Rollback main is `.beamrt-compile/v090-before-stability-fixes/main.pristine-v090.lua`
in the workspace, with a provenance/hash record beside it. It was reconstructed
from original owned spans because the initial backup raced early motion edits;
it is validated, not described as a point-in-time snapshot. Restoring that main
reselects historical v080/SSR v021-v023, whose guarded shader behavior remains
available. No broad or destructive cleanup was performed.

Reload preserving current appearance and sampling choice:

```lua
local savedBeamRT = beamrt_main.getSettings()
beamrt_main.disable()
extensions.unload("beamrt_main")
extensions.load("beamrt_main")
beamrt_main.start()
beamrt_main.applySettings(savedBeamRT)
print(beamrt_main.getVersion())
```

Expected version: `0.091`. This starts normal BeamRT and restores saved mode
and appearance settings, not a new preset. Histories intentionally restart.
The agent did not activate this reload or obtain GPU visual/performance results.

## 104. v0.092: first-surface SSR and a single reflection audit

Active SSR entries are trace v029, temporal v025, and compose v028. GI v081,
sampling choices, camera projection, preset strengths, normal bias, reflection
thickness, and sample budgets are unchanged. This remains bounded screen-space
augmentation of native lighting, not native environment-specular replacement.

### 104.1 Concrete traversal correction

Historical v024 could ignore a nonnegative opaque-depth sample without a front
endpoint, then establish a bracket against a deeper surface and sample its
color. Sky resets could enable the same foreground-skipping path. This is a
source-level mechanism demonstrated by fixtures, not proof of screenshot cause.

v029 makes that unrelated opaque sample terminal. The only initial receiver
departure exception remains in the actual original depth-texture texel, within
2 mm total ray travel and `min(2 mm, max(1 mm, receiverForwardMetres*5e-7))`
depth tolerance, independently of thickness and bias. It cannot restart after
leaving the texel, a true front sample, sky, or positive frustum-entry travel.
Invalid projection/background evidence during refinement now rejects instead of
manufacturing a front endpoint. Rejected first crossings cannot seek a later
surface. This conservative policy can remove some uncertain close/self hits.

Differences are guarded by `BEAMRT_REFLECTION_FIRST_SURFACE`; older wrappers
retain their historical behavior. Forward-depth thickness remains unchanged;
it is not AMD's Euclidean separation metric. No arbitrary camera offset or
Y-axis flip was introduced.

### 104.2 Actual SSR views, not the GI HITS debugger

`setReflectionDiagnostic(nameOrInteger)` supports:

| ID | Name | Meaning |
| --- | --- | --- |
| 0 | off | Restore the prior mode/enabled/overlay/GI-debug state. |
| 1 | receiver | Green eligible receiver; gray untraced. Eligibility is not proof of incorrect native roughness. |
| 2 | validity | Green accepted geometry, red rejected opaque/crossing candidate, magenta miss, gray untraced. |
| 3 | hituv | Accepted prepass hit UV as red/green. Invalid results use validity colors. |
| 4 | hitdepth | Red = clamped absolute forward-depth error / thickness; green = 1-red; blue .5 marks rejection. |
| 5 | rawcolor | Exact validated source texel, using true source dimensions, no confidence dimming. Invalid rays do not sample source color. |
| 6 | composite | Current confidence-premultiplied SSR times the original receiver F0/roughness/Fresnel/strength term, before adding base; black on miss. |
| 7 | sourceuv | Accepted hit UV after mapping to the source-color target. |
| 8 | rejection | Palette of the actual terminal/miss reason; see trace source. |
| 9 | direction | Eligible world reflection direction remapped to RGB. |

The trace always outputs at the originating receiver; color comes from the
validated hit. Compose material response uses the original receiver UV2/UV3,
not hit UV. These source contracts do not prove same-frame GPU resource/viewport
compatibility. Raw-color diagnostics use exact `Load`; normal beauty sampling
remains linear and can mix edge colors separately from a geometry error.

All diagnostic displays read `#BeamRT_CurrentReflection` directly. Temporal
display reuse is bypassed, effective temporal weight is 1 and denoise is 0,
without overwriting stored preferences. SSR already uses one deterministic
perfect reflected ray, without roughness jitter. The graph now explicitly
requests `targetScale = 1 1`; actual GPU dimensions still need runtime evidence.
GI and SSR diagnostics are mutually exclusive. Transitions clear SSR history.

### 104.3 One automatic local capture

After loading v0.092 and keeping the camera still:

```lua
beamrt_main.runReflectionAudit()
```

Equivalent: `beamrt_main.runLightingAudit("reflection")`. The tuner also exposes
"Capture Reflection Audit" and individual reflection views.

Eight local native-resolution PNGs are saved under the user folder's
`screenshots/beamrt-audit/<timestamp>`: native, SSR beauty, receiver, validity,
hit UV, hit depth, raw color, composite. The audit isolates SSR from BeamRT GI,
uses temporal weight 1/denoise 0, and records stage settings/texture bindings in
`manifest.json`. Thus SSR beauty is an unfiltered diagnostic comparison, not
the user's normal filtered beauty. No upload or listener is enabled.

Settings, enabled state, mode, tuner visibility, and prior debug context are
restored on success/cancel/error. `cancelLightingAudit()` cancels;
`getLightingAuditStatus()` reports status. Camera/graphics changes cancel rather
than producing a mislabeled stationary comparison. Existing 2/6/10-stage GI
audits remain available.

### 104.4 Verification and loading

Strict compilation passes all 34 active VS/PS stages; 148 unittest cases plus
the existing audit/native-Lua checks pass. CPU fixtures/mock controls are not
GPU execution, visual verification, or performance measurement. No running-game
reload was activated by the agent. See `.beamrt-validation/v092/README.md` and
`reference-review.md` for evidence and limitations.

To reload while retaining current appearance/settings:

```lua
local savedBeamRT = beamrt_main.getSettings()
beamrt_main.disable()
extensions.unload("beamrt_main")
extensions.load("beamrt_main")
beamrt_main.start()
beamrt_main.applySettings(savedBeamRT)
print(beamrt_main.getVersion())
```

Expected version: `0.092`. Alternatively restart BeamNG. Histories restart.
The v0.091 main/helper snapshot is in `.beamrt-validation/v092/v091-source`;
restoring it reselects historical trace v024/compose v026, whose macro-off
behavior was preserved. Weak night GI, native lobe replacement, and SDR/HDR
linear-stage integration remain separate unresolved work.

## 105. v0.093: repair the native tuner call and DDS noise loading

The latest live v0.092 log identified a real UI regression: the new reflection
panel called nonexistent `im.CollapsingHeader` each frame. BeamNG exports
`CollapsingHeader1`; the call is now corrected. The prior permissive UI mock
fabricated functions and did not exercise tuner rendering, so it missed this.
The new test executes the installed generated Lua wrapper namespace and
reproduces the saved old failure before verifying the corrected tuner completes
all sections/buttons with balanced UI stacks.

The log also rejects the experimental atlas's DX10 DDS header. Main now binds
`beamrtSTBN_128x128x64_rg_atlas_linear_v093.dds`, a legacy RGBA32 DDS containing
exactly the same 4,194,304 sample bytes. No noise regeneration, gamma conversion,
channel transformation, sampling algorithm change, or native-noise default
change occurred. The generator emits legacy DDS and has a strict container-only
repack command. Original DDS/PNG assets are preserved. No cache was deleted.
Native header examples support legacy RGB, but successful loading of this exact
new atlas still requires a reload/game-log check. Do not claim live directional
STBN quality or GPU color-space validation from this conversion alone.

Five native-wrapper tuner checks and seven atlas-format checks pass; all previous
148 unittest cases and audit/native-Lua checks pass too. The same SSR/GI shader
entries, settings, strengths, biases, thickness, budgets, and camera math remain.
See `.beamrt-validation/v093/README.md` and the format report for scope/hashes.
The agent did not activate a game reload. Source version is now `0.093`.

Hot reload while preserving settings and whether BeamRT was enabled:

```lua
local savedBeamRT = beamrt_main.getSettings()
local savedBeamRTState = beamrt_main.getLightingAuditState()
beamrt_main.closeTuner()
beamrt_main.disable()
extensions.unload("beamrt_main")
extensions.load("beamrt_main")
beamrt_main.applySettings(savedBeamRT)
if savedBeamRTState.enabled then beamrt_main.enable() end
beamrt_main.openTuner()
print(beamrt_main.getVersion())
```

This opens the repaired tuner for checking; expected version is `0.093`.
Alternatively restart BeamNG. A loaded v0.092 will continue its old behavior
until reload. The separate vehicle-provider invalidation warning and native
SSAO shader error in the earlier log were not modified by this scoped repair.

## 106. v0.094: three audits expose the remaining RGB-only DDS restriction

Reviewed the completed v0.093 sets at 16:06:51 (day SSR), 16:09:21 (night SSR),
and 16:09:38 (night GI). All 22 PNGs are 2560x1361, manifests report completion
and restored state, and original settings select linear GI plus STBN—not a DDA
or native-noise comparison. The tuner exception no longer recurs after reload.

Fresh log evidence at line 52341 shows v0.093 still fails atlas loading: the
native DDS loader requires RGB-only pixel-format flags. This invalidates any
STBN-quality interpretation of these selected-STBN captures. SSR diagnostics
remain useful because their deterministic ray does not use the GI noise atlas.

The ongoing, already-authorized compatibility repair now matches the shipped
native `AreaMap33.dds` RGB32 header exactly except dimensions. Runtime atlas is
`beamrtSTBN_128x128x64_rgb_atlas_linear_v094.dds`: DDPF_RGB 0x40, BGRX storage,
R/G/B masks 0xff0000/0xff00/0xff, unused alpha mask 0, no DX10, mip or gamma
metadata. All logical RGB samples and 64 RG tiles match the original DDS/PNG/
v093 atlas. Storage byte order changes but the noise pattern does not. Original
assets are preserved; no cache cleanup, settings change or shader retune occurred.
Source version is `0.094`. Successful engine uptake still needs a fresh reload.

The night reflection audit has many accepted geometry hits carrying black raw
source color, followed by further confidence/material attenuation. Night GI
contains raw/filtered signal but its visible contribution is extremely weak.
The material response estimates reflectance from already-lit color, so weak
shadow response is a plausible bottleneck; bad atlas uptake and weak source
signal prevent assigning it sole blame. Day haze exists in the native capture.
No arbitrary strength/camera/material tweak was made from these observations.

See `.beamrt-validation/v094/audit-review.md`, the v094 atlas-format report, and
the v093 labeled contact sheets/metrics. Seven format tests, five tuner/binding
checks, and existing sampling, graph, motion, audit and native-Lua checks pass.
Capture comparisons are screenshot RGB, not physical radiance; GI stages have
different accumulation counts and exposure/scene changes remain unrecorded.

Use the settings-preserving hot-reload command in section 105, or restart
BeamNG. Expected version is `0.094`; inspect its new log before claiming loaded
STBN. This is an atlas-loading correction, not a new GI/reflection algorithm.

## 107. Reversible native scene-cubemap execution probe (staged, not active)

Prepared the user-requested magenta execution test without changing the native
installation, main version/settings, SSR composer, or native graphics options.
`tools/native_cubemap_probe.ps1` stages a reviewed mod-side copy and exposes
explicit Stage/EnableMagenta/Disable/Status actions. The active native-path file
is absent until opt-in activation. Activation timing was offered to the user;
no response had arrived when this preparation was recorded.

Only the two modern forward/deferred `calculateCubeReflection` addition sites
are wrapped. The completed contribution is tinted magenta at preserved linear
luminance. The native function and separate diffuse/direct specular/emissive
terms remain intact. Known custom-cubemap, focused mirror metadata and custom
material-buffer permutations are excluded. Legacy and water paths remain native;
dynamic capture pass exclusion is not established. This is not suppression.

The controller rejects installation overlap, redirected ancestors, unknown or
user-modified native-path files, and unreviewed game-source updates. Publication
uses flushed/hashed sibling temporary files and atomic moves; disabling archives
only the owned hash-matching file recoverably. No shader cache is deleted and no
guessed general shader reload API is called. PowerShell 7.2+ is required.

Thirteen source/control/inspector tests pass. Twelve complete native/staged
defaultMat forward/deferred fragment permutations compile with native DXC SM6.1
includes; warnings match, custom-cube/macro-off binaries are identical, active
scene binaries differ. These are offline checks, not evidence of GPU execution.

The read-only inspector `extensions.load("beamrt_nativeCubemapProbe")` reports
the actual VFS shader winner and SHA1. A matching source proves mounting, not
compiled permutation execution. Test in clear daylight with BeamRT disabled;
look for magenta only in a genuinely eligible native scene reflection. After
observation, disable the owned override, restart and verify original appearance.
No permanent environment suppression is permitted without a reliable miss
fallback. Native dynamic mirrors/custom materials must remain scoped separately.

Full steps, limits and reports are under
`.beamrt-validation/native-reflection-experiment/README.md`. Milestone A
(suppression) and B (replacement) are not achieved; even execution of the tint
still requires the in-game observation and restoration confirmation.

### 107.1 User-approved activation

The user explicitly approved activation after asking where to run the command.
Ran the controller's EnableMagenta action successfully. The live mod-side native
path now contains the owned shader with SHA256
`4780B6C615D26B6D4EB7F93FA9CE904E3AFF420712D62082274D455F11FB5C0E`.
The installed native source still has the reviewed hash and is untouched.

This establishes disk publication/ownership only. A full BeamNG restart and
daylight test with BeamRT disabled are still needed. Use the read-only inspector
to verify the VFS source, then observe magenta on an eligible scene-cubemap
reflection. Do not claim execution, suppression, replacement, or restoration yet.
After the observation, run Disable to archive the owned override and restart
again to verify native appearance returns.

### 107.2 Runtime VFS success; owned test restored on disk

The user restarted and supplied two console screenshots. Fresh log started
17:24:15 and the inspector verified the actual mod shader winner and matching
SHA1 `780d2b7a337e5ae084aa9fa5f23860e1b669d7be`. BeamRT was disabled. This proves
VFS interception, not GPU execution; the console-obscured images do not clearly
show magenta reflection tint. UNVERIFIED in the inspector is explanatory text,
not an error or automatic pixel-detection result. The selected car is Burnside
Special; source/permutation eligibility remains unproven.

Ran Disable as previously requested after the test observation. The owned file
was archived recoverably at `native-reflection-experiment/restored/
20261009-172918-1498399.permutations.magenta.h.hlsl`. The active mod native-path
file is now absent; the original installation shader is unchanged. No cache or
user file was deleted. Restart and a normal-appearance check are still required
for live restoration. See `runtime-observation.md` for the evidence/limits.

### 107.3 Negative visual report; do not count execution as achieved

The user explicitly reported no visible magenta. GPU tint execution therefore
remains unproven, despite verified VFS winner/hash. The mod override is already
archived. Read-only material inspection found modern version-1.5 Burnside paint
with `dynamicCubemap=true`; the historical shader cache mostly routes vehicle
cubemap descriptors through the custom-source branch that the probe excludes.
This is a plausible branch mismatch, not proof of the active paint permutation.
Saved dynamic reflections are disabled, so declarations/cache history alone
cannot settle live routing. Cache reuse or relative-include resolution also
remain possible. No caches, materials or additional shaders were changed.

## 108. v0.095 opt-in GGX directional SSR

The user chose GGX directional sampling rather than cone filtering. Implemented
an optional roughness-aware reflection mode with Mirror SSR retained as the
startup default. This does not change the original 70 tuning values or 15 preset
tables. Existing presets preserve the selected reflection sampling mode; saved
settings/export now include `reflectionSamplingMode`. Older settings without
that field leave the current selection alone.

Active SSR entries are trace v030, temporal v031 and compose v032. GGX changes
only reflection directions/weighting/history interpretation; GI remains v081.
The pre-edit v094 sources are preserved under
`.beamrt-validation/v095/v094-source`. Changes to shared shader bases are
macro-guarded: six historical v029/v025/v028 VS/PS binaries still match their
v094 baselines byte-for-byte. No native shader override, graphics setting or
cache was changed; the archived magenta probe remains inactive on disk.

### Sampling and composition

Verified the shipped material path passes perceptual roughness through RT0.z;
native `AL_CalcSpecular` squares it once for GGX alpha. The new trace does the
same (`alpha = roughness * roughness`). A pole-safe world-normal basis and
Heitz visible-normal sampler choose one reflection direction per receiver pixel
per rendered frame. Below-macro-surface directions contribute zero without
retrying. Receiver F0 comes from RT1.rgb at the originating receiver UV.

The trace applies colored Schlick Fresnel times the height-correlated Smith
`G2/G1(V)` ratio, equivalent to `BRDF * NdotL / pdfVNDF`. The stable expression
avoids division by a grazing cosine. Composition does not apply Fresnel or
another roughness/cosine/PDF weight in GGX mode; only the existing user strength
scales that already weighted contribution. Mirror retains its original response.
The v029 first-surface, receiver-departure, native clipping, refinement,
thickness, backface and travel guards remain.

The sequence uses per-pixel uint hashing and long integer Weyl progression,
independent of the still-rejected STBN atlas. Lua uploads one sample index per
reflection preProcess, wrapping at 2^24 to stay float-exact. It does not restart
every 64/128 frames or on slow camera drift. Real cuts, resize, unavailable
camera, enable/disable, restart and mode changes reset SSR history/sequence.
Mode changes alone do not clear GI history. Existing ray and step budgets are
unchanged; actual GPU cost and convergence still need measurement.

### Zero estimators and history

Raw trace alpha remains geometric confidence, independent of RGB. A valid black
mirror hit is fresh, rather than misclassified as a miss. Mirror keeps its
signed receiver-depth lifetime: fresh, at most one grace frame, then zero.

GGX averaging includes compatible eligible receiver samples with zero RGB/alpha
(geometric misses or rejected hemisphere directions). Excluding them would
average only successful rays and make rough reflections too bright. GGX spatial
normalization does not add the old confidence-dependent sqrt weight: confidence
is already premultiplied in trace RGB. Temporal zero estimators update normally
and use at least 1/64 current-frame weight, even if the user entered zero.
Positive GGX history alpha means fresh receiver-estimator history, not a raw
ray hit. Mode changes reset history so these interpretations never mix.

Receiver depth/normal/roughness checks, camera rejection and radiance clamps
remain approximate. Neighbor eligibility uses the center view direction over a
small pixel footprint; grazing boundaries may still differ. This is not an
unbiased complete denoiser, reflection hit-distance reprojection, NRD integration
or a newly verified temporal quality fix.

### Controls, audit and validation

Use `beamrt_main.setReflectionSamplingMode("ggx")` or the tuner **GGX SSR**
button. Compare with `"mirror"` / **Mirror SSR**. After reload/restart,
`getVersion()` must report `0.095`. To retain existing tuning while selecting
combined lighting and the overlay:

```lua
beamrt_main.setMode("lighting")
beamrt_main.setReflectionsEnabled(true)
beamrt_main.setReflectionSamplingMode("ggx")
beamrt_main.enable()
```

Reflection diagnostics and reflection audits freeze sample zero so geometry
screenshots are repeatable. Manifests record selected sampling/runtime state and
the restore policy. Audits restore mode/settings, intentionally restarting SSR
history and the sequence. Frozen audits do not assess normal multi-frame GGX
convergence. Existing default-six/reflection-eight/input-ten audit counts remain.

Offline verification passes: seven shader/math checks (independent BRDF
quadrature, grazing stability, roughness spread, sequence, zero averaging and
18 strict compilations), eleven actual-Lua controls/graph/audit/UI checks, five
mirror black-hit/lifetime fixtures, and selected existing diagnostic, motion,
audit, six-slot and native Lua/FOV tests. All 17 active entries / 34 shader
stages compile with strict warnings-as-errors. Reports and test scope are in
`.beamrt-validation/v095/README.md`; passing does not prove game execution.

### Remaining limits

No game reload or GPU image/performance validation was performed for v095.
SSR still samples the existing scene-color source and uses world-distance
stepping, not pixel DDA or hierarchical Z. Fog/source contamination and additive
native cubemap double-counting remain. Native reflections are preserved as the
available miss fallback; there is no cubemap suppression/replacement or new
off-screen reflection system. The BeamRT STBN atlas loading failure is not fixed
by this mode. This is an incremental material-response improvement, not a claim
of Minecraft-style full PTGI or complete path-traced lighting.

## 109. v0.096 playable GGX reconstruction, not long exposure

The user confirmed GGX reflections look more accurate but remain equally noisy
while stationary. Live log verified v0.095 loaded, `ptgimaxreflect` selected
current-frame weight 0.25 / denoise 0.5, and GGX was selected afterward. Code
inspection found SSR uses a short fixed EWMA, independent of GI's progressive
ceiling. Half of each current ray remained raw, and a current-only neighborhood
clamp could repeatedly remove valid sparse bright history. User authorized a
noise improvement specifically for realistic, playable reflections without
waiting for long exposure; an ultra-cost screenshot mode is a separate future
request, not implemented here.

Implemented version 0.096 with only temporal entry changed to
`beamrtReflectionTemporalP_v033.hlsl`. It wraps v031 with a guarded playable
branch. Trace030, compose032, all GI/other active shaders and original 70 tuning
values/15 preset tables remain unchanged. Pre-edit v095 main/audit/temporal
sources are preserved at `.beamrt-validation/v096/v095-source`.

### Bounded reconstruction contract

Only GGX + reconstruction mode `playable` uses the new behavior:

- Existing 13 bilateral taps, nominal radius 1..3.5 pixels, and six temporal
  inputs remain. Spatial blend is `saturate(2 * reflectionDenoiseStrength)`;
  the usual 0.5 becomes full reconstruction and explicit zero stays raw.
- Compatible eligible zero estimators remain in the spatial denominator and
  refresh history. Geometric confidence and BRDF weighting remain unchanged.
- A 60 Hz current-frame response is `clamp(b * sqrt(b), 0.10, 1)`, where `b`
  is the existing user setting. The shader converts this to real frame time as
  `1 - pow(1 - weight60, 60 * dt)`. User 0.25 gives 0.125 at 60 Hz; user 1
  remains immediate. This is a bounded rolling mean, never growing exposure.
- Playable history bypasses current-only color clipping. Sparse bright energy
  is not selectively erased by a random zero neighborhood. No asymmetric
  color-reactivity heuristic was added, since it would also bias sampling.
- Existing receiver-depth/lifetime, camera, velocity, invalid-history and
  disocclusion guards remain. These can make the current spatial estimate
  dominant immediately. Reflected-source-only motion is not identified by
  receiver vectors: brief trails remain possible and are not called fixed.

Ideal accepted-history 95% bright-to-black response at the current 0.25 setting
is about 0.374 s continuously, observed after 0.400/0.383/0.375 s at 30/60/120
FPS. The minimum response floor is about 0.474 s (0.5 s frame-quantized at 30).
These are CPU fixture response bounds, not GPU convergence/timing measurements.
Spatial reconstruction applies on the first frame; there is no settle counter
or wait-before-render behavior. Sampling continues while moving.

### Timing, controls and integration

`PROGRESSIVE.reflectionReconstruction` defaults to playable, while sampling
still defaults to mirror. `setReflectionReconstruction("legacy"/"playable")`
and **Legacy filter / Playable filter** buttons permit comparison. The getter
reports choice, bounded frame delta and freeze state. Switching choices clears
SSR only, not GI; selecting the same choice does nothing. Saved/apply/export
settings include `reflectionReconstruction`; older settings and existing
presets preserve the selected choice.

Native `lua/ge/main.lua` explicitly dispatches `onPreRender(dtReal,dtSim,dtRaw)`
before rendering. The new hook caches finite positive real time, falls back to
raw time then 1/60, and clamps shader delta to 1/240..1/15. Gaps greater than
0.25 s reset active SSR history/sequence only. Missing timing does not trigger
repeated resets. Do not claim frame-time invariance outside the bounded range.
No top-level locals were added to the main module's constrained local budget.

Existing diagnostic/reflection audits force reconstruction mode0 and retain
sample-zero/current-frame semantics. Saved settings restore the filter choice;
history restarts intentionally. No matched temporal A/B capture mode was added.
Use normal rendering and the two filter buttons for visual comparison.

### Verification and remaining limits

All 17 active entries / 34 VS+PS stages compile with `/Ges /WX /O3` SM5.0.
Six new shader/math checks and ten real-Lua control/UI/audit/timing checks pass.
The shader suite performs ten strict compilations; four historical 025/031
VS/PS binaries match v095 exactly. Twenty non-temporal active/support shader
hashes were checked unchanged. Compiled temporal textures remain t0..t5; active
samplers are s0,s1,s2,s3,s5 because history uses Texture.Load (s4 optimized out).
The complete existing six-slot graph check, reflection/motion regressions,
audit restorations, native Lua51/LuaJIT/Lua55 and FOV/motion checks also pass.

In the independent flat compatible-receiver fixture, RMS noise is about 34% of
031, with mean preserved. A 1.5%-probability bright-hit fixture preserves energy;
all-zero frames decay normally. This does not predict correlated real-game
noise, visible sharpness or GPU cost. Reports/tests live under v096.

No game reload, settings mutation, native override, cache deletion, extra rays,
extra trace steps or extra filter pass occurred. Native cubemap/fog/source issues,
SSR DDA and reflected-hit-distance tracking are still unresolved. The trace and
composer are unchanged. Load v0.096 and choose **GGX SSR + Playable filter**;
the root README includes a settings-preserving reload. Game appearance,
source-motion trails and performance remain unverified until the user compares.

## 110. v0.097 hit-aware playable reconstruction and stable polished rays

User authorized hit-aware reconstruction after asking for nearly noise/smear-free
gameplay, then requested continuation after interruption. No extra rays or long
exposure were authorized as the default approach; a photo mode remains separate
future work. Implemented version 0.097 with trace034 / temporal035, compose032
unchanged. Original tuning values, all 15 preset tables and all GI shader entries
remain unchanged. Backups are `.beamrt-validation/v097/v096-source`.

### Layout chosen instead of unverified MRT or repeated traversal

Installed material/prepass shaders use multiple outputs, but no native generic
PostEffect example proves attaching SV_Target1 through target index1. The
earlier atlas/metadata-first proposal was not implemented. The final layout
uses single-target passes, the existing color path and one traversal:

1. Hit-aware trace writes original confidence-premultiplied BRDF RGB plus an
   exact numeric packed hit UV in alpha. Twelve bits per viewport-UV axis give
   approximately 0.313 pixel maximum quantization error at 2560 width. Payload
   integers 1..2^24 are exact in R32F; zero means unavailable metadata. No NaN
   bitcasts, confidence/PDF multiplication or alpha blending are permitted.
2. `BeamRT_ReflectionHitInputsFx` runs at priority 10001.5, after GI10002 and
   before SSR10001 (native ordering is descending). It packs current velocity
   XY, previous hit UV word and previous physical source depth into RGBA32F.
   Prior geometry is sampled at receiverUV+velocity, matching color history.
3. Temporal still binds only six inputs; slot3 uses this auxiliary target
   instead of native velocity while metadata is active. Motion remains in XY.
   Current hit UV comes from trace alpha; native depth remains accessible in
   slot2. Receiver depth/lifetime remains in ordinary history-color alpha.
4. A child after normal color-history copying records representative source
   UV.xy, source forward depth.z and reconstructed receiver-to-source distance.w
   into `#BeamRT_HistoryReflectionHit` (RGBA32F), without marching another ray.
   It reads only current/auxiliary/temporal/native-depth targets, never its own
   output. An eligible stochastic zero may retain a still-camera proxy while
   nonzero color remains; accepted black hits record geometry before that test.

Trace switches to RGBA32F only for active metadata selection and uses an explicit
non-blending state with unchanged linear source-color sampling. Metadata helpers
and temporal reads are point sampled, with explicit blending disabled. OFF,
legacy, mirror and frozen diagnostics use the original confidence payload and
R16F trace target. The native executable contains the R32G32B32A32F format enum;
this does not independently prove live allocation/attachment. Rough nominal
extra buffer storage is 40 bytes/pixel (about 140.6 MiB at 2560x1440), excluding
renderer pooling/overhead. Actual memory and GPU cost remain unmeasured.

### Geometry rules and scope

Current reconstructed surface-to-hit distance guides the 13-tap spatial filter
on near-polished receivers. The tolerance grows with receiver travel and the
roughness lobe; its strength fades from roughness 0.04 to 0.14 and is disabled at
or above 0.14. Eligible zero samples retain base weights. This bilateral choice
is approximate, not an unbiased complete GGX estimator at hit discontinuities.

History never compares two independent stochastic rays' distances to decide
whether a GGX sample is valid. Instead, a still camera validates the recorded
source's old depth at its old UV against current geometry. All five one-pixel
probes must disagree to reject, limiting false rejection from UV quantization
and depth edges. Current and still-camera previous source motion can retire
history even when the receiving surface is stationary. Old-UV depth checks are
skipped while the camera moves; existing camera/receiver/velocity guards remain.
The v0.096 bounded time-based average and valid-zero lifetime are unchanged.

This is representative-hit rejection, not virtual-image reprojection or complete
tracking of every contribution in a spatial/temporal lobe. There are no object
IDs or stored reflected normals. Source color/light changes without geometry or
motion changes may still trail, and spatially mixed signals can lack a reliable
proxy. Fog/source contamination, native additive cubemap competition, off-screen
geometry and linear SSR traversal remain unresolved.

Nearly polished roughness <= 0.035 uses a deterministic mirror-direction
approximation with receiver material weighting. It removes directional jitter
there, but is not exact finite-roughness GGX integration. Rougher surfaces retain
the original VNDF. No additional sample count was introduced. Stable smooth-ray
selection remains in frozen ray diagnostics so those inspect the chosen ray;
metadata packing/history helpers alone are bypassed during the existing audit.

### Controls, ownership and verification

`reflectionHitAwareEnabled` defaults true but sampling still starts in mirror.
Choose GGX + Playable + Hit-aware ON. `setReflectionHitAwareEnabled(bool)` toggles
the new path, resets only SSR and preserves GI; repeated selection is a no-op.
Settings save/apply/export and existing audits restore it. Missing older fields
preserve the selected setting. Helpers are enabled only alongside selected SSR,
disabled for GI diagnostics, repaired on partial object loss and destroyed with
their shaders/state/callbacks on unload. Pack callbacks upload flags only; they
do not measure camera motion or tick the sample sequence.

Seven source-bound metadata/geometry/build tests and ten actual-Lua control
tests pass. Exhaustive CPU validation covers every 24-bit numeric payload plus
random UV quantization/repacking. Source-motion/disocclusion/edge probes,
roughness-relaxed spatial gates, affine native eye-ray distance and accepted
static rough-lobe mean/zero decay are checked. Sixteen strict shader compilations
include four old030/033 VS+PS byte identities. All 19 active entries / 38 stages
compile with `/Ges /WX /O3`; all compiled inputs fit t0..t5/s0..s5. Existing
14-check six-input graph, reflection 8, motion 18, audit restorations and native
Lua51/LuaJIT/Lua55/FOV checks pass against the installed source.

Reports and test limits are under v097. No live module reload, screenshot/FPS
comparison, native shader override, cache deletion or game-setting mutation was
performed. GPU execution, attachment precision, sharpness/noise and performance
are unverified. Load 0.097 and compare Hit-aware ON/OFF in normal rendering.
The update is not advertised as perfect reflections or a completed photo mode.

## 111. Cube input bank review — real field found, no migration yet

User suggested packing suitable environment/static data into textureCube slots
to free primary 2D inputs. Read-only installed-binary inspection found a generic
PostEffect `textureCube` field documented alongside `texture`. The earlier
capacity check inspected only the primary texture array. Do not infer that
six primary 2D inputs is necessarily the complete native resource budget.

Both native HLSL sampler macros use the shared sREG/tREG namespaces. Cubes are
not automatically an independent Direct3D register bank, but BeamNG might expose
additional cube bindings through its wrapper. Live user probe output on
2026-10-10 confirms six texture entries and twelve textureCube entries on the
reflection trace, temporal and auxiliary effects; all cube entries are empty.
BeamNG's official PostFX documentation confirms the same field capacities.
Native routing and actual binding remain unverified; upstream Torque postFx is
not proof of BeamNG's fork. Do not guess a t6/s6 offset from these counts.
No existing binding guard, shader, main version or rendering setting was changed.

Prepared `beamrt_cubeInputProbe`, a read-only extension that logs actual field
descriptors/counts, bounded cube names, associated shader files/sampler metadata,
and the native sky fallback object if available. The user can run
`extensions.load("beamrt_cubeInputProbe")` once with the game open; it logs under
`BeamRT.CubeInputs` without a restart, cache manipulation or capture. Read its
output before implementing a cube sampler binding or choosing a register offset.
The user has completed this read-only check. Shader sampler-name metadata was
not exposed, and the optional native sky fallback object was absent. Do not ask
them to repeat this capability check; field counts are now established.
Four mock/bounds tests and native Lua51/LuaJIT/Lua55 compilation checks pass.

Directional environment/probe radiance and compatible static LUT/noise packing
are candidates. Current SSR uses dynamic screen buffers and procedural noise,
so it has no existing static-noise texture binding to free. GI noise resources
could be packed, but already use one downstream auxiliary binding and the STBN
loader is still rejected. Do not move dynamic depth/motion/history or change DDS
formats speculatively. Full notes: `.beamrt-validation/v097/cube-input-review.md`.

## 112. v0.098 — helper registration-order fix for motion-colored beauty

User's normal lighting image becomes black while still and RGB/motion-shaped
while moving. They isolated it to GGX + Playable; Mirror and Legacy work. These
two modes bypass the v0.097 hit-aware helper. Logs do not show a BeamRT diagnostic
selection. This is not intended hit-aware output and the read-only cube probe
did not mutate rendering.

Found concrete defect in reflectionHit.createInputs: registerObject ran before
target/shader/input assignment. Moved registration to after complete setup,
guarded by function-local isNew. No new main-chunk locals; version now 0.098.
Existing malformed native objects must be destroyed/recreated through a full
settings-preserving extension unload/load; field refresh alone is insufficient.
No shader, preset, ray count, format, filtering or native installation changes.

Thirteen actual-Lua checks pass, including registration-time snapshots for every
named producer, recreation/restoration and deliberate reintroduction of the old
order. The mutation has correct final fields but no target at registration and
is detected, unlike old mocks. All native Lua compile/FOV/motion checks pass.
Upstream lifecycle corroborates the likely mechanism, not BeamNG fork proof.
No live reload performed; corrected GPU image still pending user check.
See `.beamrt-validation/v098/README.md` and the reload command at README top.

## 113. Persistent SSR squares — live sequence check prepared, no filter change

User confirms v0.098 looks good, then reports square patches that persist while
stationary and are prominent while driving, material-dependent near bright
sources. GI STBN/native-noise switching does not change them; acknowledge this
was the wrong system for GGX SSR. They propose tiling/low-res reconstruction vs
normal one-ray GGX noise. Current source traces SSR at full resolution, no
explicit tile-rate reduction; point reconstruction/nearest history, insufficient
rough-lobe support, source LOD0 aliasing and stopped/reset sequence remain
candidates, not proven causes. Do not blur categorical/packed hit metadata or
attribute the patches to distance without evidence. No shader/filter change.

Added reflectionSequenceProbe, standalone read-only 3-second CPU public-state
observer. One GE console load logs automatic results in normal beamng.log; no
settings mutation, history reset, rendering change, captures or listener. Five
fixtures + all native Lua compile checks pass. User has not run it yet. Read
the reported advance/reset/freeze counts before deciding on sequence scheduling
or filter changes. CPU progress is not independently verified GPU/history.

User completed probe: 150 frames / ~3.003 s, advances149, unchanged1, resets0,
frozen0; sampleIndex11322 ->11471. GGX + Playable + Hit-aware active at start/end.
No stalled/restarting/frozen CPU sequence in this interval. Do not request the
same sequence test again or imply GPU/history acceptance is proved. Focus
remaining investigation on reflection color reconstruction/source aliasing and
history rejection. No additional shader/filter change made yet.

## 114. v0.099 — reflection color filtering (source implemented, GPU pending)

User explicitly authorized the next fix and provided staged advice. Retained
full-resolution SSR, hash/Weyl GGX, valid dark hits/zero estimators and source-hit
history; did not restore rejected STBN or rewrite tracing. New trace036 and
temporal037 macro-wrap existing entries. Older034/035 VS+PS bytes identical.

Two owned source-color passes at priority10001.75 (GI10002 first, hit-inputs
10001.5 then SSR10001) create linear half source and depth-aware 2x/4x/8x atlas.
No assumed native mipCap, cube mapping or new ray. RGB averages decode-first;
alpha representative source depth, clamped toRGBA16F capacity. Atlas in trace
slot4 (five inputs), temporal stillsix. Odd sizes handled with ceil division.
All targets assigned before registration; sources disabled in non-playable GGX,
diagnostics/frozen reflection audit/OFF. Partial repair/unload/resize covered.

Color ON samples bounded approximate source-footprint levels at accepted hits,
depth-validating color taps and reverting to raw source at incompatible layers.
Preserves raw source r<=.04; fades by .16. Roughness/travel/depth projection scale
is heuristic, not complete ray differentials or unbiased second GGX. Existing
first-surface rules/confidence/BRDF/hit payload unchanged. Camera/history filter
adds valid-only subpixelRGB, leaves signed depth/lifetime and hitUV point-exact.
Current13-tap normal exponent relaxes24->8 over r.04..20. No longer history.

New reflectionColorFilterEnabled true default, saved/apply/export, UI Color
filter ON/OFF, setter same-name. OFF restores098 color behavior, resets onlySSR,
preserves GI, all15 preset tables, hit-aware selection. Missing oldsave flag keeps
default. Sampling stillstartsMirror; chooseGGX+Playable+Hit-awareON+ColorON.

17 Lua controls/registration,6 color/numeric/old-byte-identity,14 binding and18
motion checks pass; all21 active entries/42 strict stages, nativeLua compilers
and FOV checks pass. Approx extra source buffers19.3MiB at2560x1440 +2smaller
draws/fetch work; actualGPUcost/visuals unverified. No live reload performed,
no native shaders/cache changes. User must reload once preserving tuning; then
normal gameplay ColorON/OFF test. Full technical limits/reload at v099 README.

First live image feedback: user explicitly says first supplied interior image
is ColorON, second OFF. Patches still present in both. Camera framing differs;
do not quantify improvement or count square artifact fixed. Logs show newsource
ShaderData creation and ColorOFF->ON, then final GGX, no newshader error in tail.
GPU target contents/reuse remain unverified. Need accepted-hit/miss/source stage
isolation before another filter/tuning change. Existing reflection audit captures
those views but freezes sample0 and bypasses all playable/hit/color reconstruction
even SSR beauty: raw geometry/source test only, not live pipeline A/B.

## 115. User completed interior audit — sparse raw SSR evidence, no new fix

Reviewed all8 images and manifest in current/screenshots/beamrt-audit/
2026-10-10_13-13-15. v099 complete/restoredtrue. OriginalGGX+Playable+Hit-awareON,
ColorOFF; restored ColorOFF. Source code audit freezes sample0/bypasses filter,
so do not claim live099 pipeline capture. Native lacks added console speckles;
single-sample SSRbeauty/weightedcomposite already contain sparse bright signal.
Continuous receiver mask, mixed hit/miss/rejection map; most accepted raw samples
are near-black. Lefttrim coarseROI:32407eligible,16581accepted(51.2%),15039raw
<=1/255(90.7%ofaccepted),1270raw>8/255(7.7%). CenterROI95% accepted nearblack.
8-bit post-processed PNG metrics, not linear GPU radiance/material exact masks.

Evidence supports sparse high-contrast reflection estimator, not GI STBN or a
confirmed tile/lowres/range defect. Denoiser can shape patches but is not sole
origin of sparse signal. Better variance-aware SSR reconstruction is a candidate;
must keep valid-zero energy and geometry/material/hit boundaries. No fulltemporal
history-rejection capture, no proven exact square-generating cause. No newshader
or settings mutations during review. Do not ask for sameaudit again.
Read-only pixel script work/audit-quantify.py and detailedreport in
.beamrt-validation/v099/audit-2026-10-10-analysis.md.

## 116. v0.100 — raw128 reference prepared, gameplay denoiser postponed

Read user's full pasted request. Main recommendation: stationary raw128 test
before new reflection SVGF/moments/variance-guided filtering. Built diagnostic,
not gameplay denoiser. Corrected91% single-frozen-sample accepted-hit statistic
must not be generalized to a per-pixel long-run rate. Finite128 can still noise;
persistence does not prove incorrect tracer/weights by itself.

Trace040 macro-wraps036 with transient convergence category-alpha gate; OFF
normalstartup/unsaved, clearsrestore. Accepted1 includes zero; BRDF-domain known
zero-1; unknown0. ON R32/unblended, skips normal temporal+compose subtree, helper
geometry/source producers disabled while preserving selected stable smooth-ray
choice. No ray traversal, weighting, sequence, resolution/preset changes.

Standalone reflectionConvergence module starts on load,7trackedlocal captures:
playableSSR-only ColorOFF, raw128beauty/contribution, CV, coverage, accepted-near-
zero rate, actualcount128. GI OFF both stages for matched native source. Owned
physics pause token; cameramovement/FOV/resolution changes abort. Saves/restores
settings/state/tuner/diagnostics, histories intentionallyrestart, oldpause and
otherpauseownerspreserved. Clearsownedobjects/callbacks, cancels onmission/main
unload, blocksordinaryaudits, no mainsettings mutation onpause/directorydenial.

MeanRGB arithmetic1/N raw weightedHDR includes zeros. ExactF32 alpha packs count,
unknowncount, acceptednearzerocount(8bit each). MomentsRGBA M1/M2/accepted-rate/
knownBRDF-zero-rate. Both oldhistory reads occur before either copy, GPUholds128
so capturequeue doesn't advance129+. Unknown misses zero only visibleSSR term,
not physicallyblack offscreenradiance. Darkthreshold weightedmaxRGB1e-6 differs
from previousrawPNG<=1/255. CVmap samplevariance, not varianceof128mean.

8diagnosticLua,5numeric,17gameplay,14binding,18motion tests pass. 24entries/48strict
stages compiled; old036/037 fourVSPS binariesidentical, nativeLua/FOVchecks pass.
Approx225MiB at2560x1440 +5temporarydraws, no extra rays; GPUcost/results pending.
User must reload100 then load beamrt_reflectionConvergence, closeconsole, keep
camera still. No assistantlive mutation. RootREADME has one-line reload+start;
v100README detailslimits. Do not implement new denoiser before reviewing this.

## 117. v100 live reference reviewed —128 GPU endpoint works, no denoiser-only proof

User completed screenshots/beamrt-convergence/2026-10-10_13-55-47. Readall7PNGs and
manifest: complete/restoredtrue, nativepause poppedcounter0. Countmap760791exact
green /763314near-AA-green, zero redUnder128. CPUdraws166..392 duringcapture but
GPUmeanheld128; numeric32bit countpayload visualization works. Original normal
settingsLighting+GI(screen1.75)+SSRggxPlayableHitONColorOFF restored.

Raw128 contribution formscoherent trim/gearreflection, noobviousfixedtiles at
displayedscale; CVhotspots bright aroundhighlights. Validzero/unknown categories
remainseparate. BUT playableSSR-only baseline ALSO coherent; raw128 notuniformly
smoother. TrimlocalresidualRMS1.176(raw) vs0.802(playable), dashboard0.524vs0.325:
PNGtexture/detail indicators, not pure noise. BothstagesGIoff/sourceColoroff;
fullproduction userimagesGIon. GI/sourcecoupling orGIcontribution stillcandidate,
as is drivinghistoryloss. Stage1blueinteractionmarkers absentstage2 confoundwide
brightnesscomparison. Do not claim unbiasedtracer orsoleSSRdenoiserdiagnosis.

No productionchange duringreview. Do not repeatthisreference. Readonlypixeltool
v100/work/reference-quantify.py +v100/reference-2026-10-10-analysis.md detailROI,
limits. Nextisolate GI-only/SSR-only/GI+SSR sourcecoupling beforeclaiming a new
variance-aware reflectionfilter willresolve the fullgame squareartifact.

## 118. v0.101 — user redirected to source coupling, no new denoiser

User still unhappy with noise, then specifically requested native/liveGI/frozenGI
SSR inputs instead of immediatelydenoising. Builtsourceprobe, notvariancefilter.
Code: GI10002 subtree filters/Atrous3/composes$BB, SSR10001 reads$BB, likelyGI
sourcecoupling butclosednativecache notverified bybindingnames.

Transient PROGRESSIVE.reflectionSourceProbeTarget / setter limitedto3ownedtarget
names+nildfault; controls trace t2 and colorHalf t0, resetsONLYSSR, notsaved.
Allnormalshader21entries/42stages identicalto100. Main cancelsprobe onunload/
missionchange; audits/convergenceblockedwhileprobeactive. Newmodule startsload.

Nativecopy10003.5 beforeGI; Livecopy10001.875 afterGI beforeSSR; signed linearHDR
delta child=Live-Native sameframe. Frozenroot10001.78125 recomposeLIVE Native+
heldGI-net delta. Not guessedcubemap subtraction; includesvisibilitydarkening.
Delta skipsafterfrozenwarmup (neverdisable/clear), copiescountheld; native/live
copies+GGXkeepadvancing. GI remainsin displayBASE allcases. Original$BB control
plusnative/live/frozen;14trackedPNG(beauty/source/filteredSSR each +frozenGInetA/B).
SourceOriginalview proxy afterGI, NOT samplerreadback. Freeze retains spatial
noise; persistence doesn't exonerateGI. Exposure/GIconvergence confoundseq images.

Restores settings/mode/enable/tuner/diagnostics/pauseowner/defaultsource onall
finishes; owns/deletes targets/shaders/callbacks, deniedpause/dir no mainmutation,
abortcamera/FOV/res/selection changes/timeouts. ~225MiB4RGBA32Ftargets temporary,
4sourcepasses+optionaldisplay, noextrarays. Assistantdidnotrunlive. Userneeds
reload101 +extensions.load("beamrt_reflectionSourceProbe"), closeconsole, keep
camera still, thenreview outputsin screenshots/beamrt-source-probe.

6sourceLua/3math/17gameplay/8convergence/14binding/18motionpass;27entries/54strict
stages;21productionentries allidentical100; nativeLua/FOVpass. MainREADME command
andv101README documentinterpretationlimits. No pixelcontents/noisefix claimed.

## 119. v101 source probe reviewed — sources not distinct

All14 PNGs and manifest reviewed in screenshots/beamrt-source-probe/2026-10-10_14-42-46.
Complete/restoredtrue/no failures. Native vs Live max1/255, meanabs0.000130 channel
codes outside HUD; Live vs Frozen max1, mean0.000120. Both frozenGI-net views
exactlyblack and identical in scene mask. Delta counter held796, Native/Live
890..1135 and GGX94..339 advance. CPU lifecycle works, GPU source distinction
not proven. GeartrimSSR mean1.677original/1.696native/1.691live/1.690frozen.
No demonstrated source-freeze cleanup. Camera0; GI stationaryprogressive142..2048.

Causally inconclusive: possible shared cached$backBuffer, negligibleGI output,
or ineffectivecomposer; no proven explanation. Do not exonerateGI or claim
denoiser-only cause. Nextverify actualcomposer/source routing with explicit
namedGI-lit target and positive signal before blindfilter or repeat audit.
No gameplayedit. v101/source-2026-10-10-analysis.md +work/source-quantify.py
record displayprecision/ROI limits. Latestuserdone expects review findings.

## 120. Oct 11: user-authorized real building alignment stage

User supplied PR #2 and full hybrid renderer goal, then explicitly authorized
taking over the one-real-building alignment milestone. Clean experimental branch
fast-forwarded cbc592b -> f03d45d (no checkout switch, commit or push). Later
implementation is uncommitted. Preserve user branch and experimental shaders.

Read installed WCU ZIP: real guardhouse.dae visual node guardhouse_L150 selected,
776 triangles /776 UV faces, 8 material refs,255 offline BVH nodes. Seven unique
candidate engine Material configs resolved across WCU+art_shapes ZIPs; construction
unresolved. Every alphaMode staysunknown. Generated art/beamrt/alignment package
is Gitignored private game-derived data. Original game archives unchanged.

New tools/beamrt_scene_align.py bakes actual active visual-node ancestor transforms
before unit/axis conversion; excludes siblingLOD and collisionmeshes, preserves
node/geometry/material provenance, rejects unsupported/partial source. Original
importer gains negativeUVindex rejection. Khronos spec verified row-major text /
column-vector postmultiplication. No triangle decimation to old12cap.

New meshPlacement.lua uses native MatrixF.mulP3F on scaledunitpoints plus control
points /getColumn evidence, not parsedMatrixFstrings. >2mm affine discrepancy
rejected; visualalignment remainsfalse. sceneAssetManifest captures native basis
as optionalJSONsafe metadata with expliciterror ifunavailable.

New standalone meshAlignment.lua loadsprivate package, selectsnearest matching
guardhouse (notarbitrarynearestbuilding), transforms allfacesonce, drawsbounded
orange actualmesh edges/materialrefcolors. Neverchanges GI/shadow/reflection/
physics/camera. Objecttransform/shapechange/removal marksstale; cameramotiondoesnot.
HumanconfirmAlignment explicitly recordsvisualevidence; noautomaticGPUproof.
Worldmesh export preservesall776 faces,unknownopacity,flags; NOT old12uniformload.

14 Python regressiontests +6 importerchecks pass;6 actual-Lua fixtures pass;
nativeLua51/JIT55 compile checks pass. ExistingmainFOVchecks pass. No newHLSL.
CIworkflow extended offline tests,notpushed/runremote. In-gamepreview notyetloaded
byassistant; pendinguserGEcmd: extensions.load("beamrt_meshAlignment");
beamrt_meshAlignment.previewNearest(); dump(beamrt_meshAlignment.getStatus()).
Sourcecachedregistry priornil stillmustrefresh ifmainfeaturesused; thispreview
is independent and requiresno mainreload. MESH_ALIGNMENT_MILESTONE.md/README
explain selectiondistance and futureGPUupload/alpha/shadowpersistence limits.
Optional focusPreview/restoreCamera added using verified core_camera free APIs;
only explicit commands move camera, nevervehicle. Missionchange dropsoldcamera
snapshot. Seventh Lua fixture verifies focus only explicit and mode restore.

## 121. Oct 11: full guardhouse GPU BVH preview prepared

User posted front-view wire screenshot: plausible doors/walls/roof/lamps/base
alignment, not proof of depth/GPU/shadows. After explanation user saidalright to
nextstage. Implementedisolated meshBVH module, not productionlighting changes.
New packer full776faces/255nodes,256x28RGBA8 PNG;16bitmodelcoords error<.03mm,
outwardBVHbounds,preorderescapelinks stacklesstraversal,no12facetruncation.
Privatepackages ignored; no installation or GitHub writes. Sourcechanges local.

Trace3inputs normals/depth/data, preview2inputs scene/result. Exactbyteheaders
includingalpha verify resource decoding;SRGB-view inversehandled;invaliddata
magenta, traversal4096ceiling unknown, no certifyingwhole-mapvisibility onmiss.
Worldray inverse capturedbasis rows, localdirNOTnormalized worlddistancekept.
Allopacityunknown ->orangepossiblemeshblockers, not certifiedopaquecastshadows.

Explicit synthetictestpointlight makesgeometryfootprint inspectable atnight;
doesnotspawnlightorchangegamebrightness/time. Engine-sun signselectalso retained.
Qualityhalf/fullreceivergrid,fullgeometryboth,performanceunmeasured. Default
nativeleft/classificationright;bindingproofgreen/cyanorinvalidmagenta. Newobjects
registerfieldbeforeonAdd,ownedcleanup,onmission/stale disables. NoGIsampling or
reflectioncomposer changed. Wirehiddenwhilepreview andrestoredondisable unless
userchangedmode. Supportsoldloadedalignmentgetterlessmodulewithoutunload/camera
snapshotloss. NoautomaticGPUverifiedflagfromCPUstate.

9 pack/traversaltests (249 rays vsbruteforce),5Lua controlfixtures,4strictFXCstages,
Lua51/JIT55 compilepass. CPUchecks notGPUproof. README/MESH_BVH_MILESTONE.md usercmd:
extensions.load("beamrt_meshBVH"); beamrt_meshBVH.setQuality("cinematic");
beamrt_meshBVH.setTestLightEnabled(true); beamrt_meshBVH.enable(). Awaitactualimage,
thenoffscreenpersistence check,thenalpha/material/lightquality integration. No
commit/pushauthorized yet. Previous Gitworkflow question unanswered explicitly.

## 122. Standing development rules — explicit user request, Oct 11

The objective is a hybrid renderer, not an expanding collection of debug tools.
Investigate Git history, code, logs and previous results before a new hypothesis.
Do not ask the user to repeat completed tests. At most TWO meaningful in-game
tests per hypothesis; each must name its expected result and the implementation
decision that follows. Once a cause is identified, implement the fix rather than
adding a reconfirmation diagnostic. If repeated fixes fail, revisit architecture
instead of stacking filters, tolerances or workarounds.

Prioritize geometry, materials, GPU acceleration, persistent shadows and GI
visibility. Make related changes as one batch, review compilation, compatibility
and regressions locally, and preserve working algorithms with fallbacks. Request
in-game testing only for facts unavailable from code, with one compact command
set. Every development cycle reports: what was wrong/missing; what changed; what
functionality is implemented; what remains unverified; next substantial milestone.

Evidence ledger: user's real guardhouse wire screenshot and log object40430 /
776faces /1196edges establish plausible visible alignment. Do NOT restart that
alignment-test cycle. Latest available log contains no meshBVH execution result.
GPU data loading/ray correctness remains one unresolved hardware question; the
existing compact BVH run is sufficient to address it, not a reason for another
probe. Materials/opacity and native-preserving production composition are not
implemented by the classification preview. Next substantial milestone is a
material-aware persistent shadow path with native fallback, then shared GI
visibility. Do not claim either production feature is already finished.

## 123. Oct 11: v0.103 full-mesh GI guard and identified-code fixes

User handles Git manually. Explicit continue authorized local implementation.
Reviewed existing code/history/logs; no new in-game test performed. Last log has
alignment40430 only, no BVH run. Do not repeat alignment/CPU self-test requests.

Implemented live native material declarations (standard Material, matching mapTo,
alphaTest/translucent explicitfalse andfullcoloralpha ->opaque). Mask/blend/custom/
incomplete ->fallback;16identitiesmax,no truncation. Shared stackless BVH header
used byshadow002 andGI083,full776faces. Uncertainhit doesn'thide lateropaquehit;
invalid/budget ->no falseocclusion. Shadow remains separate visibility output.

Opt-in sharedMeshGI checksreceiver->WORLDsurfel segment. Screen estimator/noise/
temporal/presets unchanged. Native lightRGB+retroA packedfull-resR32F onepass,
frees slot5,retains6inputs, auxSTBN atlas untouched. Active onlyGIrendering+world
source+positiveworldstrength+opaque+currentgeometry. DefaultsOFF;inactive restores
082/native3&5,stops/releasespack. Key changes clearGIhistory. Bound/effective kept
separate toavoid stale sampler layout afterdisable/re-enable. UI showsinactive
reason. Sourcepack~52.9MiB at2560x1353,performanceunmeasured. No directshadows or
synthetictestlight influence onGI. Native masks notmultipliedinto finishedscene.

Knownfixes: cachedvisibility getters/status/query resolveactualmodule fallback;
unconditionalmagenta inreflection026/filter001 removed;new033/002 entries restore
composer andexistingvarianceweight. VarianceOFForiginalgraph,no3wastedpasses.
Explicitvariance setterrecreatesgraph;oldforwarddeleteObjectnil bugfixedbylocal
find+delete. No newdenoiser activated. PackedPNGnowcontent-addressed;private
package regenerated. User's external commit2e5bfd4 preserved,noassistantpush.

25Lua integration/retainedmotion,7alignment,5BVHcontrols,23packingpass; native
Lua51/JIT55 compilepass. Newentries strictFXCpass;082GI/062cache/001meshVSPS
exactbaseline. Graphfixture stubs unrelatedphysicsacquisition due plain tablevecs,
not productionbug. Live native material flags/GPUdecoding/appearance/FPS pending.

SHARED_MESH_GI_MILESTONE.md +README give required5cycleitems andone normalrender
activation:save/reloadmain+unloadoldmeshBVH,applytuning,enable,HYBRID+world.35
explicitly,enableguard+dumpstatus. No debugviews/camera/time/vehiclechange. Scope
onebuilding/worldGI only;noSSRnoise/nativecubemap/wholemapclaim. NextalphaUVtexture
queries +moreinstances,thenselective native-preserving light/shadow integration.

## 124. Oct 11: v0.104 selective native direct-sun mesh integration

User explicitly authorized actual shadows, not further classification tools.
Reviewed installed native vectorLightP/farFrustum headers, Lua CustomMaterial
samplers and material-editor reload; AL_LightBin name confirmed in installed binary.
One three-input full-res deterministic BVH pass runs BEFORE AL_LightBin. Target
R32F XYZ receiver identity/W=2 definite opaque blocker; other cases W=1 fallback.
Native direct-sun helper t14 verifies dimensions/pixel/world identity (1 cm) and
only min-combines into native visibility BEFORE direct diffuse/specular shading.
Native shadow/cloud/SSS stays; subsurface receiver path excluded. No final-color
multiply, local-light/emissive/cubemap patch, random rays or filter added.

Private generator copies installed pixel source, preserves native math, validates
specific call/include contracts and free t14, content-addresses filename, records
original/dependency/generated source. Files under shaders/beamrt/generated ignored.
Installed files untouched. Enable compares actual VFS sources, requires native
AL_VectorLightShader/material APIs, refuses existing mod ownership, reloads only
chosen objects. Disable/stale/missions/unload restore original fields, no foreign
mutation overwrite. Main v104 UI/disable/unload integration; defaultOFF/unpersisted.
CastShadows=false excluded independently of GI opacity. Old loaded policy records
supported; no alignment/camera repeat. Current native copy prepared locally.

9 Lua lifecycle/control +4 generator tests pass; retained25GI/motion+5BVH+23packing
pass. Lua51/JIT55 compilation passes; strict visibilityVSPS+8nativePS permutations
pass. GPU reload/binding/pre-light scheduling, receiver agreement, reflection-view
fallback, shadows/offscreen retention/FPS unverified. No whole-map/soft-shadow/
alpha/dynamic/forward support claimed. Target~52.9MiB at2560x1353 plus bandwidth.

ONE normal daytime render command in MESH_SUN_SHADOW_MILESTONE.md:
extensions.load("beamrt_meshSunShadow"); dump(beamrt_meshSunShadow.enable()).
Normal image; compare disable, rotate caster offscreen keeping receiver onscreen.
Nighttime deliberately not fake-lit. If no effect inspectexistinglog first; do not
retest wire/CPUselfTest. Next real milestone additionalinstances+alpha thenGI light
visibility after firstliveintegrationfix. User external commit1d07902 observed
midwork andpreserved; noassistantGitwrites/pulls/pushes performed.

## 125. First live v104 activation: native Material-wrapper API mismatch fixed

User screenshot actualmesh40430/776faces/1196edges, all8materialnames rejected
nonstandard,opaque0,enablefalse. This is BEFORE anynativehook/shadow execution,
not evidence ofbadGPUrays. InstalledmaterialEditor.lua:792 andeditor/api/material.lua
use___type==class<Material>. Ourpolicy incorrectlyassumed getClassName method.
Implementednativewrapperidentityfirst,legacymethodfallbackonlywithouttag;
CustomMaterialknown-tag cannotbypass. Fieldreadwithinpcall, incompleteopacity
lognowcontainsvalues. No opacitydefaults/guessing/alphaoverride changed.6newLua
policytests+9sun+25GI regressionspass,Lua51/JIT55compilepass. Samev104bugfix.

Running policyrequirecached;final/docsonecommandunloadSun+BVH,clearpolicyrequire,
loadSun+enable. DoNOTunloadalignment orrepeatgeometry/camera. Normalclassification
expected, actualopaque counts/nativehookexecutionunverified. Ifnewerrorinspect it
directly. Nextmilestone stillnormalrealshadow+offscreen retention,theninstances/alpha.

## 126. Second live v104 activation: remove irrelevant color-alpha gate

Userlogpostclassfix:opaque0/mask4/blend2/unknown2. corrugated_modern andmetal_galvanized
explicit alphaTestfalse/translucentfalse, colorAlphanil; other6retainfallback.
Samecommandrepeated1641/1657 unchanged. Nativepermutations181-228 confirmsalpha
clipping gatedbyMFT_AlphaTest, separatetranslucentpath; coloralphaaccessor absence
doesnotmeanunknowncoverage whenbothnativeflags explicitfalse. Fixedpolicycriteria
toallowthese2withcolorAlphastillnil,noassumedvalue,no8facesopaquebypass. Known
fractionalalpha stillconservativefallback; truly missingflags/custom/mapTo mismatch
stayunknown.8policyfixtures inclactualobservedflaglayout+9sun+25GIpass,Lua51/JIT55
compilepass. Docs samecache-reloadactivation,expected2opaque4mask2blend0unknown.
No newdebugshader/opacityprobe; nextnormalnativehookexecution thenoffscreen shadow.

## 127. User-requested native geometric sunlight isolation / comparison

User saysnativeexterior shadowsalreadygood, obscuresBeamRTcontribution; goaldark
interiorsnotglobalbrightnesschange. AddedtemporarynativeSun comparisonhybrid/
beamrt-only/split/unshadowed. Normalhybriddefaultpreserved. Othermodesbypassnative
geometricSun onvalidmainreceivers;cloud/localshadows/ambient/IBL/emissive remain.
Unknown/transmitting/invalid/mismatch reflectionreceiversfallbacknative. Shaderhelper
tracksnativecloudseparately; one sharedtrace;splitLEFTnative/RIGHTBeamRTonly,not2
wholeGI/SSRrenders. Existingworldboxdiagnosticcompareunmodified. Tunerbuttonsadded.

Generatorv2private4hashvariants includeshelpersourceinchecks/digest. Luaownsall4
pathsforrestore/conflictdetection. Disable/stale/mission/unload/resetrestoreoriginal
nativeandcomparisonhybrid. Invalidtrace/clearW0 vsvalidclear1/blocked2 guards
isolation. Latestactualuserscreenshoterror isrextensions extra r,no reload ran.
Final/docsmultilinecorrectactivationreloadSun+BVH+policy,selectbeamrt-only,enable.
DoNOTretestalignment. Restore:disable. Max2meaningfultests:1normalisolation/split;
2ONLYifneededunshadowedcontrol. Controlunchanged->fixbinding/receivercontract;
controlworksbutnoBeamRTshadow->fixquery/coverage. No more generic probes.

12sunLua/5generator/8policy/retained25GIpass;32nativePS+visibilityVSPS strictFXC,
Lua51/JIT55pass. ActualnativeGPUactivation/appearance unverified. Latestobserved
2opaque4masked2blended (inferredpostfix,notconfirmedruntime). No blanketopacity.
Nextarchitecturemilestonealpha-awarecoverage+skyambient+indirectvisibility forone
building;sunshadowalonecannotmakeinteriorpitchblack. Preservelegitimatewindow/
lamp/emissive/bounce lighting. NoassistantGitwrites/installedfilestouched.

## 128. v105: driving/walking observation; real defects fixed without new tests

User identifiescarcontrolvswalkmode, notonlycamera; orangebleedstillwrong. New
day/nightsewer andpartitionheadlight screenshots arecurrentreproreferences;no
furthersamehypothesistests requested. NativeSun beamrt-only+unshadowed lookedsame;
recordtheseasfailedisolation,CPUenabled notGPUproof. Latestlogexplicitdisable3220
restoresnative. PNG256x28skipcookingnotGPUresourcefailureproof; donotPOT-pad and
triggerlossycookingofpackedbytes. Failedtracerinstallationnotignored.

InspectednativecameraUpdatechangesSunSDSMrange .5vs1 andinteriorSSAO .5vs1.5;
NOTproofofheadlightmodecause. Jbeamsections/meshs.lua activeconstructor default
lightCastShadowsfalse; props.updateGFX ownsemissions/cache/blinkstate. DoNOTfull
setLightArgs blindlywithbasebrightness; thatcanforceofflampON/manglelivecolors.

FixedBeamRTlightProvider defaultonlyplayervehicle acquisition:nearest8vehicles/
80mcameraradius,getAllVehicles nativeAPI(verifiedveToolbar),scopeexplicitvehicleId
preserved. Radiuscapfailure/capped/playerfallbackreported,falseGPUfeeds/liveactive
unknown flagsretained. NativePoint/Spot___type accepted. Recordknownconstructor
defaultsmetadata only;noactualnativeLight/state/shadowsetterwrites.8Luafixturespass
avatar-switch/removal/wrapper/cap/fallback/positions/noLightmutations. Thisisdata
acqdefectfix,NOTnativeheadlightbugfix.

FoundupstreamshaderData.cpp macros-keyedcachedprogramlookup +reloadoldGFXpaths;
BeamNGforksamebehaviorinference only, butoldnativeShaderfilename mutation unsafe.
M.meshSunShadow nowcreatesfreshprivateShaderDatapergeneratedhashwithVtx/Pixel/
defines/samplerNames0..14 BEFOREregister, rebindsNativeCustomMaterial.shader+
reloadmaterial. OriginalShaderData/cache nevermodified. Disable/failure restores
origMaterialShader/sampler,ownedclonesonlycleanup,foreignchangespreserved. Independent
unshadowedcontrol returnscloudvisibilitybeforemeshRelayguard;normalmodeskeepguards.
MainVERSION105.13sunLua fixtures modelcachedpathandnewmaterialbinding;retained25GI+
5generatorpass;32nativePS/Lua51JIT55compilepass. NativeGPUexecappearanceunverified.

LIGHT_VISIBILITY_V0105.md records5cycleitems. NextsmallcompleteSliceactualsewer
mesh+localLight/skyambientvisibility. CandidateWCUsteel_factory_sewer01..06/
underground01..02foundarchive;notmatchedlive/GPUnotimported. No new in-game
commands or tests thiscycle. NoassistantGitwrites/pulls/pushes,installedfilesuntouched.

## 129. v106: complete one-section native local-light visibility implementation

User'alright' accepted nextslice; proceededimplementationwithoutanotherdiagnostic.
Prepared8privateWCUassets sewer01..06/underground01..02 viaexistingimporter+packer.
Exacthighestnumericvisual_aLODnode,noCOLmesh/LODunion. 3981/4294/10200/3981/5538/
8727/10900/8961tris, nodes1023/1419/4095/1023/2047/3117/4095/3585 allwithin4096.
Explicitnon-area lines/linestrips exclusionrecorded;defaultimportstrict,other
unsupportedSURFACEprimitive stillfails. Actualassetparserissue fixedinbatch.

meshLocalScene readsdescriptorregistry,scansTSStaticatENABLEONLY,selectsonebyactual
transformedmeshBBoxdistance(max30m;inside/smallerBBox tiebreak),NativeMatrixFpoint
basis/inverse,layout/texture/materialchecks. No wire/camera/vehiclemutations. Native
Canal materialofflinehasnoalpha/translucentdecl (runtimeflagsnotconfirmed); industrial
trim/fencesmaskunknownfallback. DataPNGNPOTuncompressedcompatiblepathretained.

meshLocalLights privatePoint/Spot nativecopiesviafreshShaderData/materialrebind;
immutableDatasetvaluesinShaderData.defines beforeREGISTER,texture t14. Real native
worldPos->cb.lightPosition ray INSIDE nativepixelpass, noPFXPreBin depthrelay,
no separate lightreconstruction orcontrolledvehiclefilter. Definiteopaquehit0;
nativeShadowingotherwiseincludinginvalid/unknown/miss. NativeNO_SHADOW path now
getsoptionalMeshblockers. Normal/nativeattenuation,cookies,brightness,color,
electricblinking/spec/retro preserved;noLightInfo setterwrites. Exclude subsurface
receivers/speciallightmapping. Native source/helpercontracts checked. Freshshader
cachekey reusedunchanged,max64ownedrevisions bounded. BothPoint/Spotrollback;
ownershipconflict/stale/opacity/mission/unload restoresnative. Stalecheck30frames.
Main106toggle/defaultOFF/unpersisted,Maindisable/unloadrestoreslocalbindings.

10actualLua selection/lifecycle/bindfixtures+4Stdimport/sourcecontract+25retainedGI
and14alignmentpass;24strictnativePoint/SpotPS permutations shadow/no-shadow/cookie/
reversed-depth/cube withREALlargestdesc dimensions; Lua51/JIT55compilepass.
CompilerfoundnativeShadowMapIO '#define bias' collision; renameourparamsrayStartBias
insharedBVHCommon,nomathchange. RecompileGI083/mesh002 infinalreviewrequired.

UnverifiedLIVE: exactclosestsection/LOD alignment/material flags/textureupload/
nativePointSpotpathbinding/actuallightblocking/FPS. One-instanceonly,notwholeTunnel;
nativeclustered/forward/dynamicgeometrynotintercepted, nativefalse shadowsnotremoved.
Ambient/daytimefill+GI+orangelegitimatebounces remain separate. No fixclaimyet.
ONE normalrenderGEcmd:nooldwire/probes/screenshotaudits:
extensions.load("beamrt_meshLocalLights"); dump(beamrt_meshLocalLights.enable()).
Atcurrentsewer,expectselectedactualasset andnativeheadlight illuminationbehindsolid
OPAQUEwall reduced,retainedcar/walk. Restoredisable. Iferrorinspectexactlog; ifno
effectinspectselectedasset/policy/nativeRenderPathnotnewfilters. NewcompleteSlice
validationnotthirdoldSunhypothesischeck. Nextadjacentinstances/alpha thenSkyambient
andGIvisibility. Userexternalcommits2733084/1e638e1 observedmidwork,preserved;
noassistantGitwrites. Preparedprivateassets/hooksource alreadyinPC,notGitincluded.

## 130. Final v106 compatibility blocker — do NOT request another visual test yet

Furtherreviewfoundnativecore/settings/clusteredQuality.lua +graphicqualitygroup
GraphicClusteredQuality configuringGLOBAL ClusteredShading (minLightScreenSize,
lightFlares,shadowMaxCasters,shadowFallbackFrames,shadowOversample,shadowBubble).
Native cluster_shade.cs.hlsl computehandleslocalPointSpot lighting+ShadowViews;
t14 isshadowAtlas,t15shadowViews,t16baseColoroption. Legacy nativeCustomMaterial
bridgenotcoverageproofonthisbackend. Exactactive routingnotprovenfrompresence,
butdoNOTclaimcompatible/askanother'imageunchanged'test. meshLocalLights.enable
nowrefuseswhenClusteredShadingexposed beforeanyscene/renderwrite. Added11thLua
testforguard andsafeMemberMetadata. Srccompileallprevious24pass; GI083/mesh002
VSPS strictrecompilepass followingrayStartBiasrename.

getBackendInfo listsbounded128memberNAMES+TYPES (depth2,seen/cap), no getter calls
orfieldvalues/pointers/statewrites. FinalONEread-onlyAPIlookup:
extensions.load("beamrt_meshLocalLights"); dump(beamrt_meshLocalLights.getBackendInfo()).
PurposeactualClusteredShader/ResourcebindingAPI,notvisual/tracediagnostic. Ifexposed,
portrealgeometryqueriesinsidematchingcompute pass (newslot17orappropriatebinding,
no t14overwrite). Ifnotexposed,explainnativebridge requiresapproval/scope decision;
doNOTguessstaticfields,forcebackendoff,blindVFSoverride/nativeinstallwrites,or
floodwithconsoletests. Existinggeometryregistry/privateMeshscene/BVH reusable.
DocsREADME updatedclearlySTAGED/CLUSTEREDBLOCKED. No in-game shadowsfixedclaim.
## 131. Clustered dispatch interface audit completed (2026-10-11)

User's getBackendInfo result: exposed table with only ___type/__index/__newindex.
Read-only, no activation; do not request again. Presence is not active-backend
proof, and proxy enumeration is not proof that no additional API exists.
Installed Lua exposes six clustered quality controls and a developer UI opener,
not a verified mesh texture/structured-buffer binding. Executable strings confirm
the native cluster_shade.cs.hlsl path; shader compilation utilities are not a
general resource-binding API. No engine edits or native bridge installed.
Compute t14/t15 already own the shadow atlas/views. An unused register does not
provide a script binding. Additional mesh visibility must follow the native
shadowStrength lerp, otherwise no-shadow lights bypass it. Native disableShadows
view semantics, contributions and fallback must remain intact.
UNDERGROUND_LOCAL_LIGHTS_V0106.md records the completed lookup and specific
remaining boundary. Supported engine integration is preferred; unsupported
native integration needs a separate user scope decision. No new visual test.

## 132. Native feasibility investigation authorized and completed (2026-10-11)

User said yes to investigating native integration, explicitly before any
installation/injection. No binary built/loaded, no game files changed, no DLL
injection, sandbox/quality changes or process memory writes. Earlier staged CI
fixes remain user-owned and untouched.
Installed game 0.39.4.0.20972 / current log D3D12 RTX4070. Read-only PE inspection:
exe 18 named exports (debug draw/UI/SSL/preferences), no clustered/device-binding
API; libbeamng.x64.dll only getBeamEngine/destroyBeamEngine/getBeamEngineRevision.
No usable renderer SDK located. Official ROS2 cpp API inspected at
f684d48eec39c9f2a49f884a175c1aea7dd82ca6: sensor/shmem/control ABI, not render access.
Do not treat DLL loading or GPU sensor streams as engine graphics integration.

ReShade upstream 7bf9de8b33bcc76c3177007e65d73c72dd0f34c0 API/events/reference and
06-shader_replace example expose compute pipeline/layout/resource/dispatch
capabilities. This is a credible D3D12 add-on route without engine memory offsets,
not a proven game-compatible hook. Host installation requires separate approval.
NATIVE_RENDERER_FEASIBILITY.md gives exact evidence, source hash, candidate design,
root-signature/state/lifetime gates, risks and next offline implementation slice.
No new in-game command/test requested. Clustered guard unchanged; ambient and GI
are separate milestones. Next implementation is a complete offline-buildable
default-off one-mesh add-on slice, not another stand-alone pass-discovery logger.

## 133. No-ReShade native GPU worker implemented; no game attachment (2026-10-11)

User rejected ReShade dependency, then requested continuation and unload/reload
commands when runtime updates occur. Do NOT continue the earlier ReShade-host
plan. Keep the engine integration milestone gated on all five conditions.

vswhere located installed MSVC under E:\New folder (3), not the default C: tree.
native/worker now implements a versioned C ABI DLL with caller-owned D3D12 device,
owned queue/resources/layout/PSO, lossless packed RGBA8 upload, shared existing
BVH compute traversal, world transforms and explicit material modes. No new
importer, DXR, injector, loader, engine-memory scan or ReShade dependency.
Input validation and fence/resource retention prevent invalid replacements or
uncompleted work from being treated as success. Synchronous CPU readback is
offline validation only; no production gameplay/composition bridge exists.

Strict FXC cs_5_0 /Ges /WX and MSVC /W4 /WX compilation passed. Real guardhouse
776 triangles/255 nodes: three 128-ray batches (controlled opaque/unknown policy,
translated nonuniform transform) matched independent CPU brute-force categories
on RTX4070. Invalid layout/header/NaN/ray inputs, corrupt root escape link,
recovery, destroy and recreate checked. Synthetic WARP also passed. Debug layer
unavailable locally; device-loss/timeouts/live integration not exercised.
tools/beamrt_native_fixture.py reuses packer/test reference; its all-opaque policy
is controlled fixture input, NOT evidence about live guardhouse materials.
Six fixture regressions + new Windows workflow compile/run WARP, no game assets
published. Workflow result pending publication. Artifacts remain Git-ignored.

No DLL loaded into BeamNG or installed in Bin64. No camera/depth/game-device
access or consumption of native output by BeamNG proven. Preserve clustered guard.
Runtime remains v0.106: no main/rendering algorithm changed this cycle. README
has full GE Lua reload preserving tuning and unloading BeamRT before clearing
helper caches; no reload is necessary for offline-only source/tests/docs.
Next substantial milestone: verified no-ReShade host adapter plus real lighting
consumer, not further standalone renderer expansion. DLL loading alone is not it.

## 134. v0.107 handles rejected optional STBN resource; no noise-quality claim

Latest log startup5.47 rejects v094 DDS despite local DDPF_RGB0x40/native-style
header. This follows v092DX10/v093RGBA/v094RGB-only fixes. Do not repeat header
gambling/old reflection/source tests. User's current source=beamng, worldGI0,
ptgimaxreflect andGGX; rejectedAtlas was still unconditionally bound on startup.

MainVERSION0.107 adds M.noiseSourcePolicy (no new top-level local). Actual Lua
resolver refuses STBN/beamrt/spatiotemporal aliases with reason and no mutation/
history reset; native aliases keep original mode0. Auxiliary t3 uses knownnative
PNG insteadof failedDDS; v002wrapper clearsunusedSTBNbank. Native bank/history/
velocity/surfel layout/six-input ABI unchanged. v001defaultkept forrollback.
GUI says experimental atlas unavailable insteadof offering false activation.
DDS/PNG assets untouched. SavedSTBN may warn/refuse butother tuningapplies;
noJSON tuningwrite. This fixes optionaldependency handling, NOT custom atlas
decoding, GI correctness or reflection squares/noise. Reflection stillhashGGX.

6newactualLua/mainsetter/sourcecontracts; 95suite tests pass. MainLua51/JIT compile
andv001/v002 VSPSstrictFXC compilepass. NewCI suitewired. Freshv107liveuptake/noNEW
DDSrequestunverified; historical errorsremaininlog. NOISE_SOURCE_V0107.md +README
recordscope andsingle-line fullreload. No newdiagnostic/photos/scenerequest.
Nextsubstantialmilestone remainsno-ReShadegame resourceconnection; workerstill
offline, notinstalled/attached. User's intervening commit da46cd6 ispreserved.

## 135. v0.108 exact-adapter bootstrap + unavailable UI, no game attachment

User asked to continue native connection work; source93a835a updated by user.
Microsoft D3D12CreateDevice docs: normally same-process singleton per adapter.
This is a concrete SDK device-bootstrap route, not a BeamNG renderer export.
WorkerABI2 adds exactLUID+explicitcandidateCreationAllowed (mayCREATE ifnone),
device metadata/acquisition provenance andcanonicalGetDevice/IUnknown ownercheck.
No rawgamepointerguesses, private memoryscan, injector/proxy/ReShade or install.
Original worker ABI functions/scene layouts preserved; no logging-only helper.

RTX4070 offlinehost: candidate reusesexistinghostdevice andmatcheshostresource;
foreignWARP resource rejected. Explicit opt-in/unknownLUID/nullargs/provenance
checks +realguardhouseGPU batches pass. WARP test also passes. StrictMSVC/FXC
build passes; debuglayerunavailable. No BeamNG device/depth/view/queue captured.

Mainv108 UI availability policy removes blocked local-light activation button,
preflights beforeload, usesrawget toavoidextensionautoload fromstatusread. Existing
legacyhooks remain disableable. Exposure notactivebackendproof. SevennewrealLua/
main/drawtests;102 regressions pass;Lua51/JITmaincompiles. ExistingNOISEv107 fix
retained. Native legacy enable safeguard stillunchanged. No newshadernoise/math.
NATIVE_DEVICE_BOOTSTRAP_V0108.md +README/worker/feasibilitydocs exactscope.

The actual missing boundary now: acquire validgame-owned frame resources and
view/camera, synchronizeproducer/consumer, affectintendedlighting andrestore.
Do NOT ask a LUID-only game test withouta realresourceownercheck; itcannotprove
attachment. No new oldsun/guardhouse/reflection diagnostic requested. Singleline
reload updatesv108tuner only, neverloadsDLL. Futureloading/integrationrequires
separatereview. Preservecurrentrenderer,avoidstandaloneexpansionbeforeconnection.
