# BeamRT 0.110: four presets and bounded visual experiments

Implemented in the installed unpacked mod. No third-party demo code, loaders,
multiplayer hooks, stock shaders, global caches or native DLL changes were added.
No game was launched or controlled during this change. Visual improvement remains
an in-game question, not a consequence of passing offline tests.

## Exactly four visible presets

| Preset | GI screen-DDA budget | Reflection policy |
| --- | --- | --- |
| Performance | 1 path, up to 16 DDA steps | Playable GGX; hit/history helpers and local cleanup off |
| Balanced | 1 path, up to 24 DDA steps | Playable GGX; source/receiver validation on; local cleanup off |
| Quality | 1 path, up to 32 DDA steps | Same safeguards; experimental local cleanup at 0.35 |
| Cinematic | 2 paths, up to 48 DDA steps each | Same safeguards and local cleanup; higher bounded tracing budget |

All four use full-resolution GI, screen GI, the corrected estimator and the same
basic lighting gains. These budgets are settings, not measured performance or
equal traversal-cost guarantees. No ordinary preset selects the old 16/32-path
linear stress workloads. Three-scale reflection variance filtering is OFF in all
four; its role in the reported blotches has not been isolated, so it remains an
explicit experiment rather than silently following quality selection.

`lua/ge/extensions/beamrt/presets.lua` owns the four pure preset definitions.
`beamrt_main.getPresets()` returns fresh metadata; resolving a preset also returns
a fresh settings table. Old console names remain aliases to the four new tiers,
not exact reproductions of their historical settings. Old custom settings JSON
is still accepted and was not rewritten or deleted. No automatic preset is applied
merely by loading the updated module. The tuner says **Last preset**, since manual
slider edits can subsequently change those values.

## Local reflection cleanup (experimental)

Selected composer v034 adds an optional immediate five-tap cross. It uses actual
texture dimensions and depth, normal, roughness and F0 ownership gates. It does
not add rays, a target or a pass. It does not change reflection history or its
metadata; composition reads the result only for display.

- Mirror, diagnostics, frozen/convergence paths, invalid center support and
  negative grace lifetime bypass it.
- Roughness at or below 0.08 bypasses it to protect polished detail.
- Valid black and zero GGX samples stay in the normalized mean. No brightness
  threshold promotes a miss into a reflection or selects only bright neighbors.
- Original center alpha/lifetime is retained exactly.
- It can still soften rough-surface detail: this is a small spatial smoothing
  candidate, not a new confidence oracle or unbiased transport guarantee.

Quality/Cinematic select strength 0.35; Performance/Balanced leave it off. The
toggle and strength are included in normal settings save/load and exported
commands. Toggling this display-only stage does not reset GI/reflection history.
The tuner also distinguishes selected variance filtering from effective filtering
in the current mode, addressing the legacy/playable comparison ambiguity.

Single-line GE Lua controls:

```lua
beamrt_main.setReflectionLocalResolveEnabled(false)
```

```lua
beamrt_main.setReflectionLocalResolveEnabled(true)
```

```lua
beamrt_main.setReflectionLocalResolveStrength(0.35)
```

## Water receiver geometry preview (experimental, default OFF)

This is **not water SSR**. BeamNG 0.40's inspected water shader uses its SSSR
surface packing; the demo's older backbuffer-alpha marker cannot be assumed to
identify current water pixels. No verified per-pixel water ownership resource
is available to this path, so candidate geometry is not substituted into shading.

The explicit-refresh Lua provider finds at most one nearby horizontal WaterPlane
and one axis-aligned WaterBlock, with a bounded class query and 250 m range.
Unsupported transforms, missing camera data and invalid bounds fail closed.
The shader intersects the camera ray with that flat candidate surface rather
than the opaque riverbed, rejects nearer opaque geometry and uncertain finite
shoreline boundaries, and tints candidates cyan (plane) or blue (block).

There are no wave normals, underwater support, full rotated-water support,
verified rendered-water masks, off-screen reflections or lighting replacement.
Status explicitly reports ownership/waves/normal-lighting effects as unverified
or false. Refresh manually after scene/water changes. Mission change and unload
clear the candidates and turn the preview off; it is not saved into a preset.
BeamRT disable, native-SSR incompatibility, material/cache capture, reflection
audits/source probes and other diagnostic modes suppress the preview.

```lua
beamrt_main.setWaterReceiverPreviewEnabled(true)
```

```lua
beamrt_main.refreshWaterReceiverPreview(); dump(beamrt_main.getWaterReceiverPreviewStatus())
```

```lua
beamrt_main.setWaterReceiverPreviewEnabled(false)
```

The tuner places this under a collapsed **Experimental water surface preview**
section. It is a useful geometry baseline for later water reflection work, not a
claim that the source pack's complete water feature has been ported.

## Verification and game handoff

- Full Python/Lua/source suite: **926 run, 919 passed, 7 skipped**. Coverage
  includes exact four-button UI, legacy aliases, partial saved settings, strict
  setter wiring, Lua 5.1/LuaJIT agreement, water lifecycle and compatibility gates.
- Strict installed-header PostFX compilation: **50/50 VS/PS entries**.
- Local resolve: **33/33 GPU checks on each RTX 4070 and WARP**, including actual
  v033/v034 OFF equivalence, valid-zero/rare-bright means, ownership boundaries,
  alpha, invalid values and viewport mapping.
- Water: **41/41 GPU checks on each RTX 4070 and WARP**, including actual preview
  OFF identity, alpha, plane-versus-riverbed location, opaque occlusion, finite
  bounds and invalid inputs.
- Absolute `/mods` filesystem traversal passed without exclusions after the
  new files/artifacts were added. No old recovery artifacts were moved back.

The D3D12 debug layer was unavailable. None of these are live-game appearance,
allocation, performance, upscaler or complete water-ownership results.

Keep native SSR off for the existing 0.40 material-buffer interlock. Reload in GE
Lua using one line, then choose Balanced or Quality from the four-button menu:

```lua
if beamrt_main then beamrt_main.disable() end; extensions.unload('beamrt_main'); extensions.load('beamrt_main'); if beamrt_main then beamrt_main.start() end
```

For a clean local-filter A/B, keep one preset, camera, exposure and other filter
settings fixed; toggle only Local cleanup. Do not use legacy versus playable as
its A/B: that changes multiple filtering/history stages. Test water separately,
then turn its preview off before judging reflection/GI appearance.
