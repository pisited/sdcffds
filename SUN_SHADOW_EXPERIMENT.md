# BeamRT independent sun shadow tracer v001 (experimental)

This is a **standalone, diagnostic-only** visibility pass for BeamRT v0.102.
It lives on `experiment/sun-shadow-tracer-v0102`, separate from the
older sun-contact experiment PR. It does not overwrite BeamRT's `main.lua`,
does not change GI illumination, and never darkens the beauty image unless
the user explicitly enables the debug preview.

## Inputs and output

- Uses the existing `#prepass[RT0]` normals, `#prepass[Depth]` geometry depth,
  and BeamNG's engine-bound `sunDirection`.
- `#BeamRT_SunShadowVisibility` is an R16G16B16A16F target:
  - R = traced directional visibility (0 = hit occluder, 1 = no hit)
  - G = view-path coverage/confidence (0 = immediately off-screen/invalid,
    1 = ray traversed fully, or found an intersection)
  - B = surface N dot L
  - A = opaque surface validity (0 = no receiver, 1 = receiver)
- The debug viewer also reads native `#sunShadowMask[RT0]` for comparison.
- The shader **cannot detect invisible/off-screen occluders**. Unknown rays
  currently output R=1 but G below 1. Never blindly treat R as complete
  sunlight visibility without considering G or native fallbacks.
- Does not replace BeamNG's direct-light contribution.
- Not yet a full physically based shadow renderer. Cinematic changes the
  step count and search distance; soft-sun angular sampling, reprojection,
  and spatiotemporal filtering are future work.

## Activate after checking out the branch

```powershell
git fetch origin
git switch experiment/sun-shadow-tracer-v0102
```

Load in GE Lua console:

```lua
extensions.load("beamrt_shadowRenderer")
beamrt_shadowRenderer.setQuality("playable")
beamrt_shadowRenderer.enable()
beamrt_shadowRenderer.setView("identity")
```

**Expected:** obvious magenta full-screen. If unchanged, inspect beamng.log
for shader compile errors or missing named textures.

Then run the diagnostic batch, collecting images of the same camera view:

```lua
beamrt_shadowRenderer.setView("sun")
beamrt_shadowRenderer.setView("classification")
beamrt_shadowRenderer.setView("native")
beamrt_shadowRenderer.setView("difference")
```

Each command changes the current preview. Take a screenshot for each view.

- `sun`: encoded normalized sun vector; should change with time of day.
- `classification`: red = our ray found a blocker, green = no hit with
  coverage, blue = uncertain/incomplete ray. View edge blues are expected.
- `native`: existing BeamNG mask only; its exact semantics must still be
  validated in the current engine build.
- `difference`: red = BeamNG says brighter than ours; green = ours
  says brighter than BeamNG; disagreements are not automatically bugs.

### Quality options

```lua
beamrt_shadowRenderer.setQuality("playable") -- half res, 24 steps, 18m
beamrt_shadowRenderer.setQuality("cinematic") -- full res, 96 steps, 55m
```

Cinematic is expensive. It is not recommended at 4K until measured.

To keep the shadow target running but hide the preview:

```lua
beamrt_shadowRenderer.setView("off")
```

To disable all shadow tracing:

```lua
beamrt_shadowRenderer.disable()
```

To reload code (HLSL compilation may require a restart/cache refresh):

```lua
extensions.unload("beamrt_shadowRenderer")
extensions.load("beamrt_shadowRenderer")
```

Check object and state:

```lua
dump(beamrt_shadowRenderer.getStatus())
```

## Development order

1. Confirm shader identity and sun-direction auto-binding.
2. Confirm our mask follows visible geometry and the sun orientation.
3. Measure false contacts, depth errors, and view-edge uncertainty.
4. Add confidence-aware temporal filtering, geometry-proxy fallback,
   and multiple sun-angle rays where practical.
5. **Only then** use the visibility buffer for shadow replacement or
   irradiance sampling at GI hit points.

This test preserves the existing GI, GGX, and lighting composer untouched.

## Live split-screen diagnostic (preview v003)

No extra render pass is required. Both halves are composited from the **same
frame** using the existing shadow target, native sun mask, and backbuffer.

```lua
beamrt_shadowRenderer.compare("classification", "difference", 0.5)
beamrt_shadowRenderer.compare("beamrt", "native", 0.5)
beamrt_shadowRenderer.compare("scene", "classification", 0.5)
```

`compare(left, right, position)` enables the shadow renderer if needed, then
activates split mode. Position is optional and defaults to the saved position
(initially 0.5). You can change views and divider settings live:

```lua
beamrt_shadowRenderer.setSplitLeft("scene")
beamrt_shadowRenderer.setSplitRight("native")
beamrt_shadowRenderer.setSplitPosition(0.35)        -- 35% from viewport left
beamrt_shadowRenderer.setSplitLineWidth(3.0)        -- pixels; 0 to hide
beamrt_shadowRenderer.setSplitLineColor(1,1,0,1)   -- yellow RGBA 0..1
beamrt_shadowRenderer.setSplitEnabled(false)       -- restore prior normal view
```

Other selectable sides: `visibility`, `coverage`, `incidence`, `sun`,
`identity`. `beamrt` aliases `visibility`; neither `off` nor `split`
is valid as one of the two split inputs. If any argument is invalid, the
setter returns false without changing the split selection.

`beamrt_shadowRenderer.setView("split")` enables the saved split pair,
whereas `setView("classification")` or any other ordinary view exits split
mode. `setView("off")` hides the entire preview without stopping shadow
tracing. `getStatus().split` reports the current selections and divider.

A side displaying `scene` returns the existing native/BeamRT-composited
backbuffer, **not** a separately preserved original render if other BeamRT
effects have already modified the scene. These diagnostic comparisons do not
change any shadow or GI illumination.

### Split review checklist
- Try `compare("scene","classification",0.5)` first to confirm the divider
  and both sides update when moving the camera.
- Then `compare("beamrt","native",0.5)`, keeping the camera stationary.
- Finally `compare("classification","difference",0.5)`.
- Do not treat differences as proof that either renderer is more physically
  correct until the native sun mask encoding and ray confidence are verified.

## Shadow intersection accuracy A/B (trace v005)

The v005 tracer adds a refined front-to-back depth-crossing search, while
preserving the v004 coarse intersection rule as a live selectable baseline.
The **same texture inputs, ray budgets, bias, resolution, and distances** are
used in both modes. The default on extension load is `refined`.

```lua
beamrt_shadowRenderer.setHitModel("legacy")  -- previous v004 intersections
beamrt_shadowRenderer.setHitModel("refined") -- depth-bracket binary refinement
```

To inspect results in the same scene without changing the split debugger:

```lua
beamrt_shadowRenderer.compare("scene", "classification", 0.5)
beamrt_shadowRenderer.setHitModel("legacy")
-- inspect/save screenshot with camera stationary
beamrt_shadowRenderer.setHitModel("refined")
-- inspect/save the same view again
```

Or compare the calculated mask against BeamNG's native buffer:

```lua
beamrt_shadowRenderer.compare("beamrt", "native", 0.5)
beamrt_shadowRenderer.setHitModel("refined")
```

**Important:** This is an A/B *toggle*, not simultaneous baseline/refined GPU
passes. The split comparison shows the currently selected tracing algorithm
against a different view or native mask in the same frame. The only way to
compare old/new algorithms is to switch models while the scene stays fixed.

- `refined` bisects a front-to-back crossing (three steps in Playable,
  five steps in Cinematic), rejecting missing-depth intervals and checking
  the final depth agreement rather than trusting only the coarse sample.
- `legacy` uses the original v004 acceptance check unchanged.
- This still does **not** solve off-screen shadow casters, alpha-tested foliage,
  perspective undersampling of chain-link geometry, or native shadow-mask
  semantic uncertainty.
- Refinement costs more depth samples on candidate hits. Actual GPU runtime
  performance and HLSL shader compilation must be tested in BeamNG before
  merging.
- `getStatus().hitModel` identifies the current method.


## Depth-neighborhood validation (trace v006, experimental)

`setHitModel` now supports a third mode:

```lua
beamrt_shadowRenderer.setHitModel("legacy")    -- v004 coarse hit rule
beamrt_shadowRenderer.setHitModel("refined")   -- v005 depth-bisection rule
beamrt_shadowRenderer.setHitModel("validated") -- v006 depth-coherence check
```

The **default after extension load is validated**. No GI or final-lighting
composition is modified. In validated mode, a candidate that already passed
refined hit-depth checks samples the depth buffer at four adjacent screen
locations. Two or more neighbors with similar depth certify the obstruction
as *more supported* (solid red in classification). A candidate with one
agreeing neighbor remains visible, but low-confidence (red plus blue appears
purple). An isolated candidate is treated as **uncertain**, not as a confirmed
occlusion or definitively sunlit. The coverage/confidence channel (G) reflects
that uncertainty, and the current debug view highlights it with blue.

This does not provide a definitive test for thin geometry: an isolated valid
fence wire can have no supporting neighbors, so it may become *unknown* instead
of red. Conversely, multiple agreeing depth samples do not prove correct
3D occlusion. Use the existing split-screen debugger and toggle modes with a
stationary camera before judging fidelity. The four extra depth samples happen
only at candidate intersections in validated mode.

Suggested initial test:

```lua
beamrt_shadowRenderer.setQuality("cinematic")
beamrt_shadowRenderer.compare("scene", "classification", 0.5)
beamrt_shadowRenderer.setHitModel("refined")   -- screenshot
beamrt_shadowRenderer.setHitModel("validated") -- same view, screenshot
dump(beamrt_shadowRenderer.getStatus())
```

Avoid integrating this shadow target into lighting/GI until its screen-space
confidence, thin-geometry behavior, and native-mask interpretation have been
validated in-game. It still cannot trace hidden/off-screen shadow casters.

## Geometric self-shadow rejection (trace v007)

The **optional** `geometric` hit model specifically tests a case that v006
depth-neighborhood validation cannot distinguish: the ray may re-intersect
the receiver's own continuous surface (road, sidewalk, wall), producing a
solid red false shadow even though adjacent depth pixels agree.

```lua
beamrt_shadowRenderer.setHitModel("validated") -- v006 baseline
beamrt_shadowRenderer.setHitModel("geometric") -- v007 plane-aware checks
```

The new mode reconstructs the candidate caster's eye-relative position and
G-buffer normal. If its normal closely matches the receiver's and its
position is almost coplanar with the receiver, the candidate is rejected as
an unreliable same-surface intersection. Unverified hits reduce coverage
confidence rather than being described as fully sunlit. The mode also uses
a wider 1.5-screen-pixel neighborhood radius to avoid checking the same
point-sampled depth texel repeatedly; the old validated mode retains its
original behavior for A/B comparison.

This is still a screen-space *heuristic*, not proof of separate mesh identity.
It may reject a genuinely close, parallel caster; it cannot discover geometry
missing from the camera depth buffer. Treat remaining red as candidate shadow
hits, not yet trustworthy enough for GI.

Quick same-camera comparison:

```lua
beamrt_shadowRenderer.setQuality("cinematic")
beamrt_shadowRenderer.compare("scene", "classification", 0.5)
beamrt_shadowRenderer.setHitModel("validated") -- screenshot 1
beamrt_shadowRenderer.setHitModel("geometric") -- screenshot 2
```

The default after reload remains `validated`; the new model is opt-in.
Its shader must still compile and be visually checked in BeamNG.


## True hit-model A/B split-screen (preview v004)

You can compare **two different tracing algorithms in the same frame**.
Unlike `compare("scene","classification")`, which presents two
visualizations of one result, `compareModels` creates a second full-frame
shadow trace target with its own `shadowHitModel` shader constant.

```lua
beamrt_shadowRenderer.compareModels("validated", "refined", 0.5)
-- equivalent:
beamrt_shadowRenderer.compare("validated", "refined", 0.5)
```

- Left half shows the **validated** algorithm, right half **refined**.
- The dividing line is still movable with `setSplitPosition(0.35)`.
- The scene, camera, resolution, ray budget and sample distance are shared.
- Both algorithms run against the same prepass in the same frame, so the
  moving divider compares matching pixels rather than different screenshots.
- Default model display is `classification`, matching the previous red/
  green/blue/gray legend. Both sides use the same legend.

```lua
beamrt_shadowRenderer.setModelSplitLeft("geometric")
beamrt_shadowRenderer.setModelSplitRight("legacy")
beamrt_shadowRenderer.setModelSplitView("visibility")    -- grayscale, 1=lit
beamrt_shadowRenderer.setModelSplitView("coverage")      -- confidence only
beamrt_shadowRenderer.setModelSplitView("incidence")     -- N dot L
beamrt_shadowRenderer.setModelSplitView("classification")
beamrt_shadowRenderer.setModelSplitView("difference")    -- red=left-only hit,
                                                       -- green=right-only hit
```

All four hit models (`legacy`, `refined`, `validated`, `geometric`) may
be used on either side. `difference` is a full-frame comparison map, with
the vertical divider retained for consistency. Mismatches are confidence
weighted and do not necessarily establish which result is correct.

To return to inexpensive, single-tracer comparisons:

```lua
beamrt_shadowRenderer.compare("scene", "classification", 0.5)
-- or:
beamrt_shadowRenderer.setSplitEnabled(false)
```

The second post effect (`BeamRT_SunShadowCompareFx`) is only enabled while a
model-vs-model split is active. The normal single-view `setHitModel(...)`
continues to control non-model comparisons and is not overwritten by changing
the A/B pair. The `getStatus()` result includes `compareTraceEnabled` and
`split.modelLeft`, `split.modelRight`, `split.modelView`.

**Performance:** true A/B rendering involves two separate full-frame screen-
space shadow traces; expect substantially more GPU work than single-tracer
view splits. Cinematic (96-step full-resolution) is particularly expensive.
Use Playable while moving the camera, then Cinematic for static inspection.

This is experimental GitHub code and still requires a shader compilation and
render-order test inside BeamNG. No changes to production lighting/GI.

## Unweighted model disagreement (preview v005)

The original model-split `difference` view multiplies differences by BOTH
tracers' coverage confidence and surface incidence. A black pixel may mean
"same result" or "not trustworthy enough to show."

Use **rawdifference** to compare raw shadow visibility R values without that
confidence suppression:

```lua
beamrt_shadowRenderer.compareModels("validated", "refined", 0.5)
beamrt_shadowRenderer.setModelSplitView("rawdifference")
```

- **Black:** both tracers returned the same 0/1 visibility value.
- **Red:** left model reports occlusion, right model does not.
- **Green:** right model reports occlusion, left model does not.
- All red/green locations include **low-confidence or invalid receivers**:
  do not treat raw disagreements as verified shadows.
- Switch back with `setModelSplitView("difference")` to suppress untrusted
  pixels, or `setModelSplitView("coverage")` to inspect confidence on each
  side of the divider.
- Both algorithms are still executed on independent full-frame targets, and
  rawdifference does not change any shading/geometry/tracing logic.

If rawdifference is also largely black while both classification views share
the same false red patches, the cause probably lies in their common underlying
sun-ray/depth reconstruction or the limitations of screen-space geometry,
not the later validation filters.

## Independent model-pass proof (trace v008 + preview v006)

If raw visibility difference is entirely black, first establish that the
comparison target and shader constants are independent. The model-ID view
temporarily bypasses ray tracing and outputs a constant for each hit model:
legacy = 0.125, refined = 0.375, validated = 0.625, geometric = 0.875.

```lua
beamrt_shadowRenderer.compareModels("validated", "refined", 0.5)
beamrt_shadowRenderer.setModelSplitView("modelid")
```

**Expected:** a noticeably lighter gray on the LEFT than the RIGHT.
The split divider is still visible. Switching either model immediately changes
only its assigned half:

```lua
beamrt_shadowRenderer.setModelSplitLeft("legacy")
beamrt_shadowRenderer.setModelSplitRight("geometric")
```

If left and right remain the same shade, or either side is black, investigate
post-effect scheduling, per-instance shader constants, named-target sampling,
and callbacks before treating rawdifference as evidence the algorithms agree.
The comparison PostEffect now registers its own shader-constant callback.

To resume actual tracing, switch back:

```lua
beamrt_shadowRenderer.setModelSplitView("rawdifference")
-- or:
beamrt_shadowRenderer.setModelSplitView("classification")
```

`modelid` is an intentionally synthetic infrastructure test; the output is
not a real visibility buffer while that view is selected. The special mode
only runs when a model-vs-model split is active. It neither alters GI nor
production renderer settings, and normal tracing resumes as soon as the
model-ID view is exited.


## Ray-hit telemetry and self-intersection diagnostics (trace v009, preview v007)

The shadow renderer can now measure **where accepted ray hits occur** instead
of repeatedly changing the hit-validation heuristics. These are explicitly
selected diagnostic modes and never replace ordinary lighting/GI outputs.
The usual tracer R/G/B/A channels are restored immediately upon returning to
`classification`, `visibility`, or another standard view.

In GE Lua:

```lua
beamrt_shadowRenderer.setQuality("cinematic")
beamrt_shadowRenderer.setHitModel("validated")
beamrt_shadowRenderer.compare("scene", "hitdistance", 0.5)
beamrt_shadowRenderer.compare("scene", "deptherror", 0.5)
beamrt_shadowRenderer.compare("scene", "selfplane", 0.5)
```

Or compare **two distinct tracing algorithms** with the same measurements:

```lua
beamrt_shadowRenderer.compareModels("validated", "refined", 0.5)
beamrt_shadowRenderer.setModelSplitView("hitdistance")
beamrt_shadowRenderer.setModelSplitView("deptherror")
beamrt_shadowRenderer.setModelSplitView("selfplane")
beamrt_shadowRenderer.setModelSplitView("classification") -- normal shadows
```

Interpretation:
- **hitdistance**: red = short ray travel to accepted caster, green/cyan =
  farther along the ray, scaled by the chosen quality's maximum ray reach
  (18 m Playable, 55 m Cinematic). The stored R channel is travel divided
  by ray reach, not the world-space XYZ coordinates.
- **deptherror**: green = small residual between projected ray depth and
  camera depth, red = residual approaching the permitted thickness at the
  accepted intersection. The stored G channel is `abs(residual)/tolerance`,
  clamped to 0..1, *not* a world-space distance by itself.
- **selfplane**: red = candidate caster is nearly coplanar with receiver
  and their normals agree, green = measurable separation or distinct normals.
  The stored B channel is the plane offset divided by 0.25 metres when the
  normals align (otherwise 1). Red areas suggest possible self-shadowing,
  not proof that the caster and receiver are the same mesh.
- Black = no accepted hit; dim purple tint = low-confidence candidate hit.
  Diagnostics do not show *rejected* intersections and cannot determine
  whether geometry beyond the camera view is occluded.

When telemetry is active, R/G/B/A of the private shadow target are
temporarily reinterpreted as **hit travel**, **depth residual**,
**receiver-plane separation**, and **hit status**, respectively. For this
reason, comparing a standard classification and a telemetry mode in the same
single-trace split is disallowed (except pairing telemetry with `scene`).
Two telemetry views may share one split, and model-vs-model splits use both
traces with the *same* requested telemetry layout. The existing
`modelid` test remains available.

All telemetry adds G-buffer reads **only for accepted/candidate hits while
enabled**, so normal rendering keeps its existing measurement-free tracing.
For diagnostic fidelity, use Cinematic while stationary, but avoid treating
these debug views as a trustworthy, fully ray-traced shadow map.
`getStatus().traceDiagnostic` is 0 (visibility), 1 (model ID), or
2 (hit telemetry). To return to regular visualization:

```lua
beamrt_shadowRenderer.compare("scene", "classification", 0.5)
-- or in model A/B:
beamrt_shadowRenderer.setModelSplitView("classification")
```


## Native fallback / hybrid shadow diagnostics (preview v009)

**Experimental, debug-only.** The screen-space tracer cannot see casters outside
the camera depth buffer. The new `hybrid` family uses native
`#sunShadowMask[RT0]` as the base and allows BeamRT to add **only**
confidence-gated occlusion. Uncertain/off-screen/no-receiver rays do not
erase native shadows. Nothing in this change modifies BeamRT's production GI,
lighting composer, or the game's underlying shadow-map generation.

To activate in the GE Lua console:

```lua
beamrt_shadowRenderer.setQuality("playable")
beamrt_shadowRenderer.setHitModel("validated")
beamrt_shadowRenderer.compare("scene", "hybridscene", 0.5)
```

`hybridscene` (view 16) previews the *already native-shadowed* backbuffer,
with up to 35% extra darkness where the BeamRT ray hits confidently and the
native mask reports sunlight. It NEVER multiplies the native shadow mask into
the scene a second time. When the BeamRT ray cannot see off-screen casters,
this returns the unmodified scene, retaining whatever shadows BeamNG rendered.
This visual enhancement is not a tested production composite and should be
turned off when not debugging.

For mask-level inspection:

```lua
beamrt_shadowRenderer.compare("native", "hybrid", 0.5)
beamrt_shadowRenderer.compare("scene", "hybridweight", 0.5)
beamrt_shadowRenderer.compare("scene", "hybridsource", 0.5)
```

- `native` shows raw native mask R (not inverted by hybrid controls).
- `hybrid` shows native-preserving hybrid visibility, grayscale.
- `hybridweight` shows eligibility for extra screen-space occlusion, grayscale.
- `hybridsource` shows red for BeamRT's detail contribution, green for native
  visibility retained, black where both are low. This is an explanatory
  source map, not an accurate partition of direct vs indirect lighting.
- `hybridscene` shows the native-rendered scene plus confidence-gated
  additional contact/detail darkening **only in preview**.

Native mask R polarity and its actual format/temporal validity have NOT been
verified. Treat these as provisional screen-space diagnostics and test both
interpretations against an obvious moving shadow before accepting one.

```lua
beamrt_shadowRenderer.setHybridNativePolarity("normal")   -- R=1 lit, R=0 shadow
beamrt_shadowRenderer.setHybridNativePolarity("inverted") -- R=0 lit, R=1 shadow
beamrt_shadowRenderer.setHybridMinConfidence(0.95)       -- 0..0.999, default .95
beamrt_shadowRenderer.setHybridDetailStrength(0.35)      -- 0..1, default .35
dump(beamrt_shadowRenderer.getStatus())
```

The hybrid formula assumes a visible receiver and an accepted screen-space
occlusion (`R=0`, sufficient `G`, `N.L>0`), and uses
`nativeVisibility * (1 - strength * eligible)`. It **never increases**
native mask visibility, so a disappearing screen-space caster does not
erase the native fallback. G is only *path coverage*, not a reliable
probabilistic confidence, so this is deliberately conservative and should
not yet feed lighting/GI.

`hybridscene` darkens only by `strength * eligible * nativeVisibility`,
rather than multiplying the already-shadowed scene by native visibility.
That avoids deterministic double-shadowing of native occlusion, but falsely
accepted BeamRT hits may still produce extra dark regions. The strength
parameter limits their visual effect.

To return to unmodified scene/debug:

```lua
beamrt_shadowRenderer.setView("off")          -- hide preview, keep trace
beamrt_shadowRenderer.disable()               -- disable trace and preview
```

**Performance:** native fallback by itself does NOT reduce ray tracing cost.
The same shadow trace still runs. A future optimization could gate tracing
on native coverage after verifying mask semantics, timing, target availability
and a true early-out. Prematurely skipping rays may miss the chain-link/fine
detail we are trying to retain.
