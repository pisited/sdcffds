# GI frame validity repair — 2026-10-19

Two concrete defects in the existing graphics path were repaired in the installed
unpacked mod. No new graphics-access, command automation, native loading or
standalone tracing subsystem was added. The parked in-game mesh experiment stays
opt-in; these repairs do not establish the missing native-to-game resource bridge.

## Preparation must explicitly succeed

The receiver-export callback previously treated a successful `pcall` as successful
GI frame preparation. But `giCallbacks.preProcess` can return normally when the
current camera is unavailable, after resetting history. The old wrapper discarded
that distinction and the receiver marked the frame prepared anyway.

`giCallbacks.preProcess` now returns `true` for a valid normal or already-matched
buffer frame, and `false` with a reason when camera preparation fails.
`M._prepareGIFrame` propagates that result and always clears its preparation guard.
The receiver requires exactly boolean `true`; nil, false, other truthy values and
exceptions disable the visibility producer/consumer predicate instead of certifying
a prepared frame. A valid subsequent configuration can recover. Sampling advances
only once; missing-camera history resets and ordinary rendering defaults remain.

The tests execute the installed callback bodies with mocked engine APIs on both
Lua 5.1 and LuaJIT 2.1. This proves the control flow, not actual engine callback
ordering or a new rendered frame.

## Visibility must address the intended receiver

The v084 shared GPU predicate used `rtParams0` to invert the normalized prepass
viewport mapping before loading a visibility texel. It checked the resulting UV,
but not the mapping itself. An inverted viewport could round-trip to apparently
valid pixel coordinates and suppress the world contribution using invalid metadata.

The unchanged old shader failed a new WARP regression at the first negative-width
case. The repaired shader requires finite, nonnegative viewport origin, strictly
positive scale and an extent inside the normalized render target, with a 1e-6
upper-edge rounding allowance. Nonfinite/out-of-target scene UV also falls back.
It never clamps or repairs the invalid mapping into a different receiver.

The existing GI GPU fixture adds twelve invalid viewport cases, retaining its
positive full/subrectangle mapping, all 32 blocker bits, disabled/stale-key
fallback, opaque-only geometry, capture handoff and final-consumer fence tests.
The actual engine-managed pixel producer and native compute producer both feed
the exact shared consumer predicate on owned fixture resources. Full engine GI
entries are compiled separately against installed headers, not substituted with
new shader stubs.

## What remains unchanged

- v082/default GI sampling, presets, reflection filtering and rendering strengths.
- The native adapter ABI, output encoding, descriptor contract and GPU retirement.
- Default-off native game activation and the existing loading/deployment boundary.
- Original graph/bindings as the required OFF path; no whole-image darkening.
- Existing frozen launch candidates and the previous point-in-time temporary
  profile. That profile intentionally is not silently updated with these edits.

GPU results are offline only. The fixture consumer exercises the actual shared
visibility predicate, not the complete GI integrator inside BeamNG. Resource
ownership, scene/camera correspondence, queue insertion and live on/off lighting
remain unproven. Debug-layer availability and exact test counts are recorded in
the fresh `gi-frame-correctness-*` evidence directory.
