# Offline shared-traversal safety audit — 2026-10-13

Implemented directly in the installed unpacked BeamRT folder while the user was
away. BeamNG stayed closed. This is a correctness repair of the existing physical
geometry query, not another screen filter, a new tracer architecture or evidence
that the reported game lighting leaks are fixed. Lua controls and native lighting
activation were not changed. The previous successful live binaries remain intact.

## Confirmed defects

1. **Unsigned leaf-range wrap.** The old GPU check `start + count > triangleCount`
   could overflow when a corrupt leaf supplied UINT32_MAX as its start. It could
   then read unrelated texels and return a hit/miss instead of invalid data.
   The shared shader now checks start first, then uses bounded subtraction.
2. **Malformed preorder escape links.** The old check accepted a leaf that skipped
   extra nodes or an internal node whose escape did not include two children.
   The shader now requires leaf escape == node + 1 and internal escape > node + 2,
   matching the existing binary-preorder packer. Invalid encountered structure
   returns -1 before using its box or skipping the subtree.

These checks cover specific malformed ranges/topology, not every possible asset
corruption or proof that bounds/triangles/materials match a real live scene. The
material uncertainty and traversal-budget fallback policies remain unchanged.

## GPU red/green evidence

New RTX 4070 regressions failed on the old shared shader with:

- `overflowed leaf range certified a hit/miss`.
- `invalid internal subtree certified a hit/miss`.

The pre-fix shader/test/input set is preserved under
`.beamrt-validation/renderer-audit-red-c25dc9657b864f59b9f655732c6d4a98/`.
The pre-audit artifacts are also preserved under
`renderer-audit-baseline-197db64a43f14f61b75b48036f81656e/`.
Old trace shader SHA-256:
`66996cd0144113d64002fbe51dfafe25a1e161e1cd470fe847a0b36cd60923e5`.

After the repair, the actual 776-triangle/255-node guardhouse fixture's 128 rays
still agree with the CPU reference in identity, uncertain-material and nonuniform
transform passes, on both RTX 4070 and WARP. Malformed internal links, overflowing
leaf ranges and invalid leaf skips now return unknown. Recovery after replacing
bad data with the original mesh also passes. The 39-triangle synthetic CI fixture
passes on WARP; the real-asset fixture was regenerated afterwards.

The GI test separately reads the actual compute visibility texel for each corrupt
case, requiring all four channels to be -1—not a falsely certified clear mask.
Its exact consumer then preserves baseline GI. With installed BeamNG headers,
the actual game-side pixel-producer source is also compiled and run on fixture
resources: its invalid texel and consumer fallback pass on RTX and WARP.
The added readback is an offline test consumer, before the existing final-consumer
fence; the adapter's retention/discard/fence rules were not changed.

## Verification

- Project Python/Lua/source tests: **205/205**.
- Strict worker/GI C++ and HLSL builds, RTX and WARP GPU regression paths.
- 12 GI/receiver/export vertex/pixel entries compile against installed game headers
  via FXC SM5. This is compilation compatibility, not live SM6 execution proof.
- 24 staged native Point/Spot pixel permutations compile with real imported
  descriptor dimensions. The unverified clustered-light hook remains inactive.
- Existing 14 shader/root refusals, 68 handoff rejection cases, ownership,
  generation/viewport, OFF/ON/OFF and post-consumer retirement checks pass.
- Debug layer was unavailable; no debug-layer-clean, whole-scene pixel equality
  or game-performance claim is made.

Changed shared shader SHA-256:
`d4c61cf87c867215dcc84838ab3576b0ee47b7ea4e863a189451e70423192632`.
Worker trace bytecode:
`b8fcea1f8f61c294e4ad1a7623c1837ad433bd4f9d8831f3ab0b2475625ba8a4`.
GI compute bytecode:
`7c882914a43fe3dff488555f4aab8ae8b6794f730c0266d32a01f23e1af845e6`.

These hashes identify this earlier range/topology repair. The subsequent
[collapsed-geometry audit](DEGENERATE_GEOMETRY_AUDIT.md) adds a finite/zero-area
face guard, with separate preserved red evidence and new hashes. It validates
packing-induced collapse and genuine parallel rays, and raises the current
project suite to 208/208. No new game result is implied.

## Remaining boundaries

The preserved startup failure's dependency/import evidence still does not identify
the cause of its intermittent pre-attach 0xc0000135 result. Nothing in this audit
fixes or lifts that deployment hold. No user settings or security controls were
changed to work around it, and no additional game startup was attempted.

Live descriptor/CBV provenance, camera meaning, resource-state chains and ordered
GPU consumption remain unproved. The native visibility worker still has no live
lighting consumer, and clustered headlights remain unconnected. These repairs
prevent particular bad geometry data from being misclassified; they do not add
off-screen coverage, alpha-texture support or a new native-light dispatch.

Next useful work is the loader/resource-access boundary or additional separately
verified renderer defects. Do not repeat the old visual comparison just because
these narrow malformed-data guards were added.
