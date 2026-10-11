# v0.105: mode-independent light acquisition and cache-safe shader installation

## Wrong or missing

The user's latest comparison changes between controlling the car and walk mode,
not merely camera direction. The orange illumination is a separate local-light/GI
visibility symptom. Neither screenshot proves the precise native-engine cause.
Installed cameraUpdate.lua changes sun cascade distance and interior SSAO by camera
mode; these are not evidence that it controls headlight shadow casting.

BeamRT's vehicle-light provider had a genuine acquisition defect: default collection
followed only `be:getPlayerVehicleID(0)`. Walk mode can select the unicycle avatar,
so the real car's prop lights disappeared from that snapshot. These records were
not yet feeding GPU visibility; fixing them cannot be counted as fixing native
headlight shadows.

Native jbeam/sections/meshs.lua constructs prop lights with
`lightCastShadows or false`. Native point/spot shaders also support NO_SHADOW.
These establish an unshadowed-light path, not proof that the orange emitter uses
it. Live intensity, exact emitter identity, shader execution and wall occlusion
remain unresolved. Vehicle props.updateGFX continuously manages light emission;
do not blindly reapply full setLightArgs with declared brightness/color, which
could turn off lights on or corrupt blinking/braking state.

The previous sun installation changed a filename on an already-cached ShaderData.
The [upstream implementation](https://raw.githubusercontent.com/TorqueGameEngines/Torque3D/development/Engine/source/materials/shaderData.cpp)
caches programs by shader macros, and reload() reloads those instances rather than
necessarily constructing programs from newly assigned filenames. BeamNG's fork
is not proven identical, but relying on that swap was unsafe. The unshadowed
control also depended on the mesh receiver relay, so bad relay data silently
preserved native shadows and made the control inconclusive.

## Changed / implemented

- Default vehicle-light acquisition now covers the nearest eight vehicles within
  80 m of the camera, independently of which vehicle/avatar is controlled.
  Explicit vehicle queries and includeVehicleLights=false retain their scope.
  Radius/cap limits, incomplete/capped selection and compatibility player fallback
  are reported; fallback is not advertised as mode-independent. World-light native
  wrappers use their ___type tag as well as the legacy class API. No rendering or
  light-state setters are called. Native constructor defaults are represented as
  declarations, not claimed current brightness or verified active emitters.
- The sun extension creates fresh, uniquely named ShaderData objects with the
  generated source paths and native vertex/define/sampler configuration assigned
  before registration. It rebinds AL_VectorLightMaterial's shader reference and
  reloads that material. The original ShaderData/compiled cache is never edited.
  All comparison modes use separate private shader objects. Disable/stale/mission/
  failure/unload restore the original material shader and sampler, preserve foreign
  changes, and remove only owned objects.
- Explicit unshadowed mode no longer depends on the mesh texture/receiver test.
  Hybrid/BeamRT-only/split retain those safety guards. Cloud lighting remains;
  transmitting receivers and separate forward/local-light paths are unchanged.
  This is a bounded control fix, not a new debug shader family or graphics preset.

## What is NOT implemented or verified

These changes do not yet fix the orange bleed, native driving/walking headlight
behavior, daytime sewer ambient fill or complete tunnel visibility. Nearby light
data still reports feedsRayTracer=false and live emission state unverified. The
only prepared GPU mesh remains the guardhouse, with two supported opaque material
identities; sewer geometry and alpha cutouts are not yet connected. The failed
sun shadow/isolation checks remain negative runtime evidence, not erased by v105.

The 256x28 PNG warning says texture cooking is skipped, not that the GPU resource
was proven rejected. Do not blindly pad it into a cookable/lossy texture: packed
BVH bytes must remain exact. GPU uptake and the receiver relay remain unverified.

## Local verification

8 actual-Lua acquisition tests preserve car lights on avatar switch, bound selection,
explicit/disabled scope, native wrapper support, removal/fallback and model/world
positions without mutating light state. 13 sun-control tests include a modeled
cached-program path, fresh-shader binding and restoration. Retained 25 GI/motion
integration and 5 source-generator tests pass. Native Lua51/JIT55 compilation and
32 native pixel permutations compile strictly. This is not in-game rendering proof.

## Next substantial milestone

Import one actual sewer/underground section and connect its world visibility to
local lights and sky/ambient lighting. Keep native/default paths for unsupported
geometry/materials; preserve legitimate light and bounce through openings. WCU's
s_steel_factory_sewer_01 through _06 and _underground_01/_02 are candidate assets,
not yet matched to the user's exact live section. No further guardhouse/photo/
day-night diagnostic round is requested now. Native renderer results must be
validated only after a complete new integration slice, not more acquisition tests.

User handles Git updates. No assistant pull/commit/push or installation modification.
