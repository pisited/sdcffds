# Frozen-camera reflected material factors - revision 13

This extends the working camera bounce mask with **reflected surface color
factors under fixed diagnostic lighting**. It is a step toward surface shading,
not BeamNG's material renderer or a playable reflection effect. Existing image,
normal and reflection-mask modes remain available.

Revision 14 adds [whole-source offscreen geometry controls](vehicle-offscreen-geometry.md)
to this same mode, without adding mesh streams or changing the factor preview.

## Run

Keep two parked cars and physics paused with J. Position the camera outside a
car, looking at an inward-facing door/side which can reflect the other car.
The gap views that produced green in revision 12 are good starting points.
Keep the camera still, including FOV and window size. In GE Lua:

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startMaterialReflectionTest(); print(tostring(ok)..': '..tostring(why))
```

Close the console without moving the camera. The progress panel uses the same
180-second job deadline and geometry budget as before. Status:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getImageStatus()))
```

The output has four corresponding panels. Each samples the same 128-wide frozen
main-camera grid. Output size is 256 by twice the grid height (32..96), at most
49152 pixels; **the additional column does not cast additional rays**.

| | Left: identity | Right: factor lighting |
|---|---|---|
| Top | Green other / orange self / slate miss | Color factor of nearest reflected surface, lit by its geometric normal |
| Bottom | Same rays with other car excluded | Same factor calculation with other car excluded |

Dark pixels mean primary misses. Slate pixels mean a primary hit but no captured
secondary surface. Purple in the right column means an unresolved, conflicting
or unavailable material factor; it is not a painted texture or missing car.
Some factor colors may coincide with diagnostic colors: use the left column
and counters to interpret hit ownership, never infer ownership from right RGB.

Only the two cars exist in this CPU scene. Road/buildings/terrain are absent.
Every receiver triangle remains an ideal mirror, including glass/interior.
The top-right result may therefore look quite different from a real car finish.

## Native BeamNG contract

The installed `editor/materialEditor.lua` reads layer-indexed data using
`Material:getField(fieldName, layerIndex)`. Its PBR UI edits `diffuseColor`, with
`baseColorFactor`, `metallicFactor`, `roughnessFactor`, maps, instance color and
palette fields in the serialization path. `editor/api/material.lua` checks the
LuaIntf class tag `___type == "class<Material>"`. This implementation uses these
installed conventions, not a stock Torque material layout.

Unique primitive material names resolve through `scenetree.findObject`. There
are no name-based paint/glass guesses, JSON searches or texture loads. A missing
identity stays unresolved. Native class identity is required; `getClassName`
is only a fallback when the class tag is absent. Custom materials remain unknown.

At most 512 distinct identities, 192 characters per identity, 21 bounded fields
per material and 2048 characters per field are read. Overflow identities reject
instead of truncating. Color factor parsing accepts four finite 0..1 values,
or three RGB values with alpha 1, as in the installed editor's
`getTempFloatArray4_StringString`. Native stock-color names are resolved through
BeamNG's `getStockColor`, then copied and validated as finite 0..1 RGBA values.
The native result is never modified. Unknown names, failed lookups and malformed
values remain unknown; the editor's white error fallback is deliberately absent.
`diffuseColor` is preferred, with `baseColorFactor` as a fallback. If both valid
aliases disagree, the preview marks the material unknown rather than choosing
one silently. Missing fields do not default to white.

The capture stores detached Lua strings/numbers only, retaining no Material
wrappers. All material reads begin **after BOTH native mesh handles have been
freed**. Geometry acquisition still requests only positions, indices and
primitives; no new UV/color/normal getters are used. Before publication the
material fields and decoded stock-color values are reread and compared. A change cancels publication. This is
a frozen start/end material snapshot, not continuous shader-instance tracking;
an edit and exact restoration between checks cannot be detected. After saving,
the image describes its captured materials and is not refreshed by later edits.

For each actual secondary hit, display RGB is computed as:

```
round(255 * factor.rgb * (0.2 + 0.8 * abs(dot(worldFaceNormal, {0.36,-0.48,0.8}))))
```

The light vector is unit length. Its two-sided response deliberately avoids
pretending that winding has been certified. This is a display-space diagnostic,
not radiometric integration or native color management. The secondary material
and normal are used, not the receiver's factor, vehicle ID tint or screen color.
Roughness/metallic values are captured as metadata but **not applied**: the
preview does not fake roughness by dimming or blurring a single mirror sample.
Textures, paint palette masks, vertex colors, layers above zero, transmission,
opacity sampling, receiver BRDF/Fresnel, lights, shadows, emission, environment
radiance and native tonemapping remain absent. A material factor is not a fully
evaluated base color: a white factor can multiply a richly colored texture.

## Controls and evidence

The original direct CPU controls, camera native-unprojection checks, sampled
linear primary/secondary reference scans and source-excluded queries remain.
Receiver self-hits are retained in both rows. In this mode their primitive
identity and RGB must match exactly. `materialControlIdenticalSelfPixels`
counts those checked self-hits. Inter-car hits may become a miss or a farther
self-hit in the bottom row; no hit is fabricated or force-deleted.

Useful status fields:

- `profile="camera-material"`, `materialFactorPreview=true`.
- `materialSnapshotMatched=true` after unchanged end-of-job native fields.
- `materials`: requested/resolved/factor/unknown/texture/instance/layer counts.
- `reflectedFactorPixels` and `reflectedUnknownMaterialPixels`: full-pair
  secondary-hit evaluations, with separate excluded-row counts.
- `cameraBounceGeometricControlsPassed`: geometric proof criteria, unchanged.

Detailed detached material metadata is available after completion:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getMaterialStatus()))
```

Records include `rawDiffuseColor`, `rawBaseColorFactor` and `colorEncoding` to
distinguish numeric RGBA/RGB values from `native-stock-color`. Image status
`materialColorFormatRevision=2` identifies support for the native string formats.

`materialShadingVerified`, `opaqueVisibilityVerified`, `gpuExecutionVerified`
and `offscreenReflectionTestPassed` remain false. A factor preview does not
establish any of these. `textureColorsSampled`, `paintPaletteSampled`,
`roughnessApplied`, `receiverBRDFApplied` and `sceneLightingUsed` are also false.

Saved images use `/settings/beamrtVehicleRayImage-camera-material-<run>.bmp`.
Existing captures are preserved. `showImage(120)`, `hideImage()` and `stop()`
work as before. Stop/reset/unpause/camera motion invalidate the live geometry
snapshot; cancellation discards pixels, material snapshot and CPU BVH work.

Offline tests use synthetic geometry and fake Material objects, including
different source/receiver colors, missing fields, conflicting aliases, native
class fallback, source exclusion, normal-dependent lighting, material edits,
readback ownership, bitmap sizing and cancellation. Passing them does not
replace a live BeamNG result for revision 13.

## First live result and named-color correction - October 24

The first live image completed on 338768 triangle references with 17 A-to-B and
57 B-to-A secondary hits. Exclusion removed all 74 inter-car hits; all 186 self
hits and their preview pixels remained identical. Camera projection and sampled
primary/secondary reference checks passed; material fields matched at completion.

All 33 material identities resolved, but only 12 parsed as color factors. The
right full-pair panel contained 15 factor-lit hits and 245 unknown-material hits;
the excluded panel contained 12 and 174 respectively. Purple was the explicit
unknown indicator, not a rendering failure or a source-color result.

Live field checks established `ardente_main.diffuseColor = White` and
`ardente_plainblack.diffuseColor = black`, with identical baseColorFactor aliases.
`ardente_glass` instead returned four numeric components. The original parser
accepted only numeric RGBA, so it rejected valid stock-color names. Inspection of
installed `editor/api/gui.lua` confirmed its `getStockColor` and numeric-RGB paths.
The corrected parser follows these native formats and preserves unknown/error
fallbacks, alias agreement checks, detached storage and end-of-job validation.
The corrected live capture `20261024T143812Z-1379.1521889-1` completed with zero
purple fallback pixels among 260 full-pair and 186 excluded reflected-surface
pixels. All 74 inter-car hits disappeared under exclusion and all 186 self-hit
surface colors remained identical. This verifies the named-color correction for
the sampled surfaces in that capture, not every material or actual paint textures.
