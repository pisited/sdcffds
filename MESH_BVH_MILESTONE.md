# One-building GPU BVH diagnostic

Later v0.103 connects the shared material-aware query to actual world-surfel GI;
see SHARED_MESH_GI_MILESTONE.md. This page records the earlier geometry check.

Purpose: prove that the GPU can traverse the **entire imported guardhouse** and
find its world-space shadow footprint, rather than using a large proxy box.
Alignment preview showed plausible front-view agreement in the user's screenshot;
it did not prove side/depth accuracy, GPU ray execution or shadows.

This is an isolated geometry preview, **not production lighting or GI**. All
776 triangles and 255 BVH nodes are supplied. No truncation to 12 triangles.
Opacity textures are not sampled; unknown/transparent materials therefore remain
*potential blockers*, not certified opaque shadows. Do not integrate this result
into final lighting/GI until that gap and live tests are resolved.

## Run from the current alignment preview

While parked, in GE Lua:

```lua
extensions.load("beamrt_meshBVH"); beamrt_meshBVH.setQuality("cinematic"); beamrt_meshBVH.setTestLightEnabled(true); beamrt_meshBVH.enable()
```

Left half is the existing scene, right half is the geometry-intersection map:

- Orange: the full mesh blocks a ray toward the fixed test light; opacity unknown.
- Red: a blocker explicitly declared opaque (none are certified in this package).
- Green: no intersection with **this one mesh**, not proof the whole scene is clear.
- Purple: back-facing/untraced or traversal budget exhausted; do not call it sunlight.
- Bright magenta: data loading/decoding/topology validation failed; NOT a shadow.
- Sky/no depth: native scene passes through.

**The fixed test light is synthetic**, above/diagonally beside the guardhouse.
It does not create a scene light, brighten anything, or change time of day. It
lets us test world-geometry occlusion even at night, without depending on the
engine sunlight orientation or current solar elevation. Receiver pixels still
come from the current camera depth buffer; the caster geometry does not.

Enabling hides the previous wire preview; disabling restores its prior mode if
the user has not changed it in the meantime. If alignment was not captured, the
nearest prepared guardhouse is selected, without moving the camera or vehicle.
The previously running alignment extension is supported without a forced reload
that would lose its camera-restore snapshot.

## Useful controls

```lua
beamrt_meshBVH.setView("binding")       -- validates GPU texture dimensions and known byte signatures
beamrt_meshBVH.setView("classification")
beamrt_meshBVH.setSplit(false)          -- diagnostic over the full frame
beamrt_meshBVH.setView("off")           -- hide preview, tracing still costs work
beamrt_meshBVH.disable()               -- stop trace + preview
```

Binding view: green/cyan means expected data signatures decoded; magenta means
failure. This is a positive resource test, not proof every triangle ray is correct.
The status field `gpuExecutionVerified` deliberately stays false until real image
evidence is reviewed; CPU object existence does not set it true automatically.

For engine-sun geometry checks, preferably in daylight:

```lua
beamrt_meshBVH.setTestLightEnabled(false)
beamrt_meshBVH.setSunDirection("reversed") -- existing world-caster convention
-- A/B if needed:
beamrt_meshBVH.setSunDirection("normal")
```

Playable uses a half-resolution receiver grid, Cinematic native resolution. Both
retain identical full caster geometry and a 4096-node traversal ceiling. The
current mesh has only 255 nodes; larger future meshes can exhaust that ceiling,
which is reported as unknown rather than a clear ray. Performance is unmeasured.

## Data and implementation

`tools/beamrt_bvh_pack.py` generates a 256x28 lossless RGBA8 data PNG and augmented
package under Gitignored `art/beamrt/alignment/`. Model-space vertices quantize to
16 bits per axis; measured maximum error on this mesh is 0.00002691m (<0.03mm).
BVH bounds round outward, leaves store complete ranges, and preorder escape links
permit stackless traversal without a large shader-local stack. Triangle metadata
keeps opacity provenance; missing alpha is never upgraded to opaque.

Two distinct known byte signatures validate dimensions/decoding, including alpha.
The shader handles either an unorm or sRGB-decoded texture view, uses exact Load
coordinates, and rejects unsupported signature changes instead of silently
sampling corrupted positions. These checks do not substitute for full GPU tests.

Native captured instance basis is inverted into three rows. World rays transform
to model space **without normalizing their transformed direction**, retaining
world-distance semantics under nonuniform scale. No camera-visible caster pixels,
native sun mask, old box store, spare cube registers, DDS guesses, or extra trace
uniform triangle arrays are used. Trace has three 2D inputs; preview has two.

The new module owns its target/shaders/state/callbacks, assigns resource fields
before registration, and disables when its captured instance becomes stale or the
mission changes. Disabling does not alter native lighting, GI controls, reflection
controls, physics or camera state. Only the explicit preview writes the backbuffer.

Rebuild private data from the existing alignment package:

```powershell
python -B tools/beamrt_bvh_pack.py --input art/beamrt/alignment/wcu_guardhouse.beamrt.json --output art/beamrt/alignment/wcu_guardhouse.gpu.beamrt.json
```

## Verification status

Four strict FXC VS/PS stages compile. Nine packing/PNG/escape-link/traversal tests
pass, including 249 synthetic ray comparisons against brute force, unknown-budget
behavior, conservative bounds and all-byte sRGB roundtrip. Five actual-Lua control
fixtures pass; native Lua 5.1/LuaJIT/Lua5.5 compile checks pass. Retained alignment
tests pass. These are offline checks, not a hardware ray/performance benchmark.

Next live proof: inspect the footprint, move only the camera until the guardhouse
is off-screen but a receiver remains visible, and verify the footprint stays in
the same world location without recapturing. Then resolve alpha/opaque materials
and trustworthy light radiance before making the buffer part of production GI
or shadows. No native reflection replacement or GGX-noise fix is claimed.
