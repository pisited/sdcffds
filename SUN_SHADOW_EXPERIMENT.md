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
