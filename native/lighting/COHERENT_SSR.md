# Coherent SSR experimental backend (tuner v0.118.1)

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
The older renderer is stopped before enabling this one, and vice versa. GI
integration is intentionally not simultaneous in this first comparison path.

Full history storage is the default, not half-width interleaving. Trace scale
starts at 0.5 with the maximum 128-step trace budget; 1 or 4 rays are selectable.
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

Reload BeamRT to get tuner v0.118.1. Turn integrated Screen Space Reflections off
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
**Lighting & GI -> Start / Apply GI** returns to the older GI renderer. Neither operation toggles
the game's native SSR setting. Full-resolution/four-ray experiments can be costly.

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

The D3D12 offline fixture runs 49 checks on RTX 4070 and WARP, including exact
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
