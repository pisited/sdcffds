# GI/reflection history audit — 2026-10-13

Performed directly in the installed unpacked BeamRT mod. BeamNG stayed closed;
no native startup loading, resource interception, game settings, presets or
lighting-strength changes. All GPU resources belong to the offline executable.

## Reproduced and repaired

### HDR moments lost variance information

The actual GI moments pixel shader calculates luminance and squared luminance.
The main Lua renderer previously stored both current and historical moments in
RGBA16F. A finite gray input of 300 produced a second moment of 90,000, but
the GPU render target stored **65,504** on both RTX 4070 and WARP. In these runs
the conversion saturated, rather than storing infinity. On the following dark
frame the historical second moment was **32,752 instead of 45,000**, giving the
denoiser incorrect variance despite entirely finite incoming colors.

Both moments targets now use RGBA32F. GI color, temporal GI and GI color history
remain RGBA16F; texture slots and statistics equations are unchanged. The test
reads the actual Lua target-format declarations instead of hardcoding the fixed
format. Values 256, 300 and 65,504 are representable in the existing GI color
format; their squared statistics need greater range. These are controlled HDR
edge cases, not evidence that normal presets reached them in the live game.

Tradeoff: the two moments textures double in memory and have more bandwidth.
Additional allocation is 16 bytes per GI texel total: about **14.1 MiB** at
2560x1440 with half-resolution GI, or **31.6 MiB** at 3840x2160 with half-resolution
GI. These are allocation estimates, not measured game performance.

### Rejected history still contaminated current colors

Nonfinite historical RGB could enter interpolation even with zero depth/lifetime
confidence. The old shaders produced black current colors or infinite reflected
colors, and could also corrupt GI support. Invalid moment history was accumulated
instead of restarting its statistics.

GI/reflection histories now require finite payloads before entering accumulation.
Bad moment history restarts from the current sample. Invalid current radiance
no longer advertises valid GI support or fresh reflection lifetime. This repairs
the tested failure behavior; it does not identify the source of bad data in a
real game frame.

### Zero-weight samples were not harmless

An incompatible neighbor with infinite RGB still poisoned spatial reconstruction
through `Inf*0`. The optional reflection color-history gather had the same
problem with an invalid, zero-weight tap beside valid history.

Nonfinite samples now skip bounds/statistics/weighted accumulation. **Valid zero
GGX estimator samples remain in the denominator**, and genuine black mirror
hits keep their geometric lifetime. Motion thresholds, finite-sample color math,
history blending parameters and exposure controls were not retuned.

The repaired shared implementations are `beamrtTemporalP_v061.hlsl` and
`beamrtReflectionTemporalP_v025.hlsl`, included by the selected v071/v038 entries.
Older accepted canonical v005a/v020 fallback sources remain untouched.

## Evidence

- The GPU fixture executes the actual selected moments, GI temporal and
  reflection temporal pixel shaders, compiled with installed BeamNG headers.
  It uses reflected constant offsets, independent expected colors/statistics
  and actual texture readback; it is not a replacement math implementation.
- Original 33-case fixture: **14/33** passed on RTX and WARP. Sources, executable,
  bytecode, Lua format declarations and logs retained under ignored
  `.beamrt-validation/history-red-ee737a32c052451ca3ff8b10dac20115`.
- Expanded fixture adds invalid-current support/lifetime checks. With the old
  bytecode and old format, **14/35** passed on both backends. Retained under
  `.beamrt-validation/history-red-expanded-afa5c4d4d6da4883b2ea7e651da2c135`.
- Repaired shaders and format: **35/35** on both backends. Frozen passing files
  and logs under ignored
  `.beamrt-validation/history-green-19a213b2b9d34a8fb0fa9be1f13df15e`.
- Existing sunlight GPU regressions: **45/45**, RTX and WARP, after sharing the
  offline pixel-pass helper in `native/gi/gpu_fixture_pass.h`.
- Full Python/Lua/source suite: **221/221**; strict installed-header PostFX
  compilation: **48/48** VS/PS entries. The debug layer remains unavailable.

Passing pixel bytecode SHA256:

- Moments: `4e74f06d8fb27aa28a94124be1a9288ab97624b133df1d8620b92996646b4189`
- GI temporal: `beaac26c419d71012aeeb1578065238bae9491bfc1becb20732c87fc0e4d947d`
- Reflection temporal: `da371f736fb58f78bb4788fb6f1fa85c10a6d68ae76e38469a442fcb734e290b`

## Local test and remaining work

```powershell
./native/lighting/build.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/lighting/build.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
```

These fixtures do not prove live target-format refresh, sampler/resource
bindings, SM6 behavior, screenshot improvement, performance or dynamic-object
history correctness. No claim that these defects caused the earlier shadows or
orange leakage. A fresh agreed game test remains necessary for visual validation.

Exposure normalization is still an open older item: the installed native
vector-light code multiplies light energy by `lastFrameExposure`, while the
selected clean-radiance shader reads direct lighting without an explicit
exposure conversion and combines it with native material emission. Temporal
history also has no current/previous exposure ratio. The required resource units
and exposure inputs need verification before compensation; no guessed exposure
constant or brightness workaround was added. Ambient/sky contribution, broader
geometry/material coverage, clustered headlights and native resource connection
remain separate unresolved work.

## Optional reflection multiscale follow-up

[SSSR_OWNED_FORK.md](SSSR_OWNED_FORK.md) is the current independent-renderer
direction: an owned native-derived pixel-plane trace, BeamRT on/off/backend
controls and explicit missing native-parity components. It does not run the
integrated native SSR object or change its graphics setting.

[NATIVE_SSR_ENHANCEMENT.md](NATIVE_SSR_ENHANCEMENT.md) describes the current
native-first direction: reversible native dense-ray comparison, exact ownership
and restoration rules, and a separate undeployed history-edge helper experiment.
It does not enable custom GI/SSR alongside native SSR or claim game verification.

The user identified the remaining cockpit grain as reflections, not GI.
[REFLECTION_MULTISCALE.md](REFLECTION_MULTISCALE.md) documents the opt-in
three-scale extension of the existing reflection variance experiment, controlled
GPU variance measurements, resource cost, and ordinary-game comparison commands.
The history fixtures above remain unchanged and still pass 35/35 on RTX/WARP.

## Receiver and source-layer follow-up

[RENDERING_EXPERIMENTS_V0110.md](RENDERING_EXPERIMENTS_V0110.md) records the current
four-preset menu, display-only local reflection cleanup and opt-in water geometry
preview, with controls and offline/live verification boundaries.

[REFLECTION_QUALITY_UPGRADE.md](REFLECTION_QUALITY_UPGRADE.md) describes the new
v043/v039 paths, independent A/B switches, two-plane resource cost and offline GPU
checks. They are installed for a game comparison, not yet evidence of reduced
noise or corrected pictured leakage.

## Reflection comparison lab

See [REFLECTION_COMPARISON_LAB.md](REFLECTION_COMPARISON_LAB.md) for the v0.114
opt-in coverage, raw, exaggerated-gain and settled-history experiments. These
are not extra quality presets and do not modify native settings.

## Coherent SSR rendering pipeline

[COHERENT_SSR.md](COHERENT_SSR.md) covers the v0.115 opt-in complete traversal,
history, reconstruction and water backend, its BeamRT controls, offline checks
and remaining game-validation boundary. The older renderer remains available.
