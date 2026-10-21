# Coherent SSR experimental backend (tuner v0.120)

This is an opt-in rendering-only adaptation of an authorized contribution,
with BeamRT-owned shaders, resources and controls. It is not the integrated
BeamNG SSR object, and it does not establish native parity or better appearance.
No external loader, UI/core runtime, input bindings, mod-manager interception,
shader-cache clearing or stock-water-shader repair is imported.

## Implemented together

- Projected screen traversal with packed hierarchical depth and slope-aware hits.
- Stochastic GGX rays, frame-varying samples, geometry-gated spatial filtering,
  a color pyramid and isolated-bright-sample suppression.
- Independent full-resolution RGBA32F packed history with per-tap receiver
  validation, ping-pong routing, subpixel sampling and history reset controls.
- Previous-camera inverse basis captured by a GPU pass, reflected-image
  reprojection, rigid player-vehicle OBB motion and disocclusion handling.
- Glossy per-pixel reconstruction/detail rebuild and surface-detail composition.
- Combined opaque/water depth, plane/block candidates, baked river/block height
  maps, dielectric water Fresnel, wave approximation and fog attenuation.
- Optional sky/overhang fill and procedural puddles, separate from measured hits.

These stages share packed buffers and remain one pipeline rather than mixing
incompatible pieces into the older renderer. Spatial filtering is not new-ray
visibility at every neighbor. Sky/overhang fill estimates enclosure from the
screen; it is not proof of unoccluded sky. Rivers use projected height ribbons;
overlapping layers and steep descents remain limitations. Water waves do not
guarantee the engine's rendered wave phase. OBB motion is rigid, not deformation
motion. No acceleration structure, off-screen geometry tracing or new RTGI is
added by this change.

## BeamRT-specific changes

The backend starts disabled, has its own exact-object cleanup and fails closed
on native-SSR conflict, missing passes, exceptions or incomplete cleanup. It
stops on settings/mission/unload changes and requires explicit re-enabling.
The older renderer is stopped before enabling this one, and vice versa, except
for the explicit v0.120 combined PTGI mode described below. Ordinary standalone
selection remains exclusive; legacy SSR never joins the combined path.

Full history storage is the default, not half-width interleaving. Trace scale
starts at 0.5 with the maximum 128-step trace budget and six rays. One, four,
six, eight or sixteen rays are selectable; heavy cleanup chooses full resolution.
Retired/hidden standalone switches now actually honor BeamRT parameter values.
Parameter changes invalidate history. Camera interruption, vehicle switching,
invalid OBBs and teleports cannot manufacture a valid previous vehicle pose.
Engine velocity sampling is off by default: no unverified target binding or
global player-motion-blur flag is forced. It can be explored separately once
the engine target is confirmed produced. Other moving/deforming vehicles need
that input; camera history alone cannot solve their motion.

Sky fill, overhang fill and puddles start off. Water reflections are on only
when this entire backend is explicitly enabled. A runtime river bake may write
its own height-map PNG under `settings/beamrt/coherent/river_masks`; stock game
files are not rewritten. The existing four quality presets and comparison lab
still belong to the older renderer; no fifth preset collection is introduced.
New Coherent controls are transient and are not saved into the older tuning file.

Added water tint also defaults to zero: the fixed blue-green grade is bypassed
and stock rendered water remains beneath the reflections. This does not make
water pixel-identical to stock, since the reflections themselves alter its color.
The optional tint slider is labeled as an added grade, not the map's water color.
Exposure, global brightness and the older cinematic renderer are unchanged.

## Try and revert

Reload BeamRT to get tuner v0.120. Turn integrated Screen Space Reflections off
in BeamNG graphics settings. Under **Reflections**, choose **Enable reflections**,
or run in GE Lua after BeamRT is loaded:

```lua
beamrt_main.setCoherentSsrEnabled(true)
```

Keep the camera stationary for a few seconds, then compare while panning and
driving. Toggle GGX rays, accumulation, reuse, reconstruction and reflected-motion
reprojection individually. Test water and sky fill separately. Use the Coherent
debug views, not the old eight-image audit: the latter explicitly refuses this
backend rather than labeling legacy captures as Coherent output.

Disable using the matching button or `beamrt_main.setCoherentSsrEnabled(false)`.
**Lighting & GI -> Standalone GI / legacy route** returns to the older renderer. Neither operation toggles
the game's native SSR setting. Full-resolution/sixteen-ray experiments are very costly.

## Verification boundary

Offline CPU/controller checks run the actual Lua controller and complete pass
graph against engine-object mocks in Lua 5.1 and LuaJIT. They check explicit
selection, exclusivity, validation, pass loss, cleanup retries, six-slot binding,
history alternation, camera loss and rigid motion. These are not engine scheduling
or GPU execution receipts.

All 18 new production entry points compile with FXC SM5 `/Ges /WX /O3` against
installed BeamNG headers; the older 52 entry/stage combinations still compile.
The same 18 entry points also compile with installed DXC SM6, including the
wave-intrinsic branches. Strict-compiler fixes include a reserved identifier,
explicit SH coefficient copy, initialized ray arrays and return-flow forms
accepted by FXC. Compilation does not execute the game's SM6 path.

The D3D12 offline fixture runs 85 checks on RTX 4070 and WARP, including exact
zero-tint bypass of stock water color, optional tint isolation, packed
history/sign bits through an actual RGBA32F target, receiver rejection, independent
water Fresnel references, sample variation, the actual camera-history pass and
odd-sized depth-pyramid reductions. The debug layer was unavailable. These checks
do not measure convergence, driving ghosting, water alignment, leakage or image
quality in BeamNG. No game session was launched or reloaded for this integration.

## Grid-pattern and off-screen follow-up

v0.116 adds a default non-tiled per-pixel scramble with low-discrepancy temporal
phases. The previous 8x8 ordered pattern remains switchable for comparison.
The GPU fixture demonstrates the old X component's eight-pixel repetition and
the absence of that exact repeat in the new pattern. This is not a claim that
white/scrambled sampling has a blue-noise spectrum, or that the pictured road
is now clean. Also fixed: at trace scale 1, requested stochastic spatial reuse
now runs instead of silently turning off. Synthetic variance falls while the
tested water/opaque boundary is preserved. Neither test establishes real driving
convergence or absence of all reflected-source leakage.

The new leaf-only reference disables hierarchical skipping, raises the bounded
budget to 256 steps, and retains the same depth/hit tests. It is still capable
of running out of work; a changed result alone does not prove a hierarchy bug.
GPU fixtures run the real marcher against a known flat target at hierarchy
levels 0, 1 and 4, and reject an empty depth view. These tests do not reproduce
the bridge's thin cables or hidden underside.

Coherent debug views 50 through 53 show accepted source UV, log hit distance,
sampling phase and hit confidence. Their trace colors bypass history and the
beauty composite; they must not be interpreted as reflection radiance.

```lua
beamrt_main.setCoherentSsrParameter('samplingMode', 1) -- 0 = previous ordered pattern
beamrt_main.setCoherentSsrParameter('referenceTrace', true) -- slow; false restores hierarchy
beamrt_main.setCoherentSsrParameter('debugView', 50) -- 0 restores beauty
```

## v0.117 rough-reflection cleanup

Two correctness repairs are independent of the experiment switch:

- Spatial reuse carries a representative accepted neighbor hit code with the
  reconstructed signal, instead of filling a center miss with color while
  retaining its miss-distance metadata. Adaptive rough-trace reconstruction
  now selects a covered finite seed too. Native preparation refuses finite
  distance seeds from zero-coverage taps. A representative seed is NOT proof
  of visibility for a new receiver ray; glossy rebuild still tests visibility.
- A neighborhood without hit colors no longer reports a spurious RGB mismatch
  and penalizes history age based on a color range it did not measure.

**Rough stability (experimental)** starts ON in Coherent SSR. It adds weak
diagonal taps to geometry/normal/roughness-gated spatial reuse, and a
Bernoulli-inspired floor to temporal coverage clipping for intermittent GGX
samples. It ramps in over roughness 0.12 to 0.35, excludes water and requires
stochastic SSR. It does not change exposure, reflection gain, sky fill, wave
generation, stock water rendering, or the older GI/SSR backend. It adds no
camera or DLL work. The four existing presets remain unchanged.

The coverage floor is a heuristic: neighboring samples can be correlated.
It can retain stale radiance longer or soften fine rough-reflection detail;
turn it OFF for comparison. This does not repair missing off-screen geometry,
prove the photographed grid is fixed, or establish a physically unbiased filter.

```lua
beamrt_main.setCoherentSsrParameter('roughStability', false) -- compare OFF
beamrt_main.setCoherentSsrParameter('roughStability', true)  -- experimental ON
```

Changing the toggle invalidates history. Hold the same road camera and wait
several seconds after each change. Compare a still image and a slow pan.
Under **Diagnostics -> Reflection stages**, compare Raw trace (20) with History (21), then
History acceptance (44), weight (45), clipping/miss count (46), and motion
source (47). Restore Beauty (0) for appearance comparisons. These are temporary
diagnostic images, not additional quality presets. Check whether a pattern is
already in raw tracing or introduced by reconstruction/history before changing
the traversal or material strength again.

Offline fixtures execute production reuse into its RGBA16F format and the
native-history shader into RGBA32F. They test seed transport, empty misses,
adaptive rough seeds, diagonal support, water-class exclusion, the comparison
toggle, sparse-history retention, age progression and receiver-plane rejection.
These controlled GPU cases do not substitute for in-game stillness/motion tests.

## v0.118 tuner organization

v0.118.1 places each visible slider label above the full-width control, rather
than beyond its right edge. Widget IDs remain hidden and parameter values,
rendering behavior and saved tuning are unchanged.

The front Reflections tab exposes Look, Quality, Noise and temporal stability,
Water and optional appearance experiments. Diagnostics owns reflection stage
views, sample/reference experiments, legacy audits and the parked camera/water
previews. Lighting & GI retains the existing GI system and four presets.
Legacy holds the archived reflection backends, comparison lab and dense-native
experiment. Opening tabs does not switch a backend, reset history or enable a
capture. A diagnostic-view warning and explicit beauty restore remain visible
above all tabs. Legacy tuning save/load is labeled separately from session-only
current reflection controls.

The pre-cleanup legacy source snapshot is documented in `../../archive/README.md`.
The separate optional-native research track is described in `../RT_ROADMAP.md`.
Neither UI cleanup nor separate hosting establishes repository approval, DXR
support, native game resource access or a completed hardware-RT renderer.

## v0.119 high-sample cleanup

Under Reflections, **Apply high-sample cleanup (slow)** changes sampling and
reconstruction only: full-resolution tracing (including rough receivers),
maximum normal trace work, sixteen GGX rays, non-tiled sampling, fresh samples
each frame, full-resolution temporal accumulation with 0.98 retention,
surface-aware reconstruction, reflection-motion reprojection, rough stability,
0.5 spatial reuse, and the rough color pyramid. It does not start the renderer.
One/four-ray controls remain available; default sampling is now four rays.

**Undo cleanup settings** restores the sampling values from before the first
cleanup click, even if cleanup was clicked twice. This is a session-only A/B
action, not another saved preset family. It leaves reflection intensity,
roughness cutoff, face-on reflectivity, surface-detail composition, water color,
water strength/waves, sky/overhang fill and procedural puddles untouched.

The sixteen-ray non-tiled mode samples all sixteen cells of a 4x4 sample-domain
partition each frame, with independently hashed within-cell offsets per pixel
and frame. This is not a screen-space 4x4 ordered mask or a blue-noise claim.
Existing one/four-ray sequences are preserved. The production ray storage and
budget both permit sixteen; mirror mode still uses one ray.

Fixed a retention limit: native history age saturates at 31 in its five-bit
field. Previously that permanently forced at least 1/32 fresh contribution,
even at requested retention 0.98. After warmup, requested retention is now
honored instead of treating packed age as a perpetual sample-count ceiling.
Receiver validation, clipping, motion-driven refresh and invalidation remain
in place. This can retain stale signals longer; driving/disocclusion comparisons
remain necessary. History storage/layout is unchanged.

The tuner now warns when accumulation is disabled or ray animation is frozen.
It distinguishes warming history from CPU-scheduled reuse, not measured GPU
success. Retention alone does nothing when Temporal accumulation is unchecked
or retention is zero. The cleanup button enables the relevant controls together.

Offline GPU tests check stratification, bounds, reproducibility, frame variation,
frozen-sequence behavior, ray-budget limits, and the actual packed temporal pass
at mature age, including receiver-plane rejection. For a smooth sample-domain
test function with known mean, MSE fell from 0.0146844 (four rays) to 0.00064822
(sixteen rays) on RTX 4070. That is NOT a measurement of BeamNG image noise or
proof of unbiased physical reflection radiance. All eighteen production entries
compile under strict FXC SM5 and DXC SM6. No game reload was performed.

For the in-game check: enable reflections, apply cleanup, keep the same road
camera still for a few seconds, then slowly pan/drive. Compare beauty, Raw trace
and History; undo to compare the same material settings. Do not tune brightness
down to hide noise. More samples cannot recover hidden/off-screen geometry,
match the engine's water-wave phase, or guarantee zero visible noise in motion.

## v0.119.1 parked-vehicle accumulation repair

Native temporal accumulation previously classified every receiver within the
valid player-vehicle bounds as moving, even with identical previous/current
poses. This forced at least 0.20 fresh contribution (at most 0.80 history),
overriding the requested 0.98 retention and disabling reflection-motion
reprojection for parked vehicles. A new GPU regression reproduced this failure
before the repair; the four added cases all pass afterward.

The rigid previous point and normal are still reconstructed. Moving status now
requires receiver displacement above max(0.5 mm, 0.05 native pixel footprints).
The point displacement detects both translation and rotation; tiny pose jitter
does not force the moving floor. The non-native temporal fallback uses the same
movement test instead of using vehicle membership as movement evidence. This
is a bounded heuristic and still uses an approximate player OBB, not an object-ID
mask or deformation motion. Slowly moving sub-threshold receivers can be treated
as stationary; existing geometry, normal, clipping and invalidation gates remain.

GPU cases check identical parked poses, negligible pose jitter, real translation
and rotation through the production packed temporal pass. Both shader-model
builds compile. This is not proof of clean in-game car reflections, nor a repair
for SSR visibility limitations, GI differences or every source of speckling.

The Temporal accumulation checkbox OFF intentionally freezes the ray sequence;
it does not remove its grain. ON advances samples for averaging. A static noisy
image can therefore look calmer than animated samples whose history is not
converging. Its tooltip now states that distinction. After reload, keep it ON,
apply high-sample cleanup and compare a parked car with slow movement. Do not
repeatedly reset history during the convergence test.

The Lighting & GI route and Coherent route are mutually exclusive. Comparing
those buttons compares lighting/composition as well as reflection sampling, not
just an accumulation toggle. No lighting brightness, material gain, water tint,
native settings, game launch or DLL work changed in this repair.

## v0.120 PTGI + Coherent and intermediate ray counts

Under **Lighting & GI**, click **Enable PTGI + Coherent**. This is a session-only,
explicit combined experiment, not a fifth quality preset. Alternatively:

```lua
beamrt_main.setPtgiCoherentEnabled(true)
-- Stops both renderers and restores the original GI stages:
beamrt_main.setPtgiCoherentEnabled(false)
```

It retains current GI tuning and Coherent sampling/material settings. No older
SSR overlay, its independent hit/color preparation passes, or the legacy water
preview overlay is allowed alongside Coherent. Reflections remain owned by
Coherent; diffuse GI is owned by PTGI. Native SSR must still be OFF, and BeamRT
does not toggle it. The six-ray default and six/eight-ray buttons give intermediate
cost choices; changing ray count does not change the per-ray step budget or
hard-cut water reach. More samples still cost more, and equal detail/noise or a
specific FPS improvement is not guaranteed. Heavy cleanup remains sixteen rays.

The combined staging lease puts these roots in PFXBeforeBin / AfterPostFX:

| Priority (descending execution) | Root / purpose |
| --- | --- |
| 64.x | Existing Coherent depth hierarchy |
| 48 | PTGI world-surfel update and its history copy |
| 47 | PTGI receiver response and packed auxiliary inputs |
| 46 | PTGI trace, moments, temporal/spatial filtering, HDR composition and history copies |
| 24.x | Coherent source-color pyramid, tracing, history and reflection composition |

GI composition already uses the engine HDR decode/encode helpers. Coherent's
color source is captured after GI composition and before Coherent's own reflection
composition. The signal flow is intended to reflect GI-lit scene color, not a
previously composed SSR image. Histories remain separate. This ordering is
checked in the Lua object graph; actual engine scheduling/HDR resource lifetime
and combined appearance still need in-game verification.

The lease captures each original GI root's stage/bin/priority and restores it
on disable, standalone selection, mission/settings changes or unload. It does
not restore fields onto a foreign replacement. A failed restoration blocks
another activation until disable can restore the outstanding lease. Native
conflicts, lost/disabled passes, modified GI stages or non-beauty/non-HDR Coherent
configuration stop the combined route. Legacy audits and incompatible diagnostic
views stay blocked until combined rendering is disabled.

While combined, the four existing presets/applySettings apply their GI portion
only: their legacy reflection entries do not enable or retune either SSR path.
The existing standalone route and legacy settings are retained outside this mode.
GI history resets also invalidate Coherent history, since the reflected source
lighting has changed. The Lighting history reset resets both in combined mode;
the Reflections history button resets only Coherent.

### PTGI audit findings in this batch

- Fixed: long render interruptions invalidated reflection history but not GI
  history. GI now invalidates after a frame gap greater than 0.25 seconds too.
- Fixed for combined use: GI and SSR previously had incompatible selection and
  stage ownership. Both being enabled was not an integration; the lease/order
  and older-SSR exclusion above are required.
- Fixed for combined use: old presets carry legacy reflection settings, and GI
  parameter changes could otherwise leave reflection history of an older lighting
  state. Preset filtering and linked invalidation handle those cases.
- Fixed for this integration: producer-view material/clean-radiance captures
  could otherwise interrupt the active reflection source. They now require
  Coherent/combined mode to be disabled, and a pending material batch blocks
  activation. Startup callback exceptions attempt teardown and stage restoration.
- Remaining: GI uses inferred material/receiver response, not a guaranteed true
  diffuse-albedo buffer. Screen-space visibility and coarse surfel caches cannot
  establish all off-screen blockers or eliminate leakage everywhere.
- Remaining: GI history still samples the engine velocity target. Its existing
  Lua camera-motion guard reduces stale-history risk but is not full exact camera
  reprojection, object deformation motion or proof of that target's validity in
  every configuration. No global motion-blur setting was forced.
- Remaining: second-bounce history and appearance/energy controls are approximations,
  not proof of an unbiased physical PTGI estimator or hardware ray tracing.

New tests execute the actual main switching/lifecycle functions, real Coherent
Lua graph and staging module in Lua 5.1/LuaJIT, with engine object mocks. Cases
cover opt-in, order, tuning retention, six/eight-ray controls, older-SSR exclusion,
linked resets, preset isolation, conflicts, loss, rollback, restoration failure
and foreign replacements. Offline GPU checks confirm six/eight-ray budget values
in addition to prior math/history tests. They do not execute the combined mode
inside BeamNG. Start with six rays, compare GI OFF/ON at fixed reflection settings,
then try eight rays if frame time permits. Do not use sixteen-ray cleanup as a
gameplay default for this comparison.

## Extra-camera capture probe (parked; not a reflection fallback yet)

The opt-in `planarCapture` module uses ordinary RenderView fields demonstrated
by the installed game's `lua/ge/extensions/render/viewDemo.lua` and
`render/renderViews.lua`. It creates a private 512px color target with PostFX
disabled, never changes the main view or native settings, and can preview either
a mirrored water camera or a rear-facing camera. A mirrored camera uses a
right-handed basis and its actual projection, not a negative-scale camera plus
an accidental second horizontal flip. Pure Lua tests check the transform,
projection, invalid inputs, cleanup retries and foreign-view ownership.

v0.116.1 fixes a fragile wrapper-identity ownership check. A private numbered
view name and its assigned color target identify the active lease, even if
`getView()` returns a different Lua wrapper. Cleanup destroys the original
stored handle, as the game's renderViews helper does. If removal is deferred,
the probe is first deactivated and restart stays blocked until it disappears;
the accepted handle is never destroyed twice. Tests simulate both fresh
wrappers and deferred deletion. These tests do not establish the actual
engine's wrapper/deletion semantics or prove GPU output.

Restart BeamNG once when updating from v0.116 if the old fixed-name probe was
orphaned. The new module deliberately does not adopt or delete that unowned
view. If a stop reports deletion pending, wait a frame and press Stop camera
probe again. The tuner displays the current named preview target.

Starting the probe stops custom GI/SSR. It does not run concurrently with an
audit or material capture. Settings/mission/unload changes stop it. It does not
resume another renderer automatically. No new DLL is loaded or built.

```lua
beamrt_main.startReflectionCaptureProbe('mirror') -- requires one unambiguous WaterPlane height
-- Or supply a known height explicitly:
beamrt_main.startReflectionCaptureProbe('mirror', 0)
beamrt_main.startReflectionCaptureProbe('rear')
beamrt_main.logReflectionCaptureCapabilities() -- read-only binding inventory
beamrt_main.stopReflectionCaptureProbe()
```

The capture is intentionally preview-only: per-view plane clipping, depth
publication, underwater handling, view ordering and exposure parity are not
verified. A scheduled frame count or a readable property is not GPU evidence.
Do not composite this texture as trusted reflection coverage yet. The next
game test is to inspect the preview and binding receipt. If required per-view
clipping/depth controls genuinely cannot be provided through the engine API,
that is a concrete reason to reconsider a narrow native bridge. It does not
justify returning to unbounded DLL observation/injection experiments now.

```powershell
./tools/test.ps1
./native/lighting/build_coherent.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/lighting/build_coherent.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
```
