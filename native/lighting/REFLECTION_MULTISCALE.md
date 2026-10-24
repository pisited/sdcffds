# Opt-in reflection reconstruction at three scales

The old GI square pattern used a shared fixed world-cell ray. Its later spatial
and temporal reconstruction is a useful technique, not proof that current
cockpit reflection grain has the same cause. Reflections already had a disabled,
one-scale variance experiment. This extends that path instead of replacing the
tracer, adding ReShade, changing preset intensity or blurring the final image.

When explicitly enabled in playable GGX, the graph is:

`trace -> raw moments -> temporal -> filter 1 -> filter 2 -> filter 4 -> compose -> history copies`

Each filter reads the previous color output and the same raw-sample luminance
moments. Depth, decoded normal, roughness and F0 gate neighboring receivers.
The extra scales bypass roughness <=0.08 and fade in through roughness 0.20;
these buffers do not identify reflected hit layers, so wider filtering must not
be advertised as preserving all sharp reflection detail. No extra rays.

Signed receiver depth/lifetime stays unchanged. Fresh valid black/zero GGX
samples participate; invalid/grace neighbors cannot donate radiance. Nonfinite
input or statistics cannot poison the weighted sum. Unsupported/stale moments
leave the temporal result unchanged. Moments retain RGBA32F; colors remain
RGBA16F. The history copy still reads the **pre-variance temporal result**, not
the final spatial output: this avoids progressively feeding extra blur back
into temporal history. Existing temporal filtering itself is unchanged.

## Scope and evidence

`reflection_filter_test.cpp` executes the actual v003 filter, v002 one-scale
comparison and reflection moments shaders using installed game headers. It
uses a 32x16 fixture-owned receiver, RGBA16F intermediate filter targets,
RGBA32F statistics and GPU readback. It is not a game frame or performance test.

RTX 4070 and WARP both pass **28/28** checks. Controlled zero/bright sample field:

| Quantity | Input | One scale | Three scales |
| --- | --- | --- | --- |
| Spatial variance | 0.0155296 | 0.00750213 | 0.00139060 |
| Mean radiance | 0.134766 | 0.135668 | 0.135960 |

Three-scale variance is approximately **81% lower than one scale**, with mean
radiance approximately **0.89% above the input** in this controlled field. Do
not apply those percentages to the user's screenshot. Uniform HDR/black fields,
polished-detail bypass, zero-strength passthrough, signed lifetime, depth/normal/
roughness/F0 boundaries, stale/invalid statistics and zero-estimator participation
have explicit checks. The existing history fixture remains 35/35 on both.

Actual Lua graph/setter tests check step constants, 1/3 switching, graph order,
pre-variance color history, mirror/audit/convergence bypass and OFF restoration.
They mock engine objects, not resource lifetime or BeamNG execution. Strict SM5
compilation does not certify the game's SM6 execution. Debug layer unavailable.

Full project suite initially passed **227/227**. A later rerun passed **224/227**:
separate, concurrently changed `native/startup/build.ps1` no longer includes
embedded binding sources, binding-startup fixtures or loader-test options.
The binding, binding-handoff and loader source contracts reject that rollback.
This reflection work did not modify or restore that file. Focused reflection
graph tests (6), history guards (5) and Lua/renderer contracts (11) still pass.
The user subsequently explicitly approved restoring the observer build wiring;
the full project suite returned to **227/227** before the separate DLL test.
The final post-test check found that rollback had reappeared without an edit by
this agent: discovery is again **224/227** with the same three startup contracts
failing. This source conflict is preserved for coordination; it does not change
the frozen reflection GPU results or the frozen DLL observation evidence.
After the user closed VS Code, the authorized startup wiring was restored again
and the full suite passes **227/227**. The script parses cleanly and remained
unchanged through a subsequent check more than one minute later; the rollback
writer remains unknown. No rebuild, shader change or BeamNG launch was needed
for this source recovery.
Registered PostFX VS/PS compilation: **48/48**.
Frozen filter bytecode, executable, source inputs, readback logs and SHA256
manifest are retained under ignored
`.beamrt-validation/reflection-filter-green-489284589b0f4dba847157f163638adb`.
Pre-edit source inputs are retained under
`.beamrt-validation/reflection-filter-before-46c8495d9947486a8d41e4da80414d03`.

## Cost and controls

Default remains OFF, and presets/saved tuning do not enable it. ON with three
scales adds two full-resolution RGBA16F targets versus the prior one-scale
experiment: estimated extra **56.25 MiB at 2560x1440**, or **126.56 MiB at 4K**,
plus two pixel passes/bandwidth. The existing experiment's two RGBA32F moments
targets and first RGBA16F output are additional to ordinary SSR. No game FPS or
memory measurement yet. One scale is available for a cheaper comparison.

Use a normal BeamNG session, no native test launcher. Reload the Lua extension
to pick up main.lua and the new v003 shader entry. This preserves ordinary
unsaved tuning but resets histories and leaves mesh experiments off:

```lua
do local s=beamrt_main.getSettings(); beamrt_main.disable(); extensions.unload('beamrt_main'); extensions.load('beamrt_main'); beamrt_main.applySettings(s); beamrt_main.start() end
```

This reload is Lua-only; it does not load/unload a native DLL. If retained game
shader/target caching is suspected, use a normal restart instead. After loading
BeamRT, select playable GGX and enable the optional filter (one GE Lua line):

```lua
beamrt_main.setReflectionSamplingMode('ggx'); beamrt_main.setReflectionReconstruction('playable'); beamrt_main.setReflectionVariancePasses(3); beamrt_main.setReflectionVarianceEnabled(true)
```

The tuner also exposes **Variance filter ON/OFF** and **Use one/three filter
scales** buttons. Compare the same parked cockpit view with those controls,
then rotate the camera to check lost detail or trails. OFF restores the ordinary
reflection graph, not an absence of reflections:

```lua
beamrt_main.setReflectionVarianceEnabled(false)
```

Optional cheaper comparison: `beamrt_main.setReflectionVariancePasses(1)`.
Strength defaults to 0.65; `setReflectionVarianceStrength` accepts finite values
and clamps to [0,1]. Zero is a color passthrough but still runs allocated passes;
use OFF to remove them. No GI preset, exposure or light-source workaround was
changed. Live cockpit improvement, final composition, game ordering, GPU cost,
dynamic-source behavior and shutdown/restoration remain in-game test gates.
