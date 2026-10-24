# BeamRT v0.104: one-mesh native sunlight integration

## What was missing

The real guardhouse BVH supplied a classification preview and an opt-in world-GI
segment guard, but not actual direct sunlight shadows. Multiplying that mask into
finished scene color would also darken environment reflections, emissive surfaces,
local lights and indirect lighting. It would not be a selective shadow renderer.

## What changed and what is implemented

A deterministic, full-native-resolution three-input visibility pass now runs at
`PFXBeforeBin / AL_LightBin`, before native sunlight shading. It uses the shared
776-face/255-node BVH, captured instance transform and live material declarations.
It traces toward the sun over a bounded 200 m segment, independent of caster
screen coverage. There are no random rays, temporal accumulation or new filters.

The installed vector-light shader is copied into a **private generated mod file**.
The generator changes just the visibility expression before direct diffuse and
direct specular evaluation. A new material sampler at t14 reads the mesh result.
Native shadow-mask/cloud/screen-shadow factors stay intact: the combined visibility
is the minimum, never an attempt to subtract finished lighting. Subsurface receiver
shading is excluded. Local lights, emissive and environment-specular shading are
not patched. This is a native deferred sunlight integration, not forward/mirror or
map-wide coverage and not replacement of BeamNG's complete shadow system.

Only declared-opaque hits block. Unknown/masked/blended materials, explicit native
`castShadows=false`, invalid textures and traversal exhaustion retain native
lighting. Receiver-world-position and resolution checks reject mismatched/stale
main-camera results in reflection captures. The missing-resource zero value is
not a blocked sentinel. A separate R32G32B32A32F target avoids world-position
precision loss (about 52.9 MiB at 2560x1353, plus bandwidth; cost unmeasured).

Default is OFF. Enable validates native source/dependencies and generated source,
refuses another mod's active sunlight shader/sampler, and reloads only the selected
ShaderData/material. Disable, mission change, stale geometry, loss of opaque
materials and unload restore the original shader/sampler. It never changes native
files, clears shader caches, adjusts the camera/time/vehicle or adds a fake light.
Existing GI/SSR algorithms remain unchanged. Tuner v0.104 has an opt-in sun toggle;
the setting is not persisted as a preset. Main disable/unload also restores native
sunlight. Previously loaded material-policy records are supported without repeating
the completed alignment test or losing its camera snapshot.

## One in-game verification, not another diagnostic

Use **daytime with a sunlit receiver beside the guardhouse**. Nighttime has almost
no direct sunlight to shadow; the module deliberately does not create illumination.
Do not repeat the wireframe check. Activate normal rendering in GE Lua:

```lua
extensions.load("beamrt_meshSunShadow"); dump(beamrt_meshSunShadow.enable())
```

Expected: normal scene, enabled status and 776 triangles; no colored intersection
view. Additional definite blockers may extend native shadows where the native mask
misses them. Already-correct native shadows need not visibly change. Rotate so the
guardhouse itself leaves the frame while keeping its shadowed receiver visible.
The shadow should remain attached to the world, not disappear with the caster.

Compare/restore with `beamrt_meshSunShadow.disable()` (or the new tuner toggle).
This verifies the **actual shader binding, pre-light scheduling and retained shadow**
that offline checks cannot establish. If enable fails or the effect is absent,
inspect the existing log/status first; do not restart alignment or add another
generic probe. `enabled=true` alone is CPU configuration, not GPU/visual proof.

## Unverified and next substantial milestone

The native runtime's shader reload, new named-target binding, pre-light pass order,
receiver-position agreement, visible shadows, reflection-capture fallback and FPS
are unverified in BeamNG. Shadow edges are initially hard and may expose geometric
normal-bias/LOD limitations. Alpha textures, glass, multiple instances, dynamic
vehicles and forward rendering are not implemented. Do not call persistent shadows
proven until the ordinary rendered comparison above succeeds.

Next: correct any concrete live integration failure, then extend the same shared
geometry to more instances and alpha-tested casters, and validate GI light visibility.
Do not replace the working screen GI/SSR pipeline or start a large GI rewrite.

## Verification and portable preparation

9 actual-Lua sunlight-control tests cover lifecycle, rollback, source conflicts,
material fallback and native ownership. 4 standard-library generator tests cover
source preservation, stage placement, unsupported layouts and installation safety.
Existing 25 GI/motion integration and 5 BVH control tests, plus 23 extraction/packing
tests, pass. Native Lua5.1/LuaJIT/Lua5.5 compilation passes. Strict FXC compiles the
visibility VS/PS and eight supported native pixel permutations (shadow/no-shadow,
SSAO and screen-space shadows). No GPU or performance claim follows from this.

The generated native source and game mesh are Git-ignored private data. They are
prepared locally here; after installing on another PC or a game update, prepare
against that PC's installation before enabling:

```powershell
python tools/beamrt_native_sun_hook.py --game-root "E:\SteamLibrary\steamapps\common\BeamNG.drive"
```

Upstream [ShaderData reload documentation](https://reference.torque3d.org/scripting/class/classshaderdata/)
supports the targeted reload approach; this fork's actual runtime behavior remains
the in-game gate. Native bindings and shader composition were inspected in the
installed BeamNG Lua/shader files, not inferred from that upstream documentation.
No assistant Git pull/commit/push or installation modification was performed.

### First live activation: material-wrapper blocker fixed

The user's console showed 776 faces prepared but all eight material identities
rejected as "nonstandard", leaving opaque=0. The sunlight hook correctly stayed
disabled. Installed `editor/materialEditor.lua` and `editor/api/material.lua` identify
native LuaIntf material wrappers with `___type == "class<Material>"`, not the
SimObject `getClassName()` method assumed by our policy. The policy now uses that
native tag first, preserves a legacy fallback when no wrapper tag exists, and
never allows a CustomMaterial tag to bypass safety. Incomplete opacity reasons now
report the actual missing declarations. Six actual-Lua policy fixtures plus the
retained 9 sunlight/25 GI-motion tests pass; runtime opacity and GPU execution are
still unverified. This is a type/API fix, not permission to make all faces opaque.

The failed run cached the old policy. Reload only its dependent extensions once,
without unloading meshAlignment or repeating the wire/camera test:

```lua
extensions.unload("beamrt_meshSunShadow"); extensions.unload("beamrt_meshBVH"); package.loaded["ge/extensions/beamrt/meshMaterialPolicy"]=nil; extensions.load("beamrt_meshSunShadow"); dump(beamrt_meshSunShadow.enable())
```

Expected: normal material classification rather than eight blanket nonstandard
rejections. If enabled, proceed with the existing normal shadow/off-screen check;
if it fails, use the specific existing error to fix the next real integration
blocker, not another alignment diagnostic.

### Native-shadow isolation and the indoor-lighting objective

User requested native shadows disabled because they already hide whether BeamRT
casts any additional exterior shadow. Added temporary direct-sun comparison modes:

| Mode | Deferred direct-sun geometry visibility |
| --- | --- |
| `hybrid` | Normal native shadows combined with definite BeamRT blockers |
| `beamrt-only` | Native geometric sun shadows bypassed; only imported opaque BeamRT casters |
| `split` | Left native shadows, right BeamRT-only, same frame/camera |
| `unshadowed` | Direct sun without geometric shadowing, explicit wiring control |

Cloud transmittance, ambient/IBL, local-light shadows, emissive and reflections stay
native. This is not a global graphics-settings change and does not claim to disable
every shadow path, forward/translucent receiver, or dynamic-reflection capture.
Receiver mismatch, invalid/stale data and unsupported transmission retain native
fallback even in isolation. Only two observed guardhouse materials currently qualify;
cutout/translucent geometry is not made opaque to produce an impressive test image.

The existing tuner has comparison/restore buttons. Its standalone old
shadowRenderer scene/worldboxprobe comparison is retained, but it cannot isolate
the native-before-shading sunlight contribution using a finished backbuffer.
The new split applies the two lighting policies in that native shading pass with
one shared mesh trace; downstream GI/SSR is not independently rendered twice.

The user's next console error was `rextensions` (extra initial r), so that command
stopped before executing the reload. Clear the entry completely, then paste in GE Lua:

```lua
extensions.unload("beamrt_meshSunShadow")
extensions.unload("beamrt_meshBVH")
package.loaded["ge/extensions/beamrt/meshMaterialPolicy"]=nil
extensions.load("beamrt_meshSunShadow")
beamrt_meshSunShadow.setComparisonMode("beamrt-only")
dump(beamrt_meshSunShadow.enable())
```

This is the ONE normal-render isolation test. Expected: other native-only sunlight
cast shadows disappear on supported main-view receivers, while BeamRT's supported
guardhouse faces can still shadow. Choose `setComparisonMode("split")` for native
left / BeamRT-only right using the same scene; no camera reposition is required.
Restore exact native shading with `beamrt_meshSunShadow.disable()`; comparison mode
also resets to hybrid on disable/mission/unload/failure. No preset is overwritten.

Only if no difference is visible, `setComparisonMode("unshadowed")` is a second
bounded wiring control. Expected: direct-sun geometric shadows disappear. If they
remain, diagnose actual hook execution/mask binding/receiver identity, not ray
sample quality. If the control works but BeamRT-only produces no imported shadow,
the next implementation fix is the mesh sunlight query/material coverage. No third
generic diagnostic is requested for that hypothesis.

Interior brightness is NOT solved simply by removing native sunlight shadows.
Closed geometry must also occlude sky/ambient and indirect radiance; an interior
with windows, lamps, emissive surfaces or real bounce need not be pitch black.
Next substantial milestone: alpha-aware mesh coverage and sky/ambient/bounce
visibility for one building, preserving genuine light sources.

Generated native source now has four content-addressed variants; the helper source
is included in dependency checks and cache identity. Visibility W=0 marks invalid
data so isolation cannot mistake an unbound resource for a clear receiver. 12 Lua
control tests/5 generator tests/8 material tests and retained25GI-motion tests pass.
Strict FXC compiles 32 native pixel permutations plus visibilityVS/PS; Lua51/JIT55
checks pass. In-game activation/isolation and appearance remain unverified. No
assistant Git/network writes or installation edits occurred.

### Second live activation: opaque coverage is not color alpha

The next console result confirms the wrapper fix: four masked/two blended
materials are recognized, but `corrugated_modern` and `metal_galvanized` remain
unknown solely because `colorAlpha=nil`, despite explicit `alphaTest=false` and
`translucent=false`. Repeating the same command produced the same result.

Inspected installed `permutations.h.hlsl:181-228`: alpha clipping is controlled by
MFT_AlphaTest; translucent rendering is a distinct path. A missing color-alpha
accessor does not make explicit native opaque coverage unknown. The policy now
accepts those explicit non-cutout/non-translucent declarations without inventing
an alpha value. Known fractional alpha still conservatively falls back; missing
coverage flags/custom/mismatched identities do not become opaque. Masked/blended
faces remain unsupported. Expected classification from the observed flags is
2 opaque/4 mask/2 blend/0 unknown, not 8 opaque. CastShadows=false still excludes
actual sunlight blocking independently of GI opacity.

Eight policy tests now include the exact observed flag combination and missing/RGB
color values; 9 sunlight and 25 retained GI/motion tests and Lua compilation pass.
Reload cached policy with the same compact activation above. No further material
diagnostic is requested. Next is actual native shader execution and persistent
shadow rendering; if a new error appears, address that concrete blocker.
