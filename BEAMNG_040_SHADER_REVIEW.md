# BeamNG 0.40: shader compatibility and focused improvements

This pass updates the installed unpacked BeamRT mod, not a separate Git checkout.
Engine shaders are studied in place; no stock shader, native graphics setting,
DLL deployment or BeamNG process is changed by this work.

## Confirmed material-buffer conflict

The installed `shaders/common/postFx/sssr/surface.hlsl` and official PostFX
documentation describe an attachment lifetime change: after lighting,
`SssrSurfaces` overwrites `#prepass[RT1]` with packed reflection-receiver data.
It is no longer material specular RGB / retroreflectivity at that point.
BeamRT's late reflection trace, temporal filter, spatial filter, composition,
GI receiver preparation and radiance processing currently expect the old data.

The first implementation is a conservative compatibility interlock, **not** a
claim that an early material snapshot already works:

- Native SSR enabled, contradictory state, failed queries or unknown state:
  pause normal BeamRT PostFX and refuse lighting audits / clean-radiance builds.
- Native SSR must be explicitly disabled in settings, with its object absent
  or actually disabled, before normal BeamRT rendering is allowed.
- Observe the actual `PostFxSSSRObject` defensively; never toggle it or write
  native settings. Keep the user's requested BeamRT mode while blocked.
- Recheck before rendering and on settings changes. Reset GI and reflection
  histories on state transitions; retire optional GI visibility preparation.
- Cancel running lighting audits on incompatible transitions. Reflection source
  and convergence experiments also reject incompatible starts and cancel through
  their existing restoration/owned-resource cleanup paths. A compatibility
  change must not re-enable normal shading inside an isolated material publisher.
- Report blocked status in the tuner and through
  `beamrt_main.getRendererCompatibilityStatus()`.

The interlock does not certify the rest of 0.40 compatibility. It deliberately
does not preserve F0, enable combined native/BeamRT SSR, or solve water ownership.
`M.enable()` records the request even when blocked; its return alone does not
prove an effect is active. The status API and tuner distinguish those states.

## Focused reflection radiance safety

Native SSSR uses explicit exponent-bit validity checks and bounded radiance
before storing/filtering HDR samples. BeamRT's trace can otherwise pass very
large finite source RGB into downstream half-float temporal/history targets.

The new `beamrtReflectionTraceP_v042.hlsl` enables an independently implemented
RGB safety helper in the existing trace body. The old v041 path remains
available for controlled fixture comparison. Invalid RGB is rejected before
weighting; final RGB is bounded to the representable nonnegative half-float
range. Alpha is not clamped or repurposed: it carries BeamRT hit UV or signed
depth/lifetime metadata, not native SSSR confidence.

The current trace uses RGBA32F when hit-aware/convergence modes require packed
UV precision, and can otherwise use RGBA16F. Downstream storage is why RGB range
matters in both cases. This is numerical robustness, not proof that overflow
caused any photographed noise or missing reflection patch.

## Next shader work, in order

1. Verify an early material capture before enabling native SSR alongside
   BeamRT. `PFXBeforeBin / AL_LightBin` is an existing engine scheduling point,
   but producer dimensions, same-frame contents, view ownership and restoration
   still require a bounded game test. A CPU callback is not GPU-content proof.
2. Establish exact render-resolution, jitter and motion conventions for the
   current PostFX stage before applying temporal-upscaler corrections. Do not
   add a blanket jitter or exposure adjustment from a different shader stage.
3. Add previous receiver normal/material history to test depth-similar surface
   changes. Current-frame bilateral gates already exist; stricter temporal
   rejection may reduce ghosting but also increase noise.
4. Prototype the existing geometry/BVH visibility producer as an engine-managed
   compute PostEffect. Retain the receiver export's raster derivatives and the
   existing visibility consumer until the compute handoff is verified.
5. Treat water as a separate receiver contract: surface depth, wave normals,
   motion and compositing. Generic opaque-prepass reflections are not verified
   water reflections, even if a submerged floor appears reflective.

## Validation boundary

The Python/Lua tests execute the real compatibility policy and main enablement
logic with mocked engine objects. Strict shader compilation uses installed 0.40
headers. Small D3D12 fixtures compare actual reflection shaders on synthetic
inputs. These are separate from live BeamNG scheduling, appearance, stability
and performance; none establishes that the reported moonlight leak is fixed.

Verified for this patch:

- Full project suite: **860 tests, 854 passed, 6 skipped** (Lua 5.1 and LuaJIT
  compilation/behavior checks are included; mocks are not live engine proof).
- **48/48** strict FXC vertex/pixel compilations against installed 0.40 headers.
- Reflection radiance fixture: **96/96** on RTX 4070 and **96/96** on WARP,
  executing the old/new production shaders against synthetic geometry.
- The fixture reproduced old non-finite RGB propagation at 28 accepted hits;
  the new shader rejects that RGB. Ordinary finite output and packed hit UVs
  remain bit-identical in the tested cases.
- The suspected finite-overflow-to-infinity store was **not** reproduced:
  old finite RGB reached 976447 in RGBA32F, but raster RGBA16F storage clipped
  to 65504 on both backends. Explicit range limiting is additional hardening,
  not a demonstrated fix for the user's noise.
- The D3D12 debug layer was unavailable. No game was launched or controlled.

Compiler artifacts:
`.beamrt-validation/postfx-compile-71a9e47f2d244796bf5f4b720c9a1a17`.
GPU fixture artifacts: `.beamrt-validation/reflection-radiance`.
The v042 pixel-shader SHA256 matches across both build routes:
`B2F6E49BB200F8DE12A7A36F9C4AC124274849E24B9DB6B91C31E5F8B2234240`.

Upstream references (techniques and contracts, not redistributed source):

- https://documentation.beamng.com/modding/postfx/
- https://www.beamng.com/game/news/blog/beamng-drive-v0-40/
- https://gpuopen.com/fidelityfx-sssr/
