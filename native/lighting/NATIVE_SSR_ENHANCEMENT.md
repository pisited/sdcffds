# Native-first reflection development (BeamRT 0.112)

**Direction clarified in 0.113:** the primary path is now the
[BeamRT-owned SSSR fork](SSSR_OWNED_FORK.md), not this integrated-object tuning
experiment. This document records the retained legacy diagnostic and its fixes.

The primary reflection direction is now to improve the existing native SSSR
path. The custom BeamRT renderer remains an experimental reference, not another
SSR contribution stacked over native reflections. The four custom quality
presets are unchanged; they do not silently change native graphics settings.

## First opt-in experiment: dense native rays

`lua/ge/extensions/beamrt/nativeSsrEnhancement.lua` temporarily changes only the
existing `PostFxSSSRObject.samplesPerQuad` field to `4`.

The installed native `include/ClassifyTiles.hlsl` defines base-ray selection:

| Value | Base rays in an eligible 2x2 trace-pixel quad |
| --- | --- |
| 1 | One, with compatible quad reuse |
| 2 | Two diagonal base rays |
| 4 | One independent base ray for each eligible trace pixel |

This is **not four samples per pixel**. Native mirror/edge/variance rules can
already request extra rays in the lower-density modes. Dense mode removes this
quad reuse; it does not change the trace resolution, ray intersection budget,
native denoiser, water surface inputs, material composition or environment
fallback. The tracing work can increase substantially, up to about four times
the base-ray count relative to mode 1, but total frame cost is not measured.
If the baseline is already `4`, the UI explicitly reports no sampling change.
More independent rays are an experiment, not a verified noise/detail improvement.

The exact native field name is present in the installed engine's binding
metadata. Before any write the module additionally requires:

- An existing, actually enabled object of class `PostFxSSSR` with a valid ID.
- An actual registered Lua getter **and** setter for `samplesPerQuad`, or an
  explicitly advertised SimObject static field when no typed binding exists.
  A dynamic field or an HLSL `g_*` constant name is not accepted as support.
- A successful current-value read of exactly `1`, `2`, or `4`.
- Successful exact readback of `4` after setting the field.

### Binding correction after the first game check

The 0.111 game check found the native object but refused the experiment because
`samplesPerQuad` was absent from `getFields()`. No native value was changed.
The initial controller had incorrectly treated that registry as the only
supported accessor. Installed `lua/common/luaBinding.lua` establishes separate
typed Lua-property getter/setter registries, consulted before SimObject fields;
shipped graphics Lua already uses a typed native property for resolution.

The 0.112 controller verifies the actual registered function pair and reads and
writes through that pair with numeric values. It does not substitute a generic
`setField()` call for a typed property setter. Object identity and binding
identities remain part of the retained ownership contract; an uncertain binding
change must not silently switch setters during restoration. Incomplete or
unverifiable typed bindings remain blocked, even if a same-name static/dynamic
field could appear to read back successfully.

This corrects the source-level accessor mismatch. Availability and operation of
the registered native property on the running game still require the next check;
the earlier offline mock success did not establish that contract.

All loading is inert. There is no game launch, native enable/disable, object
creation, stock file override, graphics-settings write, cache clear, automatic
quality selection or DLL change. The existing RT1 compatibility interlock
remains intact: custom BeamRT GI/SSR still pauses while native SSR is enabled.

## Native versus dense comparison

The tuner has a separate **Native SSR: dense-ray comparison** section, available
even when the custom renderer is paused. Enable native SSR through BeamNG's own
graphics settings first, then open the tuner without starting custom PTGI:

```lua
extensions.load('beamrt_main'); beamrt_main.openTuner()
```

After reloading an already-loaded extension as appropriate, the explicit APIs
are:

```lua
beamrt_main.enableNativeSsrEnhancement()
```

```lua
beamrt_main.setNativeSsrComparison('native')
```

```lua
beamrt_main.setNativeSsrComparison('enhanced')
```

```lua
beamrt_main.disableNativeSsrEnhancement()
```

```lua
dump(beamrt_main.getNativeSsrEnhancementStatus())
```

The **Log native SSR details** button emits a bounded, read-only receipt of the
two allowlisted property bindings plus native CPU route/denoiser status. It does
not invoke a setter, change settings or establish GPU completion. The equivalent
console call is:

```lua
beamrt_main.logNativeSsrDiagnostics()
```

`native` restores the original sampling value retained when this experiment was
enabled; `enhanced` requests dense rays again. These labels describe only this
native sampling experiment, not an independently rendered pair of world views.
No native history-reset API has been verified or invoked: hold the camera still
and allow the same settling interval after each switch before comparing images.
Compare in motion too, and record frame time as well as noise/sharpness.

## Ownership and restoration

The module retains the exact original readback and the last value it wrote.
Restoration is conditional on the same object identity and continued ownership.
It does not overwrite a later external edit or write through a replacement
object. A retired object or conflicting external value is reported separately
from successful baseline restoration. A write/readback failure that leaves
ownership uncertain retains its ledger and `restorePending`; retry explicit
disable rather than silently losing that state.

Settings changes, mission start/end, BeamRT disable and extension unload stop the
experiment. Per-render observation stops it if native SSR becomes disabled, its
object changes or someone changes the owned field. Nothing automatically
re-enables it. Module reload releases the cached module's ownership before
refreshing its source; failed restoration retains that module rather than
orphaning its ledger. The native experiment is transient, not saved in custom
presets or tuning JSON.

## Separate offline history-edge experiment

`shaders/beamrt/beamrtNativeSsrHistory.h.hlsl` is a bounded, **not deployed**
four-tap history-footprint helper. It rejects incompatible normal/depth/class
and invalid evidence per tap, preserves compatible black/zero samples, and
uses identical weights for premultiplied RGB and coverage. All rejected taps
produce invalid zero history rather than borrowing unrelated color.

The installed native reprojection blends history normals before testing the
aggregate footprint. Its slower fallback checks individual taps, but a blended
normal can accept a footprint containing a tap the slow path would reject.
The GPU fixture reproduces that counterexample with an explicit aggregate
acceptance **model**, using installed packing/radiance/config functions:

- Three compatible black taps plus one orthogonal tap with RGB 100.
- Aggregate confidence about `0.930272`, above the native fast threshold `0.9`.
- Modeled bilinear RGB `25`; guarded RGB `0`, compatible weight `0.75`.

This does not execute the complete native reprojection pipeline, identify the
cause of a photographed artifact or demonstrate a live-game improvement. No
native shader path includes this helper. A verified integration point, complete
native-pass fixture and reversible game comparison are still needed.

Build/run outside the mod/game directories:

```powershell
./native/lighting/build_native_ssr_history.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/lighting/build_native_ssr_history.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
```

## Verification boundary

Lua 5.1/LuaJIT tests exercise the actual controller and main integration with
mocked engine objects, including conditional restoration and failure paths.
The history helper has separate strict FXC/MSVC and synthetic D3D12 checks.
Neither establishes live native property exposure, native setter effects,
shader execution, image improvement or performance. Those remain a game test.
No running BeamNG instance was controlled for this implementation.

Initial 0.111 validation (before the game exposed the accessor mismatch):

- Full project suite: **968 run, 961 passed, 7 skipped**.
- Native controller: **31 cases**, each exercised with Lua 5.1 and LuaJIT.
- Main integration: **11 cases**, each exercised with Lua 5.1 and LuaJIT.
- Existing production PostFX entries: **50/50** strict VS/PS compilations with
  installed 0.40 headers; none was replaced for this experiment.
- Offline native-history helper: **39/39** synthetic GPU checks on RTX 4070 and
  **39/39** on WARP, including strict FXC/MSVC builds. Debug layer unavailable.
- `/mods` traversal: **25503 entries**, no exclusions or traversal failures.

0.112 accessor correction validation:

- Full project suite: **990 run, 983 passed, 7 skipped**.
- Native controller: **50 cases**, each exercised with Lua 5.1 and LuaJIT.
- Main integration: **14 cases**, each exercised with Lua 5.1 and LuaJIT.
- Tests distinguish typed-only native properties from misleading dynamic fields;
  incomplete bindings, getter/setter failures, binding replacement and fresh
  object-identity checks cannot silently enter a generic dynamic-field path.
- Read-only diagnostics and their UI button invoke no setters or renderer
  enablement changes. Expected refusal messages omit Lua source-path prefixes.
- `/mods` traversal: **25524 entries**, no exclusions or traversal failures.
- No shader, GPU fixture or live native state was changed for this correction.
  No in-game acceptance or visual improvement has yet been verified.

Primary contract reference: [BeamNG PostFX documentation](https://documentation.beamng.com/modding/postfx/).
Installed sources inspected include `lua/ge/extensions/core/settings/graphic.lua`,
`lua/common/luaBinding.lua`, `lua/ge/extensions/mcp/tools/scene.lua` and
`shaders/common/postFx/sssr/include/`.
