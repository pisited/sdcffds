# Receiver history and source-layer reconstruction

Implemented in the installed mod, not a separate Git checkout. Selected trace
v043 and temporal v039 retain v042/v038 as offline comparison references.
No native DLL, stock shader, exposure setting or native SSR setting is changed.
BeamNG 0.40's native-SSR material-buffer interlock remains mandatory.

## What changes

1. **Source-layer reconstruction.** A depth-accepted SSR hit previously sampled
   source color bilinearly. That can import a bright foreground texel whose
   geometry was never accepted. The new path independently validates the four
   original color taps against a conservative reciprocal-depth plane, decodes
   each surviving HDR texel, and reconstructs compatible color. Missing color
   support remains black with accepted geometric metadata intact. Local depth
   extrema cannot fabricate a plane into an adjacent layer. Ray acceptance,
   first-surface termination and ray distribution are unchanged.
2. **Receiver-surface history.** Previous receiver world normal, roughness and
   RGB F0 now gate both nearest categorical history and every bilinear history
   color tap. Similar depth alone cannot authorize color from another surface.
   Rejected taps fall back to current radiance. Valid black hits and zero GGX
   estimator samples retain support. Signed lifetime/depth and packed UV never
   interpolate.

There are no extra rays, enlarged blur kernels, new passes or seventh samplers.
These address sampling/history defects, not screen-space coverage or off-screen
reflections. Native moonlight leakage, thin-occluder march coverage, exposure
normalization and DLL resource integration remain separate unresolved work.

## Layout, cost and tradeoffs

The existing HitInputs and HistoryHit targets become W x 2H RGBA32F atlases.
Top planes retain velocity/hit contracts. HistoryHit's bottom plane holds
current receiver normal.xy, roughness.z and numeric packed RGB8 F0+1.w.
HitInputs snapshots the previous descriptor grid before the late copy overwrites
it. Black F0 is valid (1); zero is invalid. Descriptors are written for valid
receivers even when the reflected ray misses. Reads use exact integer texels.

This adds **32 bytes per render pixel**, about **105.7 MiB at 2560 x 1353**.
Receiver validation OFF does **not** remove the allocation; the fixed layout
avoids stale-layout confusion when toggling. Disabling hit-aware GGX bypasses
helper passes; actual target release remains engine-owned.

Atlas sizing queries the trace PostEffect's render-target size, not display
resolution. Explicit target sizes prevent an oversized doubled-height allocation;
unknown/oversized extents disable the helpers until a valid extent is available.
Extent/validity transitions clear reflection history before publishing constants,
including internal-resolution changes that leave display resolution unchanged.
Shaders reject stale layouts, even with validation OFF, and reject invalid
logical dimensions. Actual upscaler/split-screen scheduling and allocation need
game verification. Logical UV and doubled-height eye-ray mapping have synthetic
GPU checks, not a live multi-view guarantee.

Source validation deliberately bypasses the old rough-source mip atlas: averaged
tiles cannot certify every original texel's surface. Temporal history-color
reconstruction stays available. Thus this can trade rough-surface noise reduction
for less leakage; it is not promised to be universally less noisy. The source
softness slider has no effect on the bypassed path. Existing color passes remain
in the graph for quick reversal.

## In-game comparison (not yet performed)

Both switches default ON for normal rendering and are session-only. Source
validation bypasses frozen audits/convergence. Receiver validation is effective
only in non-frozen playable hit-aware GGX. Both setters reject non-booleans,
reset reflection history only, and do not reset GI or change native settings.
Activity/status is not proof of GPU execution or visual correctness.

With native SSR disabled, reload via one GE Lua console line:

```lua
if beamrt_main then beamrt_main.disable() end; extensions.unload('beamrt_main'); extensions.load('beamrt_main'); if beamrt_main then beamrt_main.start() end
```

Select playable hit-aware GGX with reflections enabled (one line):

```lua
beamrt_main.setReflectionsEnabled(true); beamrt_main.setReflectionSamplingMode('ggx'); beamrt_main.setReflectionReconstruction('playable'); beamrt_main.setReflectionHitAwareEnabled(true)
```

Compare each switch independently at a fixed view/exposure with other filter
knobs unchanged. Allow history to settle after toggling, then test a small camera
pan. Look for bright dots by dark silhouettes, stable fine reflected detail,
rough-surface grain and trailing when surfaces change.

```lua
beamrt_main.setReflectionSourceReconstructionEnabled(false)
```

```lua
beamrt_main.setReflectionSourceReconstructionEnabled(true)
```

```lua
beamrt_main.setReflectionReceiverHistoryEnabled(false)
```

```lua
beamrt_main.setReflectionReceiverHistoryEnabled(true)
```

```lua
dump(beamrt_main.getReflectionQualityState())
```

The tuner exposes both switches. No game test was launched for this change.

## Offline checks

Both standalone fixtures execute real shaders compiled with installed BeamNG
headers on D3D12 textures with readback. FXC uses /Ges /WX /O3; MSVC /W4 /WX.

```powershell
./native/lighting/build_reflection_source_reconstruction.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/lighting/build_reflection_source_reconstruction.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
./native/lighting/build_reflection_receiver_history.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/lighting/build_reflection_receiver_history.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
```

Source checks reproduce the old bright-layer leak (red 25), rejecting it (red 0)
while retaining 0.75 valid-black coverage. Other cases preserve same-plane detail,
sloped surfaces, thin-feature extrema, viewport ownership, differing dimensions,
finite HDR and exact hit metadata. v043 OFF matches v042 in the tested scene.

Receiver checks compare actual v039 OFF/v038 bitwise in equivalent valid layouts,
test normal/roughness/F0 rejection, mixed bilinear ownership, black/zero samples,
exact alpha, atlas plane copying, resets, stale dimensions and eye-ray geometry.
The debug layer was unavailable. These are not debug-layer-clean or live visual,
game-scheduling or performance results.

Verified on 2026-10-19: source fixture **21/21**, receiver fixture **72/72**,
each on RTX 4070 and WARP; selected PostFX strict compilation **48/48**.
The absolute `/mods` traversal check also passed with no skipped paths after
adding the short-path development artifacts.
