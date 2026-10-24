# Collapsed-geometry fallback audit — 2026-10-13

Further offline work in the installed unpacked BeamRT folder while the user was
away. BeamNG stayed closed; no Lua/settings change, native GI activation, ReShade,
hot unload or new game probe occurred. The successful frozen live pair remains
unchanged. This audit supplements the earlier range/topology repairs.

## Confirmed issue

The shared triangle test rejected both parallel rays and unusable zero-area
faces with the same false result. If packed vertices collapsed, the traversal
could report a clean miss rather than unknown geometry. That loses information
needed for conservative lighting fallback.

This is not limited to intentionally damaged assets. A deterministic test passes
two initially valid source triangles through the existing 16-bit packer: a thin
foreground face and a distant face giving the asset a 100,001-unit X extent.
The foreground's distinct, non-collinear vertices quantize onto the same X value
and two vertices become identical. This demonstrates a packing precision limit,
not evidence that the current guardhouse or the user's screenshots had this issue.

The shader now decodes the face once, checks finite vertices/cross-product and
rejects a zero-area result as **-1 (unknown)** before the ray intersection test.
No near-zero area threshold was introduced. Valid faces parallel to the ray
still take the original intersection path and remain misses. No new triangle
format, subdivision, opacity guess or native resource interface was added.

This conservative choice can retain baseline rendering in a queried leaf with
unusable geometry, even if another face might otherwise block. It does not recover
lost precision, prove the original surface, or guarantee all bad geometry is found.
Ray/material/budget semantics and final-consumer retirement rules are unchanged.

## Red/green checks

The new GPU fixture retains valid atlas headers, topology and original boxes,
but collapses each triangle onto its first packed vertex. The old shader failed
on RTX 4070 with `collapsed geometry certified as a clean miss/hit`.
The exact red shader, executable, mesh fixture and source are preserved in:
`.beamrt-validation/renderer-degenerate-red-04b4824fb95a42f8a4e1772b6642fca9/`.
Pre-audit artifacts are in `renderer-degenerate-baseline-9b64191a789a4a9090bbb929cc6ddc68/`.

After repair, RTX 4070 and WARP return unknown on the collapsed-data regression.
The original 776-triangle guardhouse's 128 rays remain unchanged across identity,
uncertain-material and nonuniform-transform reference batches. Original-mesh
recovery and recreated-worker checks still pass. A one-face exact-coordinate GPU
control returns opaque for a crossing ray and miss for a coplanar parallel ray.

GI fixtures read the actual invalid visibility texel (-1 in every channel), then
verify the exact consumer preserves baseline radiance. Both native compute and
the game-side pixel-producer source, compiled with installed headers and run on
fixture resources, pass on RTX/WARP. Existing handoff, CBV, key/viewport and
post-consumer lifetime cases also pass. Debug layer was unavailable, so these are
not debug-layer-clean or live-game claims.

Project source/Python/Lua tests: **208/208**.
Shared shader SHA-256:
`23238e181df4503346b71fffa1e7d5acf2c66ce0e09874ecce51b47abcfebde5`.
Worker trace bytecode:
`6e4cf91135d59854d94bb79a25f8fadf53e5b42e4bdc206a3536e428d224ea9d`.
GI compute bytecode:
`2bd59a79eb519fa56206c618f7e4faaff95b3564bcafa8cbe4badd11d00afd72`.

## Startup review remains separate

The saved failing startup's narrow Application-log window was checked for the
owned fixture/PID (1000/1001 events); no matching event was returned. The enabled
Application log was readable, but this does not identify a missing dependency
or establish that the failure is fixed. Existing dependency/import evidence and
the original failure artifacts remain preserved. No security setting, DLL search
policy, global environment or unrelated process was changed.

General deployment stays held. Live geometry coverage, descriptor/CBV/camera
meaning, state/fence ordering and a native lighting consumer remain subsequent
work. This fix is not a claim that the headlight/daytime leakage is resolved.
