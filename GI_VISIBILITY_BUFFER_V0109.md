# BeamRT v0.109: game-side geometry visibility handoff

## Missing / changed / implemented

The native worker and GPU visibility consumer existed offline, but no game-side
control connected the intermediate output to GI. Existing mesh GI also selected
only the guardhouse, even when the player was in the sewer.

This cycle adds an **opt-in engine-managed PostFX backend**, not DLL loading or
an assertion that native D3D12 interception works. It exports current GI receiver
origins, computes receiver-to-world-surfel visibility against the actual imported
mesh, and binds that GPU target to the existing v084 GI consumer. The game pixel
producer and native compute producer now share one query/encoding implementation.
No guessed GPU handles, CPU visibility readback, invented lights, final-image
darkening, ReShade or native game-file modification.

`setSharedMeshVisibilitySource('underground')` selects a prepared nearby static
underground instance by its actual bounds, using the already-imported eight WCU
assets. It works with both existing inline v083 tracing and the new buffer path.
It does not load/install the unsupported clustered/headlight hook. The guardhouse
selection remains available. One section is not an entire sewer.

Default remains OFF, backend inline, source guardhouse; no preset is rewritten.
The buffer rejects invalid/stale frames, dimensions and material/geometry state.
Overflow or missing inputs falls back to inline tracing. Disabling visibility,
BeamRT OFF, mission change and unload stop its extra passes and restore original
GI shader/source inputs. Existing history reset is reused, not a new denoiser.
Frame preparation moves ahead of receiver export only while the buffer is active;
GI does not prepare/sample a second time during its matching consumer draw.

Known alpha-tested/blended/unknown materials still retain fallback. Only a real
declared-opaque intersection rejects a world bounce. Screen GI and native sun,
headlight, ambient, reflection and emissive rendering are not replaced.

## Boundaries and workload

The first pass is capped at 1,048,576 receiver/surfel pairs per frame. All passes
use matching GI dimensions and full-float targets; no low-resolution mask is
silently stretched over different receiver origins. Normal resolution usually
exceeds the first budget, so it keeps inline tracing. An **explicit** temporary
GI scale below 0.5 is now allowed (minimum 0.05); normal presets stay unchanged.

For the first test, 0.05 gives 128x72 GI at 2560x1440, or 192x108 at 3840x2160,
within the 32-surfel budget. The native scene remains full resolution; the GI
contribution will look rough. Do not save this temporary quality as a normal
preset. These shaders are physical geometry queries despite being scheduled as
pixel passes; the native C++ worker is **not attached to BeamNG**.

Unknown texture/output/header state preserves the previous contribution.
Callbacks saying “scheduled” or a CPU `effective` flag are not GPU execution or
appearance evidence. Status deliberately keeps those verification flags false.
If no world samples or supported opaque material resolve, read the inactive
reason; do not add another wire/debug shader.

## One compact game validation

Use **GE Lua**, one line per console entry. Park in/near a prepared WCU steel
factory sewer/underground section. Keep daytime, car/walk mode, lights and camera
unchanged during the visibility comparison. No old sunlight/guardhouse test.

Reload (preserves current unsaved settings; unloads cached BeamRT helpers):

```lua
do beamrtBridgeSaved=beamrt_main and beamrt_main.getSettings(); local names=extensions.getLoadedExtensionsNames(); if beamrt_main then beamrt_main.disable() end; extensions.unload('beamrt_main'); for _,n in ipairs(names) do if n:match('^beamrt_') then extensions.unload(n) end end; for k in pairs(package.loaded) do if type(k)=='string' and k:match('^ge/extensions/beamrt/') then package.loaded[k]=nil end end; extensions.load('beamrt_main'); if beamrtBridgeSaved then beamrt_main.applySettings(beamrtBridgeSaved) end; beamrt_main.start() end
```

Activate the complete small slice (explicit temporary hybrid contribution/scale):

```lua
do local ok,why=beamrt_main.setSharedMeshVisibilitySource('underground'); assert(ok,why); beamrt_main.setGIRenderScale(0.05); beamrt_main.setGISource('hybrid'); beamrt_main.setWorldGIStrength(0.35); beamrt_main.setSharedMeshVisibilityBackend('buffer'); beamrt_main.setSharedMeshVisibilityEnabled(true); dump(beamrt_main.getSharedMeshVisibilityStatus()) end
```

Wait for normal world-cache acquisition, then toggle **Full-mesh GI visibility**
OFF/ON in the tuner at the same view. The separate “GI visibility buffer” control
switches backend and is not the unoccluded baseline. Expected: v0.109, selected
underground object/triangle count, `backendActive='buffer'` once world samples
exist and budget fits. Only blocked WORLD-cache contributions should change;
native daytime fill/headlight light leaking can remain unchanged.

Decision: if normal rendering changes/restores correctly, this establishes the
engine-managed producer-to-GI path and we expand geometry coverage. If rendering
is unchanged, inspect the existing log for shader/target errors and compare
buffer ON against **inline visibility ON** once at the same settings. Inline
works/buffer does not identifies handoff/binding; neither changes does not prove
a handoff failure (there may be no contributing blocked world path). Do not
repeat sunlight comparisons or invent intensity/filter fixes.

Restore original settings after the bounded comparison:

```lua
beamrt_main.setSharedMeshVisibilityEnabled(false); beamrt_main.setSharedMeshVisibilityBackend('inline'); if beamrtBridgeSaved then beamrt_main.applySettings(beamrtBridgeSaved) end
```

This does **not** promise a pitch-black daytime sewer or fixed native orange
headlight bleed. Those need ambient/secondary-light visibility and actual
clustered local-light integration, not a whole-image darkness multiplier.

## Verification / next substantial milestone

Strict FXC VS/PS builds passed for both game passes and v084 GI; MSVC /W4 /WX
native fixtures passed. The **actual game pixel producer** fed the exact shared
GI consumer predicate on RTX 4070 and WARP, with real guardhouse data. This is
offline GPU validation, not the full BeamNG GI draw or live underground proof.
All 120 tracked Python/Lua tests and 26 local full-main integration/motion tests
passed. The original v082 pixel binary remains byte-identical (SHA256
`924033ff8e0473e83e7fc8983d56f5d405acdfbbe58cdd733181c83a79a37cdc`).
Debug layer unavailable locally; performance, live bindings, sewer appearance,
alpha textures and game-side OFF restoration remain unverified. No Git publish,
DLL load, sandbox change or game installation beyond editing this unpacked mod.
The committed old worker ABI mismatch was restored to the v2 baseline already
chosen by the user; it does not participate in this game-side backend.

Next: prove this one game GI handoff, expand to adjacent real mesh instances,
then light visibility at secondary hits. Native C++ resource capture remains a
separate reviewed host task; an engine-managed mask is not proof of DLL access.
