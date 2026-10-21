# BeamRT-owned SSSR fork, first trace port (0.113)

Current 0.114 adds the opt-in [reflection comparison lab](REFLECTION_COMPARISON_LAB.md),
classified adapter failures, and the `traceP_v002.hlsl` cache entry. The first-port
description/results below are retained as historical scope. Normal traversal
retains its previous budget; the lab can explicitly raise it to 2,048 traversal
lookups and 64 m reach. None of the missing native pipeline stages is implied.

The requested direction is an independently controlled BeamRT renderer derived
from the native approach, not tuning the integrated `PostFxSSSRObject`. The
earlier dense-native-ray controller remains a collapsed legacy diagnostic; it
is not the primary reflection implementation.

## Implemented now

- `shaders/beamrt/nativeSsr/ffx_sssr_fork.h.hlsl`: local source fork of the
  installed MIT-licensed AMD SSSR traversal file, with its full license retained.
- `adapter.h.hlsl`: BeamRT depth/normal/projection callbacks and a bounded mip-0
  dispatcher. It uses public prepass textures, not private native SSR targets.
- `traceP_v001.hlsl`: independently registered `BeamRT_SssrForkTraceShader`,
  combining that traversal with existing BeamRT GGX sampling, source validation,
  finite RGB guards and output contracts.
- An explicit **BeamRT SSSR fork (prototype)** on/off control and an experimental
  tracer comparison. No extra quality presets, automatic enablement or saved
  native graphics-setting changes.

The fork owns the trace shader and uses existing BeamRT-owned temporal and
composition passes. It does not instantiate another `PostFxSSSR`, rename the
game's object, override default shader paths, or change the game's renderer
enablement. The old experimental shader remains unchanged and selectable.

The first trace port is a **pixel-plane, mip-0 baseline**. It fits a continuous
local depth plane using the native-derived discontinuity-aware slope logic,
advances across screen pixels and validates the reflected hit. It is not the
old linear world-step marcher under a different name. The adapter normalizes
normal/reversed device depth, uses camera-relative eye rays rather than guessing
an absolute-world matrix convention, and clips hits to the finite visible ray.
Depth lookups are bounded to at most 480 per ray; non-sky pixel fits consume five
lookups. Work exhaustion, invalid depth or invalid hit normals cannot become
positive visibility evidence.

## What this does NOT establish

This is **not a complete native SSR clone or native-quality parity**. It lacks
an owned Hi-Z pyramid, native tile classification/indirect dispatch, native scene
radiance history, native denoiser port, transparent/water receiver capture and
material-integrated BRDF replacement. Existing environment reflections remain in
the base image, and the current composition augments them. It does not fix
off-screen visibility, moonlight leaks or arbitrary missing geometry.

The previous receiver-history atlas experiment is bypassed for this backend;
the existing non-hit-aware reconstruction is used initially. Its own lifecycle
and the reported stationary-grain issue are not claimed fixed by this change.
Mirror/GGX sampling, compatible source reconstruction and display filtering
still use the existing BeamRT controls. The inherited step-length/max-step
controls bound physical reach; native-style traversal itself steps pixel cells.
Backend selection is transient and does not silently modify the four presets.

## Game control

Turn **integrated native SSR OFF** in graphics settings before trying this port.
This is a material-buffer lifetime requirement, not a dependency on the native
SSR renderer: with native SSR on, `#prepass[RT1]` no longer contains the F0 data
used by the current BeamRT composition path. The compatibility interlock remains
enabled and refuses to stack both paths. No game setting is changed for you.

Reload the updated extension and open the tuner:

```lua
extensions.unload('beamrt_main'); extensions.load('beamrt_main'); beamrt_main.openTuner()
```

Use **Enable BeamRT fork**, or:

```lua
beamrt_main.setSsrForkEnabled(true)
```

Disable its reflection rendering:

```lua
beamrt_main.setSsrForkEnabled(false)
```

Select the old experimental tracer, without enabling integrated native SSR:

```lua
beamrt_main.setReflectionTraceBackend('experimental')
```

```lua
dump(beamrt_main.getSsrForkStatus())
```

The status reports requested/active/shader binding separately and explicitly
marks water, native denoiser parity, material replacement and game appearance as
unverified or absent. Diagnostic/capture modes block backend changes. Changing
backend clears reflection history, not GI history. In reflections-only mode,
the off button stops the owned renderer; as a GI overlay it disables the overlay
without disabling GI. It does not disable unrelated experimental rendering when
the fork is not selected.

## Source provenance and changes

Source inspected/copied locally:
`shaders/common/postFx/sssr/include/ffx_sssr.h` from the installed game, SHA256
`A8B800C2D6B5D00FA6C83D03D6B001F96BEA31660C642A842C71BAE67A8A0F1E`.
Its AMD copyright/permission/warranty notice is retained in the local fork.
[The upstream SSSR project publishes the same MIT license](https://github.com/GPUOpen-Effects/FidelityFX-SSSR/blob/master/license.txt).
Other engine headers are referenced from the installed game, not redistributed.
No claim of authorship over the upstream algorithm is made.

Port changes: SM5-compatible vector selection; explicit mip-0 limit and no wave
occupancy inference; initialized traversal state; guarded parallel-plane handling;
and a single output commit in the pixel-step function for strict FXC definite
assignment. The production adapter uses an explicit bounded pixel dispatcher,
not native private indirect buffers. Camera/source/finite/metadata adaptation is
BeamRT-owned. The original game files are untouched.

## Offline verification

```powershell
./native/lighting/build_sssr_fork.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/lighting/build_sssr_fork.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
```

Artifacts stay outside `/mods` and the game installation, normally under
`Documents/Codex/beamrt-sssr-fork`. The fixture executes the owned core AND the
production adapter shader against coherent synthetic receiver/wall geometry.
Checks include known plane intersections, negative traversal direction, sky,
parallel rays, budget exhaustion, both device-depth conventions, valid black
sources, invalid RGB/depth, packed-hit compatibility and changing GGX samples.
Neither the synthetic test nor mocked Lua proves game scheduling, bindings,
appearance, performance, native parity or full denoiser behavior. The D3D12 debug
layer was unavailable. No running game was controlled for this implementation.

Next priority: verify this first owned trace in game, then build owned depth
hierarchy and history/denoising stages. Actual water surface depth/normals/motion
and material composition require separate verified producers; copying files does
not make the native engine's private bindings available automatically.

Validation for the first port: **19/19** synthetic core/production-adapter GPU
checks on RTX 4070 and **19/19** on WARP, including forward and reversed depth.
The coherent fixture produced 144 accepted source hits per convention on RTX
and 158 on WARP; these checks do not require cross-backend bitwise coverage.
The installed upstream traversal file still matches its recorded SHA256.
The complete Python/Lua suite ran **1004 tests: 997 passed, 7 skipped**, including
14 new fork control/source contracts exercised with Lua 5.1 and LuaJIT. The
production PostFX set now includes the fork as a separately compiled entry.
All **52/52** selected vertex/pixel entries passed strict FXC compilation with
installed headers. `/mods` traversal passed without exclusions. These remain
offline checks; no live game comparison was performed.
