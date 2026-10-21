local EffectModule = {}
-- Rendering-only adaptation of an author-authorized contribution. No external
-- mod manager, loader, identity, input bindings or global engine overrides.
local ownedObjects = {}
local function registerOwned(object, name)
    object:registerObject(name)
    ownedObjects[name] = object
end

EffectModule.id = "beamrt_coherent"
EffectModule.name = "BeamRT Coherent SSR"
EffectModule.description = "Opt-in screen-space reflections for roads, vehicles and water. Sky and enclosure fill are separate heuristic experiments."
EffectModule.category = "Post Processing/Lighting"

EffectModule.version = "0.119.0"
EffectModule.shaderCodeVersion = EffectModule.version



EffectModule.defaultEnabled = false
EffectModule.settingsFile = "beamrt_coherent.json"
EffectModule.shaderCacheVersion = "beamrt_coherent_" .. EffectModule.shaderCodeVersion:gsub("%W", "_") .. "_shadercache"
EffectModule.shaderFiles = {
    "shaders/beamrt/coherent/beamrt_coherent_v.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent.h.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_surface.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_common.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_water.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_projection.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_environment.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_trace.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_temporal.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_history.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_accumulate.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass18_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pyramid.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_composite.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass0_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass2_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass3_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass5_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass6_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass7_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass8_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass9_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass10_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass11_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass12_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass13_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass14_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass15_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass16_p.hlsl",
    "shaders/beamrt/coherent/beamrt_coherent_pass17_p.hlsl"
}

EffectModule.parameters = {
    samplingMode = {label = "Sampling Pattern", type = "number", default = 1, min = 0, max = 1, step = 1,
        description = "0 ordered legacy 8x8; 1 non-tiled per-pixel scramble. A/B experiment, not a convergence guarantee."},
    referenceTrace = {label = "Leaf-Only Trace Reference", type = "bool", default = false,
        description = "Disables hierarchy skipping and raises the bounded step budget to 256. Slow diagnostic, not a quality preset."},
    roughStability = {label = "Rough Stability (Experimental)", type = "bool", default = true,
        description = "Geometry-gated diagonal reuse and sparse-coverage history clipping for rough opaque GGX receivers. Excludes water and mirror-like surfaces. May soften detail or retain stale radiance; toggle for A/B."},
    qualityPreset = { label = "Trace Quality", type = "number", default = 2.0, min = 0.0, max = 4.0, step = 1.0, format = "%.0f", order = 5,
        description = "Sets Ray Reach. Render Resolution is set separately." },

    amount = { label = "Amount", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01 },
    intensity = { label = "Intensity", type = "number", default = 0.68, min = 0.0, max = 2.0, step = 0.01 },
    fogTransport = { label = "Fog Occlusion", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01,
        description = "Lets BeamNG's height fog cover reflections, instead of drawing reflections over the fog." },

    maxDistance = { label = "Max Distance", type = "number", default = 85.0, min = 1.0, max = 1500.0, step = 1.0 },
    traceQuality = { label = "Trace Quality", type = "number", default = 0.5, min = 0.0, max = 1.0, step = 0.01, order = 6,
        description = "Maximum steps per ray, from 24 at 0% to 128 at 100%. Nearby reflections are always traced at full detail; this sets how far a ray can search and is the main trace cost. Rays continue to the screen edge; there is no distance limit." },
    hiZMaxLevel = { label = "Coarsest Level", type = "number", default = 4.0, min = 0.0, max = 4.0, step = 1.0,
        description = "Coarsest pyramid level the traversal may climb to: 1 = 4-texel cells, 2 = 16, 3 = 64. 0 walks every texel with no hierarchy -- a slow reference mode for checking the hierarchy finds the same reflections." },
    thicknessTexels = { label = "Depth Tolerance", type = "number", default = 4.0, min = 0.5, max = 32.0, step = 0.1, order = 6.2,
        description = "Hit acceptance tolerance in TRACE TEXELS rather than metres. One texel is the smallest depth difference the trace can resolve at a given distance, so this is self-scaling: tight near the camera where creases matter, automatically wider at range. Raising it should now trade thin-surface accuracy for tolerance to depth error -- if raising it instead REVEALS more reflection, that is a traversal localisation failure rather than a tolerance problem, and worth reporting." },
    normalBias = { label = "Normal Bias", type = "number", default = 0.0, min = 0.0, max = 1.0, step = 0.001 },
    rayStartOffset = { label = "Ray Start Offset", type = "number", default = 0.0, min = 0.0, max = 2.0, step = 0.005 },

    roughnessStart = { label = "Roughness Start", type = "number", default = 0.12, min = 0.0, max = 1.0, step = 0.01 },
    roughnessEnd = { label = "Roughness End", type = "number", default = 0.78, min = 0.0, max = 1.0, step = 0.01 },
    roughnessPower = { label = "Roughness Power", type = "number", default = 1.0, min = 0.25, max = 6.0, step = 0.05 },
    fresnelPower = { label = "Fresnel Power", type = "number", default = 6.0, min = 0.25, max = 12.0, step = 0.05 },
    fresnelStrength = { label = "Fresnel Strength", type = "number", default = 0.65, min = 0.0, max = 1.0, step = 0.01 },
    pixelRebuild = { label = "Per-Pixel Reflection Rebuild", type = "bool", default = true },
    traceFootprintAA = { label = "Sparse Edge Recovery", type = "bool", default = true,
        description = "Reduces glossy reflection holes caused by sparse trace misses. Native history uses a guarded seed search and its own visibility test. With native history off, missing glossy hits get conservative within-pixel trace samples at half resolution and below." },
    hdrComposite = { label = "HDR Composite", type = "bool", default = true },
    surfaceDetail = { label = "Surface Detail Under Reflections", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.05 },
    faceOnReflectance = { label = "Face-On Reflectance", type = "number", default = 0.35, min = 0.0, max = 1.0, step = 0.01 },
    facingFade = { label = "Facing Fade", type = "number", default = 0.15, min = 0.001, max = 1.0, step = 0.01 },
    highRoughnessSuppression = { label = "High Rough Suppression", type = "number", default = 0.45, min = 0.0, max = 1.0, step = 0.01 },

    edgeFadePixels = { label = "Screen Edge Fade", type = "number", default = 1.0, min = 0.0, max = 512.0, step = 1.0,
        description = "Soft fade at the screen border. 0 disables it." },
    reflectionEdgeFade = { label = "Reflection Edge Fade", type = "number", default = 0.4, min = 0.0, max = 1.0, step = 0.01,
        description = "Softens the edges of a reflection where neighbouring pixels have none. 0 = hard edges." },
    skyFadeStart = { label = "Sky Fade Start", type = "number", default = 0.985, min = 0.8, max = 1.0, step = 0.001 },
    skyFadeEnd = { label = "Sky Fade End", type = "number", default = 0.999, min = 0.8, max = 1.0, step = 0.001 },
    distanceFadeStart = { label = "Distance Fade Start", type = "number", default = 1.0, min = 1.0, max = 1000.0, step = 1.0 },
    distanceFadeEnd = { label = "Distance Fade End", type = "number", default = 1100.0, min = 1.0, max = 1500.0, step = 1.0 },

    backfaceFade = { label = "Backface Fade", type = "number", default = 0.35, min = 0.001, max = 1.0, step = 0.01 },
    screenJitter = { label = "Screen Jitter", type = "number", default = 0, min = 0.0, max = 1.0, step = 0.01 },
    jitterTemporalRate = { label = "Jitter Temporal Rate", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01, description = "How fast the ray/jitter phase drifts over time so the temporal denoiser gets new samples to average. 0 = auto (100% when stochastic rays are off, since it otherwise has nothing to accumulate); set a value to override." },

    temporalStrength = { label = "Temporal Accumulation", type = "number", default = 0.96, min = 0.0, max = 0.98, step = 0.01,
        description = "Weight of accumulated history. 0 = no accumulation." },
    traceSubpixelJitter = { label = "Sub-Pixel Trace Jitter", type = "bool", default = true,
        description = "Offsets the trace by a different sub-pixel position each frame, and history combines them into native-resolution detail. Requires Temporal Denoising and Native-Resolution History. Results depend on frame rate." },
    historyGeometry = { label = "History Geometry Validation", type = "bool", default = true,
        description = "Native history always rejects incompatible receivers. This developer fallback switch controls separate geometry validation in the legacy route without engine motion vectors." },
    singleRaySpecialization = { label = "One-Ray Optimization", type = "bool", default = true,
        description = "Uses a compiled one-ray shader when one ray and no trace debug view are selected. Same sampling and trace quality; independent performance comparison switch." },
    geometryReconstruction = { label = "Surface-Aware Reconstruction", type = "bool", default = true,
        description = "Rejects low-resolution samples belonging to sky or another surface before native temporal reconstruction. Uses existing depth/normal buffers; adds texture reads. Off restores bilinear reconstruction for comparison." },
    adaptiveDenoising = { label = "Adaptive Denoising", type = "bool", default = true,
        description = "Reduces native temporal work where mature history agrees with a validated measurement. Glossy clipping uses five taps; rough lobes retain nine. Keeps receiver validation, native history, rebuild and the same ray count. Off uses the full native neighbourhood for comparison." },
    virtualReprojection = { label = "Reflection Motion Reprojection", type = "bool", default = true,
        description = "Moves glossy reflection history like a mirror image at the reflected distance, instead of with the surface. Keeps glass, paint and wet roads sharp in motion. When off, history moves with the surface." },
    virtualRoughStart = { label = "Reflection Reprojection Rough Start", type = "number", default = 0.15, min = 0.0, max = 1.0, step = 0.01,
        description = "Receiver roughness where reflection-motion reprojection starts handing over to surface motion. Below this the reflection is reprojected through its virtual image only." },
    virtualRoughEnd = { label = "Reflection Reprojection Rough End", type = "number", default = 0.40, min = 0.0, max = 1.0, step = 0.01,
        description = "Receiver roughness above which history follows the surface only. Rough reflections are blurred enough that the surface's own motion is the better guess." },
    virtualMotionScale = { label = "Reflection Motion Rejection", type = "number", default = 0.20, min = 0.0, max = 1.0, step = 0.01,
        description = "Share of Motion Rejection applied to the reflection's own translation once it is reprojected correctly. Lower keeps more history in motion; the neighbourhood clip still bounds it. 1 = as much rejection as surface reprojection." },
    virtualParallaxScale = { label = "Reflection Translation Scale", type = "number", default = 0.30, min = 0.0, max = 1.5, step = 0.01,
        description = "Scales reflection-specific parallax relative to surface motion. Lower values reduce leading trails during translation. 1 matches a flat mirror; 0 follows the surface. Camera rotation is unchanged." },
    nativeTemporal = { label = "Native-Resolution History", type = "bool", default = true,
        description = "Keeps detailed reflection history independently of Render Resolution. Interleaved Native History stores alternate native pixels and reconstructs the gaps; turn interleaving off for the complete native buffer. When this is off, history follows Render Resolution." },
    interleavedHistory = { label = "Interleaved Native History", type = "bool", default = true,
        description = "Stores alternating native pixels on each row, with full colour and geometry precision. Reconstructs missing pixels on the receiver surface and recovers glossy normal detail where needed. Halves current/history storage and temporal pixel count. Requires Native-Resolution History. Off restores the complete native buffer for comparison." },
    temporalClamp = { label = "Temporal Clamp", type = "number", default = 0.90, min = 0.0, max = 1.0, step = 0.01,
        description = "Margin around the current frame's colour range used to clamp history. Higher values keep more history and allow more ghosting." },
    temporalMotionRejection = { label = "Translation Rejection", type = "number", default = 0.80, min = 0.0, max = 1.0, step = 0.01,
        description = "Rejects history in proportion to screen motion from camera movement and moving objects, where reflections can ghost. Higher values react faster and ghost less." },
    temporalMotionRejectionRot = { label = "Rotation Rejection", type = "number", default = 0.80, min = 0.0, max = 1.0, step = 0.01,
        description = "Rejects history in proportion to screen motion from camera rotation. Rotation causes no disocclusion, so 0 keeps full accumulation while looking around. At 0, camera jitter from BeamRT TAA also adds reflection detail." },

    fireflySuppression = { label = "Firefly Suppression", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01,
        description = "Clamps isolated bright pixels relative to neighbouring samples. Other highlights are not affected." },
    stochasticSSR = { label = "Stochastic GGX Rays", type = "bool", default = true,
        description = "Spreads reflection rays around the mirror direction according to surface roughness (GGX sampling), instead of tracing a single mirror ray. Rough surfaces get correctly blurred reflections." },
    stochasticResolution = { label = "Stochastic Resolution Multiplier", type = "number", default = 1.0, min = 0.5, max = 1.0, step = 0.05,
        description = "Multiplies Render Resolution while Stochastic GGX Rays is on. 0.7 traces about half as many pixels. History and the scene stay at full resolution. Lower values lose thin detail." },
    stochasticReuse = { label = "Stochastic Spatial Reuse", type = "number", default = 0.65, min = 0.0, max = 1.0, step = 0.05,
        description = "Shares samples between four neighbouring trace pixels, with depth and normal checks, before temporal accumulation. Reduces sparkle at the cost of some sharpness. Requires Temporal Denoising. 0 = off." },
    overhangFill = { label = "Overhang Fill", type = "bool", default = false,
        description = "Uses a dark fill when a missed upward ray passes under an overhang, such as a roof above an upward-facing surface. Vertical walls are excluded. Traced hits take priority." },
    overhangBrightness = { label = "Overhang Brightness", type = "number", default = 0.01, min = 0.0, max = 1.0, step = 0.01,
        description = "Neutral floor for the underside colour in the reflection buffer. 0 is black. Material reflection strength still controls its contribution." },
    overhangBounce = { label = "Underside Bounce", type = "number", default = 0.6, min = 0.0, max = 2.0, step = 0.05,
        description = "Colour of an overhang's underside, estimated as light bounced up from the surface below. 0 = a fixed dark colour." },
    stochasticBias = { label = "Stochastic Mirror Bias", type = "number", default = 0.90, min = 0.0, max = 1.0, step = 0.01,
        description = "Narrows ray sampling toward the mirror direction. Higher values are more stable but blur rough reflections less." },
    stochasticTemporalRate = { label = "Stochastic Animation", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01,
        description = "Advances the low-discrepancy ray sequence over time. Use temporal accumulation when above zero." },
    stochasticRayCount = { label = "Stochastic Ray Count", type = "number", default = 1.0, min = 1.0, max = 16.0, step = 1.0,
        description = "Rays traced per pixel each frame with Stochastic GGX Rays on. Higher values reduce noise at nearly proportional cost." },
    filteredColor = { label = "Prefiltered Scene Color", type = "bool", default = true,
        description = "Blurs what rough surfaces reflect, using a small colour pyramid." },
    colorMipScale = { label = "Reflection Cone Scale", type = "number", default = 0.35, min = 0.01, max = 4.0, step = 0.01,
        description = "Controls how quickly rough, distant hits select blurrier scene-color levels." },

    wetness = { label = "Reflectiveness Override", type = "number", default = 0.0, min = 0.0, max = 1.0, step = 0.01 },
    wetUpDotStart = { label = "Wet Up Dot Start", type = "number", default = 0.65, min = -1.0, max = 1.0, step = 0.01 },
    wetUpDotEnd = { label = "Wet Up Dot End", type = "number", default = 0.92, min = -1.0, max = 1.0, step = 0.01 },
    wetRoughnessEnd = { label = "Wet Roughness End", type = "number", default = 0.95, min = 0.0, max = 1.0, step = 0.01 },

    waterSSR = { label = "Water SSR", type = "bool", default = true, order = 100,
        description = "Detects water surfaces and gives them their own reflection response." },
    waterShaderData = { label = "Water Depth Prepass", type = "bool", default = true, order = 100.5,
        description = "Writes water surface depth into SSR's own depth buffer before tracing: water planes analytically, water blocks and rivers from a height map baked once per level. BeamNG's water shader is not modified." },
    waterAutoDetect = { label = "Auto Water Volumes", type = "bool", default = true, order = 101,
        description = "Finds water planes, water blocks and rivers once per level and bakes blocks and rivers into one height map. No per-frame cost." },
    waterRivers = { label = "Use Rivers", type = "bool", default = true, order = 103,
        description = "Builds a surface map from the level's river objects once per level." },
    waterRiverBakeResolution = { label = "River Mask Resolution", type = "number", default = 1024.0, min = 256.0, max = 2048.0, step = 256.0, order = 103.1,
        description = "Resolution of the baked river height map. 1024 suits most levels; 2048 sharpens narrow rivers on large levels." },
    waterRiverEdgePadding = { label = "River Edge Padding", type = "number", default = 0.0, min = 0.0, max = 4.0, step = 0.05, order = 103.2,
        description = "Expands baked rivers outward, in metres. Leave at 0 for exact edges; raise it slightly if the shoreline loses pixels." },
    waterRiverFlipY = { label = "River Map Flip Y", type = "bool", default = false, order = 103.3,
        description = "Flips the river map vertically. Use it only if river reflections appear mirrored." },
    waterSSRStrength = { label = "Water Reflection Strength", type = "number", default = 1.35, min = 0.0, max = 2.0, step = 0.01, order = 110,
        description = "Scales water reflectance, which follows the Fresnel equation for water: 2% looking straight down, 6% at 60 degrees, 21% at 75 degrees, full at the horizon." },
    waterColorStrength = { label = "Added Water Tint", type = "number", default = 0.0, min = 0.0, max = 1.0, step = 0.01, order = 108,
        description = "Optional artificial blue-green grade, not the map's water color. Zero preserves the stock rendered water beneath reflections." },
    waterWaveStrength = { label = "Wave Normal Strength", type = "number", default = 0.11, min = 0.0, max = 4.0, step = 0.01, order = 107.2,
        description = "How much the reconstructed wave normal tilts the water surface." },
    waterWaveScale = { label = "Wave Normal Scale", type = "number", default = 0.58, min = 0.1, max = 4.0, step = 0.01, order = 107.3,
        description = "Size of the reconstructed waves. Higher values give smaller waves." },
    waterWaveDistanceFade = { label = "Wave Distance Fade", type = "number", default = 140.0, min = 5.0, max = 1000.0, step = 1.0, order = 107.4,
        description = "Distance in metres over which waves fade to a flat surface." },
    waterSSRRoughness = { label = "Water Roughness", type = "number", default = 0.025, min = 0.004, max = 0.45, step = 0.001, order = 111,
        description = "Roughness used for water reflections. Lower values are sharper." },
    waterSSRFlatNormal = { label = "Water Flat Normal Mix", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01, order = 112,
        description = "1 uses an upward water normal; 0 uses the prepass normal behind the water." },
    waterAngleMin = { label = "Water Face-On Reflection", type = "number", default = 0.24, min = 0.0, max = 1.0, step = 0.01, order = 113,
        description = "Minimum water reflection when looking almost straight down into the water." },
    waterAngleStart = { label = "Water Angle Ramp Start", type = "number", default = 0.12, min = 0.0, max = 1.0, step = 0.01, order = 114,
        description = "Where the grazing-angle reflection ramp starts. Lower starts reflecting sooner." },
    waterAngleEnd = { label = "Water Angle Ramp End", type = "number", default = 0.82, min = 0.0, max = 1.0, step = 0.01, order = 115,
        description = "Where water reaches full reflection at shallow/oblique viewing angles." },
    waterAnglePower = { label = "Water Angle Ramp Power", type = "number", default = 8.0, min = 0.25, max = 8.0, step = 0.05, order = 116,
        description = "Shapes the water angle ramp. Higher keeps face-on water clearer for longer." },
    waterPlaneFadeMeters = { label = "Water Plane Fade", type = "number", default = 0.0, min = 0.0, max = 10.0, step = 0.01, order = 124,
        description = "Depth below the water surface at which the water mask reaches full strength." },
    waterSurfaceDepthBias = { label = "Water Surface Depth Bias", type = "number", default = 0.0, min = -2.0, max = 2.0, step = 0.01, order = 127,
        description = "Offsets the water surface along the eye ray before tracing. Leave at 0 unless self-intersection appears." },
    waterFarTraceDistance = { label = "Water Trace Distance", type = "number", default = 1250.0, min = 25.0, max = 2000.0, step = 5.0, order = 130,
        description = "Long-range water trace using coarse steps plus binary refinement." },

    puddleStrength = { label = "Puddles", type = "number", default = 0.0, min = 0.0, max = 1.0, step = 0.01, order = 140,
        description = "Amount of procedural puddles on upward-facing surfaces. 0 = off." },
    puddleScale = { label = "Puddle Scale", type = "number", default = 0.4, min = 0.2, max = 0.8, step = 0.005, order = 141,
        description = "Size of puddle areas. Lower values give larger, sparser puddles. Ctrl-click the slider to enter a value outside its range." },
    puddleEdgeLo = { label = "Puddle Coverage Low", type = "number", default = 0.45, min = 0.0, max = 1.0, step = 0.01, order = 142,
        description = "Lower noise threshold for puddles. Lower values give more coverage." },
    puddleEdgeHi = { label = "Puddle Coverage High", type = "number", default = 0.62, min = 0.0, max = 1.0, step = 0.01, order = 143,
        description = "Upper noise threshold for puddles. A smaller gap to Puddle Coverage Low gives harder edges." },
    puddleUpDotStart = { label = "Puddle Up Start", type = "number", default = 0.55, min = 0.0, max = 1.0, step = 0.01, order = 144,
        description = "Surface slope (normal Z) at which puddles begin. Kept low so bumpy flat ground stays covered; raise it to exclude gentle slopes." },
    puddleUpDotEnd = { label = "Puddle Up End", type = "number", default = 0.82, min = 0.0, max = 1.0, step = 0.01, order = 145,
        description = "Surface slope (normal Z) at which puddles reach full strength." },
    puddleRoughness = { label = "Puddle Roughness", type = "number", default = 0.02, min = 0.004, max = 0.2, step = 0.001, order = 146,
        description = "Surface roughness inside puddles. Lower values give sharper reflections." },
    puddleRippleScale = { label = "Puddle Ripple Scale", type = "number", default = 1.3, min = 0.05, max = 4.0, step = 0.01, order = 147,
        description = "Size of the animated ripples. Higher values give smaller ripples." },
    puddleRippleSpeed = { label = "Puddle Ripple Speed", type = "number", default = 0.015, min = 0.0, max = 0.2, step = 0.001, order = 148,
        description = "Speed of the ripple animation. 0 = still water." },
    puddleRippleStrength = { label = "Puddle Ripple Strength", type = "number", default = 0.010, min = 0.0, max = 1.0, step = 0.01, order = 149,
        description = "How much the ripples tilt the puddle surface." },
    puddleDarken = { label = "Puddle Darkening", type = "number", default = 0.38, min = 0.0, max = 1.0, step = 0.01, order = 150,
        description = "Maximum darkening of wet ground. Falls to 15% of this value where a puddle shows little reflection." },
    puddleFadeStart = { label = "Puddle Fade Start", type = "number", default = 40.0, min = 1.0, max = 500.0, step = 1.0, order = 150.5,
        description = "Distance from the camera, in metres, at which puddles begin to fade out." },
    puddleFadeEnd = { label = "Puddle Fade End", type = "number", default = 90.0, min = 1.0, max = 1000.0, step = 1.0, order = 150.6,
        description = "Distance from the camera, in metres, at which puddles have faded out completely." },

    skyReflection = { label = "Sky Reflection", type = "bool", default = true, order = 36.9,
        description = "Reflects the sky where rays find no hit, on land and water. When off, only traced reflections are shown." },
    waterSkyFallback = { label = "Sky Fill (Water)", type = "number", default = 0.20, min = 0.0, max = 1.0, step = 0.01, order = 37.05,
        description = "Sky reflection on water where rays find no hit. Water needs more than land to keep its surface visible over the bed; around 0.20 usually looks right." },
    skyReflectionFallback = { label = "Reflection Sky Fallback", type = "number", default = 0.5, min = 0.0, max = 1.0, step = 0.01, order = 37,
        description = "Sky reflection on ordinary surfaces where rays find no hit. Values around 0.05-0.10 usually look right." },
    skyReflectionBrightness = { label = "Sky Reflection Brightness", type = "number", default = 1.0, min = 0.0, max = 6.0, step = 0.05, order = 37.2,
        description = "Brightness of the sky ambient fallback, used where the sky is not visible on screen, in shadow." },
    puddleReflectivity = { label = "Puddle Reflectivity", type = "number", default = 0.8, min = 0.0, max = 1.0, step = 0.01, order = 139.5,
        description = "Overall puddle reflection strength, before the angle falloff." },
    puddleFresnel = { label = "Puddle Angle Falloff", type = "number", default = 0.75, min = 0.0, max = 1.0, step = 0.01, order = 139.55,
        description = "How much puddle reflections strengthen toward grazing angles. Some reflection always remains when looking straight down." },
    puddleEnvironmentStrength = { label = "Puddle Environment", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01, order = 139.57,
        description = "Sky reflection on puddles where rays find no hit. 1 keeps puddles glossy when seen from above; 0 = traced reflections only." },
    puddleEdgeSoftness = { label = "Puddle Edge Softness", type = "number", default = 0.35, min = 0.02, max = 1.0, step = 0.01, order = 139.6,
        description = "Share of each puddle that forms a soft edge. Low values give solid water with a thin rim; 1 fades the whole puddle gradually." },
    terrainMaskEnable = { label = "Terrain Material Mask", type = "bool", default = false, order = 139.7,
        description = "Limits puddles to terrain materials that hold water, such as asphalt, concrete and mud, using the level's terrain material map. The map is looked up by position, so it also applies to objects standing on that terrain." },
    terrainMaskStrength = { label = "Terrain Mask Strength", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01, order = 139.8,
        description = "How strictly the terrain material map limits puddles. 1 = fully, 0 = ignored." },
    terrainFlipY = { label = "Terrain Map Flip Y", type = "bool", default = false, order = 139.85,
        description = "Flips the terrain map vertically. Use it if puddles appear mirrored relative to the roads." },
    terrainGridSize = { label = "Terrain Grid Size", type = "number", default = 4096.0, min = 128.0, max = 8192.0, step = 1.0, order = 139.9,
        description = "Fallback terrain size, used when Terrain Runtime Bake is off and the level's size is unavailable." },
    terrainRuntimeBake = { label = "Terrain Runtime Bake", type = "bool", default = true, order = 139.95,
        description = "Reads the level's terrain file at load and builds the puddle map automatically. When off, only pre-baked maps are used." },

    engineVelocity = { label = "Motion Vectors", type = "bool", default = true, order = 22.7,
        description = "History follows BeamNG's motion vectors, so other vehicles and their deformation are tracked. Off treats the scene as static and follows only the camera. Leave on unless the Velocity probe debug view stays black while the camera moves." },
    playerVehicleMotion = { label = "Player Vehicle Motion", type = "bool", default = true, order = 22.71,
        description = "History on and around your vehicle follows its body, and history the vehicle has just uncovered is discarded. Prevents ghosting on and around the car. Leave on." },
    fillEngineVelocityHole = { label = "Fill Engine Velocity Hole", type = "bool", default = true, order = 22.72,
        description = "BeamNG leaves the player vehicle out of its velocity buffer unless 'Motion blur on player vehicle' is set. While motion blur is off, this sets that engine flag (no blur appears) and restores your setting afterwards." },
    vehicleDisocclusion = { label = "Vehicle Disocclusion", type = "bool", default = true, order = 22.73,
        description = "Rejects history the player vehicle covered last frame and has now uncovered, so the scene behind a moving car does not inherit its reflection." },
    skyBeforeTemporal = { label = "Accumulate Sky With SSR", type = "bool", default = true, order = 37.1,
        description = "Fills the environment reflection into the trace so it accumulates with the SSR hits, instead of only at composite time. ON (default) is strongly preferred: the raw SSR alpha is sparse and noisy, so letting history integrate an already-filled signal removes most of the variance the accumulator would otherwise have to absorb -- and below native render scale it keeps the fill on the same grid as the hits, which is what stops reflection edges banding when the camera is at rest. Turn off only to see the raw screen-space coverage." },
    skyScreenSpace = { label = "Screen-Space Sky", type = "bool", default = true, order = 37.3,
        description = "Uses the rendered sky and distant scenery in the reflected direction where it is on screen, instead of the sky ambient. Shows clouds, horizon and sun glow at their on-screen brightness. Directions off screen fall back to the sky ambient." },
    skyScreenBrightness = { label = "Screen Sky Brightness", type = "number", default = 0.5, min = 0.0, max = 2.0, step = 0.05, order = 37.31,
        description = "Brightness of the on-screen sky used for reflections, in shadow. Sun-Lit Boost is added in sunlight." },
    skyScreenMinDistance = { label = "Screen Sky Min Distance", type = "number", default = 400.0, min = 50.0, max = 5000.0, step = 10.0, order = 37.32,
        description = "Scenery at the projected direction nearer than this (metres) is not used as environment; beyond it, fades in. Sky always counts." },
    skyDirectionality = { label = "Sky Directionality", type = "number", default = 0.5, min = 0.0, max = 1.0, step = 0.01, order = 37.33,
        description = "How much brighter the sky ambient fallback is toward the sun. 0 = the average sky in every direction." },
    skySunBoost = { label = "Sun-Lit Boost", type = "number", default = 1.0, min = 0.0, max = 4.0, step = 0.05, order = 37.4,
        description = "Brightens sky reflections on sunlit surfaces by up to this factor; the sky brightness settings apply in shadow. 1 = twice as bright. Sunlight is read from BeamNG's sun shadow mask." },
    engineAOOcclusion = { label = "Engine AO Occlusion", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01, order = 37.43,
        description = "Darkens the sky reflection fill with BeamNG's ambient occlusion, so creases, wheel arches and the ground under cars do not reflect open sky. Traced reflections are not affected. Requires the game's Ambient Occlusion setting. 0 = off." },
    engineAOOpenLevel = { label = "Engine AO Open Level", type = "number", default = 0.88, min = 0.5, max = 1.0, step = 0.01, order = 37.44,
        description = "BeamNG's AO value on open, unoccluded ground; AO is divided by it so only real occlusion dims the sky fill. Check with debug view 48: open road should read near white. Raise if open ground still loses fill; lower if creases are not occluded enough." },
    engineSunShadow = { label = "Engine Sun Shadow", type = "bool", default = true, order = 37.47,
        description = "Takes sunlight for Sun-Lit Boost and Sun Colour Tint from BeamNG's sun shadow mask and contact shadows, with the sun's presence and colour from the engine's sun radiance. Off = the previous #lightinfo estimate, which also counted headlights and lamps as sun, darkened surfaces facing away from the sun, and gave no sun colour (0.39 hands post effects a constant white). Needs shadows on." },
    skyLightExposure = { label = "Sun Exposure Influence", type = "number", default = 0.5, min = 0.0, max = 1.0, step = 0.01, order = 37.4,
        description = "Not used." },
    adaptiveResolution = { label = "Adaptive Resolution", type = "bool", default = false, order = 21.5,
        description = "Traces rough surfaces at Rough Resolution in a second, cheaper pass and keeps Render Resolution for glossy surfaces such as water, glass and wet roads. Rough reflections are blurred, so the lower resolution does not show there. Requires Temporal Denoising and Native-Resolution History. Cost then depends on how much of the view is glossy." },
    roughResolution = { label = "Rough Resolution", type = "number", default = 0.2, min = 0.1, max = 1.0, step = 0.05, order = 21.6,
        description = "Trace resolution for rough surfaces with Adaptive Resolution on, as a fraction of the screen. Used only when lower than Render Resolution." },
    adaptiveRoughStart = { label = "Adaptive Rough Start", type = "number", default = 0.15, min = 0.0, max = 1.0, step = 0.01, order = 21.7,
        description = "Effective roughness where receivers start using the Rough Trace. Between Start and End both traces run and are blended." },
    adaptiveRoughEnd = { label = "Adaptive Rough End", type = "number", default = 0.35, min = 0.0, max = 1.0, step = 0.01, order = 21.8,
        description = "Effective roughness beyond which only the Rough Trace runs." },
    roughnessAdaptiveDenoise = { label = "Roughness-Adaptive Denoising", type = "number", default = 0.5, min = 0.0, max = 1.0, step = 0.05, order = 22.8,
        description = "Keeps more history on rough surfaces, where lag is hard to see but noise is not, and less on glossy ones, where ghosting shows. 0 = the same history settings everywhere." },
    screenMappingFromEngine = { label = "Menu Frustum Correction", type = "bool", default = true, order = 22.9,
        description = "Measure the projection centre from the engine's own view rays. BeamNG shifts the frustum while side menus are open, which offset reflections from the scene. Off restores the Lua-only projection for comparison." },
    skyLightTint = { label = "Sun Colour Tint", type = "number", default = 0.0, min = 0.0, max = 1.0, step = 0.01, order = 37.45,
        description = "Shifts the sky reflection's hue toward the sun's colour, so reflections warm up at sunset. Brightness is unchanged, and shadowed surfaces are not tinted. 0 = sky colour only." },
    lightExposureScale = { label = "Sun Exposure Response", type = "number", default = 2.0, min = 0.1, max = 12.0, step = 0.1, order = 37.46,
        description = "Maps sun brightness to the 0-1 sunlight value used by Sun-Lit Boost. Raise it if dim daylight reads as shadow; lower it if everything reads as fully lit. The Sun exposure debug view shows the result." },
    skySaturation = { label = "Sky Reflection Saturation", type = "number", default = 1.0, min = 0.0, max = 2.0, step = 0.01, order = 37.35,
        description = "Saturation of the sky reflection. 1 = BeamNG's own sky colour." },

    waterNoiseRipple = { label = "Water Detail Ripple", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 0.01, order = 151,
        description = "Fine ripples on water. 0 = off." },
    waterNoiseRippleScale = { label = "Water Detail Ripple Scale", type = "number", default = 1.0, min = 0.1, max = 4.0, step = 0.01, order = 152,
        description = "Size of the detail ripples. Higher values give smaller ripples." },

    resolveMode = { label = "Resolve Mode", type = "number", default = 1.0, min = 0.0, max = 1.0, step = 1.0, description = "0 = raw SSR, 1 = depth/normal-aware spatial resolve." },
    resolveRadius = { label = "Resolve Radius", type = "number", default = 0.5, min = 0.5, max = 6.0, step = 0.1 },
    resolveDepthSigma = { label = "Resolve Depth Sigma", type = "number", default = 0.6, min = 0.01, max = 5.0, step = 0.01 },
    resolveNormalPower = { label = "Resolve Normal Power", type = "number", default = 24.0, min = 0.0, max = 128.0, step = 1.0 },

    renderScale = { label = "Render Resolution", type = "number", default = 0.5, min = 0.1, max = 1.0, step = 0.05,
        description = "Resolution of the ray trace. History and compositing stay at native resolution." },
    skyModelVersion = { label = "Sky Model Version", type = "number", default = 0.0, min = 0.0, max = 16.0, step = 1.0, hidden = true },

    debugView = { label = "Debug View", type = "number", default = 0.0, min = 0.0, max = 53.0, step = 1.0,
        description = "20 raw, 21 history, 22 temporal delta, 23 temporal state, 27 merged water, 28 combined depth, 29 coarse Hi-Z, 30 merge diagnostic, 31 traversal iteration heat (red = the real iteration cap), 32 traversal exits (green hit / red left screen / magenta reached max distance / blue iteration cap / yellow rejected / black no ray), 33 packed pyramid, 35 Hi-Z cell footprints (checker colour = cell, brightness = its min depth), 34 sun exposure as stored (white = lit, black = shadowed; uniform white means #lightinfo is unbound), 40 ambientSH9 binding probe (left half = raw DC coefficient, right half = evaluated environment; a black LEFT half means the uniform is not auto-bound on this backend), 41 raw #lightinfo probe, 42 #VelocityBuffer probe (amplified 50x; black while panning with motion blur off means the buffer is not produced in that configuration), 43 traversal profile (red = iterations at fine pyramid levels, green = mid, blue = coarse; a mostly-red frame means the hierarchy is not being used). View 7 (trace-skip pattern) was removed with the pattern itself." }
}

EffectModule.retiredValues = {
    maxDistance = 100000.0, waterFarTraceDistance = 100000.0,
    distanceFadeStart = 100000.0, distanceFadeEnd = 100001.0,
    thicknessTexels = 4.0,
    hiZMaxLevel = 4.0, normalBias = 0.0, rayStartOffset = 0.0,
    roughnessPower = 1.0, highRoughnessSuppression = 0.0, fresnelPower = 5.0,
    facingFade = 0.10, backfaceFade = 0.35,
    wetUpDotStart = 0.65, wetUpDotEnd = 0.92, wetRoughnessEnd = 0.95,
    edgeFadePixels = 0.0, skyFadeStart = 0.985, skyFadeEnd = 0.999,
    adaptiveRoughStart = 0.15, adaptiveRoughEnd = 0.35,
    singleRaySpecialization = true, geometryReconstruction = true, adaptiveDenoising = true,
    historyGeometry = true, screenMappingFromEngine = true,
    stochasticTemporalRate = 1.0, colorMipScale = 0.35,
    virtualRoughStart = 0.15, virtualRoughEnd = 0.40, virtualMotionScale = 0.20,
    fillEngineVelocityHole = true, vehicleDisocclusion = true,
    jitterTemporalRate = 0.0, screenJitter = 0.0,
    resolveMode = 1.0, resolveRadius = 0.5, resolveDepthSigma = 0.6, resolveNormalPower = 24.0,
    engineAOOpenLevel = 0.88, engineSunShadow = true, skyBeforeTemporal = true,
    skyScreenMinDistance = 400.0, overhangBrightness = 0.01,
    waterSSRFlatNormal = 1.0, waterSurfaceDepthBias = 0.0,
    waterAngleMin = 0.0, waterAngleStart = 0.0, waterAngleEnd = 1.0, waterAnglePower = 1.0,
}
EffectModule.retiredDerived = { roughnessStart = true, fresnelStrength = true }

local qualityPresets = {
    [1] = { renderScale = 0.25, traceQuality = 0.5, overhangFill = false },
    [2] = { renderScale = 0.5, traceQuality = 0.5, overhangFill = false },
    [3] = { renderScale = 0.5, traceQuality = 0.75, overhangFill = true },
    [4] = { renderScale = 0.8, traceQuality = 0.75, overhangFill = true }
}

EffectModule.qualityPresets = qualityPresets

local function applyQualityPresetValues(self, presetId)
    presetId = math.floor((tonumber(presetId) or 0) + 0.5)
    local preset = qualityPresets[presetId]
    if not preset then return false end

    self.values = self.values or {}
    for id, v in pairs(preset) do
        if EffectModule.parameters[id] ~= nil then
            self.values[id] = v
        end
    end
    self.values.qualityPreset = presetId
    return true
end

local function polishParameterMetadata()
    local P = EffectModule.parameters

    local LAYOUT = {
        { tab = "Reflection",
          user = { "amount", "intensity", "hdrComposite", "surfaceDetail", "faceOnReflectance", "roughnessEnd", "wetness", "fogTransport",
              "reflectionEdgeFade" },
          developer = { } },
        { tab = "Quality",
          user = { "qualityPreset", "traceQuality", "renderScale", "pixelRebuild", "traceFootprintAA", "adaptiveResolution", "roughResolution" },
          developer = { } },
        { tab = "Stochastic SSR",
          user = { "stochasticSSR", "stochasticRayCount", "stochasticResolution", "stochasticReuse",
              "stochasticBias", "filteredColor" },
          developer = { } },
        { tab = "Denoising",
          user = { "temporalStrength", "temporalClamp", "temporalMotionRejection", "temporalMotionRejectionRot",
              "virtualReprojection", "roughnessAdaptiveDenoise", "fireflySuppression", "nativeTemporal", "interleavedHistory", "traceSubpixelJitter" },
          developer = { "engineVelocity", "playerVehicleMotion", "virtualParallaxScale" } },
        { tab = "Sky Reflection",
          user = { "skyReflection", "skyReflectionFallback", "waterSkyFallback", "skyScreenSpace",
              "skyScreenBrightness", "skyReflectionBrightness", "skyDirectionality", "skySunBoost", "skySaturation",
              "skyLightTint", "engineAOOcclusion", "overhangFill", "overhangBounce" },
          developer = { "lightExposureScale" } },
        { tab = "Water",
          user = { "waterSSR", "waterSSRStrength", "waterColorStrength", "waterNoiseRipple", "waterNoiseRippleScale",
              "waterRivers" },
          developer = { "waterShaderData", "waterAutoDetect", "waterRiverBakeResolution", "waterRiverEdgePadding",
              "waterRiverFlipY", "waterSSRRoughness", "waterWaveStrength", "waterWaveScale", "waterWaveDistanceFade",
              "waterPlaneFadeMeters" } },
        { tab = "Puddles",
          user = { "puddleStrength", "puddleScale", "puddleReflectivity", "puddleFresnel", "puddleEnvironmentStrength",
              "puddleRoughness", "puddleRippleStrength", "puddleRippleScale", "puddleRippleSpeed", "puddleDarken",
              "puddleEdgeSoftness", "terrainMaskEnable", "terrainMaskStrength" },
          developer = { "puddleEdgeLo", "puddleEdgeHi", "puddleUpDotStart", "puddleUpDotEnd", "puddleFadeStart",
              "puddleFadeEnd", "terrainFlipY", "terrainGridSize", "terrainRuntimeBake" } },
    }
    EffectModule.settingsLayout = LAYOUT

    for _, parameter in pairs(P) do
        parameter.advanced = true
        parameter.hidden = false
        parameter.group = nil
    end
    for _, id in ipairs({ "skyLightExposure", "skyModelVersion" }) do
        if P[id] then P[id].visible = false end
    end
    local order = 10
    for _, tab in ipairs(LAYOUT) do
        for _, kind in ipairs({ "user", "developer" }) do
            for _, id in ipairs(tab[kind]) do
                local parameter = P[id]
                if parameter then
                    parameter.group = tab.tab
                    parameter.advanced = kind == "developer"
                    parameter.order = order
                    order = order + 1
                end
            end
        end
    end

    local TEXT = {
        amount = { "Reflection Mix", "Overall blend of the reflection over the scene." },
        intensity = { "Reflection Brightness", "Brightness of everything the reflection adds, including traced hits and sky fill." },
        wetness = { "Reflectiveness Override", "Makes upward-facing surfaces reflective regardless of their roughness, as if wet." },
        fogTransport = { "Fog Occlusion", "Lets BeamNG's height fog cover reflections, instead of drawing reflections over the fog." },
        reflectionEdgeFade = { "Reflection Edge Fade", "Softens the edges of a reflection where neighbouring pixels have none. 0 = hard edges." },
        qualityPreset = { "Trace Quality Preset", "Sets Ray Reach. Render Resolution is set separately." },
        renderScale = { "Render Resolution", "Resolution of the ray trace. History and compositing stay at native resolution." },
        traceQuality = { "Ray Reach", "Maximum steps per ray, from 24 at 0% to 128 at 100%. Nearby reflections are always traced at full detail; this sets how far a ray can search and is the main trace cost. Rays continue to the screen edge; there is no distance limit." },
        hdrComposite = { "HDR Composite", "Applies reflections to the HDR scene, after water, particles and clouds and before BeamNG's exposure, bloom and tonemapping. Reflected highlights keep their full brightness, and reflections do not pick up bloom or map icons. When off, reflections are applied to the final image and clip at white. Sky brightness settings behave differently in the two modes; in HDR, 1.0 is the physically based sky." },
        surfaceDetail = { "Surface Detail Under Reflections", "How much of a surface's own fine detail (texture, bumps, specular highlights) stays visible under a reflection. The reflection replaces only the local average of the image. Applies fully on rough surfaces, less on mirror-like ones and not on water. 0 = the reflection replaces the whole pixel." },
        pixelRebuild = { "Per-Pixel Reflection Rebuild", "Rebuilds glossy reflections for each native pixel from its own normal and the traced hit distance, using this frame's colour. Keeps normal-map, ripple and texture detail at low Render Resolution and prevents ghosting on moving objects. When off, the traced reflection is upscaled." },
        faceOnReflectance = { "Face-On Reflectance", "Reflection strength when looking straight at a surface; it rises to full at grazing angles (Schlick Fresnel). Real paint, plastic and asphalt are about 0.04, but BeamNG's G-buffer has no metalness or specular colour, so this is set by preference." },
        roughnessEnd = { "Roughness Cutoff", "Material roughness at which reflections have faded out completely. The fade starts at 15% of this value. Rougher surfaces keep BeamNG's own reflections." },
        stochasticBias = { "Reflection Stability", "Narrows ray sampling toward the mirror direction. Higher values are more stable but blur rough reflections less." },
        temporalStrength = { "Temporal Denoising", "Weight of accumulated history. 0 = no accumulation." },
        filteredColor = { "Rough Reflection Filtering", "Blurs what rough surfaces reflect, using a small colour pyramid." },
        puddleStrength = { "Puddle Coverage", "Amount of procedural puddles on upward-facing surfaces. 0 = off." },
        skyReflectionFallback = { "Sky Fill (Land)", "Sky reflection on ordinary surfaces where rays find no hit. Values around 0.05-0.10 usually look right." },
        skyReflectionBrightness = { "Sky Ambient Brightness", "Brightness of the sky ambient fallback, used where the sky is not visible on screen, in shadow." },
        skyScreenBrightness = { "Screen Sky Brightness", "Brightness of the on-screen sky used for reflections, in shadow. Sun-Lit Boost is added in sunlight." },
        waterSSR = { "Water SSR", "Detects water surfaces and gives them their own reflection response." },
        waterSSRStrength = { "Water Reflection Strength", "Scales water reflectance, which follows the Fresnel equation for water: 2% looking straight down, 6% at 60 degrees, 21% at 75 degrees, full at the horizon." },
        waterColorStrength = { "Added Water Tint", "Optional blue-green grade. Zero keeps the stock rendered water color beneath reflections." },
        waterNoiseRipple = { "Water Detail Ripple", "Fine ripples on water. 0 = off." },
        waterRivers = { "River Projection", "Builds a surface map from the level's river objects once per level." },
    }
    for id, text in pairs(TEXT) do
        if P[id] then P[id].label, P[id].description = text[1], text[2] end
    end

    local formats = { amount = "%.2f", intensity = "%.2f", maxDistance = "%.0f", wetness = "%.2f",
        waterSSRStrength = "%.2f", waterSSRRoughness = "%.3f", waterSSRFlatNormal = "%.2f", waterAngleMin = "%.2f",
        waterAngleStart = "%.2f", waterAngleEnd = "%.2f", waterAnglePower = "%.2f", waterPlaneFadeMeters = "%.2f",
        waterRiverBakeResolution = "%.0f", waterRiverEdgePadding = "%.2f", waterSurfaceDepthBias = "%.2f",
        waterFarTraceDistance = "%.0f", renderScale = "%.2f" }
    for id, fmt in pairs(formats) do if P[id] then P[id].format = fmt end end

    local function setUi(id, data)
        local parameter = P[id]
        if not parameter then return end
        parameter.ui = parameter.ui or {}
        for key, v in pairs(data or {}) do parameter.ui[key] = v end
    end
    local skyOn = { id = "skyReflection", equals = true }
    setUi("qualityPreset", { discrete = true, choices = {
        { value = 0.0, label = "Custom" }, { value = 1.0, label = "Performance" }, { value = 2.0, label = "Balanced" },
        { value = 3.0, label = "High" }, { value = 4.0, label = "Ultra" } } })
    setUi("renderScale", { format = "resolutionPercent" })
    setUi("maxDistance", { suffix = " m" })
    setUi("traceQuality", { format = "percent" })
    setUi("hiZMaxLevel", { discrete = true })
    setUi("thicknessTexels", { suffix = " texels" })
    setUi("amount", { format = "percent" })
    setUi("intensity", { format = "percent" })
    setUi("reflectionEdgeFade", { format = "percent", zeroLabel = "Off" })
    setUi("wetness", { format = "percent", zeroLabel = "Off" })
    setUi("skyReflectionFallback", { format = "percent", zeroLabel = "Off", requires = skyOn })
    setUi("waterSkyFallback", { format = "percent", zeroLabel = "Off", requires = skyOn })
    setUi("skyScreenSpace", { requires = skyOn })
    setUi("skyReflectionBrightness", { format = "multiplier", requires = skyOn })
    setUi("skySaturation", { format = "percent", requires = skyOn })
    setUi("skySunBoost", { format = "multiplier", zeroLabel = "Off", requires = skyOn })
    setUi("skyScreenBrightness", { format = "multiplier", requires = { id = "skyScreenSpace", equals = true } })
    setUi("skyScreenMinDistance", { suffix = " m", requires = { id = "skyScreenSpace", equals = true } })
    setUi("skyDirectionality", { format = "percent", requires = skyOn })
    setUi("skyLightTint", { format = "percent", zeroLabel = "Off", requires = skyOn })
    setUi("engineAOOcclusion", { format = "percent", zeroLabel = "Off", requires = skyOn })
    setUi("lightExposureScale", { format = "multiplier", requires = { id = "skySunBoost", min = 0.0001 } })
    setUi("roughnessAdaptiveDenoise", { format = "percent", zeroLabel = "Off" })
    setUi("roughResolution", { format = "percent", requires = { id = "adaptiveResolution", equals = true } })
    setUi("adaptiveRoughStart", { requires = { id = "adaptiveResolution", equals = true } })
    setUi("adaptiveRoughEnd", { requires = { id = "adaptiveResolution", equals = true } })
    setUi("overhangBounce", { format = "multiplier", requires = { id = "overhangFill", equals = true } })
    setUi("overhangBrightness", { requires = { id = "overhangFill", equals = true } })
    setUi("stochasticBias", { format = "percent", requires = { id = "stochasticSSR", equals = true } })
    setUi("stochasticTemporalRate", { format = "percent", zeroLabel = "Still", requires = { id = "stochasticSSR", equals = true } })
    setUi("stochasticRayCount", { requires = { id = "stochasticSSR", equals = true } })
    setUi("stochasticResolution", { requires = { id = "stochasticSSR", equals = true } })
    setUi("stochasticReuse", { requires = { id = "stochasticSSR", equals = true } })
    setUi("colorMipScale", { format = "multiplier", requires = { id = "filteredColor", equals = true } })
    setUi("temporalStrength", { format = "historyPercent", zeroLabel = "Off" })
    setUi("temporalClamp", { format = "percent" })
    setUi("temporalMotionRejection", { format = "percent" })
    setUi("temporalMotionRejectionRot", { format = "percent" })
    setUi("fireflySuppression", { format = "percent", zeroLabel = "Off" })
    setUi("waterSSRStrength", { format = "percent", requires = { id = "waterSSR", equals = true } })
    setUi("waterRivers", { requires = { id = "waterSSR", equals = true } })
    setUi("waterRiverBakeResolution", { discrete = true, suffix = " px", requires = { id = "waterRivers", equals = true } })
    setUi("waterRiverEdgePadding", { suffix = " m", zeroLabel = "Exact", requires = { id = "waterRivers", equals = true } })
    setUi("waterRiverFlipY", { requires = { id = "waterRivers", equals = true } })
    setUi("waterColorStrength", { format = "percent", zeroLabel = "Reflection only", requires = { id = "waterSSR", equals = true } })
    setUi("waterNoiseRipple", { format = "percent", zeroLabel = "Off", requires = { id = "waterSSR", equals = true } })
    setUi("waterNoiseRippleScale", { requires = { id = "waterSSR", equals = true } })
    setUi("waterFarTraceDistance", { suffix = " m", requires = { id = "waterSSR", equals = true } })
    local puddlesOn = { id = "puddleStrength", min = 0.0001 }
    setUi("puddleStrength", { format = "percent", zeroLabel = "Off" })
    setUi("puddleScale", { format = "compact", requires = puddlesOn })
    setUi("puddleReflectivity", { format = "percent", requires = puddlesOn })
    setUi("puddleFresnel", { format = "percent", requires = puddlesOn })
    setUi("puddleEnvironmentStrength", { format = "percent", zeroLabel = "SSR only", requires = puddlesOn })
    setUi("puddleRoughness", { format = "roughness", requires = puddlesOn })
    setUi("puddleRippleStrength", { format = "percent", zeroLabel = "Still", requires = puddlesOn })
    setUi("puddleRippleScale", { format = "compact", requires = puddlesOn })
    setUi("puddleRippleSpeed", { format = "fine", zeroLabel = "Still", requires = puddlesOn })
    setUi("puddleDarken", { format = "percent", zeroLabel = "Off", requires = puddlesOn })
    setUi("puddleEdgeSoftness", { format = "percent", requires = puddlesOn })
    setUi("terrainMaskEnable", { requires = puddlesOn })
    setUi("terrainMaskStrength", { format = "percent", requires = { id = "terrainMaskEnable", equals = true } })

    P.debugView.type = "combo"
    P.debugView.group = nil
    P.debugView.advanced = true
    P.debugView.label = "Debug View"
    P.debugView.description = nil
    setUi("debugView", { choices = {
        { value = 0.0, label = "Off", description = "Normal rendering." },
        { value = 1.0, label = "Final reflection", description = "The reflection as composited, with history, sky fill and edge fade applied, multiplied by its alpha. Black means nothing is added." },
        { value = 2.0, label = "Reflection alpha", description = "Strength and coverage of the composited reflection.", legend = "white = fully reflected, black = scene only" },
        { value = 4.0, label = "Surface normals", description = "The normal the composite reflects around (water pixels use the water normal)." },
        { value = 6.0, label = "Reflection mask", description = "Material response from roughness and the wetness override.", legend = "white = fully reflective" },
        { value = 8.0, label = "Effective roughness", description = "Roughness after the wetness override and water.", legend = "black = mirror, white = fully rough" },
        { value = 16.0, label = "Water angle response", description = "How strongly water reflects at this view angle (Water angle controls)." },
        { value = 18.0, label = "Puddle mask", description = "Procedural puddle coverage.", legend = "white = puddle" },
        { value = 19.0, label = "Terrain puddle mask", description = "The terrain material weight that gates puddles, sampled in world space. It should line up with the level's roads.", legend = "white = holds water / mask disabled" },
        { value = 25.0, label = "Puddle clearcoat", description = "The puddle clearcoat layer.", legend = "R = puddle mask, G = coat response, B = total coverage" },
        { value = 26.0, label = "Puddle sources", description = "Where the puddle coat's colour comes from.", legend = "R = coat response, G = SSR confidence, B = environment fill" },
        { value = 20.0, label = "Raw trace", description = "This frame's trace before any denoising, premultiplied. Noisy by design with one stochastic ray." },
        { value = 21.0, label = "Temporal history", description = "Accumulated history as it enters the composite, premultiplied, before the composite's own sky fill." },
        { value = 22.0, label = "Temporal difference", description = "How much history differs from this frame's trace. Steady flicker here is unstable accumulation." },
        { value = 23.0, label = "Temporal state", description = "Whole screen in one colour showing the temporal routing.", legend = "red = temporal off, magenta = warming up, green = camera reprojection active, yellow = same-pixel fallback" },
        { value = 24.0, label = "Environment fill", description = "Where the sky fill lands and how strongly. Useful for water that shows its bed, or sky where it should not be.", legend = "R = land fill, G = water fill, B = share from the screen-space sky" },
        { value = 27.0, label = "Water mask", description = "Water classification in the combined depth target.", legend = "white = water" },
        { value = 28.0, label = "Combined depth", description = "Merged opaque + water depth, fourth-root so near and far both show." },
        { value = 30.0, label = "Depth merge", description = "How water depth was merged over the opaque bed.", legend = "R = bed-to-surface gap (0.25/m), G = water mask, B = combined depth" },
        { value = 31.0, label = "Trace iterations", description = "Iterations each trace pixel spent.", legend = "green = cheap, red = hit the Trace Quality cap (no hit returned)" },
        { value = 32.0, label = "Trace exits", description = "How each ray ended.", legend = "green hit, red left screen, magenta max distance, blue iteration cap, yellow rejected, cyan blocked by an overhang" },
        { value = 33.0, label = "Packed Hi-Z", description = "The packed depth pyramid, one level per quadrant. A black or flat quadrant means that level was not built.", legend = "top-left L1 min, top-right L1 max, bottom-left L2 min, bottom-right L3 min" },
        { value = 34.0, label = "Sun exposure", description = "Sunlight used by Sun-Lit Boost and Sun Colour Tint: BeamNG's sun shadow mask x contact shadows x sun presence (Engine Sun Shadow), or the #lightinfo estimate.", legend = "white = sun-lit, black = shadow" },
        { value = 49.0, label = "Per-pixel rebuild", description = "Native mode: finite hit history and uncertain miss runs. With native history off, shows the current rebuild result.", legend = "native: green = finite hit, brightness = history age, red = uncertain miss run; legacy: green = rebuilt, red = retained trace" },
        { value = 48.0, label = "Engine AO", description = "BeamNG's ambient occlusion as Engine AO Occlusion uses it (divided by Engine AO Open Level). Open ground should read near white. Uniform white everywhere = not bound (game AO off, or still warming up).", legend = "white = open, black = occluded" },
        { value = 35.0, label = "Hi-Z cells", description = "Coarsest traversal cells (level 4, 256 native pixels) as a checker; brightness = nearest depth. Cell edges should fall on multiples of 256 pixels." },
        { value = 36.0, label = "Projection check", description = "Compares the mod's camera projection with the renderer's. Checks menu frustum offsets and FOV/aspect mismatches (stretched reflections).", legend = "left: raw error, green ok / red 4+ px. right: R/G horizontal/vertical scale error, B menu offset, black = agree" },
        { value = 38.0, label = "Overhang evidence", description = "Overhang Fill's underside evidence per trace pixel (Overhang Fill on).", legend = "white = underside inferred" },
        { value = 40.0, label = "Probe: sky ambient", description = "Engine SH9 sky ambient binding.", legend = "left: raw DC term (black = not bound on this backend), right: environment colour for this pixel" },
        { value = 41.0, label = "Probe: light info", description = "Raw #lightinfo direct light x4. Black everywhere = target not bound or not warmed up." },
        { value = 42.0, label = "Probe: velocity", description = "Engine #VelocityBuffer x50. Black while panning = not produced in this configuration (keep Engine Velocity off)." },
        { value = 43.0, label = "Traversal profile", description = "Share of each ray's iterations per Hi-Z level.", legend = "R = fine levels 0-1, G = level 2, B = level 3" },
        { value = 44.0, label = "History geometry", description = "History geometry validation per pixel.", legend = "green = valid, red = rejected, blue = unavailable" },
        { value = 45.0, label = "History weight", description = "Coverage history weight used this frame. Native rebuilt colour can react faster in motion.", legend = "white = history kept, black = replaced" },
        { value = 46.0, label = "History clipping", description = "How far the variance clip had to move history.", legend = "red = colour clip distance, green = bounded miss run" },
        { value = 47.0, label = "Motion source", description = "Where each pixel's history comes from this frame.", legend = "green engine velocity, orange player vehicle body, blue exact camera, purple fallback camera, red history rejected (uncovered by the car), grey same pixel" },
    } })
end

polishParameterMetadata()

do
local balancedDefaults = {
    ["adaptiveResolution"] = false,
    ["amount"] = 1,
    ["debugView"] = 0,
    ["engineAOOcclusion"] = 1,
    ["engineVelocity"] = true,
    ["faceOnReflectance"] = 0.35,
    ["filteredColor"] = true,
    ["fireflySuppression"] = 1,
    ["fogTransport"] = 1,
    ["hdrComposite"] = true,
    ["intensity"] = 1,
    ["interleavedHistory"] = true,
    ["lightExposureScale"] = 0.3,
    ["nativeTemporal"] = true,
    ["overhangBounce"] = 0.75,
    ["overhangFill"] = false,
    ["pixelRebuild"] = true,
    ["playerVehicleMotion"] = true,
    ["puddleDarken"] = 0.68,
    ["puddleEdgeHi"] = 0.63300001621246,
    ["puddleEdgeLo"] = 0.58999997377396,
    ["puddleEdgeSoftness"] = 1,
    ["puddleEnvironmentStrength"] = 1,
    ["puddleFadeEnd"] = 90,
    ["puddleFadeStart"] = 80,
    ["puddleFresnel"] = 0.75,
    ["puddleReflectivity"] = 0.8,
    ["puddleRippleScale"] = 1.4830000400543,
    ["puddleRippleSpeed"] = 0.017000000923872,
    ["puddleRippleStrength"] = 0.0060000000521541,
    ["puddleRoughness"] = 0.02,
    ["puddleScale"] = 0.4,
    ["puddleStrength"] = 0,
    ["puddleUpDotEnd"] = 0.98,
    ["puddleUpDotStart"] = 0.92199999094009,
    ["qualityPreset"] = 2,
    ["reflectionEdgeFade"] = 0,
    ["renderScale"] = 0.5,
    ["roughResolution"] = 0.25,
    ["roughnessAdaptiveDenoise"] = 0.5,
    ["roughnessEnd"] = 0.78,
    ["skyDirectionality"] = 0.5,
    ["skyLightExposure"] = 1,
    ["skyLightTint"] = 1,
    ["skyModelVersion"] = 2,
    ["skyReflection"] = true,
    ["skyReflectionBrightness"] = 0.05,
    ["skyReflectionFallback"] = 0.6,
    ["skySaturation"] = 1,
    ["skyScreenBrightness"] = 0.5,
    ["skyScreenSpace"] = true,
    ["skySunBoost"] = 1,
    ["stochasticBias"] = 0.9,
    ["stochasticRayCount"] = 1,
    ["stochasticResolution"] = 0.5,
    ["stochasticReuse"] = 0.25,
    ["stochasticSSR"] = true,
    ["surfaceDetail"] = 1,
    ["temporalClamp"] = 1,
    ["temporalMotionRejection"] = 0.45,
    ["temporalMotionRejectionRot"] = 0.05,
    ["temporalStrength"] = 0.98,
    ["terrainFlipY"] = false,
    ["terrainGridSize"] = 2048,
    ["terrainMaskEnable"] = false,
    ["terrainMaskStrength"] = 0,
    ["terrainRuntimeBake"] = false,
    ["traceFootprintAA"] = true,
    ["traceQuality"] = 0.5,
    ["traceSubpixelJitter"] = true,
    ["virtualParallaxScale"] = 0.5,
    ["virtualReprojection"] = true,
    ["waterAutoDetect"] = true,
    ["waterColorStrength"] = 0,
    ["waterNoiseRipple"] = 1,
    ["waterNoiseRippleScale"] = 4,
    ["waterPlaneFadeMeters"] = 0.15,
    ["waterRiverBakeResolution"] = 1024,
    ["waterRiverEdgePadding"] = 0,
    ["waterRiverFlipY"] = false,
    ["waterRivers"] = true,
    ["waterSSR"] = true,
    ["waterSSRRoughness"] = 0.025,
    ["waterSSRStrength"] = 1.35,
    ["waterShaderData"] = true,
    ["waterSkyFallback"] = 0.2,
    ["waterWaveDistanceFade"] = 1000,
    ["waterWaveScale"] = 1.1,
    ["waterWaveStrength"] = 0.01,
    ["wetness"] = 0,
}
for id, v in pairs(balancedDefaults) do
    if EffectModule.parameters[id] then EffectModule.parameters[id].default = v end
    if EffectModule.retiredValues[id] ~= nil then EffectModule.retiredValues[id] = v end
end
EffectModule.parameters.temporalDenoising = { label = "Temporal Denoising", type = "bool", default = true,
    group = "Denoising", order = EffectModule.parameters.temporalStrength.order,
    description = "Accumulates reflection samples across frames to reduce noise. Disabling it also stops changes to the stochastic sample pattern between frames." }
EffectModule.parameters.temporalStrength.visible = false
EffectModule.parameters.reflectionEdgeFade.visible = false
EffectModule.parameters.interleavedHistory.visible = false
EffectModule.parameters.traceSubpixelJitter.visible = false
EffectModule.parameters.roughnessAdaptiveDenoise.visible = false
EffectModule.parameters.waterShaderData.visible = false
EffectModule.parameters.waterRiverFlipY.visible = false
EffectModule.parameters.hdrComposite.advanced = true
EffectModule.parameters.fogTransport.advanced = true
EffectModule.parameters.adaptiveResolution.advanced = true
EffectModule.parameters.roughResolution.advanced = true
EffectModule.parameters.virtualReprojection.advanced = true
EffectModule.parameters.fireflySuppression.advanced = true
EffectModule.parameters.temporalClamp.advanced = true
EffectModule.parameters.temporalMotionRejection.advanced = true
EffectModule.parameters.temporalMotionRejectionRot.advanced = true
EffectModule.parameters.skyReflectionFallback.advanced = true
EffectModule.parameters.waterSkyFallback.advanced = true
EffectModule.parameters.skyDirectionality.advanced = true
EffectModule.parameters.engineAOOcclusion.advanced = true
for _, tab in ipairs(EffectModule.settingsLayout) do
    for i,id in ipairs(tab.user) do
        if id == "temporalStrength" then tab.user[i] = "temporalDenoising" end
    end
end
for _, parameter in pairs(EffectModule.parameters) do
    local text = parameter.description
    if text then
        text = text:match("^([^%.]+%.)") or text
        if text:find("%d") then text = nil end
        parameter.description = text or ("Adjusts " .. string.lower(parameter.label) .. ".")
    end
end
EffectModule.parameters.qualityPreset.description = "Sets reflection resolution, ray reach and overhang fill."
EffectModule.parameters.traceQuality.description = "Controls how far rays search for reflected surfaces. Higher values increase tracing cost."
EffectModule.parameters.hdrComposite.description = "Composites reflections before exposure and tonemapping, preserving bright reflected highlights."
EffectModule.parameters.surfaceDetail.description = "Preserves surface texture and lighting beneath reflections."
EffectModule.parameters.faceOnReflectance.description = "Sets reflection strength on surfaces facing the camera."
EffectModule.parameters.roughnessEnd.description = "Sets the material roughness above which traced reflections fade out."
EffectModule.parameters.pixelRebuild.description = "Reconstructs reflections using each display pixel’s surface normal and the traced hit distance."
EffectModule.parameters.fogTransport.description = "Attenuates reflections through the level’s fog."
EffectModule.parameters.adaptiveResolution.description = "Uses a separate, lower resolution trace for rough surfaces."
EffectModule.parameters.roughResolution.description = "Sets the tracing resolution used for rough surfaces when Adaptive Resolution is enabled."
EffectModule.parameters.virtualReprojection.description = "Tracks the reflected position when reprojecting reflection history."
EffectModule.parameters.fireflySuppression.description = "Reduces isolated bright reflection samples."
EffectModule.parameters.temporalClamp.description = "Limits reflection history to the range of current samples."
EffectModule.parameters.temporalMotionRejection.description = "Reduces history retention during translation and object movement."
EffectModule.parameters.temporalMotionRejectionRot.description = "Reduces history retention during camera rotation."
EffectModule.parameters.skyReflectionFallback.description = "Sets sky reflection strength on land where tracing finds no surface."
EffectModule.parameters.waterSkyFallback.description = "Sets sky reflection strength on water where tracing finds no surface."
EffectModule.parameters.skyDirectionality.description = "Controls how strongly sky reflections vary with reflection direction."
EffectModule.parameters.engineAOOcclusion.description = "Uses engine ambient occlusion to reduce sky reflection in enclosed areas."
EffectModule.parameters.overhangFill.description = "Adds reflected surroundings beneath overhangs where screen tracing lacks coverage."
EffectModule.parameters.waterSSRStrength.description = "Scales water reflection strength while preserving its response to viewing angle."
EffectModule.parameters.lightExposureScale.description = "Controls how sky reflection brightness responds to sunlight exposure."
end
-- BeamRT exposes experimental controls for real A/B comparisons, including
-- controls hidden or fixed in the contributed standalone UI.

EffectModule.modNameHints = {
    { "beamrt", "coherent" },
    { "screen", "reflection" },
}

EffectModule.ui = {
    shortName = "SSR",
    homeTitle = "Screen-Space Reflections",
    navName = "SSR Reflections",
    eyebrow = "BeamRT  /  SSR",
    subtitle = "Screen-space reflections for roads, vehicles, water and wet surfaces.",
    overviewTitle = "Look",
    overviewDescription = "Appearance settings. Settings that affect performance are on the Performance tab.",
    overview = { "amount", "intensity", "wetness", "skyReflection", "skyReflectionFallback", "waterSkyFallback",
        "skyScreenBrightness", "waterSSRStrength", "waterColorStrength", "reflectionEdgeFade", "puddleStrength" },
    groupOrder = { "Reflection", "Quality", "Stochastic SSR", "Denoising", "Sky Reflection", "Water", "Puddles" },
    groupLabels = {
        ["Quality"] = "Trace",
        ["Stochastic SSR"] = "Stochastic",
        ["Sky Reflection"] = "Sky",
        ["Puddles"] = "Puddles (Experimental)"
    },
    experimentalGroups = { ["Puddles"] = true },
    groupDescriptions = {
        ["Reflection"] = "How strongly reflections show and where they fade.",
        ["Quality"] = "Trace resolution and how far each ray searches.",
        ["Stochastic SSR"] = "Roughness-based ray sampling for rough reflections, and the filter that shares samples between pixels.",
        ["Denoising"] = "Accumulation of reflections over frames: how much history is kept and when it is rejected.",
        ["Sky Reflection"] = "What surfaces reflect where rays find no hit: the on-screen sky where visible, otherwise the sky ambient. Also Overhang Fill for undersides.",
        ["Water"] = "Water surfaces: detection, reflection strength, tint and ripples.",
        ["Puddles"] = "Procedural rain puddles (experimental)."
    },
    groupWarnings = {
        ["Puddles"] = "Puddles are experimental. They depend on generated masks and on screen-space or sky reflections."
    },
    qualityButtonsTab = "performance",
    performanceTitle = "Performance",
    performanceDescription = "All settings that affect frame time. The rating shows each setting's typical share of SSR's cost.",
    performance = {
        { header = "Resolution" },
        { id = "renderScale", impact = "High" },
        { id = "stochasticResolution", impact = "High" },
        { id = "adaptiveResolution", impact = "Medium" },
        { id = "roughResolution", impact = "Low" },
        { header = "Ray search" },
        { id = "qualityPreset", impact = "High" },
        { id = "traceQuality", impact = "High" },
        { id = "stochasticSSR", impact = "Low" },
        { id = "stochasticRayCount", impact = "High" },
        { id = "traceFootprintAA", impact = "Medium", note = "Native history extends the seed search only where needed. Without native history, missing glossy hits can trace two compatible positions within the coarse pixel." },
        { id = "overhangFill", impact = "Medium" },
        { header = "Filtering and history" },
        { id = "temporalStrength", impact = "High" },
        { id = "nativeTemporal", impact = "High" },
        { id = "interleavedHistory", impact = "High" },
        { id = "stochasticReuse", impact = "Low" },
        { id = "filteredColor", impact = "Low" },
        { id = "roughnessAdaptiveDenoise", impact = "Low" },
        { id = "pixelRebuild", impact = "Low", note = "Up to 12 depth reads and one colour read per glossy pixel before native temporal accumulation. A 25% trace with it can look better than a 50% trace without it." },
        { id = "virtualReprojection", impact = "Low", note = "A second camera solve per glossy pixel, and a second history read where surface and reflection motion are blended." },
        { header = "Sky, water and puddles" },
        { id = "skyReflection", impact = "Low" },
        { id = "skyScreenSpace", impact = "Low" },
        { id = "engineAOOcclusion", impact = "Low", note = "Reads BeamNG's existing AO once per pixel; no extra pass." },
        { id = "waterSSR", impact = "Low" },
        { id = "waterRivers", impact = "Low" },
        { id = "puddleStrength", impact = "Medium" },
    },
    debugParameter = "debugView",
    debugTitle = "Debug view",
    debugDescription = "Replaces the final image with a diagnostic view. Trace diagnostics (31-43) use a slower trace shader while active.",
}

local shaderName = "BeamRTCoherentShader" .. EffectModule.shaderCodeVersion:gsub("%W", "")
local stateBlockName = "BeamRTCoherentStateBlock"
local basePostEffectName = "BeamRTCoherentPostEffect"
local fallbackTexture = "shaders/beamrt/beamrtSTBN_128x128x64_rg_atlas.png"

local effectShader = nil
local effectStateBlock = nil

local tracePass = nil
local roughTracePass = nil
local roughEnabled, roughReady, roughStartFrame = false, false, nil
local reusePass = nil
local reuseEnabled = false
local reuseReady = false
local reuseStartFrame = nil
local geometryPassA, geometryPassB = nil, nil
local geometryEnabled, geometryStartFrame = false, -1
local geometryReady = false
local traceShaderVariant = nil
local temporalDebugPass = nil
local temporalDebugEnabled = false
local temporalPassA = nil
local temporalPassB = nil
local temporalDrawingPass = nil
local applyPass = nil
local applyVariant = {
    current = 3.0,
    shaderPrefix = shaderName .. "P",
    shaderDefines = "BEAMRT_COH_SSR_CACHE_" .. EffectModule.shaderCacheVersion:gsub("%W", "_"):upper()
}
applyVariant.depth = { time = "PFXBeforeBin", bin = "AfterPostFX", priorityBase = 64.0,
    global = "BEAMRT_COH_SHARED_DEPTH" }
function applyVariant.depth.owns(name)
    return type(name) == "string" and name:find("HiZ", 1, true) ~= nil
end
applyVariant.unified = { pass = nil, enabled = false, ready = false, startFrame = -1 }
applyVariant.stageTime = "PFXBeforeBin"
applyVariant.stageBin = "AfterPostFX"

local temporalTargetAReady = false
local temporalTargetBReady = false
local temporalScheduledTarget = nil
local temporalScheduledFrame = -1
local lastTemporalOutput = "#BeamRTCoherentCurrent"
local colorMipPasses = { nil, nil, nil, nil }
local hiZPasses = { nil, nil, nil, nil, nil, nil, nil, nil, nil }
local hiZPackedPass = nil
local cameraHistoryPass = nil

local lastCameraState = nil
local currentCameraForProjection = nil
local lastCameraForProjection = nil
local reprojectionPrevious = nil
local reprojectionValid = false
local temporalHistoryWarmup = 2
local cameraCaptureSource = "unavailable"
local lastLoggedCameraCaptureSource = nil

local renderPriorityBase = 24.0
local frame = 0
local elapsedTime = 0.0
local mapLoadRescanUntilFrame = -1

local staticConstantsDirty = true
local lastStaticSignature = nil
local lastStaticSignatureCheckFrame = -999999
local bayer2x2JitterSequence = {
    { -0.25, -0.25 }, {  0.25,  0.25 }, {  0.25, -0.25 }, { -0.25,  0.25 },
}
local bayer4x4JitterSequence = {
    { -0.375, -0.375 }, {  0.125,  0.125 }, {  0.125, -0.375 }, { -0.375,  0.125 },
    { -0.125, -0.125 }, {  0.375,  0.375 }, {  0.375, -0.125 }, { -0.125,  0.375 },
    { -0.125, -0.375 }, {  0.375,  0.125 }, {  0.375, -0.375 }, { -0.125,  0.125 },
    { -0.375, -0.125 }, {  0.125,  0.375 }, {  0.125, -0.125 }, { -0.375,  0.375 },
}
applyVariant.unified.jitter8 = {}
do
    local rank2 = { {0,2}, {3,1} }
    for y=0,7 do
        for x=0,7 do
            local rank,divisor=0,1
            for _=1,3 do
                local bx=math.floor(x/divisor)%2
                local by=math.floor(y/divisor)%2
                rank=rank*4+rank2[by+1][bx+1]
                divisor=divisor*2
            end
            applyVariant.unified.jitter8[rank+1]={(x+0.5)/8-0.5,(y+0.5)/8-0.5}
        end
    end
end

local cachedRenderScaleString = nil
local cachedNativeTemporal = nil
local cachedRoutingUseTemporal = nil
local cachedRoutingUseFiltered = nil
local cachedDebugRoute = nil
local parameterSignatureIds = nil
local depthPipelineLogged = false
local cachedScreenWidth = nil
local cachedScreenHeight = nil

local pendingParameterFlush = false
local pendingWaterGeometryRefresh = false

local function fmt3(vec)
    return string.format("%.9g %.9g %.9g", vec.x, vec.y, vec.z)
end

local function getScreenSize()
    local vm = GFXDevice and GFXDevice.getVideoMode and GFXDevice.getVideoMode()

    if vm and vm.width and vm.height and vm.width > 0 and vm.height > 0 then
        return vm.width, vm.height
    end

    if screenWidth and screenHeight then
        return screenWidth, screenHeight
    end

    return 1920, 1080
end

local function getRenderScale(self)
    local values = self and self.values or {}
    local scale = values.renderScale or 0.75
    if values.stochasticSSR ~= false then
        scale = scale * math.max(0.5, math.min(1.0, values.stochasticResolution or 1.0))
    end
    return math.max(0.05, math.min(1.0, scale))
end

local function getRenderScaleString(self)
    local scale = getRenderScale(self)
    return tostring(scale) .. " " .. tostring(scale)
end

local function getSSRResolution(self)
    local scale = getRenderScale(self)
    local width, height = getScreenSize()
    return tostring(math.floor(width * scale + 0.5)) .. " " .. tostring(math.floor(height * scale + 0.5))
end

for _, entry in ipairs(EffectModule.ui.performance or {}) do
    if entry.id == "temporalStrength" then entry.id = "temporalDenoising" end
end
local function value(self, id, fallback)
    local values = self and self.values or {}
    if id == "temporalStrength" and values.temporalDenoising == false then return 0 end
    local v = values[id]
    if v == nil then v = EffectModule.retiredValues[id] end
    if v == nil then return fallback end
    return v
end

local function getParameterSignatureIds()
    if parameterSignatureIds then return parameterSignatureIds end

    parameterSignatureIds = {}
    for id, _ in pairs(EffectModule.parameters or {}) do
        parameterSignatureIds[#parameterSignatureIds + 1] = id
    end
    table.sort(parameterSignatureIds)
    return parameterSignatureIds
end

local function buildStaticSignature(self)
    local values = self and self.values or {}
    local out = {}
    for _, id in ipairs(getParameterSignatureIds()) do
        out[#out + 1] = id .. "=" .. tostring(values[id])
    end
    return table.concat(out, ";")
end

local function isWaterParameter(id)
    return type(id) == "string" and string.sub(id, 1, 5) == "water"
end

local function getRoughScale(self)
    local rough = tonumber(value(self, "roughResolution", 0.2)) or 0.2
    return math.max(0.05, math.min(1.0, rough))
end

local function resolutionString(scale)
    local width, height = getScreenSize()
    return tostring(math.floor(width * scale + 0.5)) .. " " .. tostring(math.floor(height * scale + 0.5))
end

local function forEachPass(fn, self, drawingOnly)
    if hiZPasses[1] then fn(hiZPasses[1], self) end
    if tracePass then fn(tracePass, self) end
    if roughTracePass and (not drawingOnly or roughEnabled) then fn(roughTracePass, self) end
    if reusePass and (not drawingOnly or reuseEnabled) then fn(reusePass, self) end
    if value(self, "temporalStrength", 0.0) > 0.0001 then
        if drawingOnly and temporalDrawingPass then
            fn(temporalDrawingPass, self)
        else
            if temporalPassA then fn(temporalPassA, self) end
            if temporalPassB then fn(temporalPassB, self) end
        end
    end
    if applyVariant.unified.pass then fn(applyVariant.unified.pass, self) end
    if applyPass then fn(applyPass, self) end
    if temporalDebugPass and (not drawingOnly or temporalDebugEnabled) then fn(temporalDebugPass, self) end
end

local WATER_MAX_PLANES = 4

local waterCache = {
    frame = -999999,
    planes = {},
    blocks = {}
}

local RIVER_BAKE_VERSION = "v2"
local riverState = {
    available = false,
    path = fallbackTexture,
    levelKey = "",
    signature = "",
    originX = 0.0,
    originY = 0.0,
    worldSize = 1.0,
    heightMin = 0.0,
    heightRange = 1.0,
    referenceHeight = 0.0,
    resolution = 1,
    edgePadding = 0.0,
    riverCount = 0,
    segmentCount = 0,
    bindingDirty = false,
    rebakeAtFrame = nil,
    lastFailure = ""
}

local lastExternalWaterSSR = false
local function externalWaterSSRActive()
    local bus = rawget(_G, "BEAMRT_COH_IMPROVED_WATER")
    return type(bus) == "table" and bus.active == true and bus.suppressLegacyWaterSSR == true
end

local function fmt4(a, b, c, d)
    return string.format("%.9g %.9g %.9g %.9g", tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, tonumber(d) or 0)
end

local function parseVec3(v, fallback)
    local nilOnFailure = fallback == nil
    fallback = fallback or {x = 0, y = 0, z = 0}
    if not v then if nilOnFailure then return nil else return fallback end end

    local tv = type(v)
    if tv == "table" or tv == "userdata" or tv == "cdata" then
        local okx, x = pcall(function() return v.x end)
        local oky, y = pcall(function() return v.y end)
        local okz, z = pcall(function() return v.z end)
        if okx and oky and okz and x ~= nil and y ~= nil and z ~= nil then
            return {x = tonumber(x) or fallback.x, y = tonumber(y) or fallback.y, z = tonumber(z) or fallback.z}
        end
        local ok1, vx = pcall(function() return v[1] end)
        local ok2, vy = pcall(function() return v[2] end)
        local ok3, vz = pcall(function() return v[3] end)
        if ok1 and ok2 and ok3 and vx ~= nil and vy ~= nil and vz ~= nil then
            return {x = tonumber(vx) or fallback.x, y = tonumber(vy) or fallback.y, z = tonumber(vz) or fallback.z}
        end
    elseif tv == "string" then
        local nums = {}
        for n in string.gmatch(v, "[-+%d%.]+") do
            if tonumber(n) then nums[#nums + 1] = tonumber(n) end
            if #nums >= 3 then break end
        end
        if #nums >= 3 then
            return {x = nums[1] or fallback.x, y = nums[2] or fallback.y, z = nums[3] or fallback.z}
        end
    elseif tv == "number" then
        return {x = v, y = fallback.y, z = fallback.z}
    end

    if nilOnFailure then return nil else return fallback end
end

local function normalizedVec3(v)
    if not v then return nil end
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len < 1e-8 then return nil end
    return {x = v.x / len, y = v.y / len, z = v.z / len}
end

local function crossVec3(a, b)
    return {
        x = a.y * b.z - a.z * b.y,
        y = a.z * b.x - a.x * b.z,
        z = a.x * b.y - a.y * b.x
    }
end

local function getterVec3(ok, x, y, z)
    if not ok then return nil end
    if type(x) == "number" and tonumber(y) and tonumber(z) then
        return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
    end
    return parseVec3(x, nil)
end

local function parseQuat(v, vy, vz, vw)
    local x, y, z, w
    local tv = type(v)

    if tv == "number" then
        x, y, z, w = tonumber(v), tonumber(vy), tonumber(vz), tonumber(vw)
    elseif tv == "table" or tv == "userdata" or tv == "cdata" then
        local okx, qx = pcall(function() return v.x end)
        local oky, qy = pcall(function() return v.y end)
        local okz, qz = pcall(function() return v.z end)
        local okw, qw = pcall(function() return v.w end)
        if okx and oky and okz and okw then
            x, y, z, w = tonumber(qx), tonumber(qy), tonumber(qz), tonumber(qw)
        end

        if not (x and y and z and w) then
            local ok1, q1 = pcall(function() return v[1] end)
            local ok2, q2 = pcall(function() return v[2] end)
            local ok3, q3 = pcall(function() return v[3] end)
            local ok4, q4 = pcall(function() return v[4] end)
            if ok1 and ok2 and ok3 and ok4 then
                x, y, z, w = tonumber(q1), tonumber(q2), tonumber(q3), tonumber(q4)
            end
        end

        if not (x and y and z and w) then
            local ok0, q0 = pcall(function() return v[0] end)
            local ok1, q1 = pcall(function() return v[1] end)
            local ok2, q2 = pcall(function() return v[2] end)
            local ok3, q3 = pcall(function() return v[3] end)
            if ok0 and ok1 and ok2 and ok3 then
                x, y, z, w = tonumber(q0), tonumber(q1), tonumber(q2), tonumber(q3)
            end
        end

        if not (x and y and z and w) then
            local nums = {}
            local okString, text = pcall(tostring, v)
            if okString and text then
                for n in string.gmatch(text, "[-+]?%d*%.?%d+[eE]?[-+]?%d*") do
                    nums[#nums + 1] = tonumber(n)
                    if #nums >= 4 then break end
                end
            end
            if #nums >= 4 then x, y, z, w = nums[1], nums[2], nums[3], nums[4] end
        end
    elseif tv == "string" then
        local nums = {}
        for n in string.gmatch(v, "[-+]?%d*%.?%d+[eE]?[-+]?%d*") do
            nums[#nums + 1] = tonumber(n)
            if #nums >= 4 then break end
        end
        if #nums >= 4 then x, y, z, w = nums[1], nums[2], nums[3], nums[4] end
    end

    if not (x and y and z and w) then return nil end
    local len = math.sqrt(x * x + y * y + z * z + w * w)
    if len < 1e-8 then return nil end
    return {x = x / len, y = y / len, z = z / len, w = w / len}
end

local function rotateVec3ByQuat(q, v)
    local tx = 2.0 * (q.y * v.z - q.z * v.y)
    local ty = 2.0 * (q.z * v.x - q.x * v.z)
    local tz = 2.0 * (q.x * v.y - q.y * v.x)
    return {
        x = v.x + q.w * tx + (q.y * tz - q.z * ty),
        y = v.y + q.w * ty + (q.z * tx - q.x * tz),
        z = v.z + q.w * tz + (q.x * ty - q.y * tx)
    }
end

local function callCameraGetter(coreName, globalName)
    local function tryCandidate(candidate, owner)
        if candidate == nil then return false end

        local ok, a, b, c, d = pcall(function() return candidate() end)
        if ok and a ~= nil then return true, a, b, c, d end

        if owner then
            ok, a, b, c, d = pcall(function() return candidate(owner) end)
            if ok and a ~= nil then return true, a, b, c, d end
        end
        return false
    end

    if core_camera then
        local ok, candidate = pcall(function() return core_camera[coreName] end)
        if ok then
            local called, a, b, c, d = tryCandidate(candidate, core_camera)
            if called then return true, a, b, c, d end
        end
    end
    if _G then
        local ok, candidate = pcall(function() return _G[globalName] end)
        if ok then
            local called, a, b, c, d = tryCandidate(candidate, nil)
            if called then return true, a, b, c, d end
        end
    end
    return false
end

local function orthonormalCameraBasis(forward, rightHint, upHint)
    forward = normalizedVec3(forward)
    rightHint = normalizedVec3(rightHint)
    upHint = normalizedVec3(upHint)
    if not forward then return nil end

    local right
    if rightHint and math.abs(rightHint.x * forward.x + rightHint.y * forward.y + rightHint.z * forward.z) < 0.999 then
        local upFromRight = normalizedVec3(crossVec3(rightHint, forward))
        if upFromRight then right = normalizedVec3(crossVec3(forward, upFromRight)) end
    elseif upHint and math.abs(upHint.x * forward.x + upHint.y * forward.y + upHint.z * forward.z) < 0.999 then
        right = normalizedVec3(crossVec3(forward, upHint))
    end

    if not right then
        local referenceUp = {x = 0, y = 0, z = 1}
        if math.abs(forward.z) > 0.98 then
            referenceUp = (lastCameraState and lastCameraState.up) or {x = 0, y = 1, z = 0}
        end
        right = normalizedVec3(crossVec3(forward, referenceUp))
    end
    if not right then return nil end

    local up = normalizedVec3(crossVec3(right, forward))
    if not up then return nil end
    return right, forward, up
end

local function cameraBasisFromQuat(quatValue, qy, qz, qw)
    if quatValue and type(vec3) == "function" and type(quatValue) ~= "number" then
        local ok, right, forward, up = pcall(function()
            return parseVec3(quatValue * vec3(1, 0, 0), nil),
                   parseVec3(quatValue * vec3(0, 1, 0), nil),
                   parseVec3(quatValue * vec3(0, 0, 1), nil)
        end)
        if ok then
            right, forward, up = orthonormalCameraBasis(forward, right, up)
            if right and forward and up then return right, forward, up, "quaternion operator" end
        end
    end

    local quat = parseQuat(quatValue, qy, qz, qw)
    if quat then
        local right = rotateVec3ByQuat(quat, {x = 1, y = 0, z = 0})
        local forward = rotateVec3ByQuat(quat, {x = 0, y = 1, z = 0})
        local up = rotateVec3ByQuat(quat, {x = 0, y = 0, z = 1})
        right, forward, up = orthonormalCameraBasis(forward, right, up)
        if right and forward and up then return right, forward, up, "quaternion components" end
    end

    return nil
end

local function cameraBasisFromDirection()
    local forwardOK, fx, fy, fz = callCameraGetter("getForward", "getCameraForward")
    local rightOK, rx, ry, rz = callCameraGetter("getRight", "getCameraRight")
    local upOK, ux, uy, uz = callCameraGetter("getUp", "getCameraUp")
    local forward = getterVec3(forwardOK, fx, fy, fz)
    if not forward then return nil end

    local right = getterVec3(rightOK, rx, ry, rz)
    local up = getterVec3(upOK, ux, uy, uz)
    right, forward, up = orthonormalCameraBasis(forward, right, up)
    if not right or not forward or not up then return nil end
    return right, forward, up, (rightOK or upOK) and "camera direction vectors" or "camera forward vector"
end

local function captureCameraState()
    local ok, state, source = pcall(function()
        local pos, right, forward, up, basisSource
        local fov = 65.0

        local directOK, directPos, directRight, directUp, directForward, directFovRad = pcall(function()
            return core_camera.getPosition(), core_camera.getRight(), core_camera.getUp(),
                   core_camera.getForward(), core_camera.getFovRad()
        end)
        if directOK then
            pos = parseVec3(directPos, nil)
            right = parseVec3(directRight, nil)
            up = parseVec3(directUp, nil)
            forward = parseVec3(directForward, nil)
            right, forward, up = orthonormalCameraBasis(forward, right, up)
            if pos and right and forward and up then
                basisSource = "core_camera basis"
                local fovRad = tonumber(directFovRad)
                if fovRad then fov = math.deg(fovRad) end
            else
                pos, right, forward, up = nil, nil, nil, nil
            end
        end

        if not pos then
            local posOK, px, py, pz = callCameraGetter("getPosition", "getCameraPosition")
            pos = getterVec3(posOK, px, py, pz)
        end
        if not pos then return nil, "position unavailable" end

        if not right then
            local quatOK, qx, qy, qz, qw = callCameraGetter("getQuat", "getCameraQuat")
            if quatOK then
                right, forward, up, basisSource = cameraBasisFromQuat(qx, qy, qz, qw)
            end
        end
        if not right then
            right, forward, up, basisSource = cameraBasisFromDirection()
        end
        if not right or not forward or not up then return nil, "orientation unavailable" end

        if basisSource ~= "core_camera basis" then
            local fovRadOK, cameraFovRad = callCameraGetter("getFovRad", "getCameraFovRad")
            local fovDegOK, cameraFovDeg = callCameraGetter("getFovDeg", "getCameraFovDeg")
            if fovRadOK and tonumber(cameraFovRad) then
                fov = math.deg(tonumber(cameraFovRad))
            elseif fovDegOK then
                fov = tonumber(cameraFovDeg) or fov
            end
        end
        fov = math.max(5.0, math.min(170.0, fov))

        local width, height = getScreenSize()
        local tanHalfY = math.tan(math.rad(fov) * 0.5)
        local tanHalfX = tanHalfY * (width / math.max(height, 1))
        return {
            pos = pos,
            right = right,
            forward = forward,
            up = up,
            tanHalfX = tanHalfX,
            tanHalfY = tanHalfY,
            fov = fov
        }, basisSource
    end)
    if not ok then return nil, "capture exception: " .. tostring(state) end
    return state, source
end

local function prepareCameraReprojection(self)
    local current, source = captureCameraState()
    cameraCaptureSource = source or "unavailable"
    if frame > 5 and cameraCaptureSource ~= lastLoggedCameraCaptureSource then
        local level = current and "I" or "W"
        local message = current
            and ("Temporal camera capture active via " .. cameraCaptureSource)
            or ("Temporal camera capture unavailable (" .. cameraCaptureSource .. "); using same-pixel history fallback")
        if type(log) == "function" then pcall(log, level, "BeamRTCoherent", message) end
        lastLoggedCameraCaptureSource = cameraCaptureSource
    end

    reprojectionPrevious = lastCameraState
    lastCameraForProjection = currentCameraForProjection
    currentCameraForProjection = current
    reprojectionValid = current ~= nil and reprojectionPrevious ~= nil

    if current ~= nil and lastCameraState ~= nil then
        local dx = current.pos.x - lastCameraState.pos.x
        local dy = current.pos.y - lastCameraState.pos.y
        local dz = current.pos.z - lastCameraState.pos.z
        local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
        local facing = current.forward.x * lastCameraState.forward.x +
                       current.forward.y * lastCameraState.forward.y +
                       current.forward.z * lastCameraState.forward.z
        if moved > 25.0 or facing < 0.5 or math.abs(current.fov - lastCameraState.fov) > 8.0 then
            reprojectionValid = false
            temporalHistoryWarmup = math.max(temporalHistoryWarmup, 2)
        end
    end

    lastCameraState = current
end

local function safeField(obj, fieldName, index)
    if not obj then return nil end
    if obj.getField then
        local ok, val = pcall(function() return obj:getField(fieldName, index or 0) end)
        if ok and val ~= nil and val ~= "" then return val end
    end
    local ok, val = pcall(function() return obj[fieldName] end)
    if ok and val ~= nil and val ~= "" then return val end
    return nil
end

local function cleanupRetiredWaterShaderBridge()
    -- This backend never repairs or overrides a stock water shader.
end

local function safeMethodVec3(obj, methodName, index)
    if not obj then return nil end
    local okMethod, method = pcall(function() return obj[methodName] end)
    if not okMethod or type(method) ~= "function" then return nil end

    local results
    if index == nil then
        results = {pcall(function() return method(obj) end)}
    else
        results = {pcall(function() return method(obj, index) end)}
    end

    if not results[1] or results[2] == nil then return nil end
    if type(results[2]) == "number" and type(results[3]) == "number" and type(results[4]) == "number" then
        return {x = results[2], y = results[3], z = results[4]}
    end
    return parseVec3(results[2], nil)
end

local function getObjectPosition(obj)
    return safeMethodVec3(obj, "getPosition") or parseVec3(safeField(obj, "position", 0), {x = 0, y = 0, z = 0})
end

local function getObjectScale(obj)
    return safeMethodVec3(obj, "getScale") or parseVec3(safeField(obj, "scale", 0), {x = 1, y = 1, z = 1})
end

local function parseNumberList(v)
    local nums = {}
    if v == nil then return nums end
    local tv = type(v)
    if tv == "string" then
        for n in string.gmatch(v, "[-+%d%.]+") do
            if tonumber(n) then nums[#nums + 1] = tonumber(n) end
        end
    elseif tv == "table" or tv == "userdata" then
        for i = 1, 16 do
            local ok, val = pcall(function() return v[i] end)
            if ok and val ~= nil and tonumber(val) then nums[#nums + 1] = tonumber(val) end
        end
    end
    return nums
end

local function safeMethodRaw(obj, methodName)
    if not obj then return nil end
    local okMethod, method = pcall(function() return obj[methodName] end)
    if not okMethod or type(method) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, q = pcall(function() return method(obj) end)
    if not ok then return nil end
    if b ~= nil then
        local out = {}
        for _, v in ipairs({a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,q}) do
            if v ~= nil then out[#out + 1] = v end
        end
        return table.concat(out, " ")
    end
    return a
end

local function axisFromYaw(yaw, sign, swap)
    yaw = (tonumber(yaw) or 0) * (tonumber(sign) or 1)
    local c = math.cos(yaw)
    local s = math.sin(yaw)
    local ax, ay = c, s
    if swap then
        ax, ay = -s, c
    end
    local len = math.sqrt(ax * ax + ay * ay)
    if len < 0.00001 then return 1, 0 end
    return ax / len, ay / len
end

local function getObjectYawRad(obj)
    local rot = parseVec3(safeField(obj, "rotationEuler", 0), {x = 0, y = 0, z = 0})
    local yaw = tonumber(rot.z) or 0
    if math.abs(yaw) > 6.28318530718 then yaw = math.rad(yaw) end

    if math.abs(yaw) < 0.000001 then
        local tr = safeMethodRaw(obj, "getTransform") or safeField(obj, "transform", 0)
        local nums = parseNumberList(tr)
        if #nums >= 7 then
            local ax, ay, az, angle = nums[4], nums[5], nums[6], nums[7]
            if math.abs(az or 0) > math.abs(ax or 0) and math.abs(az or 0) > math.abs(ay or 0) then
                yaw = (tonumber(angle) or 0) * ((tonumber(az) or 0) < 0 and -1 or 1)
            end
        end
    end
    return yaw
end

local function getObjectAxisX2D(obj, sign, swap)

    local candidates = {
        safeMethodVec3(obj, "getRightVector"),
        safeMethodVec3(obj, "getRight"),
        safeMethodVec3(obj, "getObjRightVector"),
    }
    for _, v in ipairs(candidates) do
        if v and tonumber(v.x) and tonumber(v.y) then
            local ax, ay = tonumber(v.x), tonumber(v.y)
            if swap then ax, ay = -ay, ax end
            if (sign or 1) < 0 then ay = -ay end
            local len = math.sqrt(ax * ax + ay * ay)
            if len > 0.00001 then return ax / len, ay / len end
        end
    end
    return axisFromYaw(getObjectYawRad(obj), sign, swap)
end

local function objectLooksEnabled(obj)
    if not obj then return false end
    local hidden = safeField(obj, "hidden", 0)
    if hidden == true or hidden == "true" or hidden == "1" then return false end
    return true
end

local function addWaterPlane(height)
    if #waterCache.planes >= WATER_MAX_PLANES then return end
    waterCache.planes[#waterCache.planes + 1] = {height = tonumber(height) or 0}
end

local function addWaterBlock(pos, scale, axisXx, axisXy, padding)
    local sx = math.max(math.abs(tonumber(scale.x) or 0), 0.01) * 0.5 + padding
    local sy = math.max(math.abs(tonumber(scale.y) or 0), 0.01) * 0.5 + padding
    sx = math.max(sx, 0.01)
    sy = math.max(sy, 0.01)

    local ax = tonumber(axisXx) or 1
    local ay = tonumber(axisXy) or 0
    local len = math.sqrt(ax * ax + ay * ay)
    if len < 0.00001 then ax, ay, len = 1, 0, 1 end

    waterCache.blocks[#waterCache.blocks + 1] = {
        cx = tonumber(pos.x) or 0,
        cy = tonumber(pos.y) or 0,
        h = tonumber(pos.z) or 0,
        hx = sx,
        hy = sy,
        c = ax / len,
        s = ay / len,
        dist2 = 0
    }
end

local function riverLevelKey()
    local mission = ""
    local ok, result = pcall(function()
        return type(getMissionFilename) == "function" and getMissionFilename() or ""
    end)
    if ok then mission = tostring(result or "") end
    mission = mission:gsub("\\", "/")
    local key = mission:match("/levels/([^/]+)/") or mission:match("levels/([^/]+)/") or "current_level"
    key = key:gsub("[^%w_%-]", "_")
    return key ~= "" and key or "current_level"
end

local function riverFileExists(path)
    local ok, result = pcall(function()
        return FS and FS.fileExists and FS:fileExists(path)
    end)
    return ok and result == true
end

local function riverHashNumber(hash, number)
    local quantized = math.floor((tonumber(number) or 0.0) * 100.0 + 0.5)
    return (hash * 65599 + (quantized % 2147483647) + 97) % 2147483647
end

local function collectRiverRibbonGeometry()
    if not scenetree or not scenetree.findClassObjects or not scenetree.findObject then
        return nil, "scene tree unavailable"
    end

    local okList, rawNames = pcall(function() return scenetree.findClassObjects("River") end)
    if not okList or type(rawNames) ~= "table" then rawNames = {} end

    local names = {}
    for _, name in pairs(rawNames) do names[#names + 1] = name end
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)

    local data = {
        segments = {}, riverCount = 0,
        rivers = {},
        minX = math.huge, minY = math.huge, minZ = math.huge,
        maxX = -math.huge, maxY = -math.huge, maxZ = -math.huge,
        heightSum = 0.0, heightSamples = 0,
        hash = 5381
    }

    local function includePoint(point)
        data.minX = math.min(data.minX, point.x)
        data.minY = math.min(data.minY, point.y)
        data.minZ = math.min(data.minZ, point.z)
        data.maxX = math.max(data.maxX, point.x)
        data.maxY = math.max(data.maxY, point.y)
        data.maxZ = math.max(data.maxZ, point.z)
        data.heightSum = data.heightSum + point.z
        data.heightSamples = data.heightSamples + 1
        data.hash = riverHashNumber(data.hash, point.x)
        data.hash = riverHashNumber(data.hash, point.y)
        data.hash = riverHashNumber(data.hash, point.z)
    end

    for _, name in ipairs(names) do
        local river = scenetree.findObject(name)
        if river and objectLooksEnabled(river) then
            local okCount, edgeCount = pcall(function()
                return river.getEdgeCount and river:getEdgeCount() or 0
            end)
            edgeCount = okCount and math.floor(tonumber(edgeCount) or 0) or 0
            if edgeCount >= 2 then
                local left, right = {}, {}
                for edgeIndex = 0, edgeCount - 1 do
                    left[edgeIndex + 1] = safeMethodVec3(river, "getTopLeftEdgePosition", edgeIndex)
                    right[edgeIndex + 1] = safeMethodVec3(river, "getTopRightEdgePosition", edgeIndex)
                end

                local before = #data.segments
                for edgeIndex = 1, edgeCount - 1 do
                    local a, b = left[edgeIndex], right[edgeIndex]
                    local c, d = left[edgeIndex + 1], right[edgeIndex + 1]
                    if a and b and c and d then
                        data.segments[#data.segments + 1] = {a = a, b = b, c = c, d = d}
                        includePoint(a); includePoint(b); includePoint(c); includePoint(d)
                    end
                end
                if #data.segments > before then
                    data.riverCount = data.riverCount + 1
                    data.rivers[#data.rivers + 1] = tostring(name) .. ":" .. tostring(edgeCount)
                    data.hash = riverHashNumber(data.hash, edgeCount)
                end
            end
        end
    end

    for _, b in ipairs(waterCache.blocks or {}) do
        local ax, ay = b.c, b.s
        local bx, by = -b.s, b.c
        local function corner(sx, sy)
            return {
                x = b.cx + ax * b.hx * sx + bx * b.hy * sy,
                y = b.cy + ay * b.hx * sx + by * b.hy * sy,
                z = b.h
            }
        end
        local p00, p10 = corner(-1, -1), corner(1, -1)
        local p01, p11 = corner(-1, 1), corner(1, 1)
        includePoint(p00); includePoint(p10); includePoint(p01); includePoint(p11)
        data.segments[#data.segments + 1] = { a = p00, b = p10, c = p01, d = p11 }
        data.blockCount = (data.blockCount or 0) + 1
        data.hash = riverHashNumber(data.hash, math.floor(b.cx * 100))
        data.hash = riverHashNumber(data.hash, math.floor(b.cy * 100))
        data.hash = riverHashNumber(data.hash, math.floor(b.h * 100))
        data.hash = riverHashNumber(data.hash, math.floor(b.hx * 100))
        data.hash = riverHashNumber(data.hash, math.floor(b.hy * 100))
        data.hash = riverHashNumber(data.hash, math.floor(b.c * 1000))
    end
    data.blockCount = data.blockCount or 0

    if #data.segments == 0 then return nil, "no River ribbons or WaterBlocks to bake" end
    data.referenceHeight = data.heightSum / math.max(data.heightSamples, 1)
    return data
end

local function rasterRiverTriangle(surface, resolution, originX, originY, worldSize, a, b, c)
    local scale = resolution / math.max(worldSize, 0.001)
    local ax, ay = (a.x - originX) * scale, (a.y - originY) * scale
    local bx, by = (b.x - originX) * scale, (b.y - originY) * scale
    local cx, cy = (c.x - originX) * scale, (c.y - originY) * scale
    local denom = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    if math.abs(denom) < 1e-8 then return end

    local minX = math.max(0, math.floor(math.min(ax, bx, cx)))
    local maxX = math.min(resolution - 1, math.ceil(math.max(ax, bx, cx)) - 1)
    local minY = math.max(0, math.floor(math.min(ay, by, cy)))
    local maxY = math.min(resolution - 1, math.ceil(math.max(ay, by, cy)) - 1)
    if minX > maxX or minY > maxY then return end

    for py = minY, maxY do
        local sampleY = py + 0.5
        for px = minX, maxX do
            local sampleX = px + 0.5
            local w0 = ((by - cy) * (sampleX - cx) + (cx - bx) * (sampleY - cy)) / denom
            local w1 = ((cy - ay) * (sampleX - cx) + (ax - cx) * (sampleY - cy)) / denom
            local w2 = 1.0 - w0 - w1
            if w0 >= -1e-5 and w1 >= -1e-5 and w2 >= -1e-5 then
                local z = w0 * a.z + w1 * b.z + w2 * c.z
                local index = py * resolution + px
                local previous = surface[index]
                if previous == nil or z > previous then surface[index] = z end
            end
        end
    end
end

local function applyRiverState(path, levelKey, signature, geometry, resolution, originX, originY, worldSize, edgePadding)
    local oldPath, oldAvailable = riverState.path, riverState.available
    riverState.available = true
    riverState.path = path
    riverState.levelKey = levelKey
    riverState.signature = signature
    riverState.originX = originX
    riverState.originY = originY
    riverState.worldSize = worldSize
    riverState.heightMin = geometry.minZ
    riverState.heightRange = math.max(geometry.maxZ - geometry.minZ, 0.001)
    riverState.referenceHeight = geometry.referenceHeight
    riverState.resolution = resolution
    riverState.edgePadding = edgePadding or 0.0
    riverState.riverCount = geometry.riverCount
    riverState.segmentCount = #geometry.segments
    riverState.lastFailure = ""
    if oldPath ~= path or oldAvailable ~= true then riverState.bindingDirty = true end
end

local function disableRiverState(levelKey, reason)
    local changed = riverState.available or riverState.path ~= fallbackTexture
    riverState.available = false
    riverState.path = fallbackTexture
    riverState.levelKey = levelKey or riverState.levelKey
    riverState.signature = ""
    riverState.riverCount = 0
    riverState.segmentCount = 0
    if changed then riverState.bindingDirty = true end
    if reason and reason ~= riverState.lastFailure then
        riverState.lastFailure = reason
        if type(log) == "function" then pcall(log, "I", "BeamRTCoherent", "River projection inactive: " .. tostring(reason)) end
    end
end

local function bakeWaterSurfaceMap(self)
    local levelKey = riverLevelKey()
    if value(self, "waterRivers", true) ~= true or value(self, "waterAutoDetect", true) ~= true then
        disableRiverState(levelKey, "disabled")
        return false
    end

    local geometry, geometryError = collectRiverRibbonGeometry()
    if not geometry then
        disableRiverState(levelKey, geometryError)
        return false
    end

    local requested = tonumber(value(self, "waterRiverBakeResolution", 1024.0)) or 1024.0
    local resolution = 128 * math.floor(math.max(256.0, math.min(2048.0, requested)) / 128.0 + 0.5)
    local edgePadding = math.max(tonumber(value(self, "waterRiverEdgePadding", 0.0)) or 0.0, 0.0)
    local boxPadding = math.max(2.0, edgePadding + 0.5)
    local spanX = math.max(geometry.maxX - geometry.minX, 0.01)
    local spanY = math.max(geometry.maxY - geometry.minY, 0.01)
    local worldSize = math.max(spanX, spanY) + boxPadding * 2.0
    local originX = (geometry.minX + geometry.maxX - worldSize) * 0.5
    local originY = (geometry.minY + geometry.maxY - worldSize) * 0.5
    local padCode = math.floor(edgePadding * 100.0 + 0.5)
    local signature = string.format("%s_%s_%d_%d_%08x", RIVER_BAKE_VERSION, levelKey, resolution, padCode, geometry.hash)
    local cacheDir = "settings/beamrt/coherent/river_masks"
    local cachePath = cacheDir .. "/" .. signature .. ".png"

    if riverState.available and riverState.signature == signature and riverState.path == cachePath then
        return false
    end

    if not riverFileExists(cachePath) then
        local okBake, bakeResult = pcall(function()
            local surface = {}
            for _, segment in ipairs(geometry.segments) do
                rasterRiverTriangle(surface, resolution, originX, originY, worldSize,
                                    segment.a, segment.b, segment.c)
                rasterRiverTriangle(surface, resolution, originX, originY, worldSize,
                                    segment.b, segment.d, segment.c)
            end

            local texelWorld = worldSize / resolution
            local growPixels = math.min(4, math.floor(edgePadding / math.max(texelWorld, 1e-5) + 0.5))
            if growPixels > 0 then
                local seeds = {}
                for index, z in pairs(surface) do seeds[#seeds + 1] = {index = index, z = z} end
                for _, seed in ipairs(seeds) do
                    local sx = seed.index % resolution
                    local sy = math.floor(seed.index / resolution)
                    for dy = -growPixels, growPixels do
                        for dx = -growPixels, growPixels do
                            if dx * dx + dy * dy <= growPixels * growPixels then
                                local px, py = sx + dx, sy + dy
                                if px >= 0 and py >= 0 and px < resolution and py < resolution then
                                    local index = py * resolution + px
                                    local previous = surface[index]
                                    if previous == nil or seed.z > previous then surface[index] = seed.z end
                                end
                            end
                        end
                    end
                end
            end

            pcall(function() if FS and FS.directoryCreate then FS:directoryCreate(cacheDir) end end)
            local bitmap = GBitmap()
            bitmap:init(resolution, resolution)
            bitmap:allocateBitmap(resolution, resolution, false, "GFXFormatR16")
            local heightRange = math.max(geometry.maxZ - geometry.minZ, 0.001)
            local covered = 0
            for y = 0, resolution - 1 do
                for x = 0, resolution - 1 do
                    local z = surface[y * resolution + x]
                    local encoded = 0
                    if z ~= nil then
                        local normalized = math.max(0.0, math.min(1.0, (z - geometry.minZ) / heightRange))
                        encoded = 1 + math.floor(normalized * 65534.0 + 0.5)
                        covered = covered + 1
                    end
                    bitmap:setTexel(x, y, encoded, encoded, encoded, 65535)
                end
            end
            if covered == 0 then return nil, "raster produced no covered texels" end
            if not bitmap:saveFile(cachePath) then return nil, "GBitmap saveFile failed" end
            return covered
        end)

        if not okBake or not bakeResult then
            local reason = okBake and "River bake returned no image" or ("River bake error: " .. tostring(bakeResult))
            disableRiverState(levelKey, reason)
            if type(log) == "function" then pcall(log, "W", "BeamRTCoherent", reason) end
            return false
        end
    end

    applyRiverState(cachePath, levelKey, signature, geometry, resolution, originX, originY, worldSize, edgePadding)
    if type(log) == "function" then
        pcall(log, "I", "BeamRTCoherent", string.format(
            "Water surface map ready: %d River(s) + %d WaterBlock(s), %d segment(s), %d^2 R16, %.3g m/texel; XY [%.3f, %.3f]..[%.3f, %.3f], Z %.3f..%.3f; map origin %.3f %.3f, size %.3f; %s",
            geometry.riverCount, geometry.blockCount, #geometry.segments, resolution, worldSize / resolution,
            geometry.minX, geometry.minY, geometry.maxX, geometry.maxY,
            geometry.minZ, geometry.maxZ, originX, originY, worldSize,
            table.concat(geometry.rivers, ", ")))
        if (geometry.maxZ - geometry.minZ) < 0.01 then
            pcall(log, "W", "BeamRTCoherent",
                "River top-edge API reported a nearly flat surface (<1 cm total Z range); projection is faithfully using those engine coordinates")
        end
    end
    return true
end

local function scanWaterVolumes(self)
    waterCache.planes = {}
    waterCache.blocks = {}

    if externalWaterSSRActive() then
        disableRiverState(riverLevelKey(), "owned by BeamRT Improved Water")
        return
    end

    local autoDetect = value(self, "waterAutoDetect", true)
    local padding = 0.35

    if autoDetect and scenetree and scenetree.findClassObjects and scenetree.findObject then
        local oceans = scenetree.findClassObjects('WaterPlane') or {}
        for _, name in pairs(oceans) do
            local obj = scenetree.findObject(name)
            if objectLooksEnabled(obj) then
                addWaterPlane(getObjectPosition(obj).z)
            end
        end

        local blocks = scenetree.findClassObjects('WaterBlock') or {}
        for _, name in pairs(blocks) do
            local obj = scenetree.findObject(name)
            if objectLooksEnabled(obj) then
                local ax, ay = getObjectAxisX2D(obj, -1, false)
                addWaterBlock(getObjectPosition(obj), getObjectScale(obj), ax, ay, padding)
            end
        end
    end

    bakeWaterSurfaceMap(self)
end

local function refreshWaterVolumesIfNeeded(self, force)
    local firstScan = waterCache.frame < 0
    if not firstScan and not force then return false end
    waterCache.frame = frame
    scanWaterVolumes(self)
    return true
end

local function isRiverBakeParameter(id)
    return id == "waterRiverBakeResolution" or id == "waterRiverEdgePadding"
end

local function isWaterGeometryParameter(id)
    return id == "waterAutoDetect"
        or id == "waterRivers"
end

local function sendWaterVolumes(pass, self)
    if not pass then return end

    local planeCount = math.min(#waterCache.planes, WATER_MAX_PLANES)

    pass:setShaderConst("$uWaterPlaneCount", planeCount)
    local riverEnabled = value(self, "waterRivers", true) == true and riverState.available
    pass:setShaderConst("$uRiverMaskEnable", riverEnabled and 1.0 or 0.0)
    pass:setShaderConst("$uRiverOriginXY", string.format("%.9g %.9g", riverState.originX, riverState.originY))
    pass:setShaderConst("$uRiverWorldSize", math.max(riverState.worldSize, 0.001))
    pass:setShaderConst("$uRiverHeightMin", riverState.heightMin)
    pass:setShaderConst("$uRiverHeightRange", math.max(riverState.heightRange, 0.001))
    pass:setShaderConst("$uRiverReferenceHeight", riverState.referenceHeight)
    pass:setShaderConst("$uRiverFlipY", value(self, "waterRiverFlipY", false) and 1.0 or 0.0)

    for i = 0, planeCount - 1 do
        local p = waterCache.planes[i + 1]
        pass:setShaderConst("$uWaterPlane" .. tostring(i), fmt4(p and p.height or 0, p and 1 or 0, 0, 0))
    end

    local maxPlaneH = -100000.0
    for i = 0, planeCount - 1 do
        local p = waterCache.planes[i + 1]
        if p and p.height and p.height > maxPlaneH then maxPlaneH = p.height end
    end
    pass:setShaderConst("$uPuddleWaterCull", maxPlaneH)
end

local terrainBlock = nil
local terrainCache = { frame = -999999, ox = 0.0, oy = 0.0, worldSize = 2048.0, available = false, level = nil }
local terrainTexPath = fallbackTexture
local terrainTexRevision = 0
local boundTerrainRevision = 0

local function fileExists(path)
    local ok, res = pcall(function() return FS and FS.fileExists and FS:fileExists(path) end)
    return ok and res == true
end

local TERRAIN_BAKE_VERSION = "v7"
local BUNDLED_TERRAIN_SUFFIX = "v6"
local TERRAIN_OUT = 512

local GM_PUDDLE = {
    ASPHALT          = { 1.00, 1.00, 0.90 },
    ASPHALT_WET      = { 1.00, 1.00, 0.90 },
    ASPHALT_OLD      = { 1.00, 0.95, 0.90 },
    ASPHALT_PREPPED  = { 1.00, 1.00, 0.90 },
    SLIPPERY         = { 1.00, 1.00, 0.90 },
    KICKPLATE        = { 1.00, 1.00, 0.90 },
    RUMBLE_STRIP     = { 0.80, 0.90, 0.85 },
    COBBLESTONE      = { 0.90, 0.90, 0.85 },
    METAL            = { 0.90, 1.00, 0.70 },
    METAL_TREAD      = { 0.85, 0.90, 0.70 },
    PLASTIC          = { 0.70, 0.90, 0.60 },
    WOOD             = { 0.35, 0.60, 0.55 },
    ROCK             = { 0.50, 0.70, 0.60 },
    DIRT             = { 0.50, 0.55, 0.78 },
    DIRT_DUSTY       = { 0.45, 0.50, 0.74 },
    DIRT_DUSTY_LOOSE = { 0.30, 0.45, 0.70 },
    GRAVEL           = { 0.35, 0.50, 0.62 },
    GRAVEL_WET       = { 0.55, 0.60, 0.72 },
    MUD              = { 0.80, 0.45, 0.92 },
    SAND             = { 0.00, 0.00, 0.00 },
    ICE              = { 0.30, 1.00, 0.25 },
    FRICTIONLESS     = { 0.30, 1.00, 0.25 },
    SNOW             = { 0.10, 0.50, 0.40 },
    BRANCHES_STRONG  = { 0.0, 0.0, 0.0 }, LEAVES_STRONG = { 0.0, 0.0, 0.0 },
    LEAVES_THIN      = { 0.0, 0.0, 0.0 }, SOFT_COLLISION_GENERAL = { 0.0, 0.0, 0.0 },
    SPIKE_STRIP      = { 0.0, 0.0, 0.0 }, SHOCK_ABSORBER = { 0.0, 0.0, 0.0 }, VOID = { 0.0, 0.0, 0.0 },
    GRASS            = { 0.06, 0.40, 0.50 },
}
local GM_DEFAULT = { 0.30, 0.70, 0.60 }

local NAME_TO_GM = {
    groundmodel_asphalt1 = "ASPHALT", grid = "ASPHALT", concrete = "ASPHALT", concrete2 = "ASPHALT",
    asphalt_wet2 = "ASPHALT_WET", asphalt_wet3 = "ASPHALT_WET", groundmodel_asphalt_old = "ASPHALT_OLD",
    rock_cliff = "ROCK", rocks_large = "ROCK", groundmodel_wood1 = "WOOD", groundmodel_wood2 = "WOOD",
    dirt_grass = "DIRT", derby_dirt = "DIRT", rockydirt = "DIRT_DUSTY", dirt_rocky = "DIRT_DUSTY",
    dirt_rocky_large = "DIRT_DUSTY", dirt_loose_dusty = "DIRT_DUSTY_LOOSE", dirt_sandy = "DIRT_DUSTY_LOOSE",
    dirt_loose = "GRAVEL", gravel_wet = "GRAVEL_WET", gravel_riverbed = "GRAVEL_WET",
    grass = "GRASS", grass2 = "GRASS", grass3 = "GRASS", grass4 = "GRASS", forest = "GRASS", forest_floor = "GRASS",
    beachsand = "SAND", sandtrap = "SAND",
}
for gm, _ in pairs(GM_PUDDLE) do NAME_TO_GM[string.lower(gm)] = gm end

local function puddleTriple(name, groundModel)
    if groundModel and groundModel ~= "" then
        local v = GM_PUDDLE[string.upper(groundModel)]
        if v then return v[1], v[2], v[3] end
    end
    name = string.lower(name or "")
    local gm = NAME_TO_GM[name]
    if gm and GM_PUDDLE[gm] then local v = GM_PUDDLE[gm]; return v[1], v[2], v[3] end
    if name:find("asphalt") or name:find("concrete") or name:find("road") or name:find("tarmac") or name:find("pavement") or name:find("cobble") then return 1.0, 1.0, 0.9 end
    if name:find("ice") then return 0.3, 1.0, 0.25 end
    if name:find("mud") then return 0.8, 0.45, 0.92 end
    if name:find("sand") then return 0.0, 0.0, 0.0 end
    if name:find("gravel") then return 0.35, 0.5, 0.62 end
    if name:find("grass") or name:find("forest") or name:find("leaves") or name:find("foliage") or name:find("moss") then return 0.06, 0.4, 0.5 end
    if name:find("rock") or name:find("cliff") or name:find("stone") then return 0.5, 0.7, 0.6 end
    if name:find("snow") then return 0.1, 0.5, 0.4 end
    if name:find("metal") then return 0.9, 1.0, 0.7 end
    if name:find("wood") then return 0.35, 0.6, 0.55 end
    if name:find("dirt") or name:find("ground") then return 0.5, 0.55, 0.78 end
    return GM_DEFAULT[1], GM_DEFAULT[2], GM_DEFAULT[3]
end

local function bakeTerrainRuntime(terrainFile, weightByIndex)
    if not terrainFile or terrainFile == "" then return nil end
    local level = terrainFile:match("/levels/([^/]+)/") or terrainFile:match("([^/\\]+)%.ter$") or "unknown"
    local cacheDir = "settings/beamrt/coherent/puddle_masks/"
    local lutTag = ""
    if weightByIndex then
        local hash = 5381
        for i = 0, 255 do
            local t = weightByIndex[i]
            if t == nil then break end
            hash = riverHashNumber(riverHashNumber(riverHashNumber(hash, t[1]), t[2]), t[3])
        end
        lutTag = string.format("_%08x", hash)
    end
    local cachePath = cacheDir .. level .. "_" .. TERRAIN_BAKE_VERSION .. lutTag .. ".png"
    if fileExists(cachePath) then return cachePath end

    local ok, result = pcall(function()
        local content = readFile(terrainFile)
        if type(content) ~= "string" or #content < 16 then
            log("W", "beamrt_coherent", "terrain: readFile failed/short (type " .. type(content) .. ", path " .. tostring(terrainFile) .. ")")
            return nil
        end
        local byte = string.byte

        local size = byte(content, 2) + byte(content, 3) * 256 + byte(content, 4) * 65536 + byte(content, 5) * 16777216
        if size < 16 or size > 16384 then log("W", "beamrt_coherent", "terrain: bad size " .. tostring(size)); return nil end

        local lmOff = 5 + size * size * 2
        local namesOff = lmOff + size * size
        if #content < namesOff + 4 then
            log("W", "beamrt_coherent", "terrain: file shorter than header implies (" .. #content .. " < " .. (namesOff + 4) .. ")")
            return nil
        end

        local lut = weightByIndex or {}
        if not weightByIndex then
            local cnt = byte(content, namesOff + 1) + byte(content, namesOff + 2) * 256 + byte(content, namesOff + 3) * 65536 + byte(content, namesOff + 4) * 16777216
            local off = namesOff + 4
            for i = 0, math.min(cnt, 255) - 1 do
                local ln = byte(content, off + 1)
                lut[i] = { puddleTriple(content:sub(off + 2, off + 1 + ln)) }
                off = off + 1 + ln
            end
        end

        log("I", "beamrt_coherent", "terrain: sample mix lut[0..4] = "
            .. tostring(lut[0] and lut[0][1]) .. ", " .. tostring(lut[1] and lut[1][1]) .. ", "
            .. tostring(lut[2] and lut[2][1]) .. ", " .. tostring(lut[3] and lut[3][1]) .. ", " .. tostring(lut[4] and lut[4][1]))

        local W = math.min(TERRAIN_OUT, size)
        W = 128 * math.max(1, math.floor(W / 128))
        local stride = size / W

        pcall(function() if FS and FS.directoryCreate then FS:directoryCreate(cacheDir) end end)

        local bmp = GBitmap()
        bmp:allocateBitmap(W, W, false, 'GFXFormatR16')
        local q1, q3 = 0.25 * stride, 0.75 * stride
        local maxIndex = size - 1
        for oy = 0, W - 1 do
            local rowA = math.min(math.floor(oy * stride + q1), maxIndex) * size + lmOff
            local rowB = math.min(math.floor(oy * stride + q3), maxIndex) * size + lmOff
            for ox = 0, W - 1 do
                local colA = math.min(math.floor(ox * stride + q1), maxIndex) + 1
                local colB = math.min(math.floor(ox * stride + q3), maxIndex) + 1
                local sum = (lut[byte(content, rowA + colA)] or GM_DEFAULT)[1]
                          + (lut[byte(content, rowA + colB)] or GM_DEFAULT)[1]
                          + (lut[byte(content, rowB + colA)] or GM_DEFAULT)[1]
                          + (lut[byte(content, rowB + colB)] or GM_DEFAULT)[1]
                local m = math.floor(sum * 0.25 * 65535 + 0.5)
                bmp:setTexel(ox, oy, m, m, m, 65535)
            end
        end

        if not bmp:saveFile(cachePath) then log("W", "beamrt_coherent", "terrain: GBitmap saveFile failed: " .. cachePath); return nil end
        log("I", "beamrt_coherent", "terrain: baked " .. cachePath .. " (" .. W .. "^2 from " .. size .. "^2)")
        return cachePath
    end)

    if ok and result then return result end
    if not ok then log("W", "beamrt_coherent", "terrain bake error: " .. tostring(result)) end
    return nil
end

local function findTerrainBlock()
    if not scenetree then return nil end
    local ok, list = pcall(function() return scenetree.findClassObjects and scenetree.findClassObjects("TerrainBlock") end)
    if not ok or not list or #list == 0 then return nil end

    local best, bestScore = nil, nil
    for _, name in ipairs(list) do
        local obj = scenetree.findObject(name)
        if obj and objectLooksEnabled(obj) then
            local nm = tostring(safeField(obj, "name", 0) or name)
            local sq = tonumber(safeField(obj, "squareSize", 0)) or 1.0
            local score = (nm == "theTerrain") and 1e9 or (1.0 / math.max(sq, 0.0001))
            if not bestScore or score > bestScore then best, bestScore = obj, score end
        end
    end
    return best
end

local function terrainWeightLUT(terr)
    local ok, mats = pcall(function() return terr.getMaterials and terr:getMaterials() end)
    if not ok or type(mats) ~= "table" or #mats == 0 then return nil end
    local lut = {}
    for i, m in ipairs(mats) do
        local nm, gm = nil, nil
        pcall(function() nm = m.getInternalName and m:getInternalName() end)
        pcall(function() gm = safeField(m, "groundmodelName", 0) end)
        lut[i - 1] = { puddleTriple(nm, gm) }
    end
    return lut
end

local function getMainTerrain()
    local ok, terr = pcall(function() return core_terrain and core_terrain.getTerrain and core_terrain.getTerrain() end)
    if ok and terr then return terr end
    return findTerrainBlock()
end

local function refreshTerrain(self)
    if (frame - terrainCache.frame) < 120 then return end
    terrainCache.frame = frame
    if not terrainBlock then terrainBlock = getMainTerrain() end
    if not terrainBlock then terrainCache.available = false; return end

    local pos = getObjectPosition(terrainBlock)
    terrainCache.ox = tonumber(pos.x) or 0.0
    terrainCache.oy = tonumber(pos.y) or 0.0

    local ws = nil
    local okws, v = pcall(function() return terrainBlock.getWorldBlockSize and terrainBlock:getWorldBlockSize() end)
    if okws and tonumber(v) and tonumber(v) > 1 then ws = tonumber(v) end
    if not ws then
        local sq = tonumber(safeField(terrainBlock, "squareSize", 0)) or 1.0
        local ts = tonumber(safeField(terrainBlock, "baseTexSize", 0)) or tonumber(value(self, "terrainGridSize", 2048.0)) or 2048.0
        ws = sq * ts
    end
    terrainCache.worldSize = math.max(ws, 1.0)

    local tf = tostring(safeField(terrainBlock, "terrainFile", 0) or "")
    terrainCache.level = tf:match("/levels/([^/]+)/")

    if terrainCache.bakedTf == tf then return end
    if terrainCache.failedTf == tf and frame < (terrainCache.retryAtFrame or 0) then return end
    terrainCache.available = false

    local resolvedPath = nil
    if value(self, "terrainRuntimeBake", true) == true then
        resolvedPath = bakeTerrainRuntime(tf, terrainWeightLUT(terrainBlock))
    end

    if not resolvedPath and terrainCache.level then
        local level = terrainCache.level
        local names = { level .. "_" .. BUNDLED_TERRAIN_SUFFIX, level }
        local lower = string.lower(level)
        if lower ~= level then
            names[#names + 1] = lower .. "_" .. BUNDLED_TERRAIN_SUFFIX
            names[#names + 1] = lower
        end
        for _, name in ipairs(names) do
            local candidate = "shaders/beamrt/coherent/terrain/" .. name .. ".png"
            if fileExists(candidate) then
                resolvedPath = candidate
                break
            end
        end
    end

    if resolvedPath then
        if resolvedPath ~= terrainTexPath then
            terrainTexPath = resolvedPath
            terrainTexRevision = terrainTexRevision + 1
        end
        terrainCache.available = true
        terrainCache.bakedTf = tf
        terrainCache.failedTf = nil
        terrainCache.retryAttempts = 0
    else
        local attempts = (terrainCache.failedTf == tf) and ((terrainCache.retryAttempts or 0) + 1) or 1
        terrainCache.failedTf = tf
        terrainCache.retryAttempts = attempts
        terrainCache.retryAtFrame = frame + math.min(120 * (2 ^ attempts), 3840)
    end
end

local SKY_MODEL_AMBIENT_SH9 = 2

local function migrateSkyModelIfNeeded(self)
    if not self then return end
    self.values = self.values or {}
    if (tonumber(self.values.skyModelVersion) or 0) >= SKY_MODEL_AMBIENT_SH9 then return end

    local hadLegacyProfile = self.values.skySaturation ~= nil
        or self.values.skyReflectionBrightness ~= nil
    if hadLegacyProfile then
        self.values.skySaturation = 1.0
        self.values.skyReflectionBrightness = 1.0
        if type(log) == "function" then
            log("I", "BeamRTCoherent",
                "Sky reflection rebased onto the engine ambient (ambientSH9); " ..
                "Brightness/Saturation reset to 1.0 from their legacy compensation values.")
        end
    end
    self.values.skyModelVersion = SKY_MODEL_AMBIENT_SH9
end

local function bootstrapPresetIfNeeded(self)
    if not self or self._presetBootstrapped then return end
    self._presetBootstrapped = true
    migrateSkyModelIfNeeded(self)
    self.values = self.values or {}
    local presetId = math.floor((tonumber(value(self, "qualityPreset", 2.0)) or 2.0) + 0.5)
    if presetId < 0 or presetId > 4 then presetId = 0 end
    self.values.qualityPreset = presetId
    self._presetObserved = presetId
end

local function setStaticConstants(pass, self)
    if not pass then return end

    pass:setShaderConst("$uAmount", value(self, "amount", 1.0))
    pass:setShaderConst("$uSamplingMode", value(self, "samplingMode", 1))
    pass:setShaderConst("$uReferenceTrace", value(self, "referenceTrace", false) and 1.0 or 0.0)
    pass:setShaderConst("$uRoughStability", value(self, "roughStability", true) and 1.0 or 0.0)
    pass:setShaderConst("$uIntensity", value(self, "intensity", 0.68))
    pass:setShaderConst("$uFogTransport", value(self, "fogTransport", 1.0))

    pass:setShaderConst("$uMaxDistance", value(self, "maxDistance", 85.0))
    pass:setShaderConst("$uTraceQuality", value(self, "traceQuality", 0.5))
    pass:setShaderConst("$uThicknessTexels", value(self, "thicknessTexels", 3.0))
    pass:setShaderConst("$uNormalBias", value(self, "normalBias", 0.0))
    pass:setShaderConst("$uRayStartOffset", value(self, "rayStartOffset", 0.0))

    pass:setShaderConst("$uRoughnessStart", 0.15 * (tonumber(value(self, "roughnessEnd", 0.78)) or 0.78))
    pass:setShaderConst("$uRoughnessEnd", value(self, "roughnessEnd", 0.78))
    pass:setShaderConst("$uRoughnessPower", value(self, "roughnessPower", 1.0))
    pass:setShaderConst("$uFresnelPower", value(self, "fresnelPower", 6.0))
    pass:setShaderConst("$uFresnelStrength", 1.0 - math.min(math.max(tonumber(value(self, "faceOnReflectance", 0.35)) or 0.35, 0.0), 1.0))
    pass:setShaderConst("$uFacingFade", value(self, "facingFade", 0.15))
    pass:setShaderConst("$uHighRoughnessSuppression", value(self, "highRoughnessSuppression", 0.45))

    pass:setShaderConst("$uEdgeFadePixels", value(self, "edgeFadePixels", 1.0))
    pass:setShaderConst("$uReflectionEdgeFade", value(self, "reflectionEdgeFade", 0.4))
    pass:setShaderConst("$uSkyFadeStart", value(self, "skyFadeStart", 0.985))
    pass:setShaderConst("$uSkyFadeEnd", value(self, "skyFadeEnd", 0.999))
    pass:setShaderConst("$uDistanceFadeStart", value(self, "distanceFadeStart", 1.0))
    pass:setShaderConst("$uDistanceFadeEnd", value(self, "distanceFadeEnd", 1100.0))

    pass:setShaderConst("$uBackfaceFade", value(self, "backfaceFade", 0.35))
    pass:setShaderConst("$uScreenJitter", value(self, "screenJitter", 0.20000000298))
    local jtr = tonumber(value(self, "jitterTemporalRate", 0.0)) or 0.0
    local stochOn = value(self, "stochasticSSR", false) == true
    if not stochOn and jtr <= 0.0 then jtr = 1.0 end
    pass:setShaderConst("$uJitterTemporalRate", value(self, "temporalStrength", 0) > 0 and jtr or 0.0)

    pass:setShaderConst("$uTemporalStrength", value(self, "temporalStrength", 0.0))
    pass:setShaderConst("$uTemporalClamp", value(self, "temporalClamp", 0.06))
    pass:setShaderConst("$uTemporalMotionRejection", value(self, "temporalMotionRejection", 0.08))
    pass:setShaderConst("$uTemporalMotionRejectionRot", value(self, "temporalMotionRejectionRot", 0.0))

    pass:setShaderConst("$uFireflySuppression", value(self, "fireflySuppression", 1.0))
    pass:setShaderConst("$uStochasticSSR", value(self, "stochasticSSR", false) and 1.0 or 0.0)
    pass:setShaderConst("$uStochasticReuse", value(self, "stochasticReuse", 0.65))
    pass:setShaderConst("$uGeometryReconstruction", value(self, "geometryReconstruction", true) and 1.0 or 0.0)
    pass:setShaderConst("$uAdaptiveDenoising", value(self, "adaptiveDenoising", true) and 1.0 or 0.0)
    pass:setShaderConst("$uOverhangFill", value(self, "overhangFill", false) and 1.0 or 0.0)
    pass:setShaderConst("$uOverhangBrightness", value(self, "overhangBrightness", 0.01))
    pass:setShaderConst("$uOverhangBounce", value(self, "overhangBounce", 0.6))
    pass:setShaderConst("$uRoughnessAdaptiveDenoise", value(self, "roughnessAdaptiveDenoise", 0.5))
    pass:setShaderConst("$uAdaptiveRoughStart", value(self, "adaptiveRoughStart", 0.15))
    pass:setShaderConst("$uAdaptiveRoughEnd", value(self, "adaptiveRoughEnd", 0.35))
    pass:setShaderConst("$uScreenMappingFromEngine", value(self, "screenMappingFromEngine", true) and 1.0 or 0.0)
    pass:setShaderConst("$uStochasticBias", value(self, "stochasticBias", 0.80))
    pass:setShaderConst("$uStochasticTemporalRate", value(self, "temporalStrength", 0) > 0 and value(self, "stochasticTemporalRate", 1.0) or 0.0)
    pass:setShaderConst("$uStochasticRayCount", value(self, "stochasticRayCount", 1))
    pass:setShaderConst("$uHiZMaxLevel", value(self, "referenceTrace", false) and 0 or value(self, "hiZMaxLevel", 4.0))
    pass:setShaderConst("$uFilteredColor", value(self, "filteredColor", false) and 1.0 or 0.0)
    pass:setShaderConst("$uColorMipScale", value(self, "colorMipScale", 0.35))

    pass:setShaderConst("$uWetness", value(self, "wetness", 0.0))
    pass:setShaderConst("$uWetUpDotStart", value(self, "wetUpDotStart", 0.65))
    pass:setShaderConst("$uWetUpDotEnd", value(self, "wetUpDotEnd", 0.92))
    pass:setShaderConst("$uWetRoughnessEnd", value(self, "wetRoughnessEnd", 0.95))

    local externalWater = externalWaterSSRActive()
    pass:setShaderConst("$uWaterSSR", (value(self, "waterSSR", true) and not externalWater) and 1.0 or 0.0)
    pass:setShaderConst("$uWaterShaderData", (value(self, "waterShaderData", true) and not externalWater) and 1.0 or 0.0)
    pass:setShaderConst("$uWaterSSRStrength", value(self, "waterSSRStrength", 1.25))
    pass:setShaderConst("$uWaterDeepColor", "0.015 0.045 0.05 1")
    pass:setShaderConst("$uWaterColorStrength", value(self, "waterColorStrength", 0.0))
    pass:setShaderConst("$uWaterSSRRoughness", value(self, "waterSSRRoughness", 0.025))
    pass:setShaderConst("$uWaterSSRFlatNormal", value(self, "waterSSRFlatNormal", 1.0))
    pass:setShaderConst("$uWaterAngleMin", value(self, "waterAngleMin", 0.24))
    pass:setShaderConst("$uWaterAngleStart", value(self, "waterAngleStart", 0.12))
    pass:setShaderConst("$uWaterAngleEnd", value(self, "waterAngleEnd", 0.82))
    pass:setShaderConst("$uWaterAnglePower", value(self, "waterAnglePower", 8.0))
    pass:setShaderConst("$uWaterPlaneFadeMeters", value(self, "waterPlaneFadeMeters", 0.0))
    pass:setShaderConst("$uWaterSurfaceDepthBias", value(self, "waterSurfaceDepthBias", 0.0))
    pass:setShaderConst("$uWaterFarTraceDistance", value(self, "waterFarTraceDistance", 1250.0))

    pass:setShaderConst("$uWaterWaveStrength", value(self, "waterWaveStrength", 0.11))
    pass:setShaderConst("$uWaterWaveScale", value(self, "waterWaveScale", 0.58))
    pass:setShaderConst("$uWaterWaveDistanceFade", value(self, "waterWaveDistanceFade", 140.0))
    pass:setShaderConst("$uWaterRippleSpeed", value(self, "waterRippleSpeed", 0.1))
    pass:setShaderConst("$uWaterOverallMag", 1.0)
    pass:setShaderConst("$uWaterRippleMag", "0.35 0.25 0.20 1.0")
    pass:setShaderConst("$uWaterWave0", "1.0 0.0 0.8 1.0")
    pass:setShaderConst("$uWaterWave1", "0.6 0.8 1.3 0.6")
    pass:setShaderConst("$uWaterWave2", "-0.8 0.6 2.1 0.35")

    pass:setShaderConst("$uResolveMode", value(self, "resolveMode", 0.532999992371))
    pass:setShaderConst("$uResolveRadius", value(self, "resolveRadius", 0.5))
    pass:setShaderConst("$uResolveDepthSigma", value(self, "resolveDepthSigma", 0.6))
    pass:setShaderConst("$uResolveNormalPower", value(self, "resolveNormalPower", 24.0))

    pass:setShaderConst("$uPuddleStrength", value(self, "puddleStrength", 0.0))
    pass:setShaderConst("$uPuddleScale", value(self, "puddleScale", 0.03))
    pass:setShaderConst("$uPuddleEdgeLo", value(self, "puddleEdgeLo", 0.45))
    pass:setShaderConst("$uPuddleEdgeHi", value(self, "puddleEdgeHi", 0.62))
    pass:setShaderConst("$uPuddleUpDotStart", value(self, "puddleUpDotStart", 0.55))
    pass:setShaderConst("$uPuddleUpDotEnd", value(self, "puddleUpDotEnd", 0.82))
    pass:setShaderConst("$uPuddleRoughness", value(self, "puddleRoughness", 0.02))
    pass:setShaderConst("$uPuddleRippleScale", value(self, "puddleRippleScale", 0.6))
    pass:setShaderConst("$uPuddleRippleSpeed", value(self, "puddleRippleSpeed", 0.02))
    pass:setShaderConst("$uPuddleRippleStrength", value(self, "puddleRippleStrength", 0.5))
    pass:setShaderConst("$uPuddleDarken", value(self, "puddleDarken", 0.12))
    pass:setShaderConst("$uPuddleFadeStart", value(self, "puddleFadeStart", 40.0))
    pass:setShaderConst("$uPuddleFadeEnd", value(self, "puddleFadeEnd", 90.0))
    pass:setShaderConst("$uPuddleReflectivity", value(self, "puddleReflectivity", 0.8))
    pass:setShaderConst("$uPuddleFresnel", value(self, "puddleFresnel", 0.7))
    pass:setShaderConst("$uPuddleEnvironmentStrength", value(self, "puddleEnvironmentStrength", 1.0))
    pass:setShaderConst("$uPuddleEdgeSoftness", value(self, "puddleEdgeSoftness", 0.35))

    pass:setShaderConst("$uWaterNoiseRipple", value(self, "waterNoiseRipple", 0.0))
    pass:setShaderConst("$uWaterNoiseRippleScale", value(self, "waterNoiseRippleScale", 1.0))

    local skyOn = value(self, "skyReflection", true) == true
    pass:setShaderConst("$uSkyReflectionFallback", skyOn and value(self, "skyReflectionFallback", 0.5) or 0.0)
    pass:setShaderConst("$uWaterSkyFallback", skyOn and value(self, "waterSkyFallback", 0.20) or 0.0)
    pass:setShaderConst("$uSkyBeforeTemporal", value(self, "skyBeforeTemporal", true) and 1.0 or 0.0)
    pass:setShaderConst("$uSkyLightExposure", value(self, "skyLightExposure", 0.5))
    pass:setShaderConst("$uSkyLightTint", value(self, "skyLightTint", 0.0))
    pass:setShaderConst("$uLightExposureScale", value(self, "lightExposureScale", 2.0))
    pass:setShaderConst("$uEngineAOOcclusion", value(self, "engineAOOcclusion", 1.0))
    pass:setShaderConst("$uEngineAOOpenLevel", value(self, "engineAOOpenLevel", 0.88))
    pass:setShaderConst("$uPixelRebuild", value(self, "pixelRebuild", true) == true and 1.0 or 0.0)
    pass:setShaderConst("$uTraceFootprintAA", value(self, "traceFootprintAA", true) == true and 1.0 or 0.0)
    pass:setShaderConst("$uSurfaceDetail", value(self, "surfaceDetail", 1.0))
    pass:setShaderConst("$uHdrComposite", value(self, "hdrComposite", true) == true and 1.0 or 0.0)
    pass:setShaderConst("$uVirtualReprojection", value(self, "virtualReprojection", true) == true and 1.0 or 0.0)
    pass:setShaderConst("$uVirtualRoughStart", value(self, "virtualRoughStart", 0.15))
    pass:setShaderConst("$uVirtualRoughEnd", value(self, "virtualRoughEnd", 0.40))
    pass:setShaderConst("$uVirtualMotionScale", value(self, "virtualMotionScale", 0.20))
    pass:setShaderConst("$uVirtualParallaxScale", value(self, "virtualParallaxScale", 0.30))
    pass:setShaderConst("$uSkyReflectionBrightness", value(self, "skyReflectionBrightness", 1.0))
    pass:setShaderConst("$uSkySaturation", value(self, "skySaturation", 1.0))
    pass:setShaderConst("$uSkyScreenSpace", value(self, "skyScreenSpace", true) and 1.0 or 0.0)
    pass:setShaderConst("$uSkyScreenBrightness", value(self, "skyScreenBrightness", 0.5))
    pass:setShaderConst("$uSkyScreenMinDistance", value(self, "skyScreenMinDistance", 400.0))
    pass:setShaderConst("$uSkyDirectionality", value(self, "skyDirectionality", 0.5))
    pass:setShaderConst("$uSkySunBoost", value(self, "skySunBoost", 1.0))

    local view = value(self, "debugView", 0.0)
    if view >= 44 and (pass == temporalPassA or pass == temporalPassB) then view = 0 end
    pass:setShaderConst("$uDebugView", view)
end

local lightInfoWarmup = 4
local lightInfoBound = false

local engineInputs = {
    sun = { want = false, warmup = 4, bound = false },
    sss = { want = false, warmup = 4, bound = false },
    ao = { want = false, warmup = 4, bound = false },
    signature = "",
    pollFrame = -1000,
}

function engineInputs.const()
    return (engineInputs.sun.bound and "1" or "0") .. " " ..
        (engineInputs.ao.bound and "1" or "0") .. " " ..
        (engineInputs.sss.bound and "1" or "0") .. " 0"
end

local velocityWarmup = 4
local temporalCameraSlot5 = nil
local velocityBound = false

local cameraHistoryWarmup = 2
local cameraHistoryReady = false

local temporalVelocityBinding = fallbackTexture
local cameraHistoryBound = false

local function setFrameConstants(pass, self)
    if not pass then return end
    local unified = applyVariant.unified
    local isPrepare = pass == unified.pass
    local unifiedSignal = unified.ready and not (pass == applyPass and temporalDebugEnabled)
    pass:setShaderConst("$uUnifiedTemporal", unifiedSignal and 1.0 or 0.0)
    pass:setShaderConst("$uHistoryInterleave", ((unifiedSignal or isPrepare) and
        value(self, "nativeTemporal", true) == true and value(self, "interleavedHistory", true) == true) and 1.0 or 0.0)
    pass:setShaderConst("$uReusePrefiltered", reuseReady and (pass == temporalPassA or pass == temporalPassB) and 1.0 or 0.0)
    pass:setShaderConst("$uReuseGuides", reuseReady and (isPrepare or
        (not unified.ready and (pass == temporalPassA or pass == temporalPassB or pass == temporalDebugPass))) and 1.0 or 0.0)
    if not pass then return end

    pass:setShaderConst("$uFrame", value(self, "temporalStrength", 0) > 0 and frame or 0)
    pass:setShaderConst("$uTime", elapsedTime)
    local isRoughTrace = roughTracePass ~= nil and pass == roughTracePass
    pass:setShaderConst("$uResolution", isRoughTrace and resolutionString(getRoughScale(self)) or getSSRResolution(self))
    local traceClass = 0.0
    if isRoughTrace then
        traceClass = 2.0
    elseif pass == tracePass and roughReady then
        traceClass = 1.0
    end
    pass:setShaderConst("$uTraceClass", traceClass)
    local _, mainHeight = getScreenSize()
    pass:setShaderConst("$uThicknessResolutionY", math.floor(mainHeight * getRenderScale(self) + 0.5))
    pass:setShaderConst("$uAdaptiveResolution", (roughReady and pass == reusePass) and 1.0 or 0.0)

    local taaBus = rawget(_G, "BEAMRT_COH_TAA_JITTER")
    local cameraJitterActive = taaBus ~= nil and taaBus.enabled == true

    local jitterAllowed = value(self, "traceSubpixelJitter", false) == true
        and value(self, "temporalStrength", 0.0) > 0.0001
        and value(self, "nativeTemporal", true) == true
    local function jitterFor(scale)
        if not jitterAllowed or scale >= 0.999 then return "0 0" end
        local w, h = getScreenSize()
        local offsets = scale>=0.5 and bayer2x2JitterSequence or
            (scale>=0.25 and bayer4x4JitterSequence or applyVariant.unified.jitter8)
        local o = offsets[(frame % #offsets) + 1]
        local tw = math.max(math.floor(w * scale + 0.5), 1)
        local th = math.max(math.floor(h * scale + 0.5), 1)
        return tostring(o[1] / tw) .. " " .. tostring(o[2] / th)
    end
    local roughJitter = roughEnabled and jitterFor(getRoughScale(self)) or "0 0"
    pass:setShaderConst("$uTraceJitterUV", isRoughTrace and roughJitter or jitterFor(getRenderScale(self)))
    pass:setShaderConst("$uRoughTraceJitterUV", roughJitter)

    local camJitterConst = "0 0"
    if cameraJitterActive
        and value(self, "temporalStrength", 0.0) > 0.0001
        and value(self, "nativeTemporal", true) == true then
        local sx = tonumber(taaBus.contentShiftUVX) or 0.0
        local sy = tonumber(taaBus.contentShiftUVY) or 0.0
        camJitterConst = tostring(-sx) .. " " .. tostring(-sy)
    end
    pass:setShaderConst("$uCameraJitterUV", camJitterConst)
    pass:setShaderConst("$uWaterShaderDataAvailable", hiZPasses[1] and 1.0 or 0.0)
    pass:setShaderConst("$uLightInfoValid", lightInfoBound and 1.0 or 0.0)
    pass:setShaderConst("$uEngineInputs", engineInputs.const())
    pass:setShaderConst("$uVelocityValid", velocityBound and 1.0 or 0.0)
    pass:setShaderConst("$uCameraHistoryValid", cameraHistoryBound and 1.0 or 0.0)
    pass:setShaderConst("$uMotionOptions",
        (value(self, "playerVehicleMotion", true) == true and "1" or "0") .. " " ..
        ((value(self, "playerVehicleMotion", true) == true and
          value(self, "vehicleDisocclusion", true) == true) and "1" or "0") .. " 0 0")

    local prev = reprojectionPrevious
    if prev then
        pass:setShaderConst("$uPrevEyePosWorld", fmt3(prev.pos))
        pass:setShaderConst("$uPrevCameraRight", fmt3(prev.right))
        pass:setShaderConst("$uPrevCameraForward", fmt3(prev.forward))
        pass:setShaderConst("$uPrevCameraUp", fmt3(prev.up))
        pass:setShaderConst("$uPrevTanHalfFovX", prev.tanHalfX)
        pass:setShaderConst("$uPrevTanHalfFovY", prev.tanHalfY)
    else
        pass:setShaderConst("$uPrevEyePosWorld", "0 0 0")
        pass:setShaderConst("$uPrevCameraRight", "1 0 0")
        pass:setShaderConst("$uPrevCameraForward", "0 1 0")
        pass:setShaderConst("$uPrevCameraUp", "0 0 1")
        pass:setShaderConst("$uPrevTanHalfFovX", 1.0)
        pass:setShaderConst("$uPrevTanHalfFovY", 1.0)
    end
    local temporalEnabled = value(self, "temporalStrength", 0.0) > 0.0001
    local cur = currentCameraForProjection
    if cur then
        local vw, vh = getScreenSize()
        local tanY = math.tan(math.rad(math.max(5.0, math.min(170.0, cur.fov or 65.0))) * 0.5)
        local tanX = tanY * (vw / math.max(vh, 1))

        local f, r, u = cur.forward, cur.right, cur.up
        local lead = 1.0
        local last = lastCameraForProjection
        if last and lead > 0.0 then
            local function lerpOut(c, l)
                return { x = c.x + (c.x - l.x) * lead,
                         y = c.y + (c.y - l.y) * lead,
                         z = c.z + (c.z - l.z) * lead }
            end
            local function norm3(v)
                local m = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
                if m < 1e-9 then return nil end
                return { x = v.x / m, y = v.y / m, z = v.z / m }
            end
            local ef = norm3(lerpOut(cur.forward, last.forward))
            local er = norm3(lerpOut(cur.right, last.right))
            if ef and er then
                local d = er.x * ef.x + er.y * ef.y + er.z * ef.z
                er = norm3({ x = er.x - ef.x * d, y = er.y - ef.y * d, z = er.z - ef.z * d })
                if er then
                    local eu = {
                        x = er.y * ef.z - er.z * ef.y,
                        y = er.z * ef.x - er.x * ef.z,
                        z = er.x * ef.y - er.y * ef.x,
                    }
                    if (eu.x * cur.up.x + eu.y * cur.up.y + eu.z * cur.up.z) < 0.0 then
                        eu = { x = -eu.x, y = -eu.y, z = -eu.z }
                    end
                    f, r, u = ef, er, eu
                end
            end
        end

        pass:setShaderConst("$uCameraRight", fmt3(r))
        pass:setShaderConst("$uCameraUp", fmt3(u))
        pass:setShaderConst("$uCameraForward", fmt3(f))
        pass:setShaderConst("$uTanHalfFovXCur", tanX)
        pass:setShaderConst("$uTanHalfFovYCur", tanY)
    else
        pass:setShaderConst("$uCameraRight", "1 0 0")
        pass:setShaderConst("$uCameraUp", "0 0 1")
        pass:setShaderConst("$uCameraForward", "0 1 0")
        pass:setShaderConst("$uTanHalfFovXCur", 1.0)
        pass:setShaderConst("$uTanHalfFovYCur", 1.0)
    end
    pass:setShaderConst("$uProjectionValid", cur and 1.0 or 0.0)

    pass:setShaderConst("$uHistoryGeometryValid", geometryReady and 1.0 or 0.0)
    pass:setShaderConst("$uTemporalHistoryValid", (temporalEnabled and temporalHistoryWarmup <= 0) and 1.0 or 0.0)
    pass:setShaderConst("$uTemporalReprojectionValid", reprojectionValid and 1.0 or 0.0)

    refreshTerrain(self)
    pass:setShaderConst("$uTerrainOriginXY", string.format("%.7g %.7g", terrainCache.ox, terrainCache.oy))
    pass:setShaderConst("$uTerrainWorldSize", terrainCache.worldSize)
    local terrainOn = (value(self, "terrainMaskEnable", true) == true) and terrainCache.available
    pass:setShaderConst("$uTerrainMaskEnable", terrainOn and 1.0 or 0.0)
    pass:setShaderConst("$uTerrainMaskStrength", value(self, "terrainMaskStrength", 1.0))
    pass:setShaderConst("$uTerrainFlipY", value(self, "terrainFlipY", false) and 1.0 or 0.0)
end

local function sendWaterVolumesToAll(self)
    forEachPass(sendWaterVolumes, self)
end

local function setStaticConstantsToAll(self)
    forEachPass(setStaticConstants, self)
end

local function setFrameConstantsToAll(self)
    forEachPass(setFrameConstants, self, true)
end

local function pushShaderConstants(self, forceStatic, forceWaterRefresh)
    if not tracePass then return end

    if forceStatic or staticConstantsDirty or (frame - lastStaticSignatureCheckFrame) >= 30 then
        local signature = buildStaticSignature(self)
        lastStaticSignatureCheckFrame = frame
        if signature ~= lastStaticSignature then
            staticConstantsDirty = true
            lastStaticSignature = signature
        end
    end

    local waterRefreshed = refreshWaterVolumesIfNeeded(self, forceWaterRefresh)

    if forceStatic or staticConstantsDirty then
        setStaticConstantsToAll(self)
        sendWaterVolumesToAll(self)
        staticConstantsDirty = false
        waterRefreshed = false
    end

    if waterRefreshed then
        sendWaterVolumesToAll(self)
    end

    setFrameConstantsToAll(self)
end

local function shaderForPass(shaderPass)
    local index = math.floor(shaderPass + 0.5)
    local name = applyVariant.shaderPrefix .. tostring(index)
    local shader = scenetree.findObject(name)
    if not shader then
        shader = createObject("ShaderData")
        shader.DXVertexShaderFile = "shaders/beamrt/coherent/beamrt_coherent_v.hlsl"
        shader.DXPixelShaderFile = "shaders/beamrt/coherent/beamrt_coherent_pass" .. tostring(index) .. "_p.hlsl"
        shader.defines = applyVariant.shaderDefines
        shader.pixVersion = 5.0
        registerOwned(shader, name)
    end
    return name
end

local function isTraceVariant(shaderPass)
    return shaderPass == 0 or shaderPass == 12 or shaderPass == 13 or shaderPass == 14
end

local function createPostEffect(name, shaderPass, renderPriority, sourceTexture, targetTexture, targetScale, auxTexture, clearMode, targetFormat)
    local effect = scenetree.findObject(name)
    local needsRegister = false

    if not effect then
        effect = createObject("PostEffect")
        needsRegister = true
    end

    local depthPass = applyVariant.depth.owns(name)
    effect:setField("renderTime", 0, depthPass and applyVariant.depth.time or applyVariant.stageTime)
    effect:setField("renderBin", 0, depthPass and applyVariant.depth.bin or applyVariant.stageBin)
    if depthPass then
        renderPriority = renderPriority - renderPriorityBase + applyVariant.depth.priorityBase
    end
    effect:setField("shader", 0, shaderForPass(shaderPass))
    effect:setField("stateBlock", 0, stateBlockName)

    local sourceBinding = (sourceTexture and sourceTexture ~= "") and sourceTexture or fallbackTexture
    local auxBinding = (auxTexture and auxTexture ~= "") and auxTexture or fallbackTexture
    effect:setField("texture", 0, sourceBinding)
    effect:setField("texture", 1, "#prepass[RT0]")
    effect:setField("texture", 2, "#prepass[Depth]")
    effect:setField("texture", 3, auxBinding)
    effect:setField("texture", 4, fallbackTexture)
    effect:setField("texture", 5, terrainTexPath)

    if shaderPass == 5 or shaderPass == 7 or shaderPass == 9 or shaderPass == 15 then
        for slot = 1, 5 do effect:setField("texture", slot, fallbackTexture) end
    elseif shaderPass == 11 then
        effect:setField("texture", 2, "#BeamRTCoherentHiZ0")
        for slot = 3, 5 do effect:setField("texture", slot, fallbackTexture) end
    elseif shaderPass == 8 then
        effect:setField("texture", 1, "#BeamRTCoherentHiZ4")
        effect:setField("texture", 2, "#BeamRTCoherentHiZ6")
        for slot = 3, 5 do effect:setField("texture", slot, fallbackTexture) end
    elseif isTraceVariant(shaderPass) or shaderPass == 2 or shaderPass == 17 or shaderPass == 10 then
        effect:setField("texture", 2, (shaderPass == 2 or shaderPass == 17) and "#BeamRTCoherentCurrent" or "#BeamRTCoherentHiZ0")
        if isTraceVariant(shaderPass) then effect:setField("texture", 4, "#BeamRTCoherentHiZPacked") end
        if shaderPass == 2 or shaderPass == 17 then
            effect:setField("texture", 3, fallbackTexture)
            effect:setField("texture", 5, fallbackTexture)
        end
        if shaderPass == 10 then
            for slot = 3, 5 do effect:setField("texture", slot, fallbackTexture) end
        end
    elseif shaderPass == 3 or shaderPass == 16 or shaderPass == 18 then
        effect:setField("texture", 3, fallbackTexture)
        effect:setField("texture", 4, "#BeamRTCoherentHiZ0")
    end

    if targetTexture then
        effect:setField("target", 0, targetTexture)
        effect:setField("targetFormat", 0, targetFormat or "GFXFormatR16G16B16A16F")
        effect:setField("targetClear", 0, clearMode or "PFXTargetClear_None")
    else
        effect:setField("target", 0, "")
    end

    effect:setField("targetScale", 0, targetScale or "1 1")

    effect.allowReflectPass = false
    effect.renderPriority = renderPriority
    effect.isEnabled = true

    if needsRegister then
        registerOwned(effect, name)
    end

    effect:setShaderConst("$uPass", isTraceVariant(shaderPass) and 0.0 or shaderPass)

    return effect
end

local function riverTextureBinding()
    return riverState.available and riverState.path or fallbackTexture
end

local function lightInfoReady()
    return lightInfoWarmup <= 0
end

local function lightInfoBinding()
    return lightInfoReady() and "#lightinfo" or fallbackTexture
end

local function velocityRequested(self)
    return value(self, "engineVelocity", false) == true
end

local function velocityBinding(self)
    return (velocityWarmup <= 0 and velocityRequested(self)) and "#VelocityBuffer" or fallbackTexture
end

local function configureHiZ0Bindings(pass)
    if not pass then return end
    pass:setField("texture", 0, "$backBuffer")
    pass:setField("texture", 1, "#prepass[RT0]")
    pass:setField("texture", 2, "#prepass[Depth]")
    pass:setField("texture", 3, riverTextureBinding())
    pass:setField("texture", 4, lightInfoBinding())
    pass:setField("texture", 5, fallbackTexture)
    if engineInputs.ao.bound then pass:setField("texture", 1, "#gtaoOutput") end
    if engineInputs.sun.bound then pass:setField("texture", 4, "#sunShadowMask") end
    if engineInputs.sss.bound then pass:setField("texture", 5, "#sssMask") end
end

local function engineFeatureEnabled(objectName)
    local obj = scenetree.findObject(objectName)
    if not obj then return false end
    local ok, enabled = pcall(function() return obj:isEnabled() end)
    return ok and enabled ~= false
end

local function shadowsEnabled()
    if not (settings and settings.getValue) then return true end
    local ok, quality = pcall(settings.getValue, "GraphicShadowsQuality")
    if not ok or quality == nil then return true end
    return quality ~= "Disabled" and quality ~= 0 and quality ~= "0"
end

local function updateEngineInputs(self)
    if frame - engineInputs.pollFrame >= 30 or frame < engineInputs.pollFrame then
        engineInputs.pollFrame = frame
        local sunWanted = value(self, "engineSunShadow", true) == true and shadowsEnabled()
        local want = {
            sun = sunWanted,
            sss = sunWanted and engineFeatureEnabled("ScreenSpaceShadowsPostFx"),
            ao = (tonumber(value(self, "engineAOOcclusion", 1.0)) or 0.0) > 0.0001 and
                engineFeatureEnabled("SSAOPostFx"),
        }
        for key, wanted in pairs(want) do
            local input = engineInputs[key]
            if wanted and not input.want then input.warmup = 4 end
            input.want = wanted
        end
    end
    for _, key in ipairs({ "sun", "sss", "ao" }) do
        local input = engineInputs[key]
        if input.want and input.warmup > 0 then input.warmup = input.warmup - 1 end
        input.bound = input.want and input.warmup <= 0
    end
    local signature = engineInputs.const()
    if signature ~= engineInputs.signature and hiZPasses[1] then
        engineInputs.signature = signature
        riverState.bindingDirty = true
        staticConstantsDirty = true
    end
end

local function recreateHiZ0ForRiver(self)
    if not riverState.bindingDirty or not hiZPasses[1] then return end

    local old = hiZPasses[1]
    pcall(function() old:disable() end)
    pcall(function() old:delete() end)
    hiZPasses[1] = createPostEffect(basePostEffectName .. "HiZ0Pass", 6.0,
        renderPriorityBase + 1.0, "$backBuffer", "#BeamRTCoherentHiZ0", "1 1", riverTextureBinding(),
        "PFXTargetClear_None")
    configureHiZ0Bindings(hiZPasses[1])
    setStaticConstants(hiZPasses[1], self)
    sendWaterVolumes(hiZPasses[1], self)
    setFrameConstants(hiZPasses[1], self)
    hiZPasses[1]:enable()
    riverState.bindingDirty = false
end

local function traceVariantFor(self)
    local debugMode = math.floor((tonumber(value(self, "debugView", 0.0)) or 0.0) + 0.5)
    local oneRay = value(self, "singleRaySpecialization", true) == true
        and debugMode < 50
        and debugMode ~= 31 and debugMode ~= 32 and debugMode ~= 35 and debugMode ~= 38 and debugMode ~= 43
        and (value(self, "stochasticSSR", true) ~= true or
            math.floor(value(self, "stochasticRayCount", 1) + 0.5) <= 1)
    local variant = oneRay and 12 or 0
    if value(self, "overhangFill", false) == true then
        variant = oneRay and 13 or 14
    end
    return variant
end

local function roughScaleString(self)
    local scale = getRoughScale(self)
    return tostring(scale) .. " " .. tostring(scale)
end

local function buildTracePass(self, name, variant, priority, target, scaleString)
    local old = scenetree.findObject(name)
    if old then
        pcall(function() old:disable() end)
        pcall(function() old:delete() end)
    end
    local pass = createPostEffect(name, variant, priority, "$backBuffer", target, scaleString,
        fallbackTexture, "PFXTargetClear_None")
    pass:setField("texture", 3, value(self, "filteredColor", false) == true
        and "#BeamRTCoherentColorMip4" or fallbackTexture)
    return pass
end

function applyVariant.recreate(self, variant)
    local name = basePostEffectName .. "ApplyPass"
    local old = scenetree.findObject(name)
    if old then
        pcall(function() old:disable() end)
        pcall(function() old:delete() end)
    end
    applyPass = createPostEffect(name, variant, renderPriorityBase - 0.3, "$backBuffer", nil, nil,
        "#BeamRTCoherentHistoryA", nil)
    applyPass:setField("texture", 4, "#BeamRTCoherentHiZ0")
    applyVariant.current = variant
    setStaticConstants(applyPass, self)
    sendWaterVolumes(applyPass, self)
    setFrameConstants(applyPass, self)
    cachedDebugRoute = nil
end

local function recreateTracePass(self, variant)
    tracePass = buildTracePass(self, basePostEffectName .. "TracePass", variant, renderPriorityBase,
        "#BeamRTCoherentCurrent", getRenderScaleString(self))
    setStaticConstants(tracePass, self)
    sendWaterVolumes(tracePass, self)
    setFrameConstants(tracePass, self)
    tracePass:enable()
    if roughTracePass then
        roughTracePass = buildTracePass(self, basePostEffectName .. "RoughTracePass", variant,
            renderPriorityBase + 0.01, "#BeamRTCoherentRough", roughScaleString(self))
        setStaticConstants(roughTracePass, self)
        sendWaterVolumes(roughTracePass, self)
        setFrameConstants(roughTracePass, self)
        if roughEnabled then roughTracePass:enable() else roughTracePass:disable() end
        roughStartFrame, roughReady = frame, false
    end
    traceShaderVariant = variant
    temporalHistoryWarmup = math.max(temporalHistoryWarmup, 2)
end

local function updateRenderScale(self)
    local scaleString = getRenderScaleString(self)
    local nativeTemporal = value(self, "nativeTemporal", true) == true
    local interleaved = nativeTemporal and value(self, "interleavedHistory", true) == true
    local screenWidth, screenHeight = getScreenSize()
    if cachedRenderScaleString == scaleString and cachedNativeTemporal == nativeTemporal
        and applyVariant.unified.layoutInterleaved == interleaved
        and cachedScreenWidth == screenWidth and cachedScreenHeight == screenHeight then return end
    if cachedScreenWidth ~= screenWidth or cachedScreenHeight ~= screenHeight then
        temporalHistoryWarmup = math.max(temporalHistoryWarmup, 2)
    end
    geometryStartFrame = frame
    geometryReady = false
    cachedScreenWidth = screenWidth
    cachedScreenHeight = screenHeight

    if tracePass then tracePass:setField("targetScale", 0, scaleString) end
    if roughTracePass then roughTracePass:setField("targetScale", 0, roughScaleString(self)) end
    if reusePass then reusePass:disable() end
    reuseEnabled, reuseReady, reuseStartFrame = false, false, nil
    if roughTracePass then roughTracePass:disable() end
    roughEnabled, roughReady, roughStartFrame = false, false, nil

    local temporalScale = nativeTemporal and (interleaved and "0.5 1" or "1 1") or scaleString
    local historySize = interleaved and (tostring(math.ceil(screenWidth * 0.5)) .. " " .. tostring(screenHeight)) or "0 0"
    for _, pass in ipairs({temporalPassA, temporalPassB, temporalDebugPass, applyVariant.unified.pass}) do
        if pass then pass:setField("targetSize", 0, historySize) end
    end
    if applyVariant.unified.pass then
        applyVariant.unified.pass:setField("targetScale", 0, interleaved and "0.5 1" or "1 1")
    end
    applyVariant.unified.ready, applyVariant.unified.startFrame = false, frame
    applyVariant.unified.layoutInterleaved = interleaved
    local historyFormat = "GFXFormatR32G32B32A32F"
    if temporalPassA then temporalPassA:setField("targetFormat", 0, historyFormat) end
    if temporalPassB then temporalPassB:setField("targetFormat", 0, historyFormat) end
    if temporalPassA then temporalPassA:setField("targetScale", 0, temporalScale) end
    if temporalPassB then temporalPassB:setField("targetScale", 0, temporalScale) end
    if temporalDebugPass then temporalDebugPass:setField("targetScale", 0, temporalScale) end
    temporalTargetAReady = false
    temporalTargetBReady = false
    temporalScheduledTarget = nil
    temporalScheduledFrame = -1

    cachedRenderScaleString = scaleString
    cachedNativeTemporal = nativeTemporal
end

local function setPassSkip(pass, skipped)
    if pass then
        pass:setField("skip", 0, skipped and "1" or "0")
    end
end

local function routeTemporalPingPong(useTemporal)
    temporalDrawingPass = nil
    if not temporalPassA or not temporalPassB then
        lastTemporalOutput = "#BeamRTCoherentCurrent"
        return lastTemporalOutput
    end

    if not useTemporal then
        setPassSkip(temporalPassA, false)
        setPassSkip(temporalPassB, false)
        temporalPassA:disable()
        temporalPassB:disable()
        temporalScheduledTarget = nil
        temporalScheduledFrame = -1
        temporalTargetAReady = false
        temporalTargetBReady = false
        lastTemporalOutput = "#BeamRTCoherentCurrent"
        return lastTemporalOutput
    end

    temporalPassA:enable()
    temporalPassB:enable()

    if frame <= 0 then
        setPassSkip(temporalPassA, true)
        setPassSkip(temporalPassB, true)
        lastTemporalOutput = "#BeamRTCoherentCurrent"
        return lastTemporalOutput
    end

    if temporalScheduledTarget ~= nil and frame > temporalScheduledFrame then
        if temporalScheduledTarget == "A" then
            temporalTargetAReady = true
        else
            temporalTargetBReady = true
        end
    end

    local writeA = (frame % 2) == 0
    local activePass = writeA and temporalPassA or temporalPassB
    local inactivePass = writeA and temporalPassB or temporalPassA
    local historyReady = writeA and temporalTargetBReady or temporalTargetAReady
    local historyTexture = writeA and "#BeamRTCoherentHistoryB" or "#BeamRTCoherentHistoryA"

    activePass:setField("texture", 2, applyVariant.unified.ready and "#BeamRTCoherentNativeCurrent" or (reuseReady and "#BeamRTCoherentReused" or "#BeamRTCoherentCurrent"))
    activePass:setField("texture", 4, temporalVelocityBinding)
    local metadataReady = geometryReady and historyReady
    local slot5 = temporalCameraSlot5 or (metadataReady and
        (writeA and "#BeamRTCoherentGeometryB" or "#BeamRTCoherentGeometryA") or fallbackTexture)
    activePass:setField("texture", 5, slot5)
    if geometryEnabled then
        setPassSkip(geometryPassA, not writeA)
        setPassSkip(geometryPassB, writeA)
    end
    activePass:setField("texture", 3, historyReady and historyTexture or fallbackTexture)
    if temporalDebugEnabled then
        temporalDebugPass:setField("texture", 2, applyVariant.unified.ready and "#BeamRTCoherentNativeCurrent" or (reuseReady and "#BeamRTCoherentReused" or "#BeamRTCoherentCurrent"))
        temporalDebugPass:setField("texture", 3, historyReady and historyTexture or fallbackTexture)
        temporalDebugPass:setField("texture", 4, temporalVelocityBinding)
        temporalDebugPass:setField("texture", 5, slot5)
        setPassSkip(temporalDebugPass, false)
    end
    setPassSkip(activePass, false)
    setPassSkip(inactivePass, true)
    temporalDrawingPass = activePass

    lastTemporalOutput = writeA and "#BeamRTCoherentHistoryA" or "#BeamRTCoherentHistoryB"
    temporalScheduledTarget = writeA and "A" or "B"
    temporalScheduledFrame = frame
    return lastTemporalOutput
end

local function applyRouting(self)
    if not tracePass and not temporalPassA and not temporalPassB and not applyPass then return end

    local useTemporal = value(self, "temporalStrength", 0.0) > 0.0001
    local useFiltered = value(self, "filteredColor", false) == true
    local debugMode = math.floor((tonumber(value(self, "debugView", 0.0)) or 0.0) + 0.5)
    local debugRoute = "combinedHiZ"
    local temporalView=debugMode<50 and debugMode~=31 and debugMode~=32 and debugMode~=35 and debugMode~=38 and debugMode~=43
    if debugMode >= 50 or debugMode == 20 or debugMode == 22 or debugMode == 31 or debugMode == 32
        or debugMode == 35 or debugMode == 38 or debugMode == 43 then
        debugRoute = "current"
    elseif debugMode == 33 then
        debugRoute = "hizPacked"
    elseif debugMode == 42 then
        debugRoute = "velocity"
    elseif debugMode == 41 then
        debugRoute = "lightInfo"
    end
    if debugMode==22 and applyVariant.unified.ready then debugRoute="nativeCurrent" end
    local wantRough = roughTracePass ~= nil and reusePass ~= nil and useTemporal
        and temporalView
        and value(self, "adaptiveResolution", false) == true
        and value(self, "nativeTemporal", true) == true
        and getRoughScale(self) < getRenderScale(self) * 0.9
    if wantRough ~= roughEnabled then
        roughEnabled, roughReady = wantRough, false
        roughStartFrame = wantRough and frame or nil
        temporalHistoryWarmup = 2
        if wantRough then roughTracePass:enable() else roughTracePass:disable() end
    end
    if roughEnabled then
        setPassSkip(roughTracePass, frame <= 0)
        roughReady = frame > math.max(roughStartFrame or frame, 1)
    end
    local wantReuse = reusePass ~= nil and useTemporal and temporalView
        and value(self, "nativeTemporal", true) == true
        and (roughEnabled or getRenderScale(self) < 0.99 or
            (value(self, "stochasticSSR", true) == true and value(self, "stochasticReuse", 0) > 0))
    if wantReuse ~= reuseEnabled then
        reuseEnabled, reuseReady = wantReuse, false
        reuseStartFrame = wantReuse and frame or nil
        temporalHistoryWarmup = 2
        if reusePass then
            if wantReuse then reusePass:enable() else reusePass:disable() end
        end
    end
    if reuseEnabled then
        setPassSkip(reusePass, frame <= 0)
        reuseReady = frame > math.max(reuseStartFrame or frame, 1)
        reusePass:setField("texture", 3, roughReady and "#BeamRTCoherentRough" or fallbackTexture)
    end
    roughReady = roughReady and reuseEnabled
    if useTemporal and cachedRoutingUseTemporal ~= true then
        temporalHistoryWarmup = 2
    end

    local unified = applyVariant.unified
    local wantUnified = unified.pass ~= nil and useTemporal and value(self, "nativeTemporal", true) == true
        and temporalView
    if wantUnified ~= unified.enabled then
        unified.enabled, unified.ready, unified.startFrame = wantUnified, false, frame
        temporalHistoryWarmup = 2
        if unified.pass then
            if wantUnified then unified.pass:enable() else unified.pass:disable() end
        end
    end
    local wasReady = unified.ready
    unified.ready = unified.enabled and frame > math.max(unified.startFrame, 1)
    if unified.ready ~= wasReady then temporalHistoryWarmup = 2 end
    if unified.enabled then
        setPassSkip(unified.pass, frame <= 0)
        unified.pass:setField("texture", 3, reuseReady and "#BeamRTCoherentReused" or
            (frame > 1 and "#BeamRTCoherentCurrent" or fallbackTexture))
    end

    temporalVelocityBinding = velocityBinding(self)
    velocityBound = temporalVelocityBinding ~= fallbackTexture
    if not velocityBound then
        temporalVelocityBinding = cameraHistoryReady and "#BeamRTCoherentCameraHistory" or fallbackTexture
    end
    cameraHistoryBound = cameraHistoryReady
    temporalCameraSlot5 = (velocityBound and cameraHistoryReady) and "#BeamRTCoherentCameraHistory" or nil
    local wantGeometry = useTemporal and not applyVariant.unified.ready and value(self, "historyGeometry", true) == true
        and value(self, "nativeTemporal", true) == true and not velocityBound
    if wantGeometry ~= geometryEnabled then
        geometryEnabled, geometryStartFrame = wantGeometry, frame
        temporalHistoryWarmup = 2
        for _, pass in ipairs({geometryPassA, geometryPassB}) do
            if wantGeometry then pass:enable() else pass:disable() end
        end
    end
    geometryReady = geometryEnabled and frame > geometryStartFrame + 1
        and cameraHistoryBound and temporalHistoryWarmup <= 0
    if geometryEnabled and frame <= 0 then
        setPassSkip(geometryPassA, true)
        setPassSkip(geometryPassB, true)
    end
    local variant = traceVariantFor(self)
    if tracePass and variant ~= traceShaderVariant then
        recreateTracePass(self, variant)
    end
    local wantApplyVariant = (debugMode ~= 0) and 16.0 or 3.0
    if applyPass and wantApplyVariant ~= applyVariant.current then
        applyVariant.recreate(self, wantApplyVariant)
    end
    local wantTemporalDebug = useTemporal and debugMode >= 44 and debugMode <= 47
    if wantTemporalDebug ~= temporalDebugEnabled then
        temporalDebugEnabled = wantTemporalDebug
        if wantTemporalDebug then temporalDebugPass:enable() else temporalDebugPass:disable() end
    end
    if temporalDebugEnabled then setPassSkip(temporalDebugPass, frame <= 0) end
    local applyAux = routeTemporalPingPong(useTemporal)
    if temporalDebugEnabled and frame > 0 then applyAux = "#BeamRTCoherentDiagnostics" end
    if applyPass then
        applyPass:setField("texture", 3, applyAux)
    end

    if cachedRoutingUseTemporal == useTemporal and
       cachedRoutingUseFiltered == useFiltered and
       cachedDebugRoute == debugRoute then return end

    for _, pass in ipairs(colorMipPasses) do
        if useFiltered then pass:enable() else pass:disable() end
    end

    if hiZPackedPass then hiZPackedPass:enable() end
    if cameraHistoryPass then cameraHistoryPass:enable() end

    if tracePass then
        tracePass:setField("texture", 4, "#BeamRTCoherentHiZPacked")
    end

    for _, pass in ipairs({ tracePass, roughTracePass }) do
        if pass then pass:setField("texture", 3, useFiltered and "#BeamRTCoherentColorMip4" or fallbackTexture) end
    end

    if applyPass then
        applyPass:setField("texture", 0, "$backBuffer")
        if debugRoute == "current" then
            applyPass:setField("texture", 4, "#BeamRTCoherentCurrent")
        elseif debugRoute == "nativeCurrent" then
            applyPass:setField("texture",4,"#BeamRTCoherentNativeCurrent")
        elseif debugRoute == "hizPacked" then
            applyPass:setField("texture", 4, "#BeamRTCoherentHiZPacked")
        elseif debugRoute == "lightInfo" then
            applyPass:setField("texture", 4, lightInfoBinding())
        elseif debugRoute == "velocity" then
            applyPass:setField("texture", 4, velocityWarmup <= 0 and "#VelocityBuffer" or fallbackTexture)
        else
            applyPass:setField("texture", 4, "#BeamRTCoherentHiZ0")
        end
        applyPass:enable()
    end

    if tracePass then tracePass:enable() end
    cachedRoutingUseTemporal = useTemporal
    cachedRoutingUseFiltered = useFiltered
    cachedDebugRoute = debugRoute
end

local function ensureEffect(self)
    applyVariant.setStage(self, false)
    bootstrapPresetIfNeeded(self)
    cleanupRetiredWaterShaderBridge()

    effectShader = scenetree.findObject(shaderName)

    if not effectShader then
        effectShader = createObject("ShaderData")
        effectShader.DXVertexShaderFile = "shaders/beamrt/coherent/beamrt_coherent_v.hlsl"
        effectShader.DXPixelShaderFile = "shaders/beamrt/coherent/beamrt_coherent_p.hlsl"
        effectShader.defines = applyVariant.shaderDefines
        effectShader.pixVersion = 5.0
        applyVariant.registerOwned(effectShader, shaderName)
    end

    local pfxDefaultStateBlock = scenetree.findObject("PFX_DefaultStateBlock")
    if not pfxDefaultStateBlock then
        log("E", "BeamRT", "Missing PFX_DefaultStateBlock")
        return
    end

    effectStateBlock = scenetree.findObject(stateBlockName)
    if not effectStateBlock then
        effectStateBlock = createObject("GFXStateBlockData")
        effectStateBlock:inheritParentFields(pfxDefaultStateBlock)
        effectStateBlock.blendDefined = true
        effectStateBlock.blendEnable = false
        effectStateBlock:setField("blendSrc", 0, "GFXBlendOne")
        effectStateBlock:setField("blendDest", 0, "GFXBlendZero")
        effectStateBlock:setField("blendOp", 0, "GFXBlendOpAdd")
        applyVariant.registerOwned(effectStateBlock, stateBlockName)
    end
    if not scenetree.findObject(stateBlockName .. "Temporal") then
        local temporalBlock = createObject("GFXStateBlockData")
        temporalBlock:inheritParentFields(effectStateBlock)
        temporalBlock.samplersDefined = true
        temporalBlock:setField("samplerStates", 0, "SamplerClampLinear")
        temporalBlock:setField("samplerStates", 2, "SamplerClampLinear")
        applyVariant.registerOwned(temporalBlock, stateBlockName .. "Temporal")
    end

    scanWaterVolumes(self)
    waterCache.frame = frame

    local scaleString = getRenderScaleString(self)

    local staleHiZ0 = scenetree.findObject(basePostEffectName .. "HiZ0Pass")
    if staleHiZ0 then
        pcall(function() staleHiZ0:disable() end)
        pcall(function() staleHiZ0:delete() end)
    end
    hiZPasses[1] = createPostEffect(basePostEffectName .. "HiZ0Pass", 6.0, renderPriorityBase + 1.0, "$backBuffer", "#BeamRTCoherentHiZ0", "1 1", riverTextureBinding(), "PFXTargetClear_None")
    hiZPasses[2] = createPostEffect(basePostEffectName .. "HiZ1Pass", 15.0, renderPriorityBase + 0.9, "#BeamRTCoherentHiZ0", "#BeamRTCoherentHiZ1", "0.5 0.5", "", "PFXTargetClear_None", "GFXFormatR16G16F")
    hiZPasses[3] = createPostEffect(basePostEffectName .. "HiZ2Pass", 7.0, renderPriorityBase + 0.8, "#BeamRTCoherentHiZ1", "#BeamRTCoherentHiZ2", "0.5 0.5", "", "PFXTargetClear_None", "GFXFormatR16G16F")
    hiZPasses[4] = createPostEffect(basePostEffectName .. "HiZ3Pass", 7.0, renderPriorityBase + 0.7, "#BeamRTCoherentHiZ2", "#BeamRTCoherentHiZ3", "0.5 0.5", "", "PFXTargetClear_None", "GFXFormatR16F")
    hiZPasses[5] = createPostEffect(basePostEffectName .. "HiZ4Pass", 7.0, renderPriorityBase + 0.6, "#BeamRTCoherentHiZ3", "#BeamRTCoherentHiZ4", "0.5 0.5", "", "PFXTargetClear_None", "GFXFormatR16F")
    hiZPasses[6] = createPostEffect(basePostEffectName .. "HiZ5Pass", 7.0, renderPriorityBase + 0.59, "#BeamRTCoherentHiZ4", "#BeamRTCoherentHiZ5", "0.5 0.5", "", "PFXTargetClear_None", "GFXFormatR16F")
    hiZPasses[7] = createPostEffect(basePostEffectName .. "HiZ6Pass", 7.0, renderPriorityBase + 0.58, "#BeamRTCoherentHiZ5", "#BeamRTCoherentHiZ6", "0.5 0.5", "", "PFXTargetClear_None", "GFXFormatR16F")
    for i, pass in ipairs(hiZPasses) do
        if i > 1 then
            for slot = 1, 5 do pass:setField("texture", slot, fallbackTexture) end
        else
            pass:setField("texture", 4, fallbackTexture)
            configureHiZ0Bindings(pass)
        end
    end
    riverState.bindingDirty = false

    hiZPackedPass = createPostEffect(basePostEffectName .. "HiZPackedPass", 8.0, renderPriorityBase + 0.55, "#BeamRTCoherentHiZ2", "#BeamRTCoherentHiZPacked", "1 1", fallbackTexture, "PFXTargetClear_None")
    hiZPackedPass:setField("texture", 1, "#BeamRTCoherentHiZ4")
    hiZPackedPass:setField("texture", 2, "#BeamRTCoherentHiZ6")
    hiZPackedPass:setField("texture", 3, fallbackTexture)
    hiZPackedPass:setField("texture", 4, fallbackTexture)
    hiZPackedPass:setField("texture", 5, fallbackTexture)

    colorMipPasses[1] = createPostEffect(basePostEffectName .. "ColorMip1Pass", 5.0, renderPriorityBase + 0.4, "$backBuffer", "#BeamRTCoherentColorMip1", "0.5 0.5", "", "PFXTargetClear_None")
    colorMipPasses[2] = createPostEffect(basePostEffectName .. "ColorMip2Pass", 5.0, renderPriorityBase + 0.3, "#BeamRTCoherentColorMip1", "#BeamRTCoherentColorMip2", "0.5 0.5", "", "PFXTargetClear_None")
    colorMipPasses[3] = createPostEffect(basePostEffectName .. "ColorMip3Pass", 5.0, renderPriorityBase + 0.2, "#BeamRTCoherentColorMip2", "#BeamRTCoherentColorMip3", "0.5 0.5", "", "PFXTargetClear_None")
    colorMipPasses[4] = createPostEffect(basePostEffectName .. "ColorMip4Pass", 5.0, renderPriorityBase + 0.1, "#BeamRTCoherentColorMip3", "#BeamRTCoherentColorMip4", "0.5 0.5", "", "PFXTargetClear_None")
    for _, pass in ipairs(colorMipPasses) do
        for slot = 1, 5 do pass:setField("texture", slot, fallbackTexture) end
    end

    refreshTerrain(self)
    boundTerrainRevision = terrainTexRevision

    local initialTraceVariant = traceVariantFor(self)
    tracePass = createPostEffect(basePostEffectName .. "TracePass", initialTraceVariant, renderPriorityBase, "$backBuffer", "#BeamRTCoherentCurrent", scaleString, fallbackTexture, "PFXTargetClear_None")
    roughTracePass = createPostEffect(basePostEffectName .. "RoughTracePass", initialTraceVariant,
        renderPriorityBase + 0.01, "$backBuffer", "#BeamRTCoherentRough", roughScaleString(self),
        fallbackTexture, "PFXTargetClear_None")
    roughTracePass:setField("texture", 2, "#BeamRTCoherentHiZ0")
    roughTracePass:setField("texture", 4, "#BeamRTCoherentHiZPacked")
    roughTracePass:disable()
    roughEnabled, roughReady, roughStartFrame = false, false, nil
    reusePass = createPostEffect(basePostEffectName .. "ReusePass", 10.0,
        renderPriorityBase - 0.05, "#BeamRTCoherentCurrent", "#BeamRTCoherentReused", "2 1",
        fallbackTexture, "PFXTargetClear_None")
    reusePass:setField("texture", 2, "#BeamRTCoherentHiZ0")
    reusePass:disable()
    reuseEnabled, reuseReady, reuseStartFrame = false, false, nil
    applyVariant.unified.pass = createPostEffect(basePostEffectName .. "NativeResolvePass", 18.0,
        renderPriorityBase - 0.075, "$backBuffer", "#BeamRTCoherentNativeCurrent", "1 1",
        fallbackTexture, "PFXTargetClear_None", "GFXFormatR32G32B32A32F")
    applyVariant.unified.pass:setField("texture", 4, "#BeamRTCoherentHiZ0")
    applyVariant.unified.pass:disable()
    applyVariant.unified.enabled, applyVariant.unified.ready = false, false
    temporalPassA = createPostEffect(basePostEffectName .. "TemporalPassA", 2.0, renderPriorityBase - 0.1, "#BeamRTCoherentHiZ0", "#BeamRTCoherentHistoryA", "1 1", "#BeamRTCoherentHistoryB", "PFXTargetClear_None", "GFXFormatR32G32B32A32F")
    temporalPassB = createPostEffect(basePostEffectName .. "TemporalPassB", 2.0, renderPriorityBase - 0.15, "#BeamRTCoherentHiZ0", "#BeamRTCoherentHistoryB", "1 1", "#BeamRTCoherentHistoryA", "PFXTargetClear_None", "GFXFormatR32G32B32A32F")
    temporalDebugPass = createPostEffect(basePostEffectName .. "TemporalDebugPass", 17.0,
        renderPriorityBase - 0.17, "#BeamRTCoherentHiZ0", "#BeamRTCoherentDiagnostics", "1 1", fallbackTexture, "PFXTargetClear_None")
    for _, pass in ipairs({ temporalPassA, temporalPassB, temporalDebugPass }) do
        pass:setField("stateBlock", 0, stateBlockName .. "Temporal")
    end
    temporalDebugPass:disable()
    temporalDebugEnabled = false
    geometryPassA = createPostEffect(basePostEffectName .. "GeometryPassA", 11.0,
        renderPriorityBase - 0.20, "#BeamRTCoherentHiZ0", "#BeamRTCoherentGeometryA", "1 1", fallbackTexture, "PFXTargetClear_None")
    geometryPassB = createPostEffect(basePostEffectName .. "GeometryPassB", 11.0,
        renderPriorityBase - 0.21, "#BeamRTCoherentHiZ0", "#BeamRTCoherentGeometryB", "1 1", fallbackTexture, "PFXTargetClear_None")
    geometryPassA:disable()
    geometryPassB:disable()
    geometryEnabled, geometryReady, geometryStartFrame = false, false, -1
    traceShaderVariant = initialTraceVariant
    applyVariant.current = 3.0
    applyPass = createPostEffect(basePostEffectName .. "ApplyPass", 3.0, renderPriorityBase - 0.3, "$backBuffer", nil, nil, "#BeamRTCoherentHistoryA", nil)
    cameraHistoryPass = createPostEffect(basePostEffectName .. "CameraHistoryPass", 9.0,
        renderPriorityBase - 0.4, "$backBuffer", "#BeamRTCoherentCameraHistory", "1 1",
        fallbackTexture, "PFXTargetClear_OnCreate", "GFXFormatR32G32B32A32F")
    cameraHistoryPass:setField("targetSize", 0, "2 2")

    tracePass:setField("texture", 2, "#BeamRTCoherentHiZ0")
    tracePass:setField("texture", 4, "#BeamRTCoherentHiZPacked")
    temporalPassA:setField("texture", 0, "#BeamRTCoherentHiZ0")
    temporalPassB:setField("texture", 0, "#BeamRTCoherentHiZ0")
    applyPass:setField("texture", 4, "#BeamRTCoherentHiZ0")

    if not depthPipelineLogged and type(log) == "function" then
        pcall(log, "I", "BeamRTCoherent", "SSR-owned combined water depth + conservative Hi-Z active (stock WaterShader untouched)")
        depthPipelineLogged = true
    end

    cachedRenderScaleString = nil
    cachedNativeTemporal = nil
    cachedRoutingUseTemporal = nil
    cachedRoutingUseFiltered = nil
    cachedDebugRoute = nil
    staticConstantsDirty = true
    lastStaticSignature = nil
    lastStaticSignatureCheckFrame = -999999

    updateRenderScale(self)
    prepareCameraReprojection(self)
    pushShaderConstants(self, true, true)
    applyRouting(self)
end

local function enable(self)
    frame, elapsedTime = 0, 0
    mapLoadRescanUntilFrame = 180
    EffectModule.resetHistory()
    ensureEffect(self)
end

local function passReferenceAlive(pass, name)
    if not pass or not scenetree or not scenetree.findObject then return false end
    local okLive, live = pcall(function() return scenetree.findObject(name) end)
    if not okLive or not live then return false end
    local okProxy = pcall(function() return pass:getField("shader", 0) end)
    return okProxy
end

local function clearPassReferences()
    lightInfoWarmup = 4
    lightInfoBound = false
    for _, key in ipairs({ "sun", "sss", "ao" }) do
        engineInputs[key].want, engineInputs[key].warmup, engineInputs[key].bound = false, 4, false
    end
    engineInputs.signature = ""
    engineInputs.pollFrame = -1000
    velocityWarmup = 4
    velocityBound = false
    cameraHistoryWarmup = 2
    cameraHistoryReady = false
    applyVariant.unified.pass = nil
    applyVariant.unified.enabled, applyVariant.unified.ready = false, false
    applyVariant.unified.startFrame = -1
    tracePass = nil
    roughTracePass = nil
    roughEnabled, roughReady, roughStartFrame = false, false, nil
    reusePass = nil
    reuseEnabled, reuseReady, reuseStartFrame = false, false, nil
    geometryPassA, geometryPassB = nil, nil
    geometryEnabled, geometryReady, geometryStartFrame = false, false, -1
    traceShaderVariant = nil
    temporalDebugPass, temporalDebugEnabled = nil, false
    temporalPassA = nil
    temporalPassB = nil
    temporalDrawingPass = nil
    applyPass = nil
    temporalTargetAReady = false
    temporalTargetBReady = false
    temporalScheduledTarget = nil
    temporalScheduledFrame = -1
    lastTemporalOutput = "#BeamRTCoherentCurrent"
    colorMipPasses = { nil, nil, nil, nil }
    hiZPasses = { nil, nil, nil, nil, nil, nil, nil }
    hiZPackedPass = nil
    cameraHistoryPass = nil
    cachedRenderScaleString = nil
    cachedNativeTemporal = nil
    cachedRoutingUseTemporal = nil
    cachedRoutingUseFiltered = nil
    cachedDebugRoute = nil
end

local OWNED_PASS_NAMES = {
    "HiZ0Pass", "HiZ1Pass", "HiZ2Pass", "HiZ3Pass", "HiZ4Pass",
    "HiZ5Pass", "HiZ6Pass", "HiZPackedPass",
    "ColorMip1Pass", "ColorMip2Pass", "ColorMip3Pass", "ColorMip4Pass",
    "TracePass", "RoughTracePass", "ReusePass", "NativeResolvePass", "TemporalPassA", "TemporalPassB", "TemporalDebugPass", "GeometryPassA", "GeometryPassB", "ApplyPass", "CameraHistoryPass",
}
function applyVariant.setStage(self, move)
    local hdr = value(self, "hdrComposite", true) == true
    applyVariant.stageTime = hdr and "PFXBeforeBin" or "PFXAfterBin"
    applyVariant.stageBin = hdr and "AfterPostFX" or "OverlayRender"
    if not move then return end
    for _, suffix in ipairs(OWNED_PASS_NAMES) do
        local pass = not applyVariant.depth.owns(suffix) and scenetree.findObject(basePostEffectName .. suffix)
        if pass then
            pcall(function()
                pass:setField("renderTime", 0, applyVariant.stageTime)
                pass:setField("renderBin", 0, applyVariant.stageBin)
                if pass:isEnabled() then
                    pass:disable()
                    pass:enable()
                end
            end)
        end
    end
    temporalHistoryWarmup = 2
end

local RETIRED_PASS_NAMES = { "TemporalPass", "CopyPass", "HiZ7Pass", "HiZ8Pass" }

local function vectorString(v, w)
    return string.format("%.6f %.6f %.6f %.1f", v[1], v[2], v[3], w or 0.0)
end

local function onPreRender(self, motion)
    local valid = type(motion) == "table" and motion.valid == true and
        motion.current ~= nil and motion.previous ~= nil
    for _, pass in ipairs({ temporalPassA, temporalPassB, temporalDebugPass }) do
        if pass then
            if valid then
                local c, p = motion.current, motion.previous
                pass:setShaderConst("$uVehicleCenter", vectorString(c.center))
                pass:setShaderConst("$uVehicleAxisX", vectorString(c.axes[1]))
                pass:setShaderConst("$uVehicleAxisY", vectorString(c.axes[2]))
                pass:setShaderConst("$uVehicleAxisZ", vectorString(c.axes[3]))
                pass:setShaderConst("$uVehicleHalf", vectorString(c.half, 1.0))
                pass:setShaderConst("$uVehiclePrevCenter", vectorString(p.center))
                pass:setShaderConst("$uVehiclePrevAxisX", vectorString(p.axes[1]))
                pass:setShaderConst("$uVehiclePrevAxisY", vectorString(p.axes[2]))
                pass:setShaderConst("$uVehiclePrevAxisZ", vectorString(p.axes[3]))
            else
                pass:setShaderConst("$uVehicleHalf", "0 0 0 0")
            end
        end
    end
end

function applyVariant.depth.publish(self)
    local bus = rawget(_G, applyVariant.depth.global)
    if type(bus) ~= "table" then
        bus = { consumers = {} }
        rawset(_G, applyVariant.depth.global, bus)
    end
    if bus.producer ~= nil and bus.producer ~= EffectModule.id then return end
    local live = hiZPasses[1] ~= nil and hiZPackedPass ~= nil
    bus.version = 1
    bus.producer = live and EffectModule.id or nil
    bus.hiZ0 = "#BeamRTCoherentHiZ0"
    bus.packed = "#BeamRTCoherentHiZPacked"
    bus.stageTime, bus.stageBin = applyVariant.depth.time, applyVariant.depth.bin
    bus.priority = applyVariant.depth.priorityBase + 0.55
    bus.water = live and value(self, "waterSSR", true) == true and
        value(self, "waterShaderData", true) == true and not externalWaterSSRActive()
    bus.ao = engineInputs.ao.bound == true
    bus.liveFrames = live and ((tonumber(bus.liveFrames) or 0) + 1) or 0
    bus.updateCount = (tonumber(bus.updateCount) or 0) + 1
    bus.consumers = type(bus.consumers) == "table" and bus.consumers or {}
end

function applyVariant.depth.revoke(reason)
    local bus = rawget(_G, applyVariant.depth.global)
    if type(bus) ~= "table" or bus.producer ~= EffectModule.id then return end
    bus.producer = nil
    bus.liveFrames = 0
    local consumers = {}
    for id, fn in pairs(type(bus.consumers) == "table" and bus.consumers or {}) do consumers[id] = fn end
    for _, fn in pairs(consumers) do
        if type(fn) == "function" then pcall(fn, reason) end
    end
end

local function disable()
    applyVariant.depth.revoke("SSR disabled")
    if scenetree and scenetree.findObject then
        for _, names in ipairs({ OWNED_PASS_NAMES, RETIRED_PASS_NAMES }) do
            for _, suffix in ipairs(names) do
                local okFind, pass = pcall(scenetree.findObject, basePostEffectName .. suffix)
                if okFind and pass then pcall(function() pass:disable() end) end
            end
        end
    end
    clearPassReferences()
end

local function update(self, dt)
    if not passReferenceAlive(tracePass, basePostEffectName .. "TracePass") then
        applyVariant.depth.revoke("SSR passes lost")
        clearPassReferences()
        return
    end

    frame = frame + 1
    elapsedTime = (elapsedTime + math.max(tonumber(dt) or 0.0, 0.0)) % 3600.0
    if velocityWarmup > 0 then velocityWarmup = velocityWarmup - 1 end
    self.wantsPlayerVehicleVelocity = value(self, "engineVelocity", true) == true and
        value(self, "fillEngineVelocityHole", true) == true
    if cameraHistoryWarmup > 0 then
        cameraHistoryWarmup = cameraHistoryWarmup - 1
    else
        cameraHistoryReady = true
    end
    if lightInfoWarmup > 0 then
        lightInfoWarmup = lightInfoWarmup - 1
    elseif not lightInfoBound and hiZPasses[1] then
        lightInfoBound = true
        riverState.bindingDirty = true
        staticConstantsDirty = true
    end
    updateEngineInputs(self)
    cleanupRetiredWaterShaderBridge()
    local externalWater = externalWaterSSRActive()
    if externalWater ~= lastExternalWaterSSR then
        lastExternalWaterSSR = externalWater
        staticConstantsDirty = true
        temporalHistoryWarmup = 2
        scanWaterVolumes(self)
        waterCache.frame = frame
        sendWaterVolumesToAll(self)
        recreateHiZ0ForRiver(self)
        if type(log) == "function" then
            pcall(log, "I", "BeamRTCoherent", externalWater
                and "Improved Water owns water SSR; legacy fullscreen water path bypassed"
                or "Improved Water handoff ended; legacy water SSR restored")
        end
    end
    if riverState.rebakeAtFrame and frame >= riverState.rebakeAtFrame then
        riverState.rebakeAtFrame = nil
        if not externalWater then
            bakeWaterSurfaceMap(self)
            waterCache.frame = frame
            sendWaterVolumesToAll(self)
            recreateHiZ0ForRiver(self)
            temporalHistoryWarmup = 2
        end
    end
    if temporalHistoryWarmup > 0 then temporalHistoryWarmup = temporalHistoryWarmup - 1 end
    prepareCameraReprojection(self)

    if frame <= mapLoadRescanUntilFrame and (frame % 20 == 0) then
        scanWaterVolumes(self)
        waterCache.frame = frame
        sendWaterVolumesToAll(self)
    end

    local forceStatic = pendingParameterFlush
    local forceWater = pendingWaterGeometryRefresh
    pendingParameterFlush = false
    pendingWaterGeometryRefresh = false

    updateRenderScale(self)
    applyRouting(self)
    pushShaderConstants(self, forceStatic, forceWater)
    recreateHiZ0ForRiver(self)

    applyVariant.depth.publish(self)

    if terrainTexRevision ~= boundTerrainRevision then
        for _, pass in ipairs({ tracePass, roughTracePass, applyPass, applyVariant.unified.pass }) do
            if pass then pcall(function() pass:setField("texture", 5, terrainTexPath) end) end
        end
        boundTerrainRevision = terrainTexRevision
    end
end

local function onMissionLoad(self)
    lastCameraState = nil
    reprojectionPrevious = nil
    reprojectionValid = false
    temporalHistoryWarmup = 2
    cameraCaptureSource = "unavailable"
    lastLoggedCameraCaptureSource = nil
    lastExternalWaterSSR = externalWaterSSRActive()
    riverState.rebakeAtFrame = nil
    mapLoadRescanUntilFrame = frame + 180
    cleanupRetiredWaterShaderBridge()
    terrainBlock = nil
    terrainCache.frame = -999999
    terrainCache.bakedTf = nil
    terrainCache.failedTf = nil
    terrainCache.retryAttempts = 0
    waterCache.frame = -999999

    if self.enabled ~= true then return end

    if not passReferenceAlive(tracePass, basePostEffectName .. "TracePass") then
        clearPassReferences()
        ensureEffect(self)
        return
    end
    refreshTerrain(self)
    for _, pass in ipairs({tracePass, roughTracePass, applyPass, applyVariant.unified.pass}) do
        if pass then pass:setField("texture", 5, terrainTexPath) end
    end
    boundTerrainRevision = terrainTexRevision
    staticConstantsDirty = true

    if tracePass then
        scanWaterVolumes(self)
        waterCache.frame = frame
        sendWaterVolumesToAll(self)
        recreateHiZ0ForRiver(self)
    end
end

local function presetDivergesFrom(self, id, v)
    local presetId = math.floor((tonumber(self.values and self.values.qualityPreset) or 0) + 0.5)
    local preset = qualityPresets[presetId]
    if not preset or preset[id] == nil then return false end
    local n = tonumber(v)
    if type(preset[id]) == "boolean" then return v ~= preset[id] end
    return n == nil or math.abs(n - preset[id]) > 1e-4
end

local function setParameter(self, id, v)
    self.values = self.values or {}
    self.values[id] = v

    if id == "qualityPreset" then
        local requested = math.floor((tonumber(v) or 0) + 0.5)
        if requested ~= self._presetObserved then
            applyQualityPresetValues(self, requested)
            self._presetObserved = requested
            temporalHistoryWarmup = 2
        end
        self.values.qualityPreset = requested
    elseif presetDivergesFrom(self, id, v) then
        self.values.qualityPreset = 0
        self._presetObserved = 0
    end

    staticConstantsDirty = true
    pendingParameterFlush = true
    if id == "hdrComposite" then
        applyVariant.setStage(self, true)
    end

    if id == "renderScale" or id == "nativeTemporal" or id == "interleavedHistory" or id == "stochasticResolution" or id == "stochasticSSR"
        or id == "roughResolution" then
        cachedRenderScaleString = nil
        cachedNativeTemporal = nil
        temporalHistoryWarmup = 2
    end

    if id == "adaptiveResolution" or id == "adaptiveRoughStart" or id == "adaptiveRoughEnd"
        or id == "historyGeometry" or id == "singleRaySpecialization" or id == "geometryReconstruction" or id == "adaptiveDenoising" or id == "stochasticReuse" or id == "overhangFill" or id == "overhangBrightness" or id == "traceFootprintAA" then
        temporalHistoryWarmup = 2
    end

    if isWaterParameter(id) and not isRiverBakeParameter(id) then
        temporalHistoryWarmup = 2
    end

    if isRiverBakeParameter(id) then
        local changed = true
        if id == "waterRiverBakeResolution" then
            local requested = tonumber(v) or 1024.0
            local resolution = 128 * math.floor(math.max(256.0, math.min(2048.0, requested)) / 128.0 + 0.5)
            changed = not riverState.available or resolution ~= riverState.resolution
        else
            local padding = math.max(tonumber(v) or 0.0, 0.0)
            changed = not riverState.available or math.abs(padding - riverState.edgePadding) > 0.0001
        end
        riverState.rebakeAtFrame = changed and (frame + 15) or nil
        return
    end

    if id == "temporalDenoising" or id == "temporalStrength" or id == "filteredColor" or id == "debugView" then
        cachedRoutingUseTemporal = nil
        cachedRoutingUseFiltered = nil
        cachedDebugRoute = nil
    end

    if id == "debugView" then
        temporalHistoryWarmup = 2
    end

    if id == "traceSubpixelJitter" or id == "hiZMaxLevel" then
        temporalHistoryWarmup = 2
    end

    if isWaterGeometryParameter(id) then
        pendingWaterGeometryRefresh = true
    end
end

applyVariant.registerOwned = registerOwned
EffectModule.enable = enable
EffectModule.disable = disable
EffectModule.update = update
EffectModule.setParameter = setParameter
EffectModule.onMissionLoad = onMissionLoad
EffectModule.onPreRender = onPreRender

function EffectModule.resetHistory()
    temporalHistoryWarmup = 2
    cameraHistoryWarmup = 2
    cameraHistoryReady = false
    temporalTargetAReady, temporalTargetBReady = false, false
    temporalScheduledTarget, temporalScheduledFrame = nil, -1
    lastCameraState, reprojectionPrevious, reprojectionValid = nil, nil, false
end

function EffectModule.getRuntimeStatus()
    local ready = true
    for _, suffix in ipairs({"HiZ0Pass", "HiZPackedPass", "TracePass", "ApplyPass", "CameraHistoryPass"}) do
        local ok, active = pcall(function()
            local pass = scenetree.findObject(basePostEffectName .. suffix)
            return pass ~= nil and pass:isEnabled() == true
        end)
        if not ok or not active then ready = false end
    end
    local temporalScheduled = temporalScheduledFrame == frame and temporalScheduledTarget ~= nil
    local temporalPass = temporalScheduledTarget == "A" and temporalPassA or temporalPassB
    local okTemporal, temporalEnabled = pcall(function()
        return temporalPass ~= nil and temporalPass:isEnabled() == true
            and temporalPass:getField("skip", 0) ~= "1"
    end)
    return {passesEnabled = ready, frame = frame, historyWarmup = temporalHistoryWarmup,
        accumulationScheduled = ready and temporalScheduled and okTemporal and temporalEnabled == true,
        cameraHistoryReady = cameraHistoryReady, waterMapAvailable = riverState.available == true,
        waterMapReason = riverState.lastFailure, historyInterleaved = value(EffectModule, "interleavedHistory", true)}
end

function EffectModule.release()
    disable()
    local failed = false
    -- Delete passes before their ShaderData/state blocks. Check proxy identity:
    -- never delete a replacement registered by somebody else under an old name.
    for _, isPass in ipairs({true, false}) do
        for name, object in pairs(ownedObjects) do
            if (name:sub(1, #basePostEffectName) == basePostEffectName) == isPass then
                local ok = pcall(function()
                    if scenetree.findObject(name) == object then
                        if isPass then object:disable() end
                        object:delete()
                    end
                end)
                if ok then ownedObjects[name] = nil else failed = true end
            end
        end
    end
    EffectModule.resetHistory()
    return not failed
end

return EffectModule
