# BeamRT v0.130.9 — experimental native per-light visibility relay

**Current integration boundary:** the installed engine's
`lua/ge/extensions/core/settings/clusteredQuality.lua` uses **`ClusterShading`**.
Previous guards checked only `ClusteredShading`, so an exposed clustered
interface was mistakenly allowed through the legacy-material gate. v0.130.9
recognizes both names in native visibility, local-mesh hooks and status/UI;
it refuses the unintegrated route before native material writes. Exposure is
not proof of a particular GPU dispatch. The live dispatch probe remained gray
and `AL_SpotLightMaterial:dumpInstances()` listed no instances, so neither
legacy execution nor native visibility has been verified. This is a guard fix,
not a working clustered shadow export. No engine quality/backend is toggled.

This is a **different diagnostic**, not another revision of the camera-depth
tracer. It instruments the installed native point/spot shader **after its real
light-space shadow calculation**, before optional lightmap adjustments. Native
projection, shadow texture, filter, bias, cookies, irradiance and RGB BRDF formulas
are retained. No additional shadow attenuation is applied to beauty or GI.

The confirmed `Advanced Lighting 1.5` build writes zero to specular/lightinfo RT1
alpha, and its inspected lighting consumer reads only RT1 RGB. The experiment
temporarily leases one native light-kind shader plus one extra sampler. It puts
quantized native visibility in that otherwise-unused alpha and displays it in a
separate PostFX. The tag and snapshot use owned `PFXTexGenOnDemand` child targets,
explicitly scheduled before/after the registered `AL_LightBinMgr` every frame.
The late display
reads only our early snapshot, never the transient native lightinfo target.
Installed game files and native light/material parameters are
not changed. Actual dispatch, RT1 binding/format and visible output are still
**unverified until tested in-game**. Other mods consuming RT1 alpha are unsupported.

At night, while the intended scene lamp is enabled, run in **GE Lua**:

```lua
extensions.reload("beamrt_main")
extensions.beamrt_main.startNativeShadowDiagnostic("SpotLight_11011175112730191")
```

The v0.130.7 live test confirmed synchronized CPU callbacks for all five passes,
but the view was gray (no matching packet). A read-only engine texture query
reported `GFXFormatR16G16B16A16F` for `#lightinfo[RT1]`, so alpha storage exists.
v0.130.8 adds explicit marker probes to isolate the native PS output path:

```lua
extensions.reload("beamrt_main")
extensions.beamrt_main.startNativeShadowDiagnostic("SpotLight_11011175112730191", "dispatch")
```

Dispatch probe: cyan = a candidate surviving negative marker from any native
draw of this light kind, NOT the selected lamp and NOT shadow visibility.
It bypasses tuple selection and the native frame-tag sampler. Gray = no marker;
18 white bars = unexpected alpha data. Neither proves why a marker is absent.
After a cyan result, use `"selector"` instead: orange means the selected native
parameter tuple's marker reached capture. The default `"visibility"` remains
the separate frame-tagged shadow diagnostic. Probe results never feed GI.

Startup first checks CPU readiness, then stops BeamRT custom rendering/captures
before installing the native diagnostic. It does not change time, native SSR,
shadow quality, lamp brightness/color/casting flags or physics. Do not enable
PTGI/Coherent or the screen-depth diagnostic during this comparison.

- Green: native sampled visibility near 1; red: near 0; intermediate colors:
  native filtered partial visibility, quantized to 16 display levels.
- Transport failures retain a faint scene and show numbered white bars along
  the top. Count the bars: 1 = wrong frame texture size; 2 = nonfinite frame data;
  3 = missing frame signature; 4 = stale frame epoch; 5 = incompatible lightinfo
  dimensions; 6 = nonfinite native alpha; 7 = matching draw reports unavailable
  shadow data (`NO_SHADOW`/invalid map). These are **not** shadow visibility.
  Snapshot failures use 8 = absent texture, 9 = invalid signature, 10 = stale
  epoch, 11 = invalid status, 13 = early capture not scheduled this epoch.
  Version 0.130 used the same magenta for every one of these failures; a solid
  magenta screenshot from that version cannot distinguish them.
- Dark gray: no matching current-frame native sample. Could be outside coverage,
  an unused legacy path, a missing RT1/alpha relay or a selector mismatch; **not lit**.

Compare an off-screen caster by moving the camera while keeping the lamp and
receiver fixed. Native map caster selection, range and shadow budgets still apply;
this does not create complete world coverage or new BVH geometry.

The binary16 relay has **1,919 non-repeating frame tags per controller lifetime**
(about 32 seconds at 60 FPS, less at higher FPS), after which it automatically
restores native shader ownership. This bound prevents tag wrapping from accepting
old data. Manual stops/restarts do not reset its budget; reload for another test.
Freshness after a full reload still relies on the native light-buffer clear and
same-frame producer order and therefore remains part of live verification.

```lua
extensions.beamrt_main.getNativeShadowDiagnosticStatus()
extensions.beamrt_main.stopNativeShadowDiagnostic()
```

`inspectNativeShadowInputs(nameOrID)` is a read-only readiness report. It requires
the confirmed manager, unmodified native material/shader/shadow alias, a uniquely
resolved static scene point/spot light and pinned installed source dependencies.
Exposed clustered dispatches, coincident selectors, disabled/moving lights and
other native shader hooks are refused. Native dispatch does not supply a scene
object ID in this legacy constant layout: the match uses the unique light
position/range and spot direction/outer cone, not a guessed persistent ID.
Status includes setup and per-draw callback counts and reported output sizes;
these prove only CPU processing, not valid GPU output. Counters survive stop/
timeout (`passesAreLastStop=true`), so status can be requested after the bounded
test. The v0.130.1 live screenshot
showed stage 1 (tag input not 1x1), before any native visibility was read.
The v0.130.2 live test stopped at epoch 32 because its guard incorrectly required
on-demand children to report enabled in the PostFX manager. v0.130.3 checks root
enable state separately from child ownership/bindings; an on-demand child can
legitimately report disabled while its parent processes it. GPU success remains
unverified.
The v0.130.3 test reached the child-attachment guard, which compared Lua wrapper
equality. v0.130.4 compares registered native IDs instead: a base SimObject
wrapper returned by enumeration need not equal the retained PostEffect wrapper.
It still requires exactly one correct child, verifies this before the native
material lease, and reports child counts/IDs on a real mismatch.
The v0.130.4 test showed stage 10 (stale snapshot). v0.130.5 uses
`setShaderConsts` rather than the potentially once-only `preProcess` callback
for per-frame authorization. Two 1x1 scratch scheduler draws ensure those
callbacks are invoked; they never write scene color. Stale snapshot rejection
is unchanged. Live refresh/native visibility still require verification.
v0.130.6 switched false-state checks to native field readback: the live binding
returned `skipDrawNative="0"` but the direct Lua property was nil. Each scheduler
field is now validated separately, with actual/expected values retained on failure.
The resulting live counters showed zero scheduler draws, one lazy child draw,
and hundreds of late display draws. v0.130.7 corrects the hook from the wrong
`AL_LightBin` name to `AL_LightBinMgr` found in the installed executable. Startup
requires that exact registered `AdvancedLightBinManager` object and identity.
If either early root still has zero CPU draw callbacks by epoch 64, it restores
instead of displaying a stale snapshot for the entire budget. Native GPU
visibility is still unverified; registered object presence is not execution proof.

Only owned fields/objects are restored; foreign replacements are not overwritten.
Failed restoration retains the lease and neutralizes the relay/display for retry.
Mission/settings/source changes, captures, custom rendering and changed selection
stop the test. This does **not** feed native visibility into PTGI or change its GI
source. See [integration notes](docs/light-visibility-diagnostic.md).

Private shaders can be prepared again against the current installation with:

```powershell
.\.beamrt-validation\python-tests\Scripts\python.exe -I -B tools/beamrt_native_shadow_diagnostic.py --game-root E:/SteamLibrary/steamapps/common/BeamNG.drive
```

## v0.129.2 — depth-crossing refinement for the visibility diagnostic

The repeated offset outlines remaining in v0.129.1 exposed a separate sampling
problem: 32 steps across 12 m can skip the old 1.5–12 cm accepted depth band,
turning continuous blockers into phase-dependent strips. The v003 shader now
brackets signed depth crossings and refines up to two brackets with six bisections
each. A candidate must converge to within 2 cm of sampled depth and still pass
the geometric receiver-plane rejection. Both crossing directions are supported.
Missing/sky samples reset the bracket; a discontinuous depth sign flip alone is
not accepted. This remains single-layer depth evidence, not complete geometry.

The base budget remains 32 coarse samples / 12 m reach, plus at most 12 refinement
samples. Bias, native shadows, GI and beauty rendering are unchanged. Missed thin
occluders and exhausted/invalid brackets remain amber/unknown, never proven clear.
At night, reload and reselect the same lamp by name using the command below.
Live reduction of the repeated bands still needs verification in the game.

## v0.129.1 — receiver-plane rejection for the visibility diagnostic

This diagnostic-only update targets receiver self-intersection (red acne).
It reconstructs geometric normals from the nearer valid depth neighbour on each
axis, offsets by a bounded 5–25 mm, and rejects candidates on/behind the receiver
plane (3–15 mm tolerance). Point depth samples now reconstruct the actual texel
centre's world ray. Missing/degenerate/discontinuous receiver frames remain
unknown rather than fabricate a shadow. Very small blockers within that plane
tolerance can still be missed; this is not a complete geometry visibility system.
The 32-step/12 m probe and 12 cm hit-thickness assumption otherwise remain.
No shadow-map/cascade settings, native lamps, GI or beauty equations change.

At night, reload and select the same lamp by its scene name for comparison:

```lua
extensions.reload("beamrt_main")
extensions.beamrt_main.setLightVisibilityDiagnostic("visibility", "SpotLight_11011175112730191")
```

Reload stops BeamRT rendering. The diagnostic alone does not restart PTGI or
Coherent; compare it before enabling beauty rendering again. This revision uses
a new shader path to avoid reusing the old compiled variant. Compilation/tests
do not establish in-game acne reduction or preserved shadow contact.

## v0.129 — separate light visibility diagnostic

The latest glass report names `character_glass`: the controlled object was the
walking avatar, not the parked car. Glass startup now refuses the native
`unicycle` walking-character identity **before changing the test preset or
requesting GPU geometry**. Enter the intended car first; free camera is fine
afterward. No caster/opacity guard was removed. This does not yet prove that
the car's glass capture or sunlight transmission works.

The next milestone is diagnostic, not another beauty preset. Native scene
PointLight/SpotLight declarations now feed an opt-in **one-selected-light**
display, separate from indirect GI. In GE Lua, reload once, then list nearby
candidates (one explicit enumeration, nearest 16 reported):

```lua
extensions.reload("beamrt_main"); extensions.beamrt_main.listLightVisibilityCandidates()
```

Use an actual ID from that report in place of `123`:

```lua
print(extensions.beamrt_main.setLightVisibilityDiagnostic("visibility", 123))
```

It works without enabling PTGI/Coherent and does not start either renderer.
The selected light is re-read each frame, without rescanning the map or touching
shared provider caches. The status report identifies its ID/name, source position,
axis/cone/range, brightness, enabled-state certainty and requested shadow policy.
`castShadows` is a request, **not proof of an allocated or sampled shadow map**.
Unknown enabled state is explicitly unavailable, never silently assumed on.

| View | Meaning |
| --- | --- |
| `influence` | Relative unoccluded potential: normal, distance, spot cone, declared brightness/color and windowed inverse-square falloff. Fixed log display gain, not calibrated engine photometry. |
| `direction` | World-space receiver-to-selected-light direction encoded as `0.5 * direction + 0.5` RGB. |
| `visibility` | Red: plausible screen-depth blocker; amber: unknown, **not proven clear**. Dark gray: disabled/outside potential influence/back-facing. Magenta: enabled state unavailable. |
| `native` | Magenta: native per-light visibility unavailable to this diagnostic. No atlas/view binding is guessed. |

Switch views without rescanning/restarting, inspect status, then turn it off:

```lua
extensions.beamrt_main.setLightVisibilityDiagnostic("direction")
extensions.beamrt_main.getLightVisibilityDiagnosticStatus()
extensions.beamrt_main.setLightVisibilityDiagnostic("off")
```

Only the explicit diagnostic replaces the display, after renderer histories and
haze; stopping removes it. It does not modify native light/material fields,
graphics settings, GI transport, beauty brightness or shadow attenuation.
Captures, source/settings changes, mission changes, unload and lost object
ownership stop it. Shader compilation and Lua tests are not live GPU proof.

The screen probe has 32 fixed samples and at most 12 m reach. It cannot establish
off-screen visibility, thin/transparent geometry or complete chassis coverage;
its 12 cm depth-hit tolerance is approximate. Scene lights only for now: no sun,
vehicle-prop telemetry, emissive sources, cookies, calibrated intensity conversion
or full geometry visibility integration. See [the visibility integration
notes](docs/light-visibility-diagnostic.md) for native resource findings and the
direct/indirect ownership boundary.

## v0.128.1 — explicit glass rejection diagnostics

The reported `No supported exterior window triangles` failure happens before
the sunlight hook is installed. Strength 0/1 cannot compare glass shadows when
that capture has failed. No renderer success is inferred from that message.

The glass panel now has **Explain glass material rejection**, or after reloading
BeamRT run this GE Lua command:

```lua
extensions.beamrt_main.inspectGlassSunMaterials()
```

This is a read-only scan of the current player vehicle's glass-like material
names and live declarations; it does not capture GPU geometry, enable rendering,
change material fields, pause physics or change settings. It logs each material's
first rejected contract plus raw checked fields. Failed captures also include
up to four exterior rejection reasons in their status. The report distinguishes
empty/missing opacity maps, caster flags, source/version/layer declarations,
alpha/instance opacity and UV limitations. It is not proof of native GPU behavior.
No selection guard, GI math, source policy or shadow equation was relaxed.

## v0.128 — paused-vehicle glass sunlight transmission experiment

Park in sunlight and pause physics with **J**, then run this in the **GE Lua**
console (BeamNG integrated SSR must already be off):

```lua
extensions.reload("beamrt_main"); print(extensions.beamrt_main.startGlassTest())
```

The public preset starts baseline PTGI + Coherent, native material response,
eight reflection rays, temporal accumulation and automatic lamp shadows, then
requests the glass snapshot. It preserves existing GI/brightness tuning.
Named HDR handoff, local haze, the old glass-caster probe and diagnostic views
are off. It never changes native graphics settings, sun/time, window opacity
or physics pause itself. Status reports asynchronous readiness/failure; a CPU
"scheduled" message is NOT proof of GPU output. Inspect Lighting & GI → Mesh
visibility and shadows for the actual exterior material names and triangle count.

This is a separate **deferred sunlight** experiment, not the v0.127 caster flag.
It reads the player's actual native flexmesh triangles and UV0, including
`_glass_tint`, excludes duplicate interior glass, builds a bounded BVH, and
publishes an R16 geometry cache in `settings/beamrt/glass_snapshots`. Native
opacity maps and opacity factors determine scalar transmission at each ray
intersection. Coplanar seam hits merge; separate panes multiply transmission.
`T = 1 - opacity` is an appearance-driven extinction approximation, not
calibrated absorption, refractive/Fresnel transport or measured window tint.
Maximum eight crossings, three exterior materials and 4096 triangles. Unsupported
or incomplete captures fail explicitly; there is no geometry truncation or
guessed window-plane replacement. Native world-vs-origin-relative coordinates
must pass the live vehicle OBB bounds check, otherwise activation is refused.

A full-resolution receiver-identified mask is produced before native direct
sunlight, and a private copy of the installed sunlight shader multiplies its
existing visibility by window transmission. Body/scene/cloud shadows remain
native, never brightened. No final-image darkening, native installation edits
or material remapping. This uses six producer texture inputs and one extra
native sun input. Other native sun hooks must be disabled first. The installed
source-specific shader can be prepared again using:

```powershell
.\.beamrt-validation\python-tests\Scripts\python.exe -I -B tools/beamrt_glass_sun_prepare.py --game-root E:/SteamLibrary/steamapps/common/BeamNG.drive
```

Compare without recompiling or changing the lighting:

```lua
extensions.beamrt_main.setGlassSunShadowStrength(0) -- native baseline
extensions.beamrt_main.setGlassSunShadowStrength(1) -- opacity-map extinction
extensions.beamrt_main.setGlassSunShadowsEnabled(false) -- restore native sunlight
```

**Limits:** physics must remain paused. Resume, vehicle/pose/material changes,
captures, settings, reload, mission transitions or disable-all stop/release the
snapshot. Readback is asynchronous and times out after five seconds. Up to eight
snapshots per module session bound cache churn. No moving/deforming cars, window
prop transforms, damaged/alpha-tested glass, animated UVs, RGB transmission,
local-lamp/headlight glass shadows or new window reflections yet. This does not
repair the separate late-GI/transparent-composition limitation. Offline shader
compilation and CPU tests are not live appearance or performance proof.

## v0.127 — native window shadow probe

Lighting & GI → Mesh visibility and shadows (experimental) now offers **Try
native window shadows** and **Restore window shadows**. This is a deliberately
limited A/B probe, NOT lighter/tinted transmission rendering. Test a stationary
vehicle in sunlight or beside an existing shadow-casting lamp. Native shadow
submission may ignore translucent casters or make them solid; neither outcome
is reported as working transmission. Please compare the ground/interior shadow
through a window opening, not the appearance of the glass itself.

The probe inspects the selected player vehicle's live material names and only
requests `castShadows` for narrowly identified, non-emissive, single-layer,
non-alpha-tested translucent window Materials from vehicle material files.
Unsupported materials are left alone. Opacity/maps, blending, body/interior
materials, GI, Coherent, native shaders and files are not changed. Native
Materials are shared, so other vehicles using the same Material also inherit
the temporary request. This does not add window reflections or RGB shadows.

Default OFF; no automatic activation. Restore, disable-all, reload, vehicle
switch, material changes, settings changes and mission lifecycle release the
owned values. A failed restore retains its lease and exposes a retry button;
replacement materials and subsequent edits are not overwritten. Inspection is
read-only and lists the actual accepted material names. CPU tests establish
selection, rollback and ownership only; live shadow opacity remains unverified.

## v0.126 — compact continuous vehicle haze and rear-light fairness

Vehicle haze no longer borrows the lamp sphere integrator. Its v006 shader
intersects each view ray with the finite positive cone (or the real point-light
sphere), then integrates sixteen deterministic samples inside only that segment.
Depth still limits the result. This avoids the sparse eight-samples-across-the-
whole-sphere pattern that produced stepped/sliced headlight volumes. The original
eight-sample streetlamp kernel is unchanged, as are reflections, GI and shadows.
This is still an unshadowed cone approximation, not native beam-cookie rendering.

Vehicle haze now has independent defaults: 20 m beam reach and 0.35 beam gain,
3 m point/red-light reach and 1.0 halo gain. All reaches are capped by the
authored light range, never written back to native lights. The tuner exposes
four separately labelled vehicle brightness/reach controls. These are artistic
haze bounds, not a claim of calibrated atmospheric scattering or shorter native
headlight illumination. Increasing samples can cost GPU time; the shorter
footprint and cone clipping may offset it, but no FPS improvement is claimed.

Both telemetry and the four-source selector now retain active red/orange light
props instead of allowing bright headlights to occupy every slot. Up to two
red-dominant sources are reserved, with the remaining slots importance-ranked.
The colour threshold excludes ordinary warm halogen headlights; it is source
classification, not a guess of a physical rear position. Nearly coincident,
same-vehicle, same-kind, same-colour and aligned props are merged for haze
(strongest retained, not summed). The existing four-source GPU budget remains.
The panel shows reported/eligible/red-selected/merged counts. An emissive-only
tail texture is still not a native light prop, so missing native sources are
reported rather than fabricated. Very weak real tail lighting can remain subtle.

The on-demand VL sampler is protocol-versioned and refreshed on mismatch, so an
extension reload does not silently keep the old first-32-props sampling policy.
CPU tests cover red-source starvation, telemetry fairness, compact bounds,
overlapping props, retained native ranges and lifecycle. Numerical cone tests
check randomized support, positive/backward cones, parallel/tangent/point/depth
cases and continuity against a dense reference. Shader compilation and CPU tests
do not prove the in-game visual result; reload once and compare from the same
camera with vehicle lights on and off.

### Glass investigation (not implemented by this haze patch)

Inspected installed shader paths: `common/material/shadergen/permutations.h.hlsl`
has a distinct forward glass-lighting path, with cube reflection behind
`MFT_CubeMap`. Its dedicated native SSR surface capture also has a separate
reflection/transmission receiver route. Coherent currently reads the ordinary
prepass; it has no independent transparent-window receiver depth, normal,
coverage and material layer. Underlying opaque depth/material data cannot
reliably substitute for that glass surface. Increasing global SSR intensity or
making glass opaque would not be a correct window-reflection fix.

The installed native sun/vehicle shadow lookup (`calcShadowPSSM` /
`calcShadowVehicle` in `common/lighting/shadowMap/shadowMapPSSM.hlsl`) returns
scalar depth visibility, not RGB glass transmittance. The inspected stock
`pickup_glass` declarations in `common.zip` already request `dynamicCubemap=true`,
declare `translucent=true`, and set `castShadows=false`. Those examples establish
native reflection support, not proof of the cause on every live vehicle.
Proper lighter/tinted glass shadows require a transmission-aware light-space
layer, preserving opaque body/interior occlusion. This patch does not toggle
glass shadow flags, alter opacity/materials, edit installed shaders, or claim
that glass reflection/transmission is now implemented.

## v0.125 — LED discovery repair and vehicle-light haze

Prepared LED discovery no longer relies on numeric scene mask `256`. It uses
the native `SOTStaticShape` constant when available, plus a read-only TSStatic
class scan that continues past the first 128 results. The incremental scan
inspects up to 128 entries per update with a soft 2 ms budget after the first
24, refreshes no more often than five seconds, and caches at most 64 matching
prepared-asset instances. It does not rescan arbitrary material contents.
This fixes the first-batch starvation path; it is not proof of the exact live
rejection behind the earlier 0/2 screenshot.

The tuner now shows inspected/matched/pending counts and rejection stages:
hidden or render-disabled geometry, source integrity, placement, material fields,
instance-emission tint, native API errors, duplicate native haze or view distance.
Material booleans accept native numeric as well as string/boolean forms. Live
`instanceColor` is honored where `instanceEmissive` is enabled; night/day control
is not overridden. Coincident same-material emitters are deduplicated. The map
contains duplicate night-only LED layers, including authored render-disabled
instances; hidden sources are not forced on to make the counter nonzero.
The same two prepared LED assets remain supported, with visual alignment and
photometry still unverified.

Local haze now includes **Vehicle light haze**, enabled when local haze starts
unless deselected for this session. It uses a separate budget of four light
sources from up to four nearby vehicles, preserving the existing eight lamp
spotlights. Spot- and point-light JBeam props are supported, including headlights,
tail/brake/fog/reverse/indicator lights when authored as actual light props.
Purely glowing textures and custom lights outside the standard prop path are
not inferred from body brightness or material names.

The GE helper reads `getProp(pid):getLiveTransformWorld()` each render update,
adding vehicle translation and using the prop's +Y axis for spot direction,
following BeamNG's shipped vehicle light debugger. A small on-demand VL helper
reads the live prop disabled/hidden flags, its exact electrics function and
authored light settings. It mirrors the shipped props scaling and JBeam
candela/lumen conversions; it does not change electrics, props or native lights.
This is a derived approximation, not a readback of final native light radiance.
Native cookies, shadows, custom controller overrides and flare optics are not
sampled. Point props use the same eight-sample integration without a cone.

Nearby vehicle selection refreshes every 0.5 s and considers at most 64 registry
entries. Read-only VL requests are bounded to 10 Hz per tracked vehicle with one
pending request each; samples expire after 0.35 s. Prop poses update every frame
so beams do not wait for the lamp detector's 0.25 s upload cadence. Generation
tokens, monotonic sequence numbers and vehicle identity checks reject stale
replies, including reset/replacement/disable cases. The VL helper has no update
hook; disabling haze removes the owned GE callback and stops further requests.
All vehicle haze is unshadowed, depth-limited scattering and adds GPU/CPU work.
No native shadow budget, reflection/GI tuning or global fog settings are changed.

Reload once, enable local haze, and check **Active vehicle haze sources** while
switching car lights on/off and moving. For the LED experiment, enable its own
checkbox and inspect the new LED rejection status if the count stays zero.
Offline tests and v005 shader compilation validate CPU/math/lifecycle contracts,
not live game appearance or frame time.

## v0.124 — material-aware reflection and prepared LED haze experiments

Two independent A/B options are added; both default OFF. Existing ray counts,
roughness cutoff, reflection strength, PTGI tuning and native materials/lights
are not changed by enabling either option. Reload the extension once to load
the new modules and shader cache version.

**Reflections → Look → Native material response (experimental)** reads native
per-pixel RGB specular reflectance from `#prepass[RT1]`, alongside the existing
native normal/roughness inputs. A second material/texture library or material-name
guess is not used. Ordinary surfaces no longer use the legacy global face-on
blend-mask floor; material reflectance and view angle determine their response.
Zero-specular material data stays nonreflective even at grazing angles, matching
the native low-reflectance Fresnel guard. Water and procedural puddles retain
their existing model, including their legacy face-on control.

The new composition preserves scene direct/diffuse/PTGI lighting and adds a
bounded material-weighted screen-space reflection. This is NOT exact native
probe replacement or a full BRDF integration: native probe lighting cannot be
isolated from the final beauty input, so overlapping native specular can still
be counted twice. Incorrect native material authoring is not repaired. Ordinary
surface detail no longer needs the four beauty low-pass taps in this mode.
It uses the existing trace/history graph and adds no rays or fullscreen pass;
no measured FPS improvement is claimed.

Native integrated SSR must remain OFF (it can repurpose RT1). This option also
requires HDR composition and terrain material masking OFF, because Apply's sixth
texture slot is shared. Conflicting changes are refused, not silently applied.
Diagnostic views temporarily use their original bindings. Turning the option
OFF restores legacy composition; restarting preserves the chosen option. Missing
or invalid material samples retain the original beauty. These are CPU binding
checks, not proof of live GPU texture contents or the named HDR handoff.

**Lighting & GI → Volumetric lighting experiment → Prepared LED emissive haze**
is a separate opt-in after local lamp haze is enabled. It supports only the two
standalone Polish Roads Owlen LED meshes (`owlen_ledy.dae` and
`owlen_led_budynek.dae`), not the pylon sign, textured logos, arbitrary glowing
surfaces or vehicle lights. The prepared catalogue contains material-mapped
triangle quadratures from those installed assets; runtime verifies source size
and Adler checksum, material identity/emission state/map, live emissive RGB/nits
and native instance transforms. It creates no native lights and edits no assets,
materials, global fog or shadow fields.
Emission uses the live RGB/nits as a uniform approximation over the selected
geometry; it does not sample the emissive texture per triangle/texel. The known
red data map is not perfectly uniform, so its variation is not reproduced.

Read-only spatial discovery inspects at most 128 TSStatic query results every
0.5 seconds or after 4 m movement; at most two emitters are selected. Four
geometry-oriented area samples per mesh feed four deterministic view-integration
steps, with 12 m local source reach and the existing 160 m view limit. Nearby
same-colour native haze samples are suppressed by a conservative proximity
heuristic, not fixture identity. No bright-pixel emitter detection is used.

This produces **haze only**, not surface illumination or area-light GI. It is
coarse, unshadowed and uses an uncalibrated nits-to-working-radiance gain; hidden
blockers may leak, and native visual mesh/pivot alignment still needs an in-game
check. It does not imply support for every emissive material. The original
eight-spotlight wide haze remains available unchanged when this option is OFF.
Disabling/restarting haze, captures and lifecycle stops clear emitter discovery
and leave emissive haze OFF until explicitly enabled again. Adds GPU work.

Offline tests cover material routing/rollback/conflicts, cold restart, live
emission validation, source integrity, placement math, nonuniform scale, bounded
selection, native-source suppression and haze-only lifecycle. Coherent and haze
shaders compile against installed BeamNG headers. Live appearance, photometry,
shadow visibility and frame time remain unverified.

## v0.123 — separate wide haze discovery

Nearby native shadow discovery and priority assistance now use 100 m instead of
80 m, keeping the same eight-light priority budget and native light ranges.
The existing level-wide automatic `castShadows` eligibility requests are not
expanded or replaced; nearby distance is not a promise of a GPU shadow view.
Native shadow selection, atlas budgets and caster materials still apply.

Haze has its own read-only `volumeLights.lua` detector. It does not borrow the
shadow-prioritized list, require shadow assistance, or write any lamp fields.
While explicitly enabled, it queries a 180 m camera-centered region and selects
up to eight supported native spotlights by a bounded brightness/range/distance
importance estimate. Source spheres wholly behind the camera are rejected;
off-screen lamps remain eligible because their volumes can enter the image.
This is not an exact visible-contribution estimator. Invalid, disabled, replaced
and out-of-range sources are rejected. Native lamp range is never enlarged.

The spatial query refreshes every 0.25 seconds or on movement of 4 m / a camera
turn. It inspects at most 512 returned entries. If unavailable, a read-only
incremental class scan processes 24–128 entries per update, with a soft 2 ms
limit above the first 24; the fallback can take longer to find a new location.
Status identifies this route, pending checks and the bounded candidate cache.
No new discovery occurs merely by opening the tuner or while haze is disabled.

The v003 haze shader extends view integration from 50 m to 160 m and supports
eight lamps, retaining eight deterministic integration samples per intersected
lamp. Its maximum sampling cost is higher than v002; no FPS improvement is
claimed. Scene-preserving output and zero-contribution bypass remain intact.
This provides wider local coverage as the camera travels, not simultaneous
whole-world rendering. It remains an opt-in, unshadowed approximation: unseen
blockers can leak. Point lights, vehicle props and emissive surfaces are still
unsupported. Disable-all, captures, lifecycle changes and inactive rendering
stop haze and clear its detector; it does not restart shadow requests.

No Coherent material response, reflection strength, roughness, resolution or ray
count changed here. The material investigation confirms native per-pixel
roughness/normals are already used; a complete duplicate material/texture library
is not needed just to consume those properties. A material-specific reflectance
handoff and composition audit remain separate work; material-name guesses are
not silently applied to native materials.

CPU tests cover independent read-only discovery, wider shadow priority, camera
movement/turns, invalid/deleted/recycled lamps, bounded fallback/cache and haze
lifecycle. The v003 shader compiles offline in both stages. These are not proof
of live GPU appearance, shadow visibility, frame time or HDR-handoff correctness.

## v0.122.2 — combined restart recovery

Combined startup now recreates PTGI's nested PostEffect graph after safe teardown,
as well as Coherent's graph. Previously only Coherent was recreated; PTGI reused
its child passes and cached target/shader-requirement state after being disabled
and moved between stages. This recovery removes that retained state without
rebuilding ShaderData, native lights, materials or geometry, or changing saved
settings. GI/reflection tuning is retained. Repeated enable on an already-active
pair does not rebuild it. Failed cleanup/construction leaves rendering stopped
and permits a retry rather than reporting a partially enabled pair as ready.

The optional haze pass now uses beauty in input slot zero and explicitly writes
scene plus scattering to `$backBuffer`, with blending disabled. A native
passthrough must preserve the scene, not show the raw normals that previously
occupied slot zero or add the scene to itself. The cache-busted v002 shader uses
the depth slot's own UV transform. Haze is still optional, unshadowed and off
at combined startup; no reduction of ray count, resolution or reflection reach.

CPU regression tests use the actual PTGI child-pass constructors and exercise
repeated combined off/on, slider edits, retained-child contamination and failed
restart/retry in Lua 5.1 and LuaJIT. Offline haze VS/PS compilation also passes.
These checks do not establish the exact native GPU cause or verify the in-game
fix. Reload BeamRT once, test combined off/on with baseline source and haze off,
then enable haze and repeat. The named HDR source remains experimental.

## v0.122.1 — combined beauty recovery and source isolation

The user reports that v0.122 can claim both renderers are active while reflections
are not visibly working. CPU-enabled objects alone do not validate the GPU image.
The named HDR target is therefore no longer the default. Combined mode defaults
to the earlier ordered `$backBuffer` route, keeping the same PTGI-before-Coherent
staging. **Combined pipeline experiments → Try named HDR source** retains the
explicit-target experiment as a session-only, inactive-only choice for A/B tests.
The exact visual regression remains unconfirmed; this is a baseline recovery and
isolation change, not proof that VL or the named target caused the reported image.

Starting combined mode now restores GI ray/lighting diagnostics and Coherent's
debug display to beauty after capture guards and safe teardown. Previously a
retained Coherent debug view could make startup fail the combined beauty contract,
and GI debug modes were rejected rather than cleared. No sampling or appearance
settings are reset. Enabling Coherent manually while GI is active now joins them
through combined startup instead of taking the standalone path that disables GI.
Repeated enable on a complete combined graph is idempotent.

Volumetrics remain off whenever combined rendering starts (normal safe teardown
stops them first). Test the baseline without haze, then opt into haze or named HDR
one at a time. **Log combined pipeline state** is a read-only CPU report of actual
pass enablement, stages, shader, source/aux textures and targets, plus diagnostic
and haze state. It is not a GPU readback. An incomplete combined graph logs this
report before stopping, where serialization is available. Live recovery still
needs an in-game comparison.

## v0.122 — explicit PTGI handoff and local haze experiment

Combined rendering now gives Coherent an explicit current-frame scene producer:
native scene → PTGI compose → `#BeamRT_PTGI_LitScene` → Coherent color pyramid,
trace/rebuild, and final composition. PTGI composition writes a full-resolution
RGBA16F HDR target instead of the generic `$backBuffer` in combined mode only.
No extra copy/blit pass is added. The early shared depth pyramid still runs
before PTGI and deliberately keeps its native source; it must not read a target
that has not been produced yet. Each renderer retains its own history. This is
one-way lit-radiance sharing, not shared ray hits, a unified denoiser, or recursive
multi-bounce transport. CPU binding/order checks stop both on producer/consumer
loss; actual current-frame GPU execution and improved appearance remain unverified.
Disable restores the PTGI target fields and standalone Coherent scene binding.

Quality-neutral CPU reductions format vehicle-motion vectors once, suppress
identical native uniform uploads per owned pass, and avoid a duplicate Coherent
history reset on combined lamp updates. No ray count, resolution, trace reach,
history precision, roughness cutoff or lighting-strength preset was reduced.
There is no measured in-game FPS improvement claim.

**Lighting & GI → Volumetric lighting experiment → Try local lamp haze** is
explicit opt-in and starts no renderer. Start GI/Coherent first; keep automatic
lamp shadows and nearby priority enabled. It reads up to four selected native
SpotLights (color, brightness, cone, range and transform), without changing them.
A separate HDR pass after Coherent integrates an optically thin scattering
approximation with eight deterministic midpoint samples per lamp, up to 50 m
and the visible surface depth. The original v001 added scattering with One/One
blending; v0.122.2 supersedes that output path with a scene-preserving replacement
composition. No animated noise, accumulation or global fog
edits; it stays outside GI/SSR histories and is not itself reflected by SSR.
It adds GPU work when active and disables its pass when no supported lamp is
available or brightness/density is zero. Point lights, vehicle props, emissive
geometry and lamps without readable fields are not supported by this prototype.

**This is not shadowed volumetrics.** Native shadow-atlas visibility is not
bound. Visible foreground depth ends the camera ray, but walls or pipes between
the lamp and a scattering point can still leak light. This is an appearance
experiment, not a replacement for the native lamp shadows or physically
calibrated photometric transport. Test around factory pipes before expanding it.
Disable-all, mission/settings changes, extension reload/unload, pass loss and
active captures stop it; it does not silently resume. Cleanup failures retain
owned objects for an explicit retry. Live GPU behavior still needs testing.

Offline shader check for this experiment:
`tools/tests/validate_postfx_shaders.py --volumes --game-root <installed-game> --compiler <fxc>`.

## v0.121.2 — low-FPS nearby shadow discovery

Nearby lamp discovery no longer waits behind the level-wide queue when the
native `findObjectList` / `SOTLight` spatial query is available. Before background
inspection, it requests an 80 m camera-centered box, inspects at most 256 hits,
and processes the nearest 16 supported enabled lamps through the same ownership
and rollback path. Priority still selects at most eight. It refreshes on the
next update after moving 4 m, or every 0.25 seconds while stationary. Missing or
rejected native queries fall back to incremental discovery; status identifies
which route is active. Opening the tuner still makes no shadow writes.

Background throughput now scales with real frame time: 24–192 inspections and
16–128 validations per update, with a soft 2 ms CPU limit on extra work above
the original 24/16 minimums. This avoids making a 15 FPS player wait through a
strict 24-per-frame queue, without synchronously flushing thousands of writes.
Individual native calls and the spatial query cannot be preempted by that limit.
Native shadow allocation/rendering remains engine-controlled: this removes our
queue delay for nearby query hits, not a promise of instant or cheaper GPU
shadows. Low-FPS live behavior still needs an in-game comparison.

## v0.121.1 — outdoor shadow-selection assistance

The v0.121 automatic path raised every smaller lamp shadow map to 1024. This
does not guarantee GPU selection and can add pressure to the installed renderer's
finite 8192² clustered shadow atlas. Automatic mode now preserves native map
sizes for distant lamps while still requesting `castShadows` level-wide.

**Nearby shadow priority** (Lighting & GI → Automatic lamp shadows) defaults ON.
Once per second, up to eight enabled lamps within 80 m of the camera receive a
reversible `priority` boost (+4 from their captured baseline), when that native
field is advertised and accepts the write. Nearby spot maps are raised to at
least 1024, point maps to 512; existing larger maps are preserved. Moving away
or turning the assist off restores owned map/priority values but leaves global
shadow requests active. Object changes and other field owners are respected.

This helps the native light manager choose camera-relevant lamps; it does not
create more atlas capacity or repair non-casting materials. It is a hypothesis
for missing outdoor shadows, not proof that the photographed box/barrier is
fixed. No material flags, ambient light, intensity, color or global graphics
quality are changed. The original factory result was user-confirmed; the new
outdoor behavior still needs an in-game comparison.

The repeated thousands counter is now labeled **Discovery checks**, not pending
new lights/maps. Periodic rescans normally perform no new shadow-field writes.
**Log nearby light shadow inputs** writes a bounded read-only report of up to
12 nearby light objects and their advertised native shadow fields to the game
log. These CPU fields do not prove GPU atlas allocation or material casting.

## v0.121 — automatic native lamp shadows

The previously tested native-lamp shadow request now starts automatically with
GI, Coherent, or combined rendering. There is **no four-light or camera-radius
limit** in automatic mode: every supported scene PointLight/SpotLight is
processed, including currently switched-off lights so their shadows are ready
when they turn on. This does not enable lights or alter their brightness, color,
range, direction or global graphics settings. It requests `castShadows` and
raises smaller advertised per-light shadow maps to 1024, retaining higher sizes.

Discovery/inspection is limited to 24 lights per frame and ownership validation
to 16 lights per frame. Rescans discover new/replaced lights every five seconds
once the previous queue finishes. Large maps take time to populate. Lua queues
are incremental; native shadow-map allocation/rendering can still cost GPU
time. The engine's visibility, shadow budgets and material caster rules still
limit actual rendered shadows; requesting every light is not unlimited GPU
shadow support. Embedded vehicle lights not exposed as scene PointLight or
SpotLight objects are outside this scanner.

Lighting & GI → **Automatic lamp shadows** shows progress and offers a disable/
restore button. Automatic mode defaults ON at renderer startup; opting out lasts
for the current session. Disable-all restores owned native fields and does not
restart by itself; the next renderer start resumes automatic mode unless opted
out. Mission/settings/unload restore as before. Captures/audits pause automatic
updates, and conflicting field owners are left alone instead of repeatedly
overwritten. Restoration failures retain their rollback lease.

No map files, native DLLs or shader hooks are changed. The user confirmed the
original nearby experiment's visual benefit; level-wide cost and appearance
still need live verification. The old fixed-cohort diagnostic API remains
available as `setNearbyLampShadowsEnabled(true)`, but the normal tuner now uses
automatic mode via `setAutomaticLampShadowsEnabled(true/false)`.

## v0.120.2 — nearby native lamp-shadow experiment

In Lighting & GI, open **Nearby lamp shadows (native experiment)** and choose
**Try nearby lamp shadows**. This explicitly requests native `castShadows` on
up to four enabled PointLight/SpotLight objects within 30 m of the camera. Smaller
advertised shadow maps are raised to 1024; higher sizes remain unchanged. The
selected lamp names/distances are shown. This fixed selection does not follow
the camera: restore, then try again at a different location.

**Restore lamp shadows** restores original owned values. Disable-all, graphics
changes, mission changes and unload also restore them. Restoration failures keep
their lease for retry; replaced objects and externally changed fields are never
overwritten. This does not save a level, alter global quality/budgets, replace
shaders, create lights or change their brightness, color, range or direction.

This is separate from the still-unconnected custom clustered mesh-light hook.
Native shadow budgets, graphics quality, disabled caster materials, and light
placement may still prevent the pipe/support shadows. Already-shadowed lamps
are reported without pretending a change occurred. GPU execution and appearance
must be checked in-game; control tests do not establish visual success.

## v0.120.1 — receiver color and coverage experiments

Lighting & GI has a collapsed **GI color and coverage experiments** section:

- **Try de-lit receiver color** estimates material tint after dividing out direct
  light color, rather than tinting arriving GI with the already-lit orange/brown
  scene color again. It keeps the existing scalar reflectance, F0/roughness gates,
  source-light color, Bounce color and GI strength controls. The new chroma has
  unit luminance; this can recover energy lost by the old peak-normalized tint.
  This is an approximate albedo estimate, not a physical material-buffer fix.
  Default OFF; **Restore original receiver color** restores the baseline.
- **Try wider DDA coverage** doubles the current screen stride, retaining the
  same sample count, world reach and validation. Select Screen DDA first. It may
  skip thin geometry; more coverage is not automatically more correct. **Undo**
  restores the exact previous stride. Linear and Coherent traversal are unchanged.

Neither action starts a renderer, changes presets, desaturates the entire GI,
or edits native water/reflections. Receiver strength is included in explicit
tuning saves and audit manifests; the DDA undo snapshot is session-only. Test
each option separately before combining them. Warm lights should remain warm.
Offline shader/control tests are not in-game appearance verification.

## v0.120 — opt-in PTGI + Coherent reflections

In **Lighting & GI**, choose **Enable PTGI + Coherent** for the experimental
combined path. PTGI diffuse lighting is composed before Coherent captures its
reflection source; the older BeamRT SSR stays off. The original stages are
restored on disable. New six/eight-ray controls sit between four and sixteen,
with six now the default. Existing material, water and GI tuning is retained.

The audit also repairs GI history invalidation after long frame gaps and links
GI changes to reflection-history resets while combined. CPU graph checks and
offline shader/GPU tests do not establish combined appearance or performance in
BeamNG. See [combined mode and audit notes](native/lighting/COHERENT_SSR.md#v0120-ptgi--coherent-and-intermediate-ray-counts).

## v0.119.1 — parked-vehicle accumulation repair

Parked cars no longer receive the moving-vehicle history-refresh floor merely
because their rigid pose is available. GPU regressions reproduce the old failure
and check parked, jittering, translating and rotating receivers. Temporal
accumulation OFF freezes noisy samples; ON advances and averages them. In-game
appearance still requires comparison. See [the repair notes](native/lighting/COHERENT_SSR.md#v01191-parked-vehicle-accumulation-repair).

## v0.119 — high-sample reflection cleanup

The Reflections tab now has a reversible **Apply high-sample cleanup (slow)**
action: full-resolution sixteen-ray sampling and temporal accumulation, without
changing brightness, material reflectivity or stock water color. Four-ray sampling
is the new default. Mature history now honors requested retention, and the tuner
warns when accumulation is off. This is still screen-space rendering; zero noise
and off-screen reflections are not guaranteed. In-game appearance is unverified.
See [Coherent SSR notes](native/lighting/COHERENT_SSR.md#v0119-high-sample-cleanup)
for changes, checks and the stillness/motion comparison.

# BeamRT v0.108 — native device bootstrap and honest feature availability

The offline no-ReShade worker now supports exact-adapter device acquisition and
resource-owner identity checks. These passed on the RTX 4070 and WARP; they do
not establish a game attachment or expose game depth/lighting resources.
The tuner now labels blocked underground local-light visibility unavailable,
with no failing activation button. Existing rendering/fallback stays intact.
See [NATIVE_DEVICE_BOOTSTRAP_V0108.md](NATIVE_DEVICE_BOOTSTRAP_V0108.md).

## v0.107 — reliable native-noise baseline (retained)

The rejected experimental DDS atlas is no longer a mandatory startup input.
Custom STBN selection now reports unavailable; native BeamNG noise is preserved.
No reflection/GI filter, sampling sequence, lighting strength or geometry tracing
changed. This handles a failed optional resource; it does not fix STBN loading
or promise less reflection noise. See [NOISE_SOURCE_V0107.md](NOISE_SOURCE_V0107.md).

## Native worker progress / current reload (2026-10-11)

A no-ReShade D3D12 GPU worker is now implemented and validated **offline** using
the existing real guardhouse BVH. It is not attached to BeamNG and does not alter
the running renderer. No native DLL, loader or injector has been installed.
See [native/worker/README.md](native/worker/README.md) for exact results/limitations.
That offline-worker batch left runtime v0.106 unchanged; the subsequent optional
noise-resource handling update is retained in current runtime v0.108.

For future Lua/HLSL updates, this full GE Lua reload preserves unsaved tuning,
unloads BeamRT extensions before clearing their helper-module cache, and recreates
the main effects. Experimental native-shadow hooks stay off; it never loads a DLL:

```lua
do local saved=beamrt_main and beamrt_main.getSettings(); local loaded=extensions.getLoadedExtensionsNames(); if beamrt_main then beamrt_main.disable() end; extensions.unload("beamrt_main"); for _,name in ipairs(loaded) do if name:match("^beamrt_") then extensions.unload(name) end end; for key in pairs(package.loaded) do if type(key)=="string" and key:match("^ge/extensions/beamrt/") then package.loaded[key]=nil end end; extensions.load("beamrt_main"); if saved then beamrt_main.applySettings(saved); beamrt_main.enable(); beamrt_main.openTuner() else beamrt_main.start() end end
```

---

# BeamRT v0.103 — shared material-aware mesh visibility for GI

Full imported guardhouse geometry now has an opt-in WORLD-surfel GI visibility
path using live native opaque declarations, rather than only a debug preview.
Screen GI and native lighting stay on their existing paths; unsupported opacity
and unavailable data fall back. No final-scene darkening pretends to replace shadows.

This batch also removes leftover magenta returns, restores existing reflection
composition/filter code, makes variance OFF remove its three experiment passes,
and fixes stale visibility-provider lookup. Local regressions and compilation pass;
live GPU loading, appearance and frame cost are not yet verified.

One normal-render activation and exact scope:
[SHARED_MESH_GI_MILESTONE.md](SHARED_MESH_GI_MILESTONE.md).

---

# BeamRT v0.102 — one-building GPU BVH preview

Full imported guardhouse geometry now has an isolated GPU BVH traversal path,
not a 12-triangle truncation or box proxy. Live GPU correctness is still pending.
In GE Lua, while parked near the current alignment capture:

```lua
extensions.load("beamrt_meshBVH"); beamrt_meshBVH.setQuality("cinematic"); beamrt_meshBVH.setTestLightEnabled(true); beamrt_meshBVH.enable()
```

Native scene is left; geometry intersections right. Orange = mesh blocks a ray
to a fixed **synthetic test light**, green = no hit against this mesh, magenta =
data failure. This is geometry proof, not finished lighting or alpha-aware shadows.
No scene light/time change, GI/reflection toggle, or camera move occurs.
Stop with `beamrt_meshBVH.disable()`. Details: [MESH_BVH_MILESTONE.md](MESH_BVH_MILESTONE.md).

---

# BeamRT v0.102 — real building alignment preview

The next geometry milestone is implemented: a selected real West Coast guardhouse
visual mesh, node-transform-aware extraction, material references, native instance
placement and an isolated wireframe alignment check. No GI/shadow/reflection changes
are activated. Actual in-game alignment and GPU mesh tracing remain unverified.

In GE Lua while parked in West Coast USA:

```lua
extensions.load("beamrt_meshAlignment"); beamrt_meshAlignment.previewNearest(); dump(beamrt_meshAlignment.getStatus())
```

The nearest **prepared guardhouse** instance is selected; it may not be in the
current view. Orange edges are real mesh triangles, not box shadows. Hide with
`beamrt_meshAlignment.setMode("off")`, or clear with `beamrt_meshAlignment.clear()`.
Optional `beamrt_meshAlignment.focusPreview()` takes only the free camera to it;
`beamrt_meshAlignment.restoreCamera()` returns to the previous camera mode.
Details, private package reproduction, evidence and limits:
[MESH_ALIGNMENT_MILESTONE.md](MESH_ALIGNMENT_MILESTONE.md).

---

# BeamRT v0.101 — reflection source isolation

No new denoiser or claimed noise fix. Tests original SSR input, native-only color,
live reconstructed GI-lit color, and frozen GI contribution while keeping GI in
the displayed scene. The freeze holds the matched signed GI image change and
recombines it with live native color, so native lighting isn't frozen too.

While parked, reload and run once in GE Lua:

```lua
local savedBeamRT = beamrt_main.getSettings(); beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.applySettings(savedBeamRT); beamrt_main.enable(); extensions.load("beamrt_reflectionSourceProbe")
```

Close console and keep camera still until completion. Physics pauses temporarily;
14 local captures include beauty, source and isolated SSR for each case, plus two
held-GI verification views. Settings and physics are restored automatically.
Repeat with `beamrt_reflectionSourceProbe.start()`; cancel with
`beamrt_reflectionSourceProbe.cancel()`. Results: `screenshots/beamrt-source-probe/`.

Freezing GI preserves any spatial noise already in it. Patches remaining while
frozen do not automatically exonerate the source. Normal `$backBuffer` ordering
suggests GI enters SSR; captures must verify the effective image, not just field
names. Details and limits: `.beamrt-validation/v101/README.md`.

---

# BeamRT v0.100 — raw reflection convergence diagnostic

Gameplay reconstruction is unchanged. This adds the proposed **128-frame raw
GGX reference test**, not SVGF, a photo preset, or a claimed square-artifact fix.
It saves a playable reference, raw average, variance/coverage/dark-rate views and
an actual per-pixel sample-count view, then restores your settings and physics.

While parked, reload once and start it in the GE Lua console:

```lua
local savedBeamRT = beamrt_main.getSettings(); beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.applySettings(savedBeamRT); beamrt_main.enable(); extensions.load("beamrt_reflectionConvergence")
```

Close the console and **keep the camera still until completion**. Physics pauses
temporarily; camera/FOV/resolution movement cancels the reference. Results go to
`screenshots/beamrt-convergence/` in the game user folder. Repeat with
`beamrt_reflectionConvergence.start()`; cancel with
`beamrt_reflectionConvergence.cancel()`.

Both comparison stages use SSR-only native scene color, source Color filter
OFF, and consistent near-mirror directions. The raw stage accumulates weighted
samples without spatial filtering, reprojection or history clipping. Valid zeros
remain; unknown misses are recorded separately, not labeled physically black.
128 samples are a finite reference, not ground truth: rare bright samples can
still leave legitimate noise. New gameplay denoising waits until this is reviewed.

All24 production/diagnostic entries /48 stages compile strictly. Diagnostic,
numeric, gameplay, binding and motion tests pass; in-game results are pending.
Details: `.beamrt-validation/v100/README.md`.

---

# BeamRT v0.099 — rough-reflection color reconstruction

Targets persistent square-shaped bright patches in playable GGX reflections.
Adds depth-aware 2x/4x/8x source-color levels, blends only compatible history
color at subpixel coordinates, and relaxes the normal filter on rough materials.
Polished source detail, valid black hits, hit-aware metadata, full-resolution
SSR, procedural GGX sampling and the existing one-ray/short-history budget stay
intact. Mirror and Legacy paths bypass the new filtering.

Reload from the GE Lua console while preserving your current tuning:

```lua
local savedBeamRT = beamrt_main.getSettings(); beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.applySettings(savedBeamRT); beamrt_main.enable()
```

Confirm **v0.099**, then use **GGX SSR → Playable filter → Hit-aware ON → Color
filter ON**. The new Color filter button compares against v0.098 without changing
GI or your preset. The equivalent switch is
`beamrt_main.setReflectionColorFilterEnabled(true)` (or `false` for comparison).
It resets only SSR history. Missing fields in older saves keep the new default.

This is approximate source-footprint filtering, not a promise of perfect or
smear-free reflections. It adds two smaller color passes and bandwidth, not
more rays or long exposure. In-game visual benefit and GPU cost remain unverified.
All 21 active entries / 42 stages compile strictly; 17 control, 6 color/identity,
14 binding and 18 motion checks pass. Details: `.beamrt-validation/v099/README.md`.

---

# BeamRT v0.098 — hit-aware output-target correction

Fixes the v0.097 helper creation order: its off-screen target and shader bindings
are now assigned before native registration. The old order could display motion
data (RGB while moving, black while still) in GGX + Playable + Hit-aware ON.
Mirror and Legacy bypass this helper, explaining why they remained usable.
Shaders, sampling, presets, ray budget and filtering equations are unchanged.

Reload the module to destroy and recreate the already-registered helper. In the
GE Lua console, this preserves your current tuning:

```lua
local savedBeamRT = beamrt_main.getSettings(); beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); beamrt_main.applySettings(savedBeamRT); beamrt_main.enable()
```

The tuner should show **v0.098**. Select GGX SSR, Playable filter and Hit-aware ON
for the normal-image check. No shader cache deletion or Nsight capture needed.
Thirteen offline Lua checks and native Lua51/LuaJIT/Lua55 compilation pass;
the corrected GPU image remains unverified. Details: `.beamrt-validation/v098/README.md`.

---

# BeamRT v0.097 — hit-aware playable reflections (superseded by v0.098)

After reloading BeamRT, select **GGX SSR → Playable filter → Hit-aware ON**.
Keep your existing preset and enable reflections as before. The new path:

- Checks reflected-source depth and motion before reusing history.
- Protects sharp reflections from spatial mixing across different hit layers.
- Uses a stable mirror approximation on nearly polished materials (roughness
  at or below 0.035); rougher surfaces retain stochastic GGX directions.
- Keeps the same one-ray/step budget and short rolling history—no long exposure.

**Hit-aware OFF** restores the v0.096 playable behavior for comparison. Legacy
filter and Mirror SSR bypass the new metadata path. Legacy still means the
previous filter, not a dedicated photo mode.

The equivalent controls, after loading v0.097, are:

```lua
beamrt_main.setReflectionSamplingMode("ggx")
beamrt_main.setReflectionReconstruction("playable")
beamrt_main.setReflectionHitAwareEnabled(true)
```

`beamrt_main.getVersion()` must return `0.097`. The settings-preserving reload
sequence in the next section also works for this version; add the hit-aware
selection above if your saved setting has it disabled.

This is an incremental quality improvement, not a guarantee of noise-free or
smear-free reflections. History geometry is a representative source proxy, not
complete reflected-image reprojection. Depth validation of the old source is
limited to a still camera; moving cameras retain existing rejection guards.
Source lighting/color changes without geometry or motion changes can still trail.
Spatial hit-layer filtering is an approximation, relaxed for rough materials.

The six temporal inputs are preserved by packing geometry into existing slots.
Two helper passes and 32-bit buffers add bandwidth/memory cost without tracing
another ray. In-game frame-rate and visual quality have not yet been verified.
Native cubemap/fog limitations remain; no game installation shader was changed.

Seven metadata/shader checks, ten control checks and the existing graph/motion/
audit checks pass. All 19 active entries / 38 VS+PS stages compile strictly.
Details: `.beamrt-validation/v097/README.md`.

---

# BeamRT v0.096 — playable GGX reconstruction

Select **GGX SSR** and **Playable filter** in the reflection controls after
reloading BeamRT. This strengthens the existing edge-aware reconstruction and
uses a short, frame-time-corrected rolling average. It does not add rays, increase
trace steps, add a filtering pass, or enable long exposure. **Legacy filter**
restores v0.095 reconstruction for comparison; Mirror SSR remains unchanged.

At the PTGI DDA Max + Reflections preset's current-frame setting of 0.25, the
ideal accepted-history response reaches 95% of a changed signal in roughly
0.37 seconds. Spatial reconstruction is available immediately. This is a CPU
model response bound, not a promise of measured game convergence or frame rate.
Camera motion, depth rejection and disocclusion can discard history sooner.
Moving reflected objects can still briefly trail when the receiving surface
and camera stay still; hit-side geometry tracking is not implemented yet.

The existing one-ray budget, 13 spatial taps, six temporal inputs, GI settings
and preset tables are preserved. The new filter retains valid zero samples and
does not repeatedly clip stationary history to a random one-frame color range.
Playable reconstruction is the new default filter choice, but affects only GGX.
Both choices persist through saved settings; older settings preserve the choice.

If BeamRT is already running, this GE Lua console sequence preserves current
tuning while loading the new module and choosing playable GGX:

```lua
local savedBeamRT = beamrt_main.getSettings()
beamrt_main.disable()
extensions.unload("beamrt_main")
extensions.load("beamrt_main")
beamrt_main.applySettings(savedBeamRT)
beamrt_main.setMode("lighting")
beamrt_main.setReflectionsEnabled(true)
beamrt_main.setReflectionSamplingMode("ggx")
beamrt_main.setReflectionReconstruction("playable")
beamrt_main.enable()
```

Alternatively restart BeamNG, choose your existing preset, then select GGX SSR,
Playable filter and enable reflections. `beamrt_main.getVersion()` must return
`0.096`. Diagnostics/reflection audits intentionally bypass the new filter and
freeze sample zero; use normal rendering for the filter comparison.

Offline verification is recorded in `.beamrt-validation/v096/README.md`.
In-game noise, sharpness, trails and GPU cost still need a loaded-game comparison.
Native cubemap replacement, fog separation, SSR DDA and hit-distance tracking
are not included in this update.

---

# BeamRT v0.095 — optional roughness-aware GGX reflections

**GGX SSR** samples reflection directions from each surface's roughness instead
of always tracing a perfect mirror ray. Smooth materials keep a narrow lobe;
rougher eligible materials spread it across rendered frames. This uses one ray
per receiver pixel with the existing trace budget, not a larger ray count.

After reloading BeamRT or restarting BeamNG, select **GGX SSR** in the tuner's
reflection controls, enable reflections, and start lighting. The equivalent
GELua console commands are:

```lua
beamrt_main.setMode("lighting")
beamrt_main.setReflectionsEnabled(true)
beamrt_main.setReflectionSamplingMode("ggx")
beamrt_main.enable()
```

To compare with the original direction, use **Mirror SSR** or
`beamrt_main.setReflectionSamplingMode("mirror")`. Mirror remains the startup
default. Existing presets preserve the selected sampling mode; saved settings
now include it. Switching modes clears reflection history, not GI history.
`beamrt_main.getVersion()` should return `0.095`.

The GGX path uses visible-normal importance sampling and applies its colored
Fresnel/sampling weight once. Compatible zero-contribution rays participate in
spatial and temporal averages, avoiding a bright hit-only average. Procedural
sampling is independent of the still-unverified BeamRT STBN texture loader.

Native reflections remain intact: BeamRT is still an additive screen-space
overlay, not a native cubemap replacement. Fog in the sampled scene color,
off-screen geometry, and receiver-only temporal filtering remain limitations.
Reflection audits freeze sample zero for deterministic diagnostics; they do
not measure normal GGX convergence. Offline shader, math, Lua-control and
regression checks pass. In-game appearance and performance are not yet verified.

Older release notes follow; their historical runtime claims are not evidence
that the current STBN atlas loads successfully.

---

# BeamRT v0.078 — visible, playable DDA PTGI presets

The high-cost Beauty Max preset was intentionally neutral: it disabled world GI
and the previous-GI bounce, used only 0.10 exposure, and spent 32 paths by up to
160 linear steps on a result that Screen DDA could approximate much more
cheaply. It remains available as the conservative comparison baseline.

**PTGI DDA** is the new gameplay-oriented beauty preset. It runs one
full-resolution, 32-step-budgeted Screen DDA path, relies on STBN/SVGF/temporal
convergence, selects the cleaned direct-diffuse estimator, and deliberately
raises transported-color visibility. A guarded 0.22 previous-GI bounce,
stronger receiver tint/saturation, and soft highlight budget produce clearer
color bleeding without re-enabling the artifact-prone coarse world surfels.
**PTGI DDA + REFL** adds the material-aware reflection overlay to the same base.

At their compiled budgets, the screen trace ceiling falls from Beauty Max's
32 x 160 linear samples to 1 x 32 DDA samples per GI pixel. The exact speedup is
GPU/scene dependent, but the large amount of redundant linear work is gone.

---

# BeamRT v0.077 — camera-stable reflection history

Reflection history now recognizes that a reflected ray changes when the camera
moves, even when BeamNG's receiver motion vector reprojects the surface pixel
perfectly. The old pass retained up to 82% of that obsolete view-dependent
sample, which made highlights and reflected shapes slide opposite camera motion.
v0.077 rapidly retires reflection history as screen motion begins and becomes
current-frame dominant while moving. The existing edge-aware spatial filter
continues to control current-frame noise.

BeamNG's `previousUv = currentUv + velocity` convention was verified and remains
unchanged; reversing it would have made all reprojection incorrect. Static-camera
accumulation is preserved, and **BEAUTY MAX** remains reflection-free.

---

# BeamRT v0.076 — visible material-aware reflections

The first material-aware reflection preset was too conservative: a typical 4%
dielectric F0 was multiplied by squared roughness response, 0.65 preset strength,
and screen-hit confidence, often leaving less than a 1% visible change. v0.076
keeps BeamNG's material/F0 distinction but uses a bounded perceptual Fresnel
curve and a gentler roughness falloff. **BEAUTY + REFLECTIONS** now uses strength
1.0 and a 0.50 roughness cutoff.

This is still substantially more restrained than the old unconditional 22%
minimum, and **BEAUTY MAX** remains an unchanged reflection-free baseline.

---

# BeamRT v0.075 — opt-in material-aware reflections

BeamRT reflections can now run as an optional overlay after normal PTGI instead
of replacing GI as a separate diagnostic mode. The neutral presets remain
reflection-free. **BEAUTY + REFLECTIONS** copies Beauty Max exactly, then enables
a conservative screen-space reflection pass.

The reflection composer now reads BeamNG's real specular/F0 buffer and applies
colored Schlick Fresnel. This removes the old fixed 22% minimum blend that made
ordinary smooth dielectrics look uniformly chrome-coated. The preset uses 0.65
strength and a 0.42 roughness cutoff to complement, rather than overpower,
BeamNG's native probes and material lighting.

Reflections remain screen-space: they cannot show off-screen objects or hidden
geometry, and they may fade at screen edges. Use **BEAUTY MAX** for the accepted
neutral baseline and **BEAUTY + REFLECTIONS** only when the extra pass is wanted.

---

# BeamRT v0.074 — receiver-aware diffuse GI composition

BeamRT now estimates the receiver's bounded diffuse reflectance from the lit
surface and BeamNG's direct-light buffer when composing indirect light. The
material prepass is used only for its real meaning here—specular/F0—so metallic
receivers can reject a diffuse lobe. Previously the final pass used only the
backbuffer's chroma, allowing dark rubber, wheel wells, and asphalt to accept
nearly the same GI energy as white paint. That produced the moving smooth/shiny
coating most visible around wheels and under strong warm light.

Receiver reflectance now controls diffuse throughput, while existing roughness
and confidence gates remain active. **BEAUTY MAX** uses this path by default.
The change is in the final composition pass, so it applies equally to linear,
DDA, hybrid, and world source modes without changing their ray hits.

---

# BeamRT v0.073 — confidence-aware reconstruction and Beauty Max

BeamRT now carries ray-hit support through temporal accumulation instead of
overwriting it with depth. Historical depth is read from the existing moments
history. Temporal denoising and final upsampling use this support so isolated
wheel/silhouette hits remain local instead of becoming a smooth reflective
coating. Low-roughness receivers also use a more conservative diffuse response.

The DDA path cap is now source-aware: it still protects screen/hybrid DDA, but
no longer reduces world-only GI to one path. A new accuracy-first screenshot
preset is available from the tuner as **BEAUTY MAX** or through GELua:

```lua
beamrt_main.applyPreset("beautymax")
```

It selects 32 paths, full GI resolution, 160 linear steps, the corrected
estimator, BeamRT STBN, confidence-aware temporal reconstruction, and screen-only
GI. This deliberately omits the experimental Screen DDA and coarse surfel world
fallback until their intersection/material accuracy is good enough for beauty
rendering. It is designed for stationary screenshots and is very expensive.

---

# BeamRT v0.072 — BeamRT spatiotemporal blue noise

BeamRT now owns a reproducible 64-frame, two-channel spatiotemporal blue-noise
candidate instead of relying only on BeamNG's static GTAO tile. It is packed as
an 8x8 atlas of 128x128 frames and sampled directly by the GI trace shader.
Runtime sampling uses a linear RGBA8 DDS so texture gamma cannot bend the
random distribution; a PNG copy remains for previewing the atlas.
BeamNG's original 2D source remains available as an exact A/B baseline.

```lua
beamrt_main.setGIPathCount(1)
beamrt_main.setBlueNoiseStrength(1)
beamrt_main.setBlueNoiseSource("stbn") -- or "beamng"
```

Changing sources resets temporal history. Compare from the same camera and
wait the same 64 or 128 frames before judging. The generator, atlas, and metric
report live under `tools/` and `shaders/beamrt/`. This changes sampling, not ray
intersection correctness; bad hits will remain bad hits, merely with a better
distributed error pattern.

---

# BeamRT v0.071 — automatic motion temporal mode

Long exposure now accumulates only while stationary. During camera movement it
automatically keeps a short guarded temporal history instead of deleting all
history and exposing a completely fresh one-path blue-noise image every frame.
Stopping the camera starts a new clean progressive exposure.

A stationary RenderView also reports tiny floating-point FOV fluctuations.
BeamRT now ignores differences up to 0.001 degrees, preventing the progressive
exposure from being discarded every 32--48 samples. Real FOV changes and all
resolution changes still reset immediately.

Two raw views separate ray motion from screen-depth availability:

```lua
beamrt_main.setRayHitDiagnostic("direction")
beamrt_main.setRayHitDiagnostic("viewalignment")
beamrt_main.setRayHitDiagnostic("hits")
```

`direction` encodes the fixed world ray. `viewalignment` is red when that ray
points back toward the camera, green when it points forward, and blue when it
is transverse. A stable direction can still lose `hits` near the view center
because the visible depth buffer contains only the camera-facing layer.
The old `EXPERIMENTAL WOW` button is consequently labeled `SCREEN DDA AUDIT`;
use `Balanced` or `Cinematic` for normal rendering.

---

# BeamRT v0.070 — bounded Screen DDA audit

The experimental Screen DDA is no longer treated as a production beauty
marcher. A plain depth buffer provides no empty-space hierarchy, so a full
one-pixel traversal multiplied by full resolution, 16 paths, and 128 steps can
request billions of depth reads per frame. v0.070 caps DDA to one path and 32
near-field screen/world steps, while leaving the linear beauty baseline intact.

Raw hit diagnostics now use a deterministic world-oriented ray instead of a
screen-pixel blue-noise ray. Beauty presets explicitly restore `linear`, so an
earlier DDA test cannot leak into Cinematic, Ultra, or other high-cost presets.
The `EXPERIMENTAL WOW` button is now the isolated half-resolution DDA audit.

```lua
beamrt_main.applyPreset("experimental") -- bounded DDA audit
beamrt_main.setRayHitDiagnostic("hits")
beamrt_main.setRayHitDiagnostic("off")
beamrt_main.applyPreset("balanced")     -- linear beauty baseline
```

Screen-space diffuse rays can still lose coverage when the selected hemisphere
direction points behind visible geometry, and exact screen-radiance samples can
look reflection-like. Those are representation/source-footprint limitations,
not problems that more DDA steps can solve.

---

# BeamRT v0.066 — true blue-noise primary GI sampling

## v0.066 current milestone

v0.066 keeps the accepted v0.065 candidate-continuation, emissive-separation,
Material V2, hit-validation, CleanRadiance, surfel, temporal, and composer paths.
The only active transport change is the primary diffuse-ray sequence.

At blue-noise strength `1`, BeamRT now uses BeamNG's shipped 128x128 GTAO
`noiseBlue.png` values directly: one channel selects a stratified cosine-radius
sample and the other rotates the azimuth. Both are advanced per frame with the
same 32-bit fixed-point Weyl multipliers used by BeamNG GTAO. The old cell/hash
generator no longer contaminates the full-strength primary sequence.

```lua
beamrt_main.setBlueNoiseStrength(1) -- v0.066 true blue-noise/Weyl sequence
beamrt_main.setBlueNoiseStrength(0) -- exact v0.065 hash sequence A/B
```

The default is `1` for this experimental milestone. This should change the
*distribution* of low-spp noise, not ray count, hit rules, energy, or denoising.
Judge it first at 1–4 paths from a fixed camera and allow temporal history to
warm separately after each switch. The previous `beamrtGITraceP_v065.hlsl`
entry remains on disk as a cache-busted fallback.

---

# BeamRT v0.065 — multi-candidate tracing + Material V2 / emissive transport

## v0.065 current milestone

v0.065 starts cashing in the renderer archaeology instead of adding another disconnected experiment. The active GI entry is `beamrtGITraceP_v065.hlsl`; v0.064 remains on disk and the new controls can restore its stop-on-first-candidate and combined-emissive behavior for A/B testing.

### Multi-candidate screen tracing

Both `linear` and `screendda` now validate a candidate *inside* traversal. With candidate continuation enabled, recoverable self/near-origin, backface, depth-error, background, screen-edge, or local-discontinuity rejects no longer automatically kill the ray. The marcher advances to later samples and can accept a later surface. Outside-viewport rejects and an exhausted retry budget still terminate. Linear keeps the v0.064 front/behind bracket plus bisection refinement.

```lua
beamrt_main.setCandidateContinuation(1)  -- v0.065 behavior
beamrt_main.setCandidateRetryCount(4)   -- 0..8
beamrt_main.setCandidateContinuation(0)  -- v0.064 stop-on-first-candidate A/B
```

### Emissive separation

When the accepted CleanRadiance source is active, screen hits now split outgoing radiance into reflected diffuse/feedback and native `Material_Emissive`. The emitted term can bypass the extra *emitter reflector cosine* that previously attenuated small bright fixtures, while receiver/path weighting and hit validation remain in place. This is intended to test the tunnel case where a large lit tank appeared to bounce more strongly than the fluorescent emitter.

```lua
beamrt_main.setEmissiveSeparation(1) -- v0.065 emitted-radiance weighting
beamrt_main.setEmissiveSeparation(0) -- v0.064 combined hit weighting
```

### Material V2 capture

The proven Material Debug producer-view bridge now supports the full transport-relevant evaluated set discovered in BeamNG: BaseColor, Opacity, Metallic, Roughness, AmbientOcclusion, NormalsWS, Emissive, ClearCoat, and ClearCoatRoughness. These new caches are diagnostic-only in v0.065 except for the already accepted BaseColor/Metallic/Emissive CleanRadiance path. That keeps clear-coat/AO/roughness discoveries observable before they are allowed to change transport.

Capture all nine without moving the camera:

```lua
beamrt_main.publishMaterialV2Caches()
dump(beamrt_main.getMaterialCachePublication())
```

Or capture individually with `publishOpacityCache`, `publishRoughnessCache`, `publishAmbientOcclusionCache`, `publishNormalsWSCache`, `publishClearCoatCache`, and `publishClearCoatRoughnessCache`. Inspect with `bufferdiag`, e.g. `roughnessCache`, `ambientOcclusionCache`, `normalsWSCache`, `clearCoatCache`, `clearCoatRoughnessCache`, or `opacityCache`.

### Emitter classifier

A fifth clean-radiance diagnostic target, `#BeamRT_EmitterClass`, compares native material emission with direct diffuse outgoing radiance. In raw RGB, **red** means emissive dominates, **green** means direct-lit diffuse dominates, and **yellow** means both are significant.

```lua
beamrt_main.refreshCleanRadianceDiagnostics()
beamrt_main.setMode("bufferdiag")
beamrt_main.setBufferDiagnosticView("raw")
beamrt_main.setBufferDiagnostic("emitterClass", "rgb")
```

Ambient-SH reconstruction, exposure-independent persistent storage, and clear-coat/glossy transport are intentionally **not** folded into this build yet; those need separate acceptance gates after the new captures are verified in-game.


BeamRT v0.005a builds on the accepted Phase 3 screen-space one-bounce diffuse GI result. It adds animated world-anchored ray samples, velocity-buffer reprojection, previous-depth rejection, motion-aware neighborhood history clamping, and a small depth/normal-aware spatial filter. Phase 4 visual and reload acceptance passed on BeamNG `0.39.4.0.20972`.

v0.006 started Phase 5 without changing the accepted GI path. GELUA enumerates nearby static scene objects, reads their shipped `getWorldBox()` bounds, selects the nearest 16, and uploads those bounds to the debug PostEffect. Its `geometry` mode traces reflection rays against both the visible depth buffer and those world-space AABBs. That bridge passed its acceptance test.

v0.007 keeps that accepted AABB baseline and additionally builds oriented boxes from the shipped local `getObjBox()`, `getTransform()`, and `getScale()` APIs. The new `orientedgeometry` mode directly exposes AABB-only excess volume so the square-ish proxy artifacts can be measured instead of guessed. Its in-game gate passed. This is still an architecture probe, not final geometry or a claim of path tracing.

v0.008 made the planned larger jump beyond boxes. On explicit refresh it sends 32 deterministic detailed rays through BeamNG's shipped `Engine.castRay(..., includeTerrain=true, renderGeometry=true)` path: a 20-ray 360-degree Fibonacci shell plus a 12-ray downward grid. Real hit positions and normals become world-space surfel discs uploaded to HLSL. Modes `surfels` and `surfelcompare` validated their geometry, normals, and world-space reach; v0.008 passed its in-game visual, data, cleanup, and reload gates.

v0.009 is the first controlled surfel-to-lighting integration. The GI trace shader can run in `screen`, `surfels`, or `hybrid` source mode. A surfel hit contributes only when its center projects onto matching current-frame depth and a compatible G-buffer normal, allowing the shader to sample a real HDR radiance value rather than inventing material color. Hybrid mode preserves the accepted visible-depth hit when present and uses the validated surfel path only as a fallback.

v0.010 adds `surfelradiance`, a direct validation diagnostic prompted by an inconclusive strength A/B. It classifies surfel miss, projection rejection, depth rejection, normal rejection, and accepted radiance lookup with unmistakable colors. In-game testing produced extensive stable green regions, the strict `giStrength=0` no-op passed, and disable/unload/reload cleanup printed all three expected `true` results. The v0.009/v0.010 implementation milestone is accepted for continued development; useful coverage and quality remain experimental.

v0.011 adds `hybridcoverage`, which follows the actual diffuse hybrid decision rather than the reflection ray used by the geometry diagnostics. Cyan means visible depth supplied the first-choice hit, green means visible depth missed and a depth/normal/edge-validated surfel supplied the fallback, and dark purple means neither path supplied a usable source. The in-game frame showed stable green fallback across the vehicle and environment; an approximate screenshot sample placed green at 29% of cyan-plus-green usable hits. v0.011 is accepted for continued development.

v0.012 is the architectural jump beyond repeated current-frame coverage tests. A dedicated 32×4 `R16G16B16A16F` GPU atlas stores one HDR radiance record per world surfel. Visible surfels update their column from the current HDR backbuffer; off-screen or temporarily occluded surfels retain their last valid radiance through a ping-pong history target. The GI tracer samples this persistent atlas first and uses the old current-frame projection only while a cache entry is cold. The cache is invalidated when surfel identities change.

The v0.012 in-game gate then passed: BeamNG loaded the new GI and surfel-cache shaders, built 25 surfels from 32 detailed rays with zero call failures, enabled the persistent cache, and reported `Cache FX: true` without a BeamRT error.

v0.020 added optional roughness-aware screen-space reflections. BeamNG already supplies useful vehicle reflections, so this path is retained as an experiment rather than the primary direction.

v0.030 pivots the user-facing path back to lighting. `lighting`/`ptgi` now traces four stratified cosine-weighted diffuse paths per half-resolution lighting pixel instead of exposing another square diagnostic. The pattern rotates every frame and feeds the accepted velocity/depth-aware temporal filter. Visible-depth hits provide immediate color bleed, while the persistent surfel-radiance atlas supplies previously observed off-screen lighting. A depth-aware full-resolution upscale protects silhouettes. The compositor gives dark receivers more bounce response and caps indirect energy relative to existing scene luminance so bright emitters do not simply wash out the frame. The world cache checks every 120 lighting frames and recenters after eight metres of camera travel. The first in-game beauty gate passed: both v0.030 shaders loaded, 22/32 rays produced surfels with zero call failures, cache and PTGI effects enabled, and the frame rendered normally without diagnostic blocks. Motion stability and measured GPU cost remain pending.

v0.031 is a focused beauty/noise pass rather than another geometry diagnostic. The full-resolution compositor now uses a 13-tap depth-and-normal-aware reconstruction, reduces the temporal current-frame weight, adds restrained screen-space contact grounding from the existing G-buffer, preserves stronger colored bounce, and permits a larger but still luminance-limited indirect-light budget. `giStrength=0` still exits before contact shading and remains an exact no-op. Offline shader compilation passed; the in-game appearance, motion stability, and additional full-resolution cost are the current acceptance gate.

v0.032 adds a native BeamNG ImGui tuning window so visual iteration no longer requires repeated console commands. `beamrt_main.start()` now opens the tuner and starts lighting. Four presets (`Showcase`, `Balanced`, `Clean / Stable`, and `Performance`) provide useful anchors; live sliders cover beauty, temporal noise, ray cost, and persistent world-cache behavior. The panel can save/load a personal tuning file and copy a complete GELUA command containing the exact current values. v0.032 also adopts a moderately richer Showcase configuration as its default. The menu and new defaults are staged for their first in-game load/interaction test.

v0.040 is the first deliberately expensive beauty path. Diffuse GI can now trace 1–16 paths per GI pixel, render at 50%, 75%, or full resolution, and march as many as 128 steps. The new `ULTRA` preset selects 16 paths, full resolution, and 96 steps—up to roughly 32 times the old v0.030 theoretical trace workload when step count is included. World-cache disc edge/radius confidence suppresses the colored fog/smoke caused by combining very large surfels with high world-GI strength. The tuner exposes these controls and expands the beauty ranges. Offline compilation passes; the first in-game v0.040 load, cost, and appearance gate is pending.

v0.041 separates precise entry from practical slider ranges. Every numeric tuner control now has a right-hand box: type the exact value and press Enter. Console and exact-entry ceilings are 32 paths and 512 ray steps, while the sliders remain 1–16 paths and 8–128 steps so ordinary adjustment is not hypersensitive. `MAX 32x200` is a deliberately extreme full-resolution stress preset. Values above that remain available manually, but can stall the GPU or trigger Windows timeout recovery. The cache-busted v0.041 shader and all other active shader stages compile cleanly; in-game testing is pending.

v0.050 moves the primary quality work from brute-force sampling into the final lighting model. The previous fixed luminance budget made GI strength values near 4 look surprisingly similar because they were silently capped. The cache-busted composer now exposes indirect exposure, shadow focus, receiver-color tint, contrast, energy ceiling, and highlight rolloff. It preserves sky pixels exactly, suppresses the flat full-frame veil on bright surfaces, and gives bright bounce a soft filmic shoulder. The log shows the user's 32/512 uniforms were accepted while the still-loaded v0.040 shader actually capped execution at 16 paths/128 steps; `YOUR BEST` safely reproduces that effective rendered baseline. `CINEMATIC` keeps the same sampling ceiling and changes the lighting model. All active shaders compile in both stages, and a later clean log confirms v0.050 loaded its intended shader set without BeamRT errors. Same-camera appearance and strict no-op checks remain manual.

v0.051 attacks the duplicated-reflection/echoed-GI artifact before adding more rays. Both live screen-space GI hits and radiance entering the persistent surfel atlas now pass through the same diffuse-like source estimator. It keeps broad, coherent colored illumination but uses hit roughness, normal/depth-compatible neighboring luminance, and bright-outlier winsorization to distrust sharp view-dependent highlights. `setRadianceCleanup(0)` restores the exact raw source path for A/B testing; `setRadianceCleanup(1)` enables the estimator and `setSpecularReject(...)` controls its strength.

v0.052 is a deliberately low-risk optimization pass. It removes duplicated center reads in the temporal filter, uses 5/9/13 reconstruction taps at full/75%/half GI scale, uploads unchanged surfel geometry only on dirty/rebind events, disables the surfel-cache PostFX root in screen-only mode, hoists diffuse-basis and ray-projection invariants, and builds replacement surfel sets over several frames before atomically swapping them. The default CPU acquisition budget is four detailed rays per frame and is configurable with `setSurfelRefreshRaysPerFrame(...)`. All nine active shaders compile cleanly as both vertex and pixel stages; in-game validation is pending.

v0.053 adds a temporary, isolated named-buffer diagnostic mode. Six fixed PostEffects can inspect `#sunShadowMask[RT0]`, both `#lightinfo` render targets, `#prepass[RT1]`, `#gtaoOutput[RT0]`, and `#ssaoMask[RT0]` without changing the v0.052 PTGI/temporal/surfel shaders. Only the selected probe is enabled, and switching back to `lighting` immediately restores the normal BeamRT chain. Raw RGB/R/G/B/A display is the default; gain, exposure, and an explicit optional BeamNG HDR decode are available. The cache-busted diagnostic shader and the other nine registered shaders compile in both stages; BeamNG target availability and semantics require in-game inspection.

v0.054 applies the now source-confirmed light-buffer semantics. The default `directdiffuse` radiance source takes bounce energy only from `#lightinfo[RT0].rgb`; it does not consume RT0 alpha or `#lightinfo[RT1]`, which are specular. Because BeamNG does not retain ordinary material diffuse color in a persistent PostFX target, BeamRT derives only a bounded material-color/reflectance estimate from the v0.051 cleaned scene sample and rejects ordinary-material retroreflectivity through `#prepass[RT1].a`. `setRadianceCleanup(0)` remains the exact raw-backbuffer path, and `setRadianceSource("legacy")` preserves the cleaned v0.051 fallback. The same selection runs at live GI hits and before persistent surfel-cache storage.

v0.054 also introduces a backend-neutral scene database. DecalRoads are cached once after level population using `Sim.getDecalRoadData()` and supplemented with a bounded `Sim.getVerticesOfDecalRoad(id)` fallback for SceneTree roads absent from bulk data. Vehicle GPUMesh capture remains lazy and keeps the native live/deforming mesh object. Forest and TSStatic providers now own unique-asset/instance cache interfaces without forcing whole-level scans. A ray-backend registry names the current PostFX/CPU systems and explicitly marks DXR unavailable until a real native bridge exists.

v0.055 hardens that scene database against the verified runtime API inventory. Bulk DecalRoad records now receive `textureLength`, `renderPriority`, `overObjects`, and related layer metadata from their matched SceneTree objects instead of retaining zero placeholders. Incomplete identity/fallback coverage is reported as a failed build rather than a valid cache. Vehicle capture now checks GPUMesh readiness, copies the native vertex/index/normal/tangent/UV/color buffers through FFI, enumerates flexmesh and propmesh descriptors, and normalizes primitive-to-material ranges. Terrain, material, and light providers were added; the light provider uses the verified frustum-mask-64 path and separately records vehicle prop lights while leaving their unverified enabled/electrics state unknown. Initial DecalRoad, Terrain, light, and visible-TSStatic snapshots are staggered after mission start. Forest spatial queries now require a verified caller adapter instead of guessing `ForestData.Circle` arguments. The backend selector now routes the three real PostFX source modes and marks standalone CPU/DXR backends unavailable. These caches remain acquisition-only and do not yet replace the current screen/surfel tracer.

v0.056 corrects the rejected v0.054 `directdiffuse` material-color estimator. The old estimator normalized an already illuminated scene color and multiplied that chroma by the same colored `lightinfo0` value again, causing orange/warm direct light to be applied twice. The new path estimates diffuse reflectance component-wise as cleaned radiance divided by direct-light RGB, regularizes poorly illuminated channels toward a neutral scalar estimate, and reconstructs radiance only where direct lighting is trustworthy. Dark or uncertain pixels blend back to the cleaned-backbuffer result. Retro rejection remains after reconstruction, and `setRadianceSource("legacy")` still provides the cleaned-backbuffer A/B. The UV path is also corrected: active shaders bind `#lightinfo[RT0]` at PostFX slot 3 and map hit coordinates from prepass target space through viewport space into the engine-supplied `rtParams3` light-buffer transform. The v0.054 shaders and slot layout remain on disk as fallbacks.

v0.057 adds `#BeamRT_BaseColorProbe[RT0]` to the isolated buffer diagnostic system as `baseColorProbe`. The explicit RT0 form is baked into the fixed fullscreen PostEffect at creation time; it is never applied through a runtime disable/rebind/enable sequence. This is a controlled test, not a presumed fix: both `#BeamRT_BaseColorProbe` and `#BeamRT_BaseColorProbe[RT0]` were previously observed to resolve to real texture userdata through `imUtils`. The effect samples the named texture directly through the existing diagnostic shader. Use RGB plus raw view to inspect the probe without HDR decoding. RenderView, material-debug systems, and the normal BeamRT lighting pipeline are unchanged.

v0.058 now contains the accepted GPU-only producer-view publication lifecycle. BeamRT creates/configures the BaseColor probe through `getOrCreateView()` and uses matching native Material Debug captures for BaseColor, Metallic, and Emissive. Each fixed passthrough publisher reads its active producer RenderView's `$backBuffer` and writes a persistent named cache. Publishers remain enabled after their first successful draw and are frozen with `oneFrameOnly=true`, `onThisFrame=false`, and `skip=true`; normal completion never calls `disable()`, so the named targets remain allocated and main-view-readable. The PTGI lighting equation is unchanged.

v0.059 adds an inspectable clean-radiance experiment without changing the live PTGI equation. BeamNG shader source confirms that the native Material Debug outputs expose working-space `material.baseColor`, `material.metallic`, and `material.emissive` directly, while final beauty lighting is HDR-encoded later. BeamRT therefore performs no guessed gamma or HDR conversion. One requested main-view frame builds and freezes four linear `R16G16B16A16F` targets: `diffuseAlbedo = BaseColor * (1 - Metallic)`, `directDiffuseRadiance = diffuseAlbedo * lightinfo0.rgb`, depth-masked Emissive, and their combined `cleanRadiance`. Sky/background is rejected through `#prepass[Depth]`. All four are selectable through the existing raw buffer diagnostic. They do not feed the GI tracer yet.

v0.060 connects the accepted `#BeamRT_CleanRadiance[RT0]` target to both live screen-space PTGI hits and persistent surfel-radiance ingestion behind an explicit `legacy`/`clean` selector. Legacy remains the startup default and preserves the prior beauty-derived estimator exactly. Clean selection is accepted only when all three material-cache generations match the generations used to build CleanRadiance, both shader paths have the clean target bound, and the real camera still matches the build snapshot. Position changes beyond 0.01 m, orientation changes beyond 0.05 degrees, any FOV/resolution change, cache invalidation, generation mismatch, graphics/shader reset, or mission change marks CleanRadiance stale and immediately returns the public selector to `legacy`. Every actual source change resets temporal GI and clears only source-dependent surfel radiance/history; geometry surfels remain intact. Material caches are never recaptured automatically.

v0.061 is an intentionally aggressive, fully switchable transport experiment. A stationary camera can now use an exact batch-weighted running average instead of the short-memory temporal blend, retaining as many as 65,536 ray samples while adding only 1–32 new paths per frame. The camera snapshot is compared against the accumulation origin, so cumulative movement, rotation, FOV, or resolution changes restart the exposure. The ray sequence no longer repeats every 64 frames. A selectable `corrected` estimator removes the duplicated receiver cosine from cosine-weighted hemisphere sampling while preserving the v0.060 estimator as `legacy`. Bounce localization can favor nearby hits instead of a room-wide ambient lift, an optional depth-validated previous-GI feedback term approximates a second bounce, and clean-source native emissive radiance can be independently amplified. `EXPERIMENTAL WOW` enables 4 paths/frame, full resolution, a 4,096-sample ceiling, corrected estimation, localized transport, a restrained second bounce, and 4x native emissive bounce. Every control independently resets history and has an explicit off/legacy value.

v0.062 targets the observed 4-path grain versus 16-path cost directly. A view-aware ray budget shortens the global screen/world reach and further restricts rays heading back toward the camera, retaining a small near-field radius instead of spending the complete deep-scene budget. A low-path bilateral outer ring adds 16 comparatively cheap depth/normal-aware reconstruction samples; its influence is strongest at four paths and fades to zero by twelve. The experimental preset now uses eight paths, 45% overall reach, 18% rear reach, stronger denoising, and low-path rescue. This aims to put more independent rays into nearby useful bounce at a cost closer to four full-length paths. Full v0.061 reach/reconstruction remains available by setting both reach controls to 1 and low-path rescue to 0.

v0.063 makes ray-hit correctness the acceptance gate before denoising. The active marcher can bracket a front-to-behind depth crossing, reject silhouette jumps that do not converge into the configured thickness band, and perform 0–6 binary refinements; `-1` restores the exact legacy thickness-only test. A second selectable marcher advances in screen-pixel increments using BeamNG's +Y-forward depth convention and analytically reconstructs world-ray travel, allowing direct A/B against the world-step marcher. Raw fullscreen `hits`, `steps`, `distance`, and `normals` views run the exact production ray function with a frozen diagnostic direction and bypass temporal filtering/composition. BeamNG's native GTAO blue-noise tile and an SVGF-style first/second-luminance-moments prototype are present but start at strength zero so they cannot conceal bad intersections. The `EXPERIMENTAL WOW` preset deliberately enables them only after the ray gate. An entirely separate `voxeldda` mode packs a synthetic occupancy-only 32³ grid into a 256×128 target and tests world-space DDA traversal; it stores no materials/radiance and never feeds PTGI.

v0.064 targets the remaining echo/duplicate-image artifact. Candidate screen hits now have optional confidence validation using travel distance, refined depth error, facing, screen edge, and local depth/normal continuity; weak hits can fall through to the world/surfel representation. New `confidence`, `error`, and `rejection` raw views expose exactly why a candidate was accepted or rejected. The temporal pass also has a motion-only echo guard which downweights stale reprojected history when the current tracer has weak support and begins neighborhood clamping earlier during motion. `setHitValidationStrength(0)` and `setEchoHistoryGuard(0)` preserve the v0.063 A/B behavior.

Targeted BeamNG build: `0.39.4.0.20972`.

This remains a hybrid screen-derived lighting experiment. v0.012 can retain previously observed radiance off-screen, but it cannot discover radiance that has never appeared in a rendered frame. The v0.063 synthetic occupancy DDA is an isolated lab, not a scene voxelizer or lighting backend. No native DXR, production voxel tracing, acceleration structure, or replacement renderer is present.

## Installation

The unpacked development mod belongs at:

```text
C:\Users\ab\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\beamrt\
```

No BeamNG base-game file is replaced or modified.

BeamNG should execute `scripts/beamrt/modScript.lua` when the mod is mounted. If automatic loading fails, open the BeamNG console, select GELUA, and run:

```lua
extensions.load("beamrt_main")
```

## Why v0.004 looked square

v0.004 used one fixed diffuse ray for every 0.25-world-unit cell. That made the noise stay attached to geometry, which was useful for validating reconstruction, but every pixel inside a cell shared the same result. The visible square boundaries were therefore expected.

v0.005a defaults to 0.015625-world-unit cells and changes the ray direction every frame. The temporal pass reprojects and averages those samples. A basic bilateral filter reduces remaining high-frequency noise without intentionally crossing large depth or normal discontinuities. Its history clamp stays loose at rest so stochastic hit/miss samples can converge, then tightens as screen-space velocity rises to suppress trails.

## Render path

Debug modes `off` through `raymarch` retain the original single fullscreen pass through `BeamRT_DebugFx`.

`lighting`, `ptgi`, or the legacy `diffusegi` alias switches to a six-pass BeamRT-only chain:

1. `BeamRT_SurfelCacheFx` projects the 32 world surfels into the current frame, validates depth/normal, and ingests either the existing beauty-derived estimator or `#BeamRT_CleanRadiance[RT0]` according to the v0.060 PTGI selector. It retains valid history for non-visible entries in `#BeamRT_SurfelRadianceCurrent`.
2. `BeamRT_SurfelCacheCopyFx` copies the 32×4 atlas into `#BeamRT_SurfelRadianceHistory` for the next frame.
3. `BeamRT_GIFx` traces a selectable 1–32 stratified diffuse rays at 50%, 75%, or full resolution against visible depth and/or sparse world surfels. Accepted screen hits and projected cold-surfel lookups use the same v0.060 legacy/clean selector; warm surfels read the correspondingly rebuilt persistent atlas. The pass writes confidence-weighted linear indirect light to `#BeamRT_CurrentGI`.
4. `BeamRT_TemporalFx` filters and reprojects GI into `#BeamRT_TemporalGI`. In v0.061 long-exposure mode it uses `newBatchSamples / totalSamples` as the exact current-frame weight and freezes when the configured sample ceiling is reached. v0.062 can add a low-path 5x5 outer reconstruction ring without changing the retained 3x3 fallback.
5. `BeamRT_ComposeFx` performs a 13-tap depth/normal-aware full-resolution reconstruction, shapes indirect exposure/contrast/color/shadow response, applies an adjustable soft energy shoulder, and adds restrained G-buffer contact grounding.
6. `BeamRT_HistoryCopyFx` copies accumulated GI plus depth into `#BeamRT_HistoryGI`.

All history/cache targets use `GFXFormatR16G16B16A16F`. GI history alpha stores normalized eye-linear depth; surfel-cache alpha is a validity bit. The cache uses four identical rows so screen-ray derivatives remain defined while producing its fixed 32-column atlas.

The velocity convention is BeamNG's shipped convention: `previousUV - currentUV`, so the history lookup is `currentUV + velocity`. The design follows the shipped GTAO temporal implementation at a smaller proof-of-concept scale.

`reflections` uses an independent four-pass chain:

1. `BeamRT_ReflectionFx` reconstructs world position/normal, traces a reflected view ray through visible depth, and writes accepted HDR hit radiance.
2. `BeamRT_ReflectionTemporalFx` performs depth/normal-aware filtering and velocity reprojection. History alpha packs normalized depth plus a hit-valid bit.
3. `BeamRT_ReflectionComposeFx` applies the current G-buffer roughness and a Schlick-style Fresnel response, then energy-conservatively interpolates between base and reflected radiance.
4. `BeamRT_ReflectionHistoryCopyFx` preserves the accumulated reflection result for the next frame.

The reflection targets are `#BeamRT_CurrentReflection`, `#BeamRT_TemporalReflection`, and `#BeamRT_HistoryReflection`, all `R16G16B16A16F`.

`bufferdiag` is a separate one-pass probe. It disables every normal BeamRT output effect and enables exactly one fixed-bound diagnostic PostEffect writing to `$backBuffer`. It does not feed diagnostic values into GI history, temporal history, or the surfel cache. Some targets are graphics-setting dependent; a black image may be valid zero data or an unavailable named target, so inspect `beamng.log` for binding warnings.

## Live GELUA controls

The effect is created but disabled by default.

```lua
beamrt_main.enable()
beamrt_main.disable()
beamrt_main.toggle()
beamrt_main.start() -- enable lighting and open the v0.055 tuning window
beamrt_main.openTuner()
beamrt_main.closeTuner()
beamrt_main.toggleTuner()
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))

-- v0.061/v0.062 experimental transport. This also starts PTGI and opens the tuner.
beamrt_main.applyExperimentalPreset()
beamrt_main.setProgressiveAccumulation(true)
beamrt_main.setProgressiveMaxSamples(4096) -- accepted range 1..65536
beamrt_main.setProgressiveClampStrength(0.10)
beamrt_main.setGIEstimator("corrected")     -- or "legacy"
beamrt_main.setGILocalization(0.55)        -- 0 = broad v0.060, 1 = strongly local
beamrt_main.setSecondBounceStrength(0.25)  -- 0 disables; accepted range 0..8
beamrt_main.setEmissiveBoost(4.0)          -- clean source only; 1 is native, 0..32
beamrt_main.setRayReach(0.45)              -- 1 = full configured reach
beamrt_main.setRearRayReach(0.18)          -- extra multiplier toward the camera
beamrt_main.setLowPathRescue(0.80)         -- 0 = original 3x3 reconstruction
dump(beamrt_main.getProgressiveStatus())

beamrt_main.setMode("off")
beamrt_main.setMode("normals")
beamrt_main.setMode("depth")
beamrt_main.setMode("roughness")
beamrt_main.setMode("position")
beamrt_main.setMode("raymarch")
beamrt_main.setMode("diffusegi")
beamrt_main.setMode("lighting") -- aliases: ptgi, pathtracedlighting
beamrt_main.setMode("geometry")
beamrt_main.setMode("orientedgeometry")
beamrt_main.setMode("surfels")
beamrt_main.setMode("surfelcompare")
beamrt_main.setMode("surfelradiance")
beamrt_main.setMode("hybridcoverage")
beamrt_main.setMode("reflections") -- alias: ssr

-- Temporary native-buffer probe; raw display is the default.
beamrt_main.setMode("bufferdiag")
-- v0.054 auto-enables BeamRT when entering bufferdiag
beamrt_main.setBufferDiagnostic("sunShadowMask", "r")
beamrt_main.setBufferDiagnostic("lightinfo0", "rgb")
beamrt_main.setBufferDiagnostic("lightinfo1", "rgb")
beamrt_main.setBufferDiagnostic("prepass1", "rgb")
beamrt_main.setBufferDiagnostic("baseColorProbe", "rgb")
beamrt_main.setBufferDiagnostic("baseColorCache", "rgb")
beamrt_main.setBufferDiagnostic("metallicProbe", "rgb")
beamrt_main.setBufferDiagnostic("metallicCache", "rgb")
beamrt_main.setBufferDiagnostic("emissiveProbe", "rgb")
beamrt_main.setBufferDiagnostic("emissiveCache", "rgb")
beamrt_main.setBufferDiagnostic("diffuseAlbedo", "rgb")
beamrt_main.setBufferDiagnostic("directDiffuseRadiance", "rgb")
beamrt_main.setBufferDiagnostic("maskedEmissive", "rgb")
beamrt_main.setBufferDiagnostic("cleanRadiance", "rgb")
beamrt_main.setBufferDiagnostic("gtaoOutput", "r")
beamrt_main.setBufferDiagnostic("ssaoMask", "r")
beamrt_main.setBufferDiagnosticGain(1.0)       -- 0..1,000,000
beamrt_main.setBufferDiagnosticExposure(0.0)   -- -20..20 stops
beamrt_main.setBufferDiagnosticView("raw")     -- raw or hdr
beamrt_main.exitBufferDiagnostic()              -- immediate return to lighting

-- Persistent cross-RenderView GPU material-cache publication.
beamrt_main.publishBaseColorCache()
dump(beamrt_main.getBaseColorPublication())
beamrt_main.cancelBaseColorPublication() -- optional emergency restoration
beamrt_main.publishMetallicCache()
dump(beamrt_main.getMetallicPublication())
beamrt_main.publishEmissiveCache()
dump(beamrt_main.getEmissivePublication())
-- Only one material publication may be active at a time.
beamrt_main.cancelMaterialCachePublication()

-- Build one frozen diagnostic frame after all three caches are valid and the
-- camera is stationary.
beamrt_main.refreshCleanRadianceDiagnostics()
dump(beamrt_main.getCleanRadianceDiagnostics())
beamrt_main.cancelCleanRadianceDiagnostics() -- optional while a build is armed

-- v0.060 PTGI source selection. Startup/reload always begins on legacy.
beamrt_main.setPTGIRadianceSource("clean")
beamrt_main.getPTGIRadianceSource() -- exactly "clean" or "legacy"
beamrt_main.setPTGIRadianceSource("legacy")

beamrt_main.setDepthGain(20)
beamrt_main.setPositionScale(0.1)
beamrt_main.setRayStepSize(0.55)
beamrt_main.setRayThickness(0.80)
beamrt_main.setRayNormalBias(0.04)
beamrt_main.setRaySteps(36)
beamrt_main.setGIPathCount(8) -- exact/API range: 1..32
beamrt_main.setGIRenderScale(0.75) -- 0.5..1.0
beamrt_main.setGIStrength(0.90)
beamrt_main.setGIClamp(6.0)
beamrt_main.setContactShadowStrength(0.58)
beamrt_main.setBounceSaturation(1.25)
beamrt_main.setGIExposure(0.0)          -- -8..8 photographic stops
beamrt_main.setGIShadowFocus(0.75)      -- 0..1, protect directly lit surfaces
beamrt_main.setGIReceiverTint(0.40)     -- 0..1, approximate receiver albedo
beamrt_main.setGIContrast(1.10)         -- 0.25..4 around an 18% pivot
beamrt_main.setGIEnergyLimit(1.75)      -- 0.1..32, multiplier for indirect budget
beamrt_main.setGIHighlightRolloff(0.80) -- 0..1, hard cap to soft shoulder

beamrt_main.setGICellSize(0.0125)
beamrt_main.setTemporalBlend(0.07)
beamrt_main.setHistoryDepthTolerance(0.008)
beamrt_main.setDenoiseStrength(1.0)
beamrt_main.resetHistory()

beamrt_main.refreshGeometry()
beamrt_main.setGeometryRadius(100)
beamrt_main.setGeometryMaxObjectExtent(200)
print("BeamRT proxy count: " .. tostring(beamrt_main.getGeometryProxyCount()))
print("BeamRT oriented proxy count: " .. tostring(beamrt_main.getOrientedGeometryProxyCount()))
beamrt_main.dumpGeometry()

beamrt_main.refreshSurfels()
beamrt_main.setSurfelTraceDistance(75)
beamrt_main.setSurfelRadius(1.75)
print("BeamRT surfel count: " .. tostring(beamrt_main.getSurfelCount()))
beamrt_main.dumpSurfels()

beamrt_main.setGISource("hybrid") -- hybrid, screen, or surfels
print("BeamRT GI source: " .. tostring(beamrt_main.getGISource()))
beamrt_main.setWorldGIStrength(1.15)
beamrt_main.setWorldLeakSuppression(0.85)
beamrt_main.setRadianceCleanup(1.0) -- 0 = exact legacy/raw source path
beamrt_main.setSpecularReject(0.85) -- 0..1 glossy-highlight rejection
beamrt_main.setRadianceSource("directdiffuse") -- aliases: lightinfo, lightinfo0
beamrt_main.setRadianceSource("legacy")        -- cleaned final-HDR fallback
beamrt_main.setRadianceChromaStrength(1.0)     -- 0..1 bounded material-color carry
beamrt_main.setRetroReject(1.0)                -- 0..1 prepass1.a rejection
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setSurfelCacheBlend(0.15)
beamrt_main.setSurfelRefreshDistance(8)
beamrt_main.setSurfelRefreshRaysPerFrame(4) -- integer 1..32; pending cache-build CPU budget

beamrt_main.applyPreset("cinematic") -- userbest, maxquality, ultra, showcase, balanced, clean, performance
beamrt_main.saveTuning()
beamrt_main.loadTuning()
beamrt_main.printSettings()

beamrt_main.setReflectionStrength(0.85)
beamrt_main.setReflectionMaxRoughness(0.58)
beamrt_main.resetReflectionHistory()

-- Backend-neutral scene acquisition. DecalRoads also build automatically once
-- after mission population; these commands are for inspection/manual rebuilds.
beamrt_main.rebuildSceneDatabase("decalRoads")
beamrt_main.rebuildSceneDatabase("terrain")
beamrt_main.rebuildSceneDatabase("lights") -- defaults to main-view frustum mask 64
beamrt_main.rebuildSceneDatabase("tsStatic") -- defaults to main-view frustum mask 256
dump(beamrt_main.getSceneDatabaseStats())
beamrt_main.captureVehicleGeometry() -- copies current player GPUMesh buffers/primitives
beamrt_main.captureMaterial("road_asphalt_2lane")
beamrt_main.selectRayBackend("postfxHybrid") -- also postfxScreen/postfxSurfels
dump(beamrt_main.getRayBackendStatus())
```

## v0.060 clean-radiance PTGI acceptance workflow

`beamrt_main.setPTGIRadianceSource("clean")` does not regenerate any material cache. It first verifies that CleanRadiance is valid and non-stale; BaseColor, Metallic, and Emissive generations still match the generations used by CleanRadiance; the real camera transform/FOV/resolution still matches the CleanRadiance build snapshot; and both the live GI and surfel-cache shader paths have `#BeamRT_CleanRadiance[RT0]` bound. If accepted, subsequent live screen hits, projected cold-surfels, and persistent surfel ingestion read the clean target. The switch resets temporal GI and clears source-dependent surfel radiance/history while preserving surfel geometry.

`beamrt_main.setPTGIRadianceSource("legacy")` immediately restores the complete pre-v0.060 source path. Startup and extension reload always select `legacy`; the clean choice is deliberately not stored in tuning settings.

If a selected clean source becomes invalid, BeamRT logs the exact cause and automatically changes the public selection to `legacy`. It never continues sampling a known-stale clean image and never automatically recaptures material buffers.

Use this complete GELUA workflow. Keep the camera stationary from the first publication through both A/B screenshots and allow several frames of warm-up after every source switch.

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main"); print("BeamRT version: "..tostring(beamrt_main.getVersion()))
```

Expected: `BeamRT version: 0.060`.

```lua
beamrt_main.publishBaseColorCache()
```

After completion:

```lua
beamrt_main.publishMetallicCache()
```

After completion:

```lua
beamrt_main.publishEmissiveCache()
```

After completion:

```lua
beamrt_main.refreshCleanRadianceDiagnostics()
```

After the one-frame build:

```lua
dump(beamrt_main.getCleanRadianceDiagnostics())
```

Require `valid=true`, `stale=false`, matching source generations, and `feedsPTGI=false` before selection. Then:

```lua
beamrt_main.setPTGIRadianceSource("clean")
beamrt_main.setMode("lighting"); beamrt_main.enable()
```

For the live-hit-only comparison:

```lua
beamrt_main.setGISource("screen")
beamrt_main.setPTGIRadianceSource("legacy")
beamrt_main.setPTGIRadianceSource("clean")
```

Allow several frames after each selector call before capturing its screenshot. Then test persistent ingestion independently:

```lua
beamrt_main.setGISource("hybrid")
beamrt_main.setPTGIRadianceSource("legacy")
beamrt_main.setPTGIRadianceSource("clean")
```

`beamrt_main.getPTGIRadianceSource()` returns exactly `"legacy"` or `"clean"`. While clean is genuinely selected and usable, `getCleanRadianceDiagnostics().feedsPTGI` is true. Any source change deliberately clears the previous temporal and surfel-radiance accumulation, so first-frame comparisons are not representative.

## PTGI tuner workflow

Run `beamrt_main.start()` in GELUA. The native ImGui tuner opens. Choose **CINEMATIC** first; **YOUR BEST** recreates the effective 16×128 result seen under the old loaded v0.040 shader, and **MAX 32x200** is the first preset that deliberately activates the new higher compiled ceiling. Each numeric control has a practical slider and an exact box on its right; type the value and press Enter. Under **Radiance source cleanup**, use **RAW SOURCE (A/B)** and **CLEAN DIFFUSE SOURCE** from the same stationary camera to test reflection echo directly. Each button invalidates both temporal GI and the persistent cache; wait several frames after switching. Use **Indirect exposure**, **Shadow focus**, **Indirect contrast**, and **Energy ceiling** for the large visual changes. More paths only reduce sampling noise; they do not improve the lighting model or sparse world representation. Full resolution is four times as many GI pixels as half resolution. If world bounce looks smoky, keep **Leak suppression** near `0.9`, reduce cache update speed, and keep **Surfel radius** below roughly `2.5 m`.

The console calls the same validated setters as the menu. For example:

```lua
beamrt_main.setGIPathCount(32); beamrt_main.setRaySteps(200); beamrt_main.setGIRenderScale(1); beamrt_main.resetHistory()
```

The console does not bypass the shader ceiling: v0.053 retains the v0.052 rejection above 32 paths or 512 steps because the HLSL loop must have a finite compiled maximum.

Use **Save My Tuning** to write `/settings/beamrtTuner.json` in the BeamNG user folder. Use **Copy Values** to place a complete reproducible GELUA command on the clipboard; this is the preferred way to report a visually successful configuration. Cache distance/radius changes should be followed by **Refresh World Cache**.

`setGICellSize` accepts `0.005` through `1` world unit. Smaller cells hide block boundaries but can increase high-frequency noise.

`setTemporalBlend` is the minimum weight of the current frame. Lower values converge more smoothly but can ghost longer; higher values react faster but retain more noise. The accepted range is `0.02` through `1`.

`setHistoryDepthTolerance` is a relative normalized eye-depth threshold. Lower values reject history more aggressively around motion and disocclusion. The accepted range is `0.0001` through `0.25`.

`setDenoiseStrength` blends between the raw current ray (`0`) and the 3×3 bilateral estimate (`1`).

Changing ray geometry, GI clamp, or cell size resets the temporal history automatically. `resetHistory()` is available for camera teleports, comparisons, or suspected stale history.

## Phase 5 findings and v0.007 design

The authoritative BeamNG 0.39.4 files used for this step were:

- `lua/ge/ge_utils.lua`: confirms `Engine.castRay`, the slower detailed CPU raycast returning point and normal data, and distinguishes it from the distance-only `castRayStatic` path.
- `lua/ge/extensions/core/terrain.lua`: confirms direct GELUA access to `TerrainBlock:getHeight`, `getNormal`, and `getSmoothNormal`.
- `lua/ge/extensions/core/environment.lua`: confirms shipped scene enumeration through `scenetree.findClassObjects("TSStatic")`.
- `lua/ge/extensions/editor/api/object.lua` and `editor/objectScreenSizeViz.lua`: confirm `SceneObject:getWorldBox()` and its `minExtents`/`maxExtents` members, including the validity checks used by BeamNG's editor.
- `lua/ge/extensions/editor/objectTool.lua`: confirms the editor constructs an oriented selection box from `getTransform()`, the local `getObjBox()` extents, separate `getScale()`, and the world-box center. Matrix columns 0 and 1 are the local X/Y orientation axes.
- `lua/ge/extensions/editor/assemblySpline/molecule.lua`: explicitly documents `getObjBox()` as the mesh bounding box in local mesh space.
- `lua/ge/client/postFx/smaa.lua` and `dof.lua`: confirm vector values can be passed to PostEffects with `setShaderConst` using space-separated strings.
- `lua/ge/extensions/tech/terrainImporter.lua`: confirms GELUA can construct and save `GBitmap` data, but the shipped Lua inspected here does not expose a direct per-frame structured GPU-buffer or mesh-buffer upload API for a normal mod.

The viable mod-only routes are therefore not equivalent:

- Scene-object bounds are available immediately and can be updated for moving objects, but they are coarse AABBs and lose mesh shape/material information.
- `Engine.castRay` can query real collision/render geometry on the CPU, but BeamNG labels this route slow; per-pixel use is not viable.
- Terrain height sampling can build a local height field, but it cannot represent overhangs or general meshes by itself.
- A Lua-generated bitmap atlas is technically possible as a later cached/batched experiment, but it needs a deliberate update and texture-lifetime design.
- Direct vertex/index buffers, UAV voxelization, BLAS/TLAS, and DXR dispatch remain unavailable through the shipped mod-facing Lua/PostFX interfaces inspected so far.

v0.006 chooses scene-object AABBs because that is the smallest reversible experiment that proves world geometry can cross the GELUA-to-HLSL boundary. It scans `TSStatic`, `MeshRoad`, `ProceduralMesh`, and `GroundPlane`, rejects invalid or over-large bounds, pads nearly flat bounds to 5 cm, sorts by distance to the camera, and uploads at most 16. It never modifies the source objects.

v0.007 derives an OBB for each selected object when local bounds, transform, and scale are exposed. The world center and two normalized orientation axes plus three half-extents are packed into three float4 constants; HLSL reconstructs the third axis with a cross product and transforms each ray into box-local space. Objects without the required API receive an axis-aligned fallback, and the log reports oriented versus fallback counts. Mode 7 remains unchanged for controlled A/B comparison.

`geometry` mode colors reflection-ray results as follows:

- cyan: visible-depth hit only;
- magenta: world-space proxy hit only;
- white: both tracers hit;
- dark purple: both miss.

Magenta is the important Phase 5 signal: it means the shader intersected a GELUA-provided world proxy even though the visible-depth ray did not report a hit. The proxy is still only a box, so it is expected to over-occlude empty space around rotated or irregular meshes.

`orientedgeometry` mode uses this five-color legend:

- cyan: visible-depth hit only;
- magenta: oriented-box hit only;
- white: visible-depth and oriented-box hit;
- orange: coarse AABB hit but oriented box miss;
- dark purple: all three tests miss.

Orange is the direct explanation for the earlier square-ish regions: those rays intersect the empty corner volume of the world AABB but not the tighter object-aligned box.

## Phase 5 v0.007 acceptance test

Press Ctrl-L, then run in GELUA:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setGeometryRadius(100)
beamrt_main.setGeometryMaxObjectExtent(200)
beamrt_main.refreshGeometry()
print("BeamRT proxy count: " .. tostring(beamrt_main.getGeometryProxyCount()))
print("BeamRT oriented count: " .. tostring(beamrt_main.getOrientedGeometryProxyCount()))
beamrt_main.dumpGeometry()
beamrt_main.setMode("orientedgeometry")
```

Expected results:

- The version is `0.007` and the log names `beamrtDebugP_v007.hlsl`.
- The proxy count is nonzero near the same test objects used for v0.006; `TSStatic` entries should normally contribute to the oriented count.
- The dump marks each proxy as `OBB=local-box` or `OBB=AABB-fallback` and prints finite center, half-extents, and axes.
- Mode 8 shows the five-color legend above. Orange regions should correspond to excess AABB corners and should generally reduce the large square-ish magenta regions seen in mode 7.
- Switching between `setMode("geometry")` and `setMode("orientedgeometry")` from the same camera should visibly isolate the refinement.
- Rotating the camera must leave both proxy representations attached to the world.
- Returning to `setMode("diffusegi")` must preserve the accepted v0.005a renderer.
- Ctrl-L and explicit unload/reload must remain free of shader, Lua, and duplicate-object errors.

v0.007 passed offline HLSL compilation for both shader stages and its in-game acceptance test on BeamNG `0.39.4.0.20972`. Six of six uploaded `TSStatic` proxies used genuine local-space OBB data with finite centers, half-extents, and orientation axes; none fell back to an AABB. Both diagnostic modes rendered stably. The selected scene consisted mainly of thin panels, planes, and tubes, so there was no large orange AABB-excess region from the tested view; that is a valid near-equal-bounds result rather than a fallback. Returning to `diffusegi`, disabling, unloading, and reloading all succeeded without BeamRT shader, Lua, or duplicate-object errors.

## Phase 5 v0.008 sparse-surface acceptance test

Press Ctrl-L, then run in GELUA:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
print("BeamRT surfel count: " .. tostring(beamrt_main.getSurfelCount()))
beamrt_main.dumpSurfels()
beamrt_main.setMode("surfels")
```

Expected mode 9 result: intersected surfel discs display their true raycast normal as `normal * 0.5 + 0.5`; misses are dark purple. The colored regions should remain world-attached while the camera rotates. This is deliberately sparse and disc-shaped.

Then run:

```lua
beamrt_main.setMode("surfelcompare")
```

Mode 10 colors are:

- cyan: visible-depth hit only;
- green: detailed world-surfel hit only (bright green is shell, yellow-green is ground-grid);
- white: both hit;
- dark purple: both miss.

Green is the important signal: the reflection ray reached detailed CPU-raycast geometry not represented by its visible-depth trace. After moving a significant distance, call `refreshSurfels()` because the cache is intentionally a snapshot. Finally return to `diffusegi`, disable, and exercise unload/reload exactly as in the previous gates.

v0.008 passed offline `vs_5_0` and `ps_5_0` compilation and its in-game gate. Two refreshes produced 23 and 28 finite surfels from 32 rays with zero call failures; normals were unit length, normal-colored patches stayed world-attached, and mode 10 showed green surfel-only regions. Returning to `diffusegi`, disabling, unloading, and reloading all succeeded; `Debug removed`, `GI removed`, and `BeamRT reloaded` each printed `true`.

## Phase 5 v0.009 hybrid-radiance acceptance test

Press Ctrl-L, select GELUA, and run:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
beamrt_main.setWorldGIStrength(1.0)
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setGIStrength(0.7)
beamrt_main.setMode("diffusegi")
beamrt_main.setGISource("screen")
```

Hold the camera still for at least 16 frames and take the first comparison image. Without moving the camera, run each command separately and allow another 16 frames before each image:

```lua
beamrt_main.setGISource("surfels")
beamrt_main.setGISource("hybrid")
```

Expected:

- `screen` reproduces the accepted v0.005a path;
- `surfels` is sparse but must show stable, colored indirect-light regions rather than the mode-9 normal palette;
- `hybrid` retains the screen result and fills some misses where a visible, depth/normal-validated surfel supplies radiance;
- no surfel contribution should appear through clearly occluding foreground geometry;
- changing source mode resets temporal history, so comparisons require a short reconvergence pause;
- moving far from the snapshot requires `refreshSurfels()`.

For a strict no-op check, run `beamrt_main.setGIStrength(0)`. Restore with `setGIStrength(0.7)`. Finally repeat the v0.008 cleanup/unload/reload check and inspect `beamng.log` for `beamrtGITraceP_v009`, shader compilation, Lua errors, NaNs, and duplicate objects.

Initial in-game testing loaded the correct v0.009 shader, uploaded 23 surfels from 32 rays with zero failures, and completed the `screen`/`surfels`/`hybrid` sequence without BeamRT errors. The surfel-only image was clean enough that a nonzero contribution was not yet unambiguous, so the gate additionally requires a stationary surfel-only comparison at `setWorldGIStrength(0)` and `setWorldGIStrength(4)`.

That strength comparison suggested a slightly stronger blue lift at `4`, but a viewport/framing change made it insufficient as proof. v0.010 replaces that ambiguous comparison with the following direct gate. After Ctrl-L, run:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setMode("surfelradiance")
```

Mode 11 colors: dark purple means no surfel-disc intersection; magenta means the surfel center could not be projected into the viewport; orange means current depth rejected it; red means depth passed but the visible normal disagreed; green means the surfel passed every check and can supply real HDR radiance. Any stable green region proves the v0.009 lighting path has valid inputs.

For the v0.011 exact hybrid-coverage gate, reload the extension and run:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setSurfelTraceDistance(60)
beamrt_main.setSurfelRadius(2)
beamrt_main.refreshSurfels()
beamrt_main.setWorldGIStrength(1)
beamrt_main.setSurfelVisibilityTolerance(1.5)
beamrt_main.setMode("hybridcoverage")
```

Mode 12 colors: cyan is a diffuse visible-depth hit, green is a validated surfel fallback after visible depth missed, and dark purple is a complete miss/rejection. Stable green is the gate proving useful hybrid extension rather than merely a valid surfel lookup in isolation.

## Phase 5 v0.006 acceptance test

Press Ctrl-L, then run in GELUA:

```lua
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable()
beamrt_main.setGeometryRadius(100)
beamrt_main.setGeometryMaxObjectExtent(200)
beamrt_main.refreshGeometry()
print("BeamRT proxy count: " .. tostring(beamrt_main.getGeometryProxyCount()))
beamrt_main.dumpGeometry()
beamrt_main.setMode("geometry")
```

Expected results:

- The version is `0.006` and the log names `beamrtDebugP_v006.hlsl`.
- A normal level near static scenery reports one through 16 proxies. An empty test level may legitimately report zero.
- The proxy dump contains real nearby BeamNG object names/classes and finite world-space minimum/maximum coordinates.
- `geometry` mode is not the normal shaded scene; it shows the four diagnostic colors above.
- Rotating the camera near buildings, barriers, or props should expose some magenta proxy-only regions. Their placement should remain world-stable.
- `beamrt_main.setGeometryRadius(5); beamrt_main.refreshGeometry()` should usually reduce the count; restoring `100` should repopulate it.
- Returning to `beamrt_main.setMode("diffusegi")` must preserve the accepted v0.005a temporal GI behavior.
- `beamrt_main.disable()` must restore the unmodified scene.
- Ctrl-L and explicit unload/reload must not produce duplicate-object or shader errors.

The v0.006 proxy-geometry gate passed in-game on BeamNG `0.39.4.0.20972`. The shader produced all four diagnostic categories, including magenta proxy-only hits. GELUA uploaded six finite `TSStatic` bounds in the test scene; changing the radius from 100 m to 5 m reduced the selected set, and restoring 100 m repopulated it. Returning to `diffusegi` preserved the accepted filtered temporal result. Explicit unload/reload recreated v0.006 cleanly, and the log contained no BeamRT shader, Lua, or duplicate-object errors.

This accepts the scene-object-to-HLSL geometry bridge, not AABBs as the final scene representation. Proxy data will not be mixed into final GI until its over-occlusion and missing-material limitations are addressed.

## Phase 4 acceptance test

After entering a level, press Ctrl-L once, then run this in GELUA:

```lua
print("BeamRT loaded:", extensions.isExtensionLoaded("beamrt_main"))
print("Debug effect:", scenetree.findObject("BeamRT_DebugFx") ~= nil)
print("GI effect:", scenetree.findObject("BeamRT_GIFx") ~= nil)
print("Temporal effect:", scenetree.findObject("BeamRT_TemporalFx") ~= nil)
print("Compose effect:", scenetree.findObject("BeamRT_ComposeFx") ~= nil)
print("History copy:", scenetree.findObject("BeamRT_HistoryCopyFx") ~= nil)
```

Set a conservative baseline:

```lua
beamrt_main.enable()
beamrt_main.setRayStepSize(0.75)
beamrt_main.setRayThickness(1.0)
beamrt_main.setRayNormalBias(0.05)
beamrt_main.setRaySteps(32)
beamrt_main.setGIClamp(5.0)
beamrt_main.setGICellSize(0.015625)
beamrt_main.setTemporalBlend(0.12)
beamrt_main.setHistoryDepthTolerance(0.01)
beamrt_main.setDenoiseStrength(0.75)
beamrt_main.setGIStrength(0.7)
beamrt_main.setMode("diffusegi")
```

Then perform these comparisons from the same camera:

```lua
beamrt_main.setTemporalBlend(1.0); beamrt_main.resetHistory()
beamrt_main.setTemporalBlend(0.12); beamrt_main.resetHistory()

beamrt_main.setDenoiseStrength(0.0); beamrt_main.resetHistory()
beamrt_main.setDenoiseStrength(0.75); beamrt_main.resetHistory()

beamrt_main.setGICellSize(0.25); beamrt_main.resetHistory()
beamrt_main.setGICellSize(0.015625); beamrt_main.resetHistory()
```

Expected results:

- `setTemporalBlend(1.0)` shows the changing one-ray-per-pixel estimate with little temporal smoothing.
- `setTemporalBlend(0.12)` should visibly settle over roughly 8–16 frames while the camera is still.
- Denoise strength `0.75` should reduce fine speckle more than `0`, while strong object silhouettes remain recognizable.
- Cell size `0.015625` should look substantially less blocky than `0.25`.
- During slow camera motion, the accumulated illumination should track surfaces rather than remain fixed on the screen.
- Revealed surfaces and moving vehicle edges should discard stale history quickly. Small edge flicker is expected; long bright trails are not.
- `setGIStrength(0)` must remain a visual no-op.
- The sky and invalid ray misses must not acquire accumulated GI.
- `disable()` must restore the unmodified scene.

Exercise cleanup after the visual test:

```lua
extensions.unload("beamrt_main")
print("Debug removed:", scenetree.findObject("BeamRT_DebugFx") == nil)
print("GI removed:", scenetree.findObject("BeamRT_GIFx") == nil)
extensions.load("beamrt_main")
print("Debug recreated:", scenetree.findObject("BeamRT_DebugFx") ~= nil)
print("GI recreated:", scenetree.findObject("BeamRT_GIFx") ~= nil)
```

Phase 4 acceptance passed with v0.005a: the earlier world-cell checker pattern was removed, accumulated GI remained attached across several camera views, no persistent bright history trails were visible, base output was restored on unload, and the log contained no BeamRT shader, Lua, NaN, or duplicate-object errors.

## v0.012 decisive cache gate

This replaces the repeated stationary screen-versus-hybrid screenshot loop. Reload once in GELUA:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable(); beamrt_main.refreshSurfels()
beamrt_main.setGISource("surfels"); beamrt_main.setWorldGIStrength(1); beamrt_main.setGIStrength(0.7)
beamrt_main.setMode("diffusegi")
```

The gate was: version `0.012`; creation messages for `BeamRT_SurfelCacheShader` and `BeamRT_SurfelCacheFx`; no BeamRT Lua/HLSL error; and a live cache object. The submitted console result passed those implementation checks with 25 surfels and zero detailed-ray failures.

## v0.020 reflection gate

After Ctrl-L, reload once and enter the new mode:

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.enable(); beamrt_main.setReflectionStrength(0.85)
beamrt_main.setReflectionMaxRoughness(0.58); beamrt_main.setMode("reflections")
print("Reflection FX: " .. tostring(scenetree.findObject("BeamRT_ReflectionFx") ~= nil))
```

The gate is version `0.020`, `Reflection FX: true`, no BeamRT compile/Lua error, visible world-attached reflections on glossy car/floor regions, graceful fading near screen borders, and no long temporal trails during a slow orbit. `setReflectionStrength(0)` must be a strict visual no-op. This is one capability gate, not another sequence of tiny parameter comparisons.

## v0.058 validation gate

1. Clean-reload the extension and confirm `beamrt_main.getVersion() == "0.058"`. Confirm the log creates dormant BaseColor, Metallic, and Emissive publishers with their `$backBuffer -> #BeamRT_*Cache` mappings and reports no PostEffect/named-target error.
2. Reproduce the fixed-camera orange-light case and compare `setRadianceSource("directdiffuse")` against `setRadianceSource("legacy")` after each view converges. Directdiffuse must no longer square the orange/warm light chroma, and colored surfaces must retain materially plausible bounce rather than inheriting one overwhelming lightinfo hue.
3. Check light/shadow boundaries and viewport edges for a spatial offset between the GI source and visible geometry. The slot-3 `rtParams3` mapping should keep lightinfo aligned with prepass hits at every supported resolution and viewport.
4. Verify `setRadianceCleanup(0)` still selects exact raw final-HDR radiance and `setGIStrength(0)` remains a strict visual no-op.
5. Compare material-color carry at `0` and `1`, then retro rejection at `0` and `1` around colorful surfaces, road signs, and license plates.
6. Call `publishBaseColorCache()`, `publishMetallicCache()`, and `publishEmissiveCache()` sequentially. Each result must report `active=false`, `phase="frozen"`, `valid=true`, `stale=false`, `publisherEnabled=true`, and `publisherSkipped=true`. In NamedTextureTarget Viewer compare each probe/cache pair, then display each cache through main-view raw-RGB `bufferdiag`. Move the camera between checks: all three caches must remain frozen until explicitly republished. Confirm the previous BeamRT mode/enabled state and `main.usePostEffects` are restored after every capture.
7. After roughly 165 mission frames, inspect `getSceneDatabaseStats()`. West Coast should be close to 12,752 bulk roads plus 12 fallback roads, with complete coverage and roughly the bulk count reported under `metadataBackfilled`. Terrain, visible-light, visible-TSStatic, and DecalRoad-material snapshots should also be populated.
8. Call `captureVehicleGeometry()` once. Confirm nonzero vertices, indices, flexmesh/propmesh counts and primitives, no core-buffer acquisition error, and sensible optional-buffer warnings. This is acquisition-only and must not change the image.
9. Select `postfxScreen`, `postfxSurfels`, and `postfxHybrid` through `selectRayBackend(...)`; `getRayBackendStatus()` and `getGISource()` must stay synchronized. `cpuHybrid` and `dxr` must reject selection.

Known v0.058 limitations: BaseColor publication is accepted, while the new Metallic and Emissive caches still require independent in-game acceptance. Frozen caches are diagnostic-only and are marked stale on mission, settings/graphics, shader, or material invalidation; they must then be republished. `directdiffuse` still uses its existing approximation and does not consume any of the three new caches yet. Prepass RT1 alpha is only known to mean retroreflectivity for ordinary opaque permutations; DecalRoad fallbacks remain capped at 256; Forest spatial queries still need a verified adapter; Terrain material layers and Forest/TSStatic DAE triangles are unresolved; vehicle prop-light enabled/electrics state is intentionally unknown; and none of the new scene providers feeds the active tracer yet.

## Troubleshooting

The active log is:

```text
C:\Users\ab\AppData\Local\BeamNG\BeamNG.drive\current\beamng.log
```

Search for `BeamRT`, `v012`, `beamrtSurfelCache`, `beamrtGITrace`, `compile`, and `error`.

### Shader compile failure

1. Confirm the active v0.020 entries exist: `beamrtReflectionTraceP_v020.hlsl`, `beamrtReflectionTemporalP_v020.hlsl`, and `beamrtReflectionComposeP_v020.hlsl`.
2. Fix the first HLSL error in `beamng.log`; later errors may be cascading.
3. Press Ctrl-L after source changes. Versioned entry points prevent reuse of older cached programs.
4. If the old shader remains cached, use the BeamNG Launcher cache-cleaning workflow rather than deleting unrelated cache data manually.
5. Confirm the renderer is D3D12 and Advanced Lighting is active.

### Missing PostEffect objects

1. Run `extensions.load("beamrt_main")` in GELUA.
2. Check the five effect-object commands in the acceptance test.
3. Verify the path is exactly `lua/ge/extensions/beamrt/main.lua`.
4. Inspect the log for `[BeamRT] extension load (v0.020)` and object-creation messages.
5. If only a child effect is missing, unload and reload the extension so the whole chain is recreated.

### Blank or black output

1. Run `beamrt_main.disable()`; the original scene should return immediately.
2. Test `beamrt_main.enable(); beamrt_main.setMode("normals")`. If that is also blank, the issue is not temporal history.
3. Confirm `#prepass[RT0]`, `#prepass[Depth]`, and `#VelocityBuffer` exist in the NamedTextureTarget viewer.
4. Confirm the five BeamRT named targets appear after enabling `diffusegi`, including `BeamRT_SurfelRadianceCurrent` and `BeamRT_SurfelRadianceHistory`.
5. Run `beamrt_main.resetHistory()` after a resolution change or camera teleport.

### Excessive ghosting or trails

1. Reduce history lifetime by increasing `setTemporalBlend` from `0.12` to `0.2` or `0.3`.
2. Tighten rejection with `setHistoryDepthTolerance(0.005)`.
3. Run `resetHistory()` and repeat the motion test.
4. If trails occur only on very fast-moving vehicle pieces, capture the velocity-buffer visualizer; dynamic-object velocity quality limits reprojection.

### Still noisy or blocky

1. Use `setGICellSize(0.0078125)` for finer cells.
2. Lower `setTemporalBlend` to `0.08` for more history, accepting slower response.
3. Increase `setDenoiseStrength(1.0)`.
4. Keep the camera still for at least 16 frames when comparing convergence.
5. Do not use a larger depth tolerance to hide noise; it increases ghosting risk.

### Automatic loading fails

1. Confirm the bootstrap path is exactly `scripts/beamrt/modScript.lua`.
2. Confirm BeamRT is enabled in the Mod Manager and the unpacked directory is mounted.
3. Run `extensions.load("beamrt_main")` as the manual fallback.
4. Inspect `beamng.log` for BeamRT Lua errors or another mod failing earlier during initialization.

## Scope boundary

### v0.104 real-mesh sunlight integration (opt-in)

v0.106 prepares actual WCU underground meshes and stages a direct world-mesh query
inside the legacy native point/spot light passes. This build also exposes clustered
compute lighting, whose integration is still blocked by its binding interface;
the legacy hook refuses activation there. **Not yet a verified headlight/sewer
fix.** See [scope and required binding-interface lookup](UNDERGROUND_LOCAL_LIGHTS_V0106.md).

v0.105 corrects vehicle-light acquisition across driving/walking and replaces the
unsafe cached-shader filename swap with private shader objects/material rebinding.
These are implementation fixes, **not verified headlight/sewer shadow fixes**.
See [scope, evidence and next integration milestone](LIGHT_VISIBILITY_V0105.md).

The guardhouse BVH now has an actual native direct-sun shading hook, not only a
colored preview. Native shadows remain; unknown/alpha materials fall back. GI/SSR
algorithms are preserved. Default OFF; GPU execution, off-screen appearance and
cost remain unverified. See [implementation and one normal-render activation](MESH_SUN_SHADOW_MILESTONE.md).
The native hook is generated privately from the local installation; its source
is not included in Git and must be prepared when moving to another PC/game version.

Phase 4 intentionally departs from v0.004's single-pass design because previous-frame data requires persistent intermediate targets. All added objects and targets are uniquely BeamRT-prefixed and are removed when the extension unloads. No base-game files are changed.

Phase 5's geometry bridge, oriented-box refinement, sparse detailed-raycast surfels, radiance validation, exact hybrid coverage, and v0.012 persistent-radiance implementation gate are accepted. v0.020 reflections are staged for their first in-game gate. The accepted screen-only GI renderer remains selectable through `setGISource("screen")`. Native DX12/DXR work has not started.
