# v0.106 — actual underground geometry in native local-light visibility

**Current status:** geometry preparation and the legacy light-pass integration are
implemented and locally tested. Final review found that this installation also
exposes `ClusteredShading`; activation is now blocked until its dispatch/resource
interface is integrated. Do not count this as a working headlight/bleed fix and
do not run the old activation comparison on an unsupported backend.

## What was wrong or missing

BeamRT's prepared GPU scene contained the guardhouse, not the sewer/underground
rooms in the user's latest screenshots. Vehicle light acquisition was already
corrected in v105, but records alone cannot block a light. Native prop lights can
use a no-shadow rendering path, and camera-dependent caster availability can leave
light visible behind solid geometry. The exact native cause of the user's
driving/walking difference and orange spill has not been proven.

## What changed / functionality now implemented

The existing importer/BVH packer now prepares eight private WCU candidate assets:

| Asset | Selected visual node | Triangles | BVH nodes |
| --- | --- | ---: | ---: |
| sewer_01 | s_factory_sewer_01_a1000 | 3981 | 1023 |
| sewer_02 | s_factory_sewer_02_a1000 | 4294 | 1419 |
| sewer_03 | s_factory_sewer_03_a2000 | 10200 | 4095 |
| sewer_04 | s_factory_sewer_04_a2000 | 3981 | 1023 |
| sewer_05 | s_factory_sewer_05_a1000 | 5538 | 2047 |
| sewer_06 | s_factory_sewers_06_a3000 | 8727 | 3117 |
| underground_01 | s_factory_underground_01_a20000 | 10900 | 4095 |
| underground_02 | s_factory_underground_02_a10000 | 8961 | 3585 |

One exact highest-detail visual node is selected per asset. Collision shapes and
other LODs are not unioned into the rendering mesh. Some assets also contain lines;
an explicit importer option records these non-area primitives as excluded from
triangle visibility. Unsupported **surface** primitives still fail rather than
silently dropping geometry. The original importer defaults remain strict.

At enable, one live TSStatic instance is selected by distance to the transformed
mesh bounds (not distance to its object origin). Its native scaled point basis is
captured, inverse transform calculated, data layout validated and live material
declarations acquired. Runtime loads descriptor data rather than constructing
another large CPU triangle/edge preview. Nothing moves the camera or vehicle.
The selected static caster is retained across camera/controlled-vehicle changes;
30-frame stale/opacity checks and mission/unload restore the native paths.

Private copies of the installed native point and spot pixel shaders directly
query the full selected BVH between the native receiver world position and the
native light position. There is **no screen-depth/receiver relay** between the
geometry query and these native light passes. Instance/data/material constants
are set as immutable defines before fresh ShaderData registration. The shader
cache is reused for unchanged datasets; private revisions are bounded.

Only a definite declared-opaque triangle hit removes direct local light. Native
shadowing is retained; the mesh query also applies when the native permutation
has NO_SHADOW. Miss/unknown/invalid/budget cases keep native behavior. Thin/
subsurface receivers and special lightmapping are excluded. Alpha-tested,
blended/custom/unresolved/no-shadow materials are not made solid by guesswork.

Attenuation, cookies, current position/intensity/color, electrics/blinking, direct
specular and retroreflection evaluation remain native. No light-state setters,
brightness clamps, fake lamps or final-image darkening are used. Reflections,
emissive, native sunlight, sky/ambient shading and existing GI remain separate.

Default OFF; not persisted as a graphics preset. Native CustomMaterials are
rebound to new private ShaderData, not mutated cached original shaders. Source
and helper dependencies are checked; existing mod ownership is refused. A failed
second binding rolls back both point and spot materials. Main disable/unload and
extension disable/stale/mission restore original shader references and samplers.
Shader cleanup removes only owned objects. Tuner v106 has the opt-in toggle.

## What remains unverified / unsupported

Live selection of the user's exact underground section, its mesh alignment/active
LOD, material policy, data texture upload, native point/spot binding, visible
blocking, walking/driving consistency and FPS remain unverified in BeamNG. Tests
cannot establish those facts. Camera-independent query code is not evidence that
the live render uses it.

Only ONE imported section contributes additional blockers. Adjacent sections,
terrain and moving vehicles are not newly traced; their native shadow paths stay.
The native light must actually execute a supported deferred point/spot pass. If
a light is culled entirely or uses a separate clustered/forward path, this hook
does not intercept it. It cannot correct a false native shadow by itself.

This batch does NOT fix sky/ambient daytime fill or guarantee that all orange
illumination vanishes: legitimate bounce, emissive/reflections, unsupported
material coverage and existing GI leakage can remain. Avoid interpreting the
night image as exact daytime ground truth. No settings are forced downward.

## Current blocking interface lookup

Installed clusteredQuality.lua configures ClusteredShading, and cluster_shade.cs.hlsl
has its own compute accumulation/shadow atlas and structured-buffer inputs. Its
t14 is already the native shadow atlas, not a free geometry slot. Legacy
AL_Point/Spot CustomMaterial bindings are therefore not evidence of integration
with this alternative renderer. Do not guess a setting, disable the optimized
backend, pad into lossy texture cooking, or modify the native installation.

One bounded read-only metadata lookup is needed because the clustered bindings
are not described in the installed Lua source. It lists names/types only, does
not call getters, and cannot enable an effect or change any rendering state:

```lua
extensions.load("beamrt_meshLocalLights"); dump(beamrt_meshLocalLights.getBackendInfo())
```

The implementation decision is whether a supported Lua shader/resource binding
interface exists. If it does, connect the prepared geometry to that actual
dispatch. If it does not, report the need for an explicitly authorized native
bridge rather than asking for more shadow screenshots. This is a new specific
interface blocker, not another guardhouse/day-night rendering diagnostic.

## Legacy-only normal-render activation (not for the current exposed clustered backend)

The private files are already prepared on this PC. While at the demonstrated
WCU underground location, use GE Lua:

```lua
extensions.load("beamrt_meshLocalLights"); dump(beamrt_meshLocalLights.enable())
```

No old guardhouse alignment test, wire view, photo audit or exposure change is
needed. Expected: the log names an actual nearby sewer/underground mesh and its
triangle/material counts; normal rendering stays visible. With an opaque concrete
wall blocking a native headlight/local-light path, its direct illumination beyond
that wall should be reduced even after switching between car and walk mode.
Compare/restore using `beamrt_meshLocalLights.disable()` (or the tuner toggle).

If enable fails, inspect its specific error/current log before another test.
If enabled but unchanged, inspect the actual selected asset, material coverage and
native lighting path—not more random ray/filter settings. `enabled=true` remains
CPU configuration only. This is validation of a complete new integration slice,
not a third repetition of the old sunlight-control hypothesis.

## Next substantial milestone

Correct any concrete live local-light integration fault, then add adjoining
instances/alpha-aware coverage and sky/ambient visibility for the same underground
space. Use that scene for GI visibility too, preserving native fallback and real
light/bounce reaching it through openings. Do not declare the indoor-lighting goal
complete from this batch.

## Verification and portable preparation

11 actual-Lua selector/binding/lifecycle/backend-refusal tests and 4 importer/source-contract tests
pass, plus retained 25 GI/motion and 14 alignment tests. Strict FXC compiles 24
native local-light permutations with the largest real descriptor sizes: native
shadow/no-shadow, cookies, forward/reversed depth and point cube-map variants.
Native Lua51/LuaJIT/Lua55 compile checks pass. The compile review found a collision
with the native `bias` macro; renaming our parameter fixes that without changing
the native macro or tracing math. No runtime rendering/performance proof follows.
GI083/mesh002 also recompile strictly after that parameter rename.

Game geometry/generated native source remain Git-ignored private data. Another
installation or game update must prepare its own compatible files:

```powershell
python tools/beamrt_underground_prepare.py --game-root "E:\SteamLibrary\steamapps\common\BeamNG.drive"
```

No assistant Git pull/commit/push, native installation edits, cache deletion,
vehicle respawn or control-setting changes were performed.
