-- BeamRT v0.102: independent reflection noise and reconstruction controls.

local M = {}
M.dependencies = {"ui_imgui"}

local im = ui_imgui
local sceneDatabase = require("ge/extensions/beamrt/sceneDatabase")
local rayBackendRegistry = require("ge/extensions/beamrt/rayBackendRegistry")

-- The companion helper is a normal required module, so an extension reload
-- otherwise keeps its old functions even after its source file changes.
package.loaded["ge/extensions/beamrt/lightingAudit"] = nil

local LOG_TAG = "BeamRT"
local VERSION = "0.102"
local TUNING_FILE = "/settings/beamrtTuner.json"
local STATE_NAME = "BeamRT_DebugState"
local DEBUG_SHADER_NAME = "BeamRT_DebugShader"
local GI_TRACE_SHADER_NAME = "BeamRT_GITraceShader"
local TEMPORAL_SHADER_NAME = "BeamRT_TemporalShader"
local COMPOSE_SHADER_NAME = "BeamRT_ComposeShader"
local COPY_SHADER_NAME = "BeamRT_CopyShader"
local SURFEL_CACHE_SHADER_NAME = "BeamRT_SurfelCacheShader"
local REFLECTION_TRACE_SHADER_NAME = "BeamRT_ReflectionTraceShader"
local REFLECTION_TEMPORAL_SHADER_NAME = "BeamRT_ReflectionTemporalShader"
local REFLECTION_COMPOSE_SHADER_NAME = "BeamRT_ReflectionComposeShader"
local BUFFER_DIAGNOSTIC_SHADER_NAME = "BeamRT_BufferDiagnosticShader"
local CLEAN_RADIANCE = {
  shaderName = "BeamRT_CleanRadianceShader",
  shaderEntry = "shaders/beamrt/beamrtCleanRadianceP_v065.hlsl",
  requiredMaterialCaches = {"basecolor", "metallic", "emissive"},
  selectedPTGISource = "legacy",
  selectedPTGISourceMode = 0,
  bindings = {gi = false, surfelCache = false},
  positionTolerance = 0.01,
  orientationToleranceDegrees = 0.05,
  -- RenderView.fov contains tiny frame-to-frame floating point noise on an
  -- otherwise stationary camera (observed around 0.00008 degrees). Treat only
  -- a materially changed projection as a FOV change.
  fovToleranceDegrees = 0.001,
  build = nil,
  result = {
    active = false,
    phase = "stale",
    lastResult = "never built",
    valid = false,
    stale = true,
    resolution = nil,
    generation = 0,
    cameraSnapshot = nil,
    sourceGenerations = nil,
  },
}
local PROGRESSIVE = {
  reflectionVariance = {
    momentsShaderName = "BeamRT_ReflectionMomentsShader",
    atrousShaderName = "BeamRT_ReflectionAtrousShader",
    momentsEffectName = "BeamRT_ReflectionMomentsFx",
    atrousEffectName = "BeamRT_ReflectionAtrousFx",
    momentsCopyEffectName = "BeamRT_ReflectionMomentsHistoryCopyFx",
    momentsShaderEntry = "shaders/beamrt/beamrtReflectionMomentsP_v001.hlsl",
    atrousShaderEntry = "shaders/beamrt/beamrtReflectionAtrousP_v001.hlsl",
    enabled = false,
    strength = 0.65,
    scale = 1.0,
  },
  enabled = true,
  maxSamples = 4096,
  samples = 0,
  currentWeight = 1.0,
  clampStrength = 0.10,
  cameraSnapshot = nil,
  lastReset = "startup",
  runtimeMode = "stationary progressive",
  estimatorMode = 0,
  estimatorName = "legacy",
  localization = 0.0,
  secondBounceStrength = 0.0,
  emissiveBoost = 1.0,
  rayReach = 1.0,
  rearRayReach = 1.0,
  lowPathRescue = 0.0,
  blueNoiseStrength = 1.0,
  blueNoiseMode = 0,
  blueNoiseSource = "beamng",
  hitRefinementSteps = 5,
  rayDebugMode = 0,
  rayDebugName = "off",
  marcherMode = 0,
  marcherName = "linear",
  screenRayStride = 1.0,
  screenDdaMaxSteps = 32,
  screenDdaMaxPaths = 1,
  hitValidationStrength = 1.0,
  minHitTravelPixels = 1.0,
  echoHistoryGuard = 0.80,
  cameraMotion = 0.0,
  motionCameraSnapshot = nil,
  motionWindowSnapshot = nil,
  motionWindowFrames = 0,
  motionWindowStrength = 0.0,
  motionWindowDistance = 0.0,
  motionWindowRotation = 0.0,
  motionWindowProjection = 0.0,
  motionHoldFrames = 0,
  motionActive = false,
  cameraCutReason = nil,
  lightingDiagnostic = {mode = 0, name = "off", gain = 4.0},
  lightingAccuracyMode = 1, -- conservative by default; 0 is legacy baseline
  reflectionDiagnostic = {mode = 0, name = "off"},
  reflectionSampling = {mode = 0, name = "mirror", frame = 0, sampleIndex = 0},
  reflectionReconstruction = {mode = 1, name = "playable", frameDelta = 1 / 60},
  reflectionHit = {
    enabled = true,
    inputsShaderName = "BeamRT_ReflectionHitInputsShader",
    inputsShaderEntry = "shaders/beamrt/beamrtReflectionHitInputsP_v001.hlsl",
    inputsEffectName = "BeamRT_ReflectionHitInputsFx",
    inputsTarget = "#BeamRT_ReflectionHitInputs",
    copyShaderName = "BeamRT_ReflectionHitCopyShader",
    copyShaderEntry = "shaders/beamrt/beamrtReflectionHitCopyP_v001.hlsl",
    copyEffectName = "BeamRT_ReflectionHitCopyFx",
    historyTarget = "#BeamRT_HistoryReflectionHit",
    traceStateName = "BeamRT_ReflectionHitTraceState",
    callbacks = {},
  },
  lightingAudit = require("ge/extensions/beamrt/lightingAudit"),
  reflectionConvergenceEnabled = false,
  reflectionSourceProbeTarget = nil,
  reflectionTuning = {sampleCellPixels = 1.0, noiseSeed = 0,
    filterRadiusScale = 1.0, sourceFootprintScale = 1.0},
  reflectionColor = {
    enabled = true,
    halfShaderName = "BeamRT_ReflectionRadianceHalfShader",
    halfShaderEntry = "shaders/beamrt/beamrtReflectionRadianceHalfP_v001.hlsl",
    halfEffectName = "BeamRT_ReflectionRadianceHalfFx",
    halfTarget = "#BeamRT_ReflectionRadianceHalf",
    atlasShaderName = "BeamRT_ReflectionRadianceAtlasShader",
    atlasShaderEntry = "shaders/beamrt/beamrtReflectionRadianceAtlasP_v001.hlsl",
    atlasEffectName = "BeamRT_ReflectionRadianceAtlasFx",
    atlasTarget = "#BeamRT_ReflectionRadianceAtlas",
    callbacks = {},
  },
  inputPrep = {
    receiverShaderName = "BeamRT_ReceiverResponseShader",
    receiverShaderEntry = "shaders/beamrt/beamrtReceiverResponseP_v001.hlsl",
    receiverEffectName = "BeamRT_ReceiverResponseFx",
    receiverTarget = "#BeamRT_ReceiverResponse",
    auxiliaryShaderName = "BeamRT_AuxiliaryPackShader",
    auxiliaryShaderEntry = "shaders/beamrt/beamrtAuxiliaryPackP_v001.hlsl",
    auxiliaryEffectName = "BeamRT_AuxiliaryPackFx",
    auxiliaryTarget = "#BeamRT_AuxiliaryInputs",
    stateName = "BeamRT_SixInputState",
    traceStateName = "BeamRT_SixInputTraceState",
    callbacksName = "BeamRT_ReceiverResponseFxCallbacks",
    callbacks = {},
    imageWidth = 0, imageHeight = 0,
    imageSize = "1 1",
  },
  candidateContinuation = 1.0,
  candidateRetryCount = 4,
  emissiveSeparation = 1.0,
  svgf = {
    shaderName = "BeamRT_MomentsShader",
    shaderEntry = "shaders/beamrt/beamrtMomentsP_v001.hlsl",
    effectName = "BeamRT_MomentsFx",
    copyEffectName = "BeamRT_MomentsHistoryCopyFx",
    atrousShaderName = "BeamRT_AtrousShader",
    atrousShaderEntry = "shaders/beamrt/beamrtAtrousP_v001.hlsl",
    atrousEffectNames = {"BeamRT_AtrousFx1", "BeamRT_AtrousFx2", "BeamRT_AtrousFx3"},
    atrousTargets = {"#BeamRT_AtrousGI1", "#BeamRT_AtrousGI2", "#BeamRT_AtrousGI3"},
    atrousSteps = {1, 2, 4},
    strength = 0.0,
    varianceScale = 4.0,
    maxHistory = 32,
  },
  voxel = {
    atlasShaderName = "BeamRT_VoxelAtlasShader",
    atlasShaderEntry = "shaders/beamrt/beamrtVoxelAtlasP_v002.hlsl",
    displayShaderName = "BeamRT_VoxelDDAShader",
    displayShaderEntry = "shaders/beamrt/beamrtVoxelDDAP_v001.hlsl",
    effectName = "BeamRT_VoxelDDAFx",
    displayEffectName = "BeamRT_VoxelDDADisplayFx",
    callbacksName = "BeamRT_VoxelDDAFxCallbacks",
    cellSize = 1.0,
    maxSteps = 96,
    debugMode = 0,
    debugName = "hit",
  },
}
local MATERIAL_CACHE_CONFIGS = {
  basecolor = {
    key = "basecolor",
    publicName = "baseColor",
    materialMode = "Material_BaseColor",
    probeViewName = "BeamRT_BaseColorProbe",
    probeTargetName = "BeamRT_BaseColorProbe",
    cacheTarget = "#BeamRT_BaseColorCache",
    publishEffectName = "BeamRT_BaseColorPublishFx",
  },
  opacity = {
    key = "opacity",
    publicName = "opacity",
    materialMode = "Material_Opacity",
    probeViewName = "BeamRT_OpacityProbe",
    probeTargetName = "BeamRT_OpacityProbe",
    cacheTarget = "#BeamRT_OpacityCache",
    publishEffectName = "BeamRT_OpacityPublishFx",
  },
  metallic = {
    key = "metallic",
    publicName = "metallic",
    materialMode = "Material_Metallic",
    probeViewName = "BeamRT_MetallicProbe",
    probeTargetName = "BeamRT_MetallicProbe",
    cacheTarget = "#BeamRT_MetallicCache",
    publishEffectName = "BeamRT_MetallicPublishFx",
  },
  emissive = {
    key = "emissive",
    publicName = "emissive",
    materialMode = "Material_Emissive",
    probeViewName = "BeamRT_EmissiveProbe",
    probeTargetName = "BeamRT_EmissiveProbe",
    cacheTarget = "#BeamRT_EmissiveCache",
    publishEffectName = "BeamRT_EmissivePublishFx",
  },
  roughness = {
    key = "roughness",
    publicName = "roughness",
    materialMode = "Material_Roughness",
    probeViewName = "BeamRT_RoughnessProbe",
    probeTargetName = "BeamRT_RoughnessProbe",
    cacheTarget = "#BeamRT_RoughnessCache",
    publishEffectName = "BeamRT_RoughnessPublishFx",
  },
  ambientocclusion = {
    key = "ambientocclusion",
    publicName = "ambientOcclusion",
    materialMode = "Material_AmbientOcclusion",
    probeViewName = "BeamRT_AmbientOcclusionProbe",
    probeTargetName = "BeamRT_AmbientOcclusionProbe",
    cacheTarget = "#BeamRT_AmbientOcclusionCache",
    publishEffectName = "BeamRT_AmbientOcclusionPublishFx",
  },
  normalsws = {
    key = "normalsws",
    publicName = "normalsWS",
    materialMode = "Material_NormalsWS",
    probeViewName = "BeamRT_NormalsWSProbe",
    probeTargetName = "BeamRT_NormalsWSProbe",
    cacheTarget = "#BeamRT_NormalsWSCache",
    publishEffectName = "BeamRT_NormalsWSPublishFx",
  },
  clearcoat = {
    key = "clearcoat",
    publicName = "clearCoat",
    materialMode = "Material_ClearCoat",
    probeViewName = "BeamRT_ClearCoatProbe",
    probeTargetName = "BeamRT_ClearCoatProbe",
    cacheTarget = "#BeamRT_ClearCoatCache",
    publishEffectName = "BeamRT_ClearCoatPublishFx",
  },
  clearcoatroughness = {
    key = "clearcoatroughness",
    publicName = "clearCoatRoughness",
    materialMode = "Material_ClearCoatRoughness",
    probeViewName = "BeamRT_ClearCoatRoughnessProbe",
    probeTargetName = "BeamRT_ClearCoatRoughnessProbe",
    cacheTarget = "#BeamRT_ClearCoatRoughnessCache",
    publishEffectName = "BeamRT_ClearCoatRoughnessPublishFx",
  },
}
CLEAN_RADIANCE.outputs = {
  diffusealbedo = {
    publicName = "diffuseAlbedo",
    target = "#BeamRT_DiffuseAlbedo",
    effectName = "BeamRT_DiffuseAlbedoFx",
    outputMode = 0,
  },
  directdiffuseradiance = {
    publicName = "directDiffuseRadiance",
    target = "#BeamRT_DirectDiffuseRadiance",
    effectName = "BeamRT_DirectDiffuseRadianceFx",
    outputMode = 1,
  },
  maskedemissive = {
    publicName = "maskedEmissive",
    target = "#BeamRT_MaskedEmissive",
    effectName = "BeamRT_MaskedEmissiveFx",
    outputMode = 2,
  },
  cleanradiance = {
    publicName = "cleanRadiance",
    target = "#BeamRT_CleanRadiance",
    effectName = "BeamRT_CleanRadianceFx",
    outputMode = 3,
  },
  emitterclass = {
    publicName = "emitterClass",
    target = "#BeamRT_EmitterClass",
    effectName = "BeamRT_EmitterClassFx",
    outputMode = 4,
  },
}
local DEBUG_EFFECT_NAME = "BeamRT_DebugFx"
local GI_EFFECT_NAME = "BeamRT_GIFx"
local TEMPORAL_EFFECT_NAME = "BeamRT_TemporalFx"
local COMPOSE_EFFECT_NAME = "BeamRT_ComposeFx"
local COPY_EFFECT_NAME = "BeamRT_HistoryCopyFx"
local SURFEL_CACHE_EFFECT_NAME = "BeamRT_SurfelCacheFx"
local SURFEL_CACHE_COPY_EFFECT_NAME = "BeamRT_SurfelCacheCopyFx"
local REFLECTION_EFFECT_NAME = "BeamRT_ReflectionFx"
local REFLECTION_TEMPORAL_EFFECT_NAME = "BeamRT_ReflectionTemporalFx"
local REFLECTION_COMPOSE_EFFECT_NAME = "BeamRT_ReflectionComposeFx"
local REFLECTION_COPY_EFFECT_NAME = "BeamRT_ReflectionHistoryCopyFx"
local DEBUG_CALLBACKS_NAME = DEBUG_EFFECT_NAME .. "Callbacks"
local GI_CALLBACKS_NAME = GI_EFFECT_NAME .. "Callbacks"
local SURFEL_CACHE_CALLBACKS_NAME = SURFEL_CACHE_EFFECT_NAME .. "Callbacks"
local REFLECTION_CALLBACKS_NAME = REFLECTION_EFFECT_NAME .. "Callbacks"

local DEBUG_SHADER_ENTRY = "shaders/beamrt/beamrtDebugP_v011.hlsl"
local GI_TRACE_SHADER_ENTRY = "shaders/beamrt/beamrtGITraceP_v082.hlsl"
local TEMPORAL_SHADER_ENTRY = "shaders/beamrt/beamrtTemporalP_v071.hlsl"
local COMPOSE_SHADER_ENTRY = "shaders/beamrt/beamrtLightingComposeP_v079.hlsl"
local COPY_SHADER_ENTRY = "shaders/beamrt/beamrtCopyP_v005.hlsl"
local SURFEL_CACHE_SHADER_ENTRY = "shaders/beamrt/beamrtSurfelCacheP_v062.hlsl"
local REFLECTION_TRACE_SHADER_ENTRY = "shaders/beamrt/beamrtReflectionTraceP_v041.hlsl"
local REFLECTION_TEMPORAL_SHADER_ENTRY = "shaders/beamrt/beamrtReflectionTemporalP_v038.hlsl"
local REFLECTION_COMPOSE_SHADER_ENTRY = "shaders/beamrt/beamrtReflectionComposeP_v032.hlsl"
local BUFFER_DIAGNOSTIC_SHADER_ENTRY = "shaders/beamrt/beamrtBufferDiagnosticP_v001.hlsl"

local MODE_IDS = {
  off = 0,
  normals = 1,
  depth = 2,
  roughness = 3,
  position = 4,
  worldpos = 4,
  worldposition = 4,
  raymarch = 5,
  rays = 5,
  hits = 5,
  diffusegi = 6,
  gi = 6,
  bounce = 6,
  lighting = 6,
  ptgi = 6,
  pathtracedlighting = 6,
  geometry = 7,
  proxy = 7,
  proxies = 7,
  worldgeometry = 7,
  orientedgeometry = 8,
  oriented = 8,
  obb = 8,
  surfels = 9,
  surfel = 9,
  worldnormals = 9,
  surfelcompare = 10,
  surfacecompare = 10,
  surfelradiance = 11,
  radiancevalidation = 11,
  surfelvalidation = 11,
  hybridcoverage = 12,
  gicoverage = 12,
  coverage = 12,
  exacthybrid = 12,
  reflections = 13,
  reflection = 13,
  ssr = 13,
  bufferdiag = 14,
  bufferdiagnostic = 14,
  voxeldda = 15,
  dda = 15,
  voxellab = 15,
}

-- These effects are intentionally separate and fixed-bound. BeamNG PostFX
-- does not expose a reliable GELUA preflight for every named render target,
-- so fixed effects avoid runtime texture rebinding ambiguity. A missing target
-- remains isolated to this disposable diagnostic mode and is also reported by
-- BeamNG's renderer in beamng.log.
local BUFFER_DIAGNOSTIC_SOURCES = {
  sunshadowmask = {
    publicName = "sunShadowMask",
    target = "#sunShadowMask[RT0]",
    effectName = "BeamRT_BufferDiag_SunShadowMaskFx",
  },
  lightinfo0 = {
    publicName = "lightinfo0",
    target = "#lightinfo[RT0]",
    effectName = "BeamRT_BufferDiag_LightInfo0Fx",
  },
  lightinfo1 = {
    publicName = "lightinfo1",
    target = "#lightinfo[RT1]",
    effectName = "BeamRT_BufferDiag_LightInfo1Fx",
  },
  prepass1 = {
    publicName = "prepass1",
    target = "#prepass[RT1]",
    effectName = "BeamRT_BufferDiag_Prepass1Fx",
  },
  basecolorprobe = {
    publicName = "baseColorProbe",
    -- Controlled cross-RenderView sampling test: bind explicit RT0 when the
    -- fixed diagnostic PostEffect is created. Do not rebind this at runtime.
    target = "#BeamRT_BaseColorProbe[RT0]",
    effectName = "BeamRT_BufferDiag_BaseColorProbeFx",
  },
  basecolorcache = {
    publicName = "baseColorCache",
    -- Fixed creation-time binding to the producer-view publication target.
    -- The publisher writes this target; diagnostics never rebind it at runtime.
    target = "#BeamRT_BaseColorCache[RT0]",
    effectName = "BeamRT_BufferDiag_BaseColorCacheFx",
  },
  opacitycache = {
    publicName = "opacityCache",
    target = "#BeamRT_OpacityCache[RT0]",
    effectName = "BeamRT_BufferDiag_OpacityCacheFx",
  },
  metallicprobe = {
    publicName = "metallicProbe",
    target = "#BeamRT_MetallicProbe[RT0]",
    effectName = "BeamRT_BufferDiag_MetallicProbeFx",
  },
  metalliccache = {
    publicName = "metallicCache",
    target = "#BeamRT_MetallicCache[RT0]",
    effectName = "BeamRT_BufferDiag_MetallicCacheFx",
  },
  emissiveprobe = {
    publicName = "emissiveProbe",
    target = "#BeamRT_EmissiveProbe[RT0]",
    effectName = "BeamRT_BufferDiag_EmissiveProbeFx",
  },
  emissivecache = {
    publicName = "emissiveCache",
    target = "#BeamRT_EmissiveCache[RT0]",
    effectName = "BeamRT_BufferDiag_EmissiveCacheFx",
  },
  roughnesscache = {
    publicName = "roughnessCache",
    target = "#BeamRT_RoughnessCache[RT0]",
    effectName = "BeamRT_BufferDiag_RoughnessCacheFx",
  },
  ambientocclusioncache = {
    publicName = "ambientOcclusionCache",
    target = "#BeamRT_AmbientOcclusionCache[RT0]",
    effectName = "BeamRT_BufferDiag_AmbientOcclusionCacheFx",
  },
  normalswscache = {
    publicName = "normalsWSCache",
    target = "#BeamRT_NormalsWSCache[RT0]",
    effectName = "BeamRT_BufferDiag_NormalsWSCacheFx",
  },
  clearcoatcache = {
    publicName = "clearCoatCache",
    target = "#BeamRT_ClearCoatCache[RT0]",
    effectName = "BeamRT_BufferDiag_ClearCoatCacheFx",
  },
  clearcoatroughnesscache = {
    publicName = "clearCoatRoughnessCache",
    target = "#BeamRT_ClearCoatRoughnessCache[RT0]",
    effectName = "BeamRT_BufferDiag_ClearCoatRoughnessCacheFx",
  },
  diffusealbedo = {
    publicName = "diffuseAlbedo",
    target = "#BeamRT_DiffuseAlbedo[RT0]",
    effectName = "BeamRT_BufferDiag_DiffuseAlbedoFx",
  },
  directdiffuseradiance = {
    publicName = "directDiffuseRadiance",
    target = "#BeamRT_DirectDiffuseRadiance[RT0]",
    effectName = "BeamRT_BufferDiag_DirectDiffuseRadianceFx",
  },
  maskedemissive = {
    publicName = "maskedEmissive",
    target = "#BeamRT_MaskedEmissive[RT0]",
    effectName = "BeamRT_BufferDiag_MaskedEmissiveFx",
  },
  cleanradiance = {
    publicName = "cleanRadiance",
    target = "#BeamRT_CleanRadiance[RT0]",
    effectName = "BeamRT_BufferDiag_CleanRadianceFx",
  },
  emitterclass = {
    publicName = "emitterClass",
    target = "#BeamRT_EmitterClass[RT0]",
    effectName = "BeamRT_BufferDiag_EmitterClassFx",
  },
  gtaooutput = {
    publicName = "gtaoOutput",
    target = "#gtaoOutput[RT0]",
    effectName = "BeamRT_BufferDiag_GTAOOutputFx",
  },
  ssaomask = {
    publicName = "ssaoMask",
    target = "#ssaoMask[RT0]",
    effectName = "BeamRT_BufferDiag_SSAOMaskFx",
  },
}

local BUFFER_DIAGNOSTIC_SOURCE_ALIASES = {
  sunshadow = "sunshadowmask",
  sunshadowmask = "sunshadowmask",
  lightinfo = "lightinfo0",
  lightinfo0 = "lightinfo0",
  lightinfo1 = "lightinfo1",
  prepass1 = "prepass1",
  basecolor = "basecolorprobe",
  basecolorprobe = "basecolorprobe",
  basecolorcache = "basecolorcache",
  publishedbasecolor = "basecolorcache",
  opacitycache = "opacitycache",
  publishedopacity = "opacitycache",
  metallic = "metallicprobe",
  metallicprobe = "metallicprobe",
  metalliccache = "metalliccache",
  publishedmetallic = "metalliccache",
  emissive = "emissiveprobe",
  emissiveprobe = "emissiveprobe",
  emissivecache = "emissivecache",
  publishedemissive = "emissivecache",
  roughnesscache = "roughnesscache",
  publishedroughness = "roughnesscache",
  ambientocclusioncache = "ambientocclusioncache",
  aocache = "ambientocclusioncache",
  publishedambientocclusion = "ambientocclusioncache",
  normalswscache = "normalswscache",
  normalcache = "normalswscache",
  publishednormalsws = "normalswscache",
  clearcoatcache = "clearcoatcache",
  publishedclearcoat = "clearcoatcache",
  clearcoatroughnesscache = "clearcoatroughnesscache",
  publishedclearcoatroughness = "clearcoatroughnesscache",
  diffusealbedo = "diffusealbedo",
  albedo = "diffusealbedo",
  directdiffuse = "directdiffuseradiance",
  directdiffuseradiance = "directdiffuseradiance",
  maskedemissive = "maskedemissive",
  cleanradiance = "cleanradiance",
  emitterclass = "emitterclass",
  emitterclassification = "emitterclass",
  gtao = "gtaooutput",
  gtaooutput = "gtaooutput",
  ssao = "ssaomask",
  ssaomask = "ssaomask",
}

local BUFFER_DIAGNOSTIC_CHANNELS = {
  rgb = 0,
  r = 1,
  g = 2,
  b = 3,
  a = 4,
}

local MAX_GEOMETRY_BOXES = 16
local MAX_SURFELS = 32
local SURFEL_SPHERE_RAYS = 20
local GEOMETRY_CLASSES = {
  "TSStatic",
  "MeshRoad",
  "ProceduralMesh",
  "GroundPlane",
}

local modeName = "off"
local debugMode = MODE_IDS.off
local enabledRequested = false
local depthGain = 20.0
local positionScale = 0.1
local rayStepSize = 0.55
local rayThickness = 0.80
local rayNormalBias = 0.04
local rayMaxSteps = 36
local giPathCount = 4
local giRenderScale = 0.5
local giStrength = 0.90
local giClamp = 6.0
local giCellSize = 0.0125
local giFrameIndex = 0
local temporalBlend = 0.07
local historyDepthTolerance = 0.008
local denoiseStrength = 1.0
local contactShadowStrength = 0.58
local bounceSaturation = 1.25
local giExposure = 0.0
local giShadowFocus = 0.75
local giReceiverTint = 0.40
local giContrast = 1.10
local giEnergyLimit = 1.75
local giHighlightRolloff = 0.80
local historyValid = 0
local historyWarmupFrames = 0
local geometryRadius = 100.0
local geometryMaxObjectExtent = 200.0
local geometryBoxes = {}
local geometryScanPosition = nil
local orientedGeometryProxyCount = 0
local surfels = {}
local surfelScanPosition = nil
local surfelTraceDistance = 75.0
local surfelBaseRadius = 1.75
local giSourceMode = 0 -- 0 hybrid, 1 screen-space only, 2 world surfels only
-- Opt-in world-surfel GI visibility through the same verified opaque mesh
-- dataset as the experimental off-screen shadow geometry. Disabled by default.
M.sceneGIVisibility = {enabled = false, revision = -1, lastEnabled = nil}
local worldGIStrength = 1.15
local worldLeakSuppression = 0.85
local radianceCleanup = 1.0
local specularReject = 0.85
local radianceSourceMode = 1 -- 0 legacy cleaned backbuffer, 1 de-lit/re-lit lightinfo0 approximation
local radianceSourceName = "directdiffuse"
local radianceChromaStrength = 1.0
local retroReject = 1.0
local surfelVisibilityTolerance = 1.5
local surfelCacheBlend = 0.15
local surfelCacheResetFrames = 2
local surfelRefreshCheckFrames = 0
local surfelRefreshDistance = 8.0
local surfelRefreshRaysPerFrame = 4
local pendingSurfelRefresh = nil
local surfelGeometryDirtyGI = true
local surfelGeometryDirtyCache = true
local reflectionStrength = 0.75
local reflectionStepSize = 0.30
local reflectionThickness = 0.25
local reflectionNormalBias = 0.045
local reflectionMaxSteps = 80
local reflectionMaxDistance = 24.0
local reflectionMaxRoughness = 0.34
local reflectionTemporalBlend = 0.25
local reflectionHistoryDepthTolerance = 0.006
local reflectionDenoiseStrength = 0.45
local reflectionHistoryValid = 0
local reflectionHistoryWarmupFrames = 0
local reflectionOverlayEnabled = false
local bufferDiagnosticSource = "sunshadowmask"
local bufferDiagnosticChannelName = "rgb"
local bufferDiagnosticChannel = BUFFER_DIAGNOSTIC_CHANNELS.rgb
local bufferDiagnosticGain = 1.0
local bufferDiagnosticExposure = 0.0
local bufferDiagnosticHDRDecode = false
local materialCachePublication = nil
local materialCacheResults = {}
for key, config in pairs(MATERIAL_CACHE_CONFIGS) do
  materialCacheResults[key] = {
    active = false,
    phase = "stale",
    target = config.cacheTarget .. "[RT0]",
    lastResult = "never published",
    valid = false,
    stale = true,
    resolution = nil,
    generation = 0,
    cameraSnapshot = nil,
  }
end

local tuningWindowOpen = im.BoolPtr(false)
local tuningPointers = {
  giStrength = im.FloatPtr(giStrength),
  worldGIStrength = im.FloatPtr(worldGIStrength),
  bounceSaturation = im.FloatPtr(bounceSaturation),
  contactShadowStrength = im.FloatPtr(contactShadowStrength),
  giClamp = im.FloatPtr(giClamp),
  giExposure = im.FloatPtr(giExposure),
  giShadowFocus = im.FloatPtr(giShadowFocus),
  giReceiverTint = im.FloatPtr(giReceiverTint),
  giContrast = im.FloatPtr(giContrast),
  giEnergyLimit = im.FloatPtr(giEnergyLimit),
  giHighlightRolloff = im.FloatPtr(giHighlightRolloff),
  temporalBlend = im.FloatPtr(temporalBlend),
  denoiseStrength = im.FloatPtr(denoiseStrength),
  historyDepthTolerance = im.FloatPtr(historyDepthTolerance),
  giCellSize = im.FloatPtr(giCellSize),
  rayStepSize = im.FloatPtr(rayStepSize),
  rayThickness = im.FloatPtr(rayThickness),
  rayNormalBias = im.FloatPtr(rayNormalBias),
  rayMaxSteps = im.IntPtr(rayMaxSteps),
  giPathCount = im.IntPtr(giPathCount),
  surfelTraceDistance = im.FloatPtr(surfelTraceDistance),
  surfelBaseRadius = im.FloatPtr(surfelBaseRadius),
  surfelVisibilityTolerance = im.FloatPtr(surfelVisibilityTolerance),
  surfelCacheBlend = im.FloatPtr(surfelCacheBlend),
  surfelRefreshDistance = im.FloatPtr(surfelRefreshDistance),
  surfelRefreshRaysPerFrame = im.IntPtr(surfelRefreshRaysPerFrame),
  worldLeakSuppression = im.FloatPtr(worldLeakSuppression),
  radianceCleanup = im.FloatPtr(radianceCleanup),
  specularReject = im.FloatPtr(specularReject),
  radianceChromaStrength = im.FloatPtr(radianceChromaStrength),
  retroReject = im.FloatPtr(retroReject),
  progressiveMaxSamples = im.IntPtr(PROGRESSIVE.maxSamples),
  progressiveClampStrength = im.FloatPtr(PROGRESSIVE.clampStrength),
  giLocalization = im.FloatPtr(PROGRESSIVE.localization),
  secondBounceStrength = im.FloatPtr(PROGRESSIVE.secondBounceStrength),
  emissiveBoost = im.FloatPtr(PROGRESSIVE.emissiveBoost),
  rayReach = im.FloatPtr(PROGRESSIVE.rayReach),
  rearRayReach = im.FloatPtr(PROGRESSIVE.rearRayReach),
  lowPathRescue = im.FloatPtr(PROGRESSIVE.lowPathRescue),
  blueNoiseStrength = im.FloatPtr(PROGRESSIVE.blueNoiseStrength),
  svgfStrength = im.FloatPtr(PROGRESSIVE.svgf.strength),
  svgfVarianceScale = im.FloatPtr(PROGRESSIVE.svgf.varianceScale),
  svgfMaxHistory = im.IntPtr(PROGRESSIVE.svgf.maxHistory),
  hitRefinementSteps = im.IntPtr(PROGRESSIVE.hitRefinementSteps),
  screenRayStride = im.FloatPtr(PROGRESSIVE.screenRayStride),
  hitValidationStrength = im.FloatPtr(PROGRESSIVE.hitValidationStrength),
  minHitTravelPixels = im.FloatPtr(PROGRESSIVE.minHitTravelPixels),
  echoHistoryGuard = im.FloatPtr(PROGRESSIVE.echoHistoryGuard),
  candidateContinuation = im.FloatPtr(PROGRESSIVE.candidateContinuation),
  candidateRetryCount = im.IntPtr(PROGRESSIVE.candidateRetryCount),
  emissiveSeparation = im.FloatPtr(PROGRESSIVE.emissiveSeparation),
  reflectionStrength = im.FloatPtr(reflectionStrength),
  reflectionMaxRoughness = im.FloatPtr(reflectionMaxRoughness),
  reflectionStepSize = im.FloatPtr(reflectionStepSize),
  reflectionThickness = im.FloatPtr(reflectionThickness),
  reflectionNormalBias = im.FloatPtr(reflectionNormalBias),
  reflectionTemporalBlend = im.FloatPtr(reflectionTemporalBlend),
  reflectionDenoiseStrength = im.FloatPtr(reflectionDenoiseStrength),
  reflectionSampleCellPixels = im.FloatPtr(PROGRESSIVE.reflectionTuning.sampleCellPixels),
  reflectionNoiseSeed = im.IntPtr(PROGRESSIVE.reflectionTuning.noiseSeed),
  reflectionFilterRadiusScale = im.FloatPtr(PROGRESSIVE.reflectionTuning.filterRadiusScale),
  reflectionSourceFootprintScale = im.FloatPtr(PROGRESSIVE.reflectionTuning.sourceFootprintScale),
}

local TUNING_PRESETS = {
  experimental = {
    rayStepSize = 0.20, rayThickness = 0.55, rayNormalBias = 0.035, rayMaxSteps = 32,
    giPathCount = 1, giRenderScale = 0.5,
    giStrength = 1.35, giClamp = 16.0, giCellSize = 0.005,
    temporalBlend = 0.10, historyDepthTolerance = 0.004, denoiseStrength = 0.85,
    contactShadowStrength = 0.20, bounceSaturation = 1.35,
    giExposure = 0.15, giShadowFocus = 0.82, giReceiverTint = 0.50,
    giContrast = 1.15, giEnergyLimit = 3.0, giHighlightRolloff = 0.88,
    worldGIStrength = 1.50, worldLeakSuppression = 0.94,
    radianceCleanup = 1.0, specularReject = 0.90,
    progressiveEnabled = true, progressiveMaxSamples = 4096, progressiveClampStrength = 0.10,
    giEstimator = "corrected", giLocalization = 0.55, secondBounceStrength = 0.25, emissiveBoost = 4.0,
    rayReach = 0.45, rearRayReach = 0.18, lowPathRescue = 0.80,
    blueNoiseStrength = 1.0, svgfStrength = 1.0, svgfVarianceScale = 4.0, svgfMaxHistory = 32,
    hitRefinementSteps = 2, candidateRetryCount = 1,
    rayMarcher = "screendda", screenRayStride = 1.0,
    surfelTraceDistance = 120.0, surfelBaseRadius = 1.35,
    surfelVisibilityTolerance = 1.0, surfelCacheBlend = 0.12, surfelRefreshDistance = 7.0,
  },
  userbest = {
    rayStepSize = 0.20, rayThickness = 0.55, rayNormalBias = 0.039, rayMaxSteps = 128,
    giPathCount = 16, giRenderScale = 1.0,
    giStrength = 4.0, giClamp = 10.25, giCellSize = 0.005,
    temporalBlend = 0.093, historyDepthTolerance = 0.05, denoiseStrength = 1.0,
    contactShadowStrength = 0.06, bounceSaturation = 0.90,
    giExposure = 0.0, giShadowFocus = 0.80, giReceiverTint = 0.40,
    giContrast = 1.10, giEnergyLimit = 2.50, giHighlightRolloff = 0.80,
    worldGIStrength = 4.0, worldLeakSuppression = 0.94,
    radianceCleanup = 1.0, specularReject = 0.85,
    surfelTraceDistance = 150.0, surfelBaseRadius = 1.83,
    surfelVisibilityTolerance = 5.0, surfelCacheBlend = 1.0, surfelRefreshDistance = 30.0,
    rayMarcher = "linear",
  },
  cinematic = {
    rayStepSize = 0.24, rayThickness = 0.55, rayNormalBias = 0.035, rayMaxSteps = 128,
    giPathCount = 16, giRenderScale = 1.0,
    giStrength = 2.20, giClamp = 12.0, giCellSize = 0.005,
    temporalBlend = 0.075, historyDepthTolerance = 0.01, denoiseStrength = 1.0,
    contactShadowStrength = 0.10, bounceSaturation = 1.15,
    giExposure = 0.60, giShadowFocus = 0.88, giReceiverTint = 0.55,
    giContrast = 1.18, giEnergyLimit = 2.20, giHighlightRolloff = 0.88,
    worldGIStrength = 2.50, worldLeakSuppression = 0.94,
    radianceCleanup = 1.0, specularReject = 0.90,
    surfelTraceDistance = 120.0, surfelBaseRadius = 1.40,
    surfelVisibilityTolerance = 1.5, surfelCacheBlend = 0.25, surfelRefreshDistance = 10.0,
    rayMarcher = "linear",
  },
  maxquality = {
    rayStepSize = 0.15, rayThickness = 0.55, rayNormalBias = 0.03, rayMaxSteps = 200,
    giPathCount = 32, giRenderScale = 1.0,
    giStrength = 1.25, giClamp = 16.0, giCellSize = 0.005,
    temporalBlend = 0.16, historyDepthTolerance = 0.003, denoiseStrength = 0.65,
    contactShadowStrength = 0.42, bounceSaturation = 1.80,
    giExposure = 0.25, giShadowFocus = 0.80, giReceiverTint = 0.45,
    giContrast = 1.12, giEnergyLimit = 2.0, giHighlightRolloff = 0.82,
    worldGIStrength = 1.80, worldLeakSuppression = 0.94,
    radianceCleanup = 1.0, specularReject = 0.90,
    surfelTraceDistance = 120.0, surfelBaseRadius = 1.25,
    surfelVisibilityTolerance = 0.9, surfelCacheBlend = 0.18, surfelRefreshDistance = 7.0,
    rayMarcher = "linear",
  },
  beautymax = {
    -- Accuracy-first still-image preset. Until the experimental screen DDA and
    -- coarse surfel cache pass their visual gates, spend the maximum budget on
    -- the validated linear screen path instead of mixing representations.
    rayStepSize = 0.18, rayThickness = 0.42, rayNormalBias = 0.035, rayMaxSteps = 160,
    giPathCount = 32, giRenderScale = 1.0,
    giStrength = 1.10, giClamp = 12.0, giCellSize = 0.005,
    temporalBlend = 0.06, historyDepthTolerance = 0.004, denoiseStrength = 0.60,
    contactShadowStrength = 0.0, bounceSaturation = 1.15,
    giExposure = 0.10, giShadowFocus = 0.82, giReceiverTint = 0.45,
    giContrast = 1.10, giEnergyLimit = 1.60, giHighlightRolloff = 0.90,
    worldGIStrength = 0.0, worldLeakSuppression = 0.96,
    radianceCleanup = 1.0, specularReject = 0.95,
    progressiveEnabled = true, progressiveMaxSamples = 4096, progressiveClampStrength = 0.08,
    giEstimator = "corrected", giLocalization = 0.70, secondBounceStrength = 0.0, emissiveBoost = 2.5,
    rayReach = 1.0, rearRayReach = 0.35, lowPathRescue = 0.0,
    blueNoiseStrength = 1.0, blueNoiseSource = "beamng",
    svgfStrength = 0.75, svgfVarianceScale = 3.0, svgfMaxHistory = 64,
    hitRefinementSteps = 5, hitValidationStrength = 1.0, minHitTravelPixels = 2.0,
    candidateContinuation = 1.0, candidateRetryCount = 4,
    emissiveSeparation = 1.0, echoHistoryGuard = 1.0,
    rayMarcher = "linear", screenRayStride = 1.0,
    giSource = "screen",
    surfelTraceDistance = 80.0, surfelBaseRadius = 1.25,
    surfelVisibilityTolerance = 0.8, surfelCacheBlend = 0.10, surfelRefreshDistance = 6.0,
  },
  ptgiplay = {
    -- Gameplay-oriented PTGI: one full-resolution Screen DDA path is allowed to
    -- converge temporally, while the lighting controls make transported color
    -- and the guarded previous-GI bounce deliberately visible. This avoids the
    -- 32 paths x 160 linear steps paid by Beauty Max.
    rayStepSize = 0.20, rayThickness = 0.55, rayNormalBias = 0.035, rayMaxSteps = 64,
    giPathCount = 1, giRenderScale = 1.0,
    giStrength = 1.65, giClamp = 10.0, giCellSize = 0.005,
    temporalBlend = 0.10, historyDepthTolerance = 0.004, denoiseStrength = 0.90,
    contactShadowStrength = 0.0, bounceSaturation = 1.45,
    giExposure = 0.40, giShadowFocus = 0.86, giReceiverTint = 0.58,
    giContrast = 1.12, giEnergyLimit = 2.25, giHighlightRolloff = 0.90,
    worldGIStrength = 0.0, worldLeakSuppression = 0.96,
    radianceCleanup = 1.0, specularReject = 0.92,
    radianceSource = "directdiffuse", radianceChromaStrength = 0.75, retroReject = 1.0,
    progressiveEnabled = true, progressiveMaxSamples = 1024, progressiveClampStrength = 0.10,
    giEstimator = "corrected", giLocalization = 0.60, secondBounceStrength = 0.22, emissiveBoost = 4.0,
    rayReach = 0.70, rearRayReach = 0.25, lowPathRescue = 0.70,
    blueNoiseStrength = 1.0, blueNoiseSource = "beamng",
    svgfStrength = 1.0, svgfVarianceScale = 4.0, svgfMaxHistory = 32,
    hitRefinementSteps = 3, hitValidationStrength = 1.0, minHitTravelPixels = 2.0,
    candidateContinuation = 0.90, candidateRetryCount = 2,
    emissiveSeparation = 1.0, echoHistoryGuard = 1.0,
    rayMarcher = "screendda", screenRayStride = 1.0,
    giSource = "screen",
    surfelTraceDistance = 80.0, surfelBaseRadius = 1.25,
    surfelVisibilityTolerance = 0.8, surfelCacheBlend = 0.10, surfelRefreshDistance = 6.0,
  },
  ultra = {
    rayStepSize = 0.24, rayThickness = 0.62, rayNormalBias = 0.035, rayMaxSteps = 96,
    giPathCount = 16, giRenderScale = 1.0,
    giStrength = 1.25, giClamp = 12.0, giCellSize = 0.006,
    temporalBlend = 0.12, historyDepthTolerance = 0.004, denoiseStrength = 0.82,
    contactShadowStrength = 0.42, bounceSaturation = 1.80,
    giExposure = 0.20, giShadowFocus = 0.78, giReceiverTint = 0.42,
    giContrast = 1.10, giEnergyLimit = 1.85, giHighlightRolloff = 0.80,
    worldGIStrength = 1.80, worldLeakSuppression = 0.92,
    radianceCleanup = 1.0, specularReject = 0.85,
    surfelTraceDistance = 120.0, surfelBaseRadius = 1.35,
    surfelVisibilityTolerance = 1.0, surfelCacheBlend = 0.18, surfelRefreshDistance = 7.0,
    rayMarcher = "linear",
  },
  showcase = {
    rayStepSize = 0.55, rayThickness = 0.80, rayNormalBias = 0.04, rayMaxSteps = 36,
    giPathCount = 8, giRenderScale = 0.75,
    giStrength = 0.90, giClamp = 6.0, giCellSize = 0.0125,
    temporalBlend = 0.07, historyDepthTolerance = 0.008, denoiseStrength = 1.0,
    contactShadowStrength = 0.58, bounceSaturation = 1.25,
    giExposure = 0.0, giShadowFocus = 0.75, giReceiverTint = 0.40,
    giContrast = 1.10, giEnergyLimit = 1.75, giHighlightRolloff = 0.80,
    worldGIStrength = 1.15, worldLeakSuppression = 0.85,
    radianceCleanup = 1.0, specularReject = 0.85, surfelTraceDistance = 75.0, surfelBaseRadius = 1.75,
    surfelVisibilityTolerance = 1.5, surfelCacheBlend = 0.15, surfelRefreshDistance = 8.0,
    rayMarcher = "linear",
  },
  balanced = {
    rayStepSize = 0.65, rayThickness = 0.85, rayNormalBias = 0.05, rayMaxSteps = 28,
    giPathCount = 4, giRenderScale = 0.5,
    giStrength = 0.75, giClamp = 5.0, giCellSize = 0.015625,
    temporalBlend = 0.10, historyDepthTolerance = 0.01, denoiseStrength = 1.0,
    contactShadowStrength = 0.65, bounceSaturation = 1.20,
    giExposure = -0.10, giShadowFocus = 0.70, giReceiverTint = 0.35,
    giContrast = 1.05, giEnergyLimit = 1.50, giHighlightRolloff = 0.75,
    worldGIStrength = 1.0, worldLeakSuppression = 0.8,
    radianceCleanup = 1.0, specularReject = 0.80, surfelTraceDistance = 60.0, surfelBaseRadius = 2.0,
    surfelVisibilityTolerance = 1.5, surfelCacheBlend = 0.20, surfelRefreshDistance = 8.0,
    rayMarcher = "linear",
  },
  clean = {
    rayStepSize = 0.50, rayThickness = 0.72, rayNormalBias = 0.04, rayMaxSteps = 40,
    giPathCount = 8, giRenderScale = 0.75,
    giStrength = 0.72, giClamp = 5.0, giCellSize = 0.01,
    temporalBlend = 0.045, historyDepthTolerance = 0.007, denoiseStrength = 1.0,
    contactShadowStrength = 0.45, bounceSaturation = 1.10,
    giExposure = -0.20, giShadowFocus = 0.82, giReceiverTint = 0.30,
    giContrast = 1.08, giEnergyLimit = 1.35, giHighlightRolloff = 0.90,
    worldGIStrength = 1.0, worldLeakSuppression = 0.9,
    radianceCleanup = 1.0, specularReject = 0.90, surfelTraceDistance = 75.0, surfelBaseRadius = 1.5,
    surfelVisibilityTolerance = 1.25, surfelCacheBlend = 0.10, surfelRefreshDistance = 7.0,
    rayMarcher = "linear",
  },
  performance = {
    rayStepSize = 0.85, rayThickness = 1.0, rayNormalBias = 0.06, rayMaxSteps = 20,
    giPathCount = 2, giRenderScale = 0.5,
    giStrength = 0.65, giClamp = 4.0, giCellSize = 0.025,
    temporalBlend = 0.14, historyDepthTolerance = 0.014, denoiseStrength = 0.85,
    contactShadowStrength = 0.25, bounceSaturation = 1.10,
    giExposure = -0.30, giShadowFocus = 0.68, giReceiverTint = 0.30,
    giContrast = 1.0, giEnergyLimit = 1.25, giHighlightRolloff = 0.75,
    worldGIStrength = 0.80, worldLeakSuppression = 0.7,
    radianceCleanup = 1.0, specularReject = 0.75, surfelTraceDistance = 50.0, surfelBaseRadius = 2.5,
    surfelVisibilityTolerance = 2.0, surfelCacheBlend = 0.25, surfelRefreshDistance = 10.0,
    rayMarcher = "linear",
  },
}

-- Preserve Beauty Max as the neutral baseline. This opt-in variant changes only
-- the reflection controls, so selecting it cannot silently alter the accepted
-- GI/ray/temporal settings.
TUNING_PRESETS.beautyreflect = {}
for settingName, settingValue in pairs(TUNING_PRESETS.beautymax) do
  TUNING_PRESETS.beautyreflect[settingName] = settingValue
end
TUNING_PRESETS.beautyreflect.reflectionsEnabled = true
TUNING_PRESETS.beautyreflect.reflectionStrength = 0.85
TUNING_PRESETS.beautyreflect.reflectionMaxRoughness = 0.35
TUNING_PRESETS.beautyreflect.reflectionStepSize = 0.24
TUNING_PRESETS.beautyreflect.reflectionThickness = 0.22
TUNING_PRESETS.beautyreflect.reflectionNormalBias = 0.04
TUNING_PRESETS.beautyreflect.reflectionTemporalBlend = 0.22
TUNING_PRESETS.beautyreflect.reflectionDenoiseStrength = 0.55

TUNING_PRESETS.ptgiplayreflect = {}
for settingName, settingValue in pairs(TUNING_PRESETS.ptgiplay) do
  TUNING_PRESETS.ptgiplayreflect[settingName] = settingValue
end
TUNING_PRESETS.ptgiplayreflect.reflectionsEnabled = true
TUNING_PRESETS.ptgiplayreflect.reflectionStrength = 0.72
TUNING_PRESETS.ptgiplayreflect.reflectionMaxRoughness = 0.32
TUNING_PRESETS.ptgiplayreflect.reflectionStepSize = 0.35
TUNING_PRESETS.ptgiplayreflect.reflectionThickness = 0.28
TUNING_PRESETS.ptgiplayreflect.reflectionNormalBias = 0.045
TUNING_PRESETS.ptgiplayreflect.reflectionTemporalBlend = 0.30
TUNING_PRESETS.ptgiplayreflect.reflectionDenoiseStrength = 0.40

-- The quality-oriented DDA path keeps the practical screen marcher, spends a
-- second path on coverage, and leans on the real three-scale reconstruction
-- rather than the unusably expensive 32-path linear preset.
TUNING_PRESETS.ptgimax = {}
for settingName, settingValue in pairs(TUNING_PRESETS.ptgiplay) do
  TUNING_PRESETS.ptgimax[settingName] = settingValue
end
TUNING_PRESETS.ptgimax.giPathCount = 2
TUNING_PRESETS.ptgimax.screenDdaMaxPaths = 2
TUNING_PRESETS.ptgimax.screenDdaMaxSteps = 48
TUNING_PRESETS.ptgimax.rayReach = 0.75
TUNING_PRESETS.ptgimax.temporalBlend = 0.075
TUNING_PRESETS.ptgimax.progressiveMaxSamples = 2048
TUNING_PRESETS.ptgimax.progressiveClampStrength = 0.08
TUNING_PRESETS.ptgimax.secondBounceStrength = 0.35
TUNING_PRESETS.ptgimax.giStrength = 1.75
TUNING_PRESETS.ptgimax.giExposure = 0.45
TUNING_PRESETS.ptgimax.svgfVarianceScale = 3.25
TUNING_PRESETS.ptgimax.candidateRetryCount = 3

TUNING_PRESETS.ptgimaxreflect = {}
for settingName, settingValue in pairs(TUNING_PRESETS.ptgimax) do
  TUNING_PRESETS.ptgimaxreflect[settingName] = settingValue
end
TUNING_PRESETS.ptgimaxreflect.reflectionsEnabled = true
TUNING_PRESETS.ptgimaxreflect.reflectionStrength = 0.80
TUNING_PRESETS.ptgimaxreflect.reflectionMaxRoughness = 0.34
TUNING_PRESETS.ptgimaxreflect.reflectionStepSize = 0.28
TUNING_PRESETS.ptgimaxreflect.reflectionThickness = 0.24
TUNING_PRESETS.ptgimaxreflect.reflectionNormalBias = 0.04
TUNING_PRESETS.ptgimaxreflect.reflectionTemporalBlend = 0.25
TUNING_PRESETS.ptgimaxreflect.reflectionDenoiseStrength = 0.50

local function beamrtLog(level, message)
  log(level, LOG_TAG, "[BeamRT] " .. message)
end

local function findObject(name)
  return scenetree.findObject(name)
end

local function setIfPresent(objectName, constantName, value)
  local object = findObject(objectName)
  if object then
    object:setShaderConst(constantName, value)
  end
end

local function finiteComponent(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and math.abs(value) < 10000000000
end

local function vector4String(vector, w)
  return string.format("%.9g %.9g %.9g %.9g", vector.x, vector.y, vector.z, w or 0)
end

local function getCurrentCameraPosition()
  if core_camera and core_camera.getPosition then
    return core_camera.getPosition()
  end
  if getCameraPosition then
    return getCameraPosition()
  end
  return nil
end

local function distanceSquaredToBox(point, boxMin, boxMax)
  local dx = math.max(boxMin.x - point.x, 0, point.x - boxMax.x)
  local dy = math.max(boxMin.y - point.y, 0, point.y - boxMax.y)
  local dz = math.max(boxMin.z - point.z, 0, point.z - boxMax.z)
  return dx * dx + dy * dy + dz * dz
end

local function normalizedAxis(vector)
  if not vector or not finiteComponent(vector.x) or not finiteComponent(vector.y) or not finiteComponent(vector.z) then
    return nil
  end
  local lengthSquared = vector.x * vector.x + vector.y * vector.y + vector.z * vector.z
  if lengthSquared < 0.00000001 then
    return nil
  end
  local inverseLength = 1 / math.sqrt(lengthSquared)
  return vec3(vector.x * inverseLength, vector.y * inverseLength, vector.z * inverseLength)
end

local function buildOrientedProxy(object, worldBox, proxyMin, proxyMax)
  if object.getObjBox and object.getTransform and object.getScale then
    local objectBox = object:getObjBox()
    local transform = object:getTransform()
    local scale = object:getScale()
    if objectBox and objectBox.minExtents and objectBox.maxExtents and transform and scale then
      local axisX = normalizedAxis(transform:getColumn(0))
      local axisY = normalizedAxis(transform:getColumn(1))
      local center = worldBox:getCenter()
      local half = vec3(
        math.abs((objectBox.maxExtents.x - objectBox.minExtents.x) * scale.x) * 0.5,
        math.abs((objectBox.maxExtents.y - objectBox.minExtents.y) * scale.y) * 0.5,
        math.abs((objectBox.maxExtents.z - objectBox.minExtents.z) * scale.z) * 0.5
      )
      if axisX and axisY and center
        and finiteComponent(center.x) and finiteComponent(center.y) and finiteComponent(center.z)
        and finiteComponent(half.x) and finiteComponent(half.y) and finiteComponent(half.z)
        and half.x >= 0 and half.y >= 0 and half.z >= 0 then
        half.x = math.max(half.x, 0.025)
        half.y = math.max(half.y, 0.025)
        half.z = math.max(half.z, 0.025)
        return center, half, axisX, axisY, true
      end
    end
  end

  local center = vec3(
    (proxyMin.x + proxyMax.x) * 0.5,
    (proxyMin.y + proxyMax.y) * 0.5,
    (proxyMin.z + proxyMax.z) * 0.5
  )
  local half = vec3(
    (proxyMax.x - proxyMin.x) * 0.5,
    (proxyMax.y - proxyMin.y) * 0.5,
    (proxyMax.z - proxyMin.z) * 0.5
  )
  return center, half, vec3(1, 0, 0), vec3(0, 1, 0), false
end

local function pointDistanceSquared(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  local dz = a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

local function markSurfelGeometryDirty()
  surfelGeometryDirtyGI = true
  surfelGeometryDirtyCache = true
end

local function appendSurfel(targetSurfels, hit, sourceName, radius, cameraPosition, maxTraceDistance)
  if not hit or not hit.pt or not hit.norm or #targetSurfels >= MAX_SURFELS then
    return false
  end
  local position = vec3(hit.pt)
  local normal = normalizedAxis(vec3(hit.norm))
  if not normal
    or not finiteComponent(position.x) or not finiteComponent(position.y) or not finiteComponent(position.z)
    or pointDistanceSquared(position, cameraPosition) > (maxTraceDistance * 1.5) ^ 2 then
    return false
  end

  local mergeDistanceSquared = math.max(radius * 0.2, 0.25) ^ 2
  for _, existing in ipairs(targetSurfels) do
    local normalAgreement = normal.x * existing.normal.x + normal.y * existing.normal.y + normal.z * existing.normal.z
    if normalAgreement > 0.95 and pointDistanceSquared(position, existing.position) <= mergeDistanceSquared then
      return false
    end
  end

  table.insert(targetSurfels, {
    position = position,
    normal = normal,
    radius = radius,
    sourceName = sourceName,
    sourceId = sourceName == "ground-grid" and 1 or 0,
  })
  return true
end

local function castSurfelRay(targetSurfels, origin, target, sourceName, radius, cameraPosition, maxTraceDistance)
  local ok, hit = pcall(Engine.castRay, origin, target, true, true)
  if not ok then
    beamrtLog("W", "surfel raycast failed: " .. tostring(hit))
    return false, false
  end
  if not hit then
    return true, false
  end
  return true, appendSurfel(targetSurfels, hit, sourceName, radius, cameraPosition, maxTraceDistance)
end

local function refreshSurfels(shouldLog)
  local cameraPosition = getCurrentCameraPosition()
  if not cameraPosition then
    if shouldLog then
      beamrtLog("W", "surfel refresh skipped: camera position is unavailable")
    end
    return false
  end

  local snapshotPosition = vec3(cameraPosition.x, cameraPosition.y, cameraPosition.z)
  local snapshotTraceDistance = surfelTraceDistance
  local snapshotBaseRadius = surfelBaseRadius
  local rays = {}
  local goldenAngle = math.pi * (3 - math.sqrt(5))

  for index = 0, SURFEL_SPHERE_RAYS - 1 do
    local z = 1 - 2 * ((index + 0.5) / SURFEL_SPHERE_RAYS)
    local radial = math.sqrt(math.max(0, 1 - z * z))
    local angle = index * goldenAngle
    local direction = vec3(math.cos(angle) * radial, math.sin(angle) * radial, z)
    table.insert(rays, {
      origin = snapshotPosition,
      target = snapshotPosition + direction * snapshotTraceDistance,
      sourceName = "fibonacci-shell",
      radius = snapshotBaseRadius,
    })
  end

  local spacing = math.min(snapshotTraceDistance * 0.2, 12)
  local gridRadius = math.max(snapshotBaseRadius, spacing * 0.75)
  for gridX = 0, 3 do
    for gridY = 0, 2 do
      local offsetX = (gridX - 1.5) * spacing
      local offsetY = (gridY - 1.0) * spacing
      table.insert(rays, {
        origin = snapshotPosition + vec3(offsetX, offsetY, math.min(snapshotTraceDistance * 0.5, 30)),
        target = snapshotPosition + vec3(offsetX, offsetY, -snapshotTraceDistance),
        sourceName = "ground-grid",
        radius = gridRadius,
      })
    end
  end

  pendingSurfelRefresh = {
    origin = snapshotPosition,
    traceDistance = snapshotTraceDistance,
    rays = rays,
    nextRay = 1,
    surfels = {},
    raysCast = 0,
    raycastFailures = 0,
    shouldLog = shouldLog and true or false,
  }
  if shouldLog then
    beamrtLog("I", string.format("world surfel refresh scheduled: %d detailed rays at %d rays/frame", #rays, surfelRefreshRaysPerFrame))
  end
  return true
end

local function refreshGeometryProxies(shouldLog)
  local cameraPosition = getCurrentCameraPosition()
  if not cameraPosition then
    geometryBoxes = {}
    geometryScanPosition = nil
    orientedGeometryProxyCount = 0
    if shouldLog then
      beamrtLog("W", "geometry proxy refresh skipped: camera position is unavailable")
    end
    return false
  end

  local candidates = {}
  local seenIds = {}
  local radiusSquared = geometryRadius * geometryRadius

  for _, className in ipairs(GEOMETRY_CLASSES) do
    local objectNames = scenetree.findClassObjects(className) or {}
    for _, objectName in ipairs(objectNames) do
      local object = findObject(objectName)
      if object and object.getWorldBox then
        local objectId = object:getId() or (className .. ":" .. tostring(objectName))
        if not seenIds[objectId] then
          seenIds[objectId] = true
          local worldBox = object:getWorldBox()
          local boxMin = worldBox and worldBox.minExtents or nil
          local boxMax = worldBox and worldBox.maxExtents or nil
          if boxMin and boxMax
            and finiteComponent(boxMin.x) and finiteComponent(boxMin.y) and finiteComponent(boxMin.z)
            and finiteComponent(boxMax.x) and finiteComponent(boxMax.y) and finiteComponent(boxMax.z)
            and boxMin.x <= boxMax.x and boxMin.y <= boxMax.y and boxMin.z <= boxMax.z then
            local extentX = boxMax.x - boxMin.x
            local extentY = boxMax.y - boxMin.y
            local extentZ = boxMax.z - boxMin.z
            local largestExtent = math.max(extentX, extentY, extentZ)
            local distanceSquared = distanceSquaredToBox(cameraPosition, boxMin, boxMax)
            if largestExtent <= geometryMaxObjectExtent and largestExtent >= 0.001 and distanceSquared <= radiusSquared then
              local proxyMin = vec3(boxMin.x, boxMin.y, boxMin.z)
              local proxyMax = vec3(boxMax.x, boxMax.y, boxMax.z)
              if extentX < 0.05 then proxyMin.x = proxyMin.x - 0.025; proxyMax.x = proxyMax.x + 0.025 end
              if extentY < 0.05 then proxyMin.y = proxyMin.y - 0.025; proxyMax.y = proxyMax.y + 0.025 end
              if extentZ < 0.05 then proxyMin.z = proxyMin.z - 0.025; proxyMax.z = proxyMax.z + 0.025 end
              local obbCenter, obbHalf, obbAxisX, obbAxisY, isOriented = buildOrientedProxy(
                object,
                worldBox,
                proxyMin,
                proxyMax
              )
              table.insert(candidates, {
                name = tostring(objectName),
                className = className,
                min = proxyMin,
                max = proxyMax,
                obbCenter = obbCenter,
                obbHalf = obbHalf,
                obbAxisX = obbAxisX,
                obbAxisY = obbAxisY,
                isOriented = isOriented,
                distanceSquared = distanceSquared,
              })
            end
          end
        end
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.distanceSquared == b.distanceSquared then
      return a.name < b.name
    end
    return a.distanceSquared < b.distanceSquared
  end)

  geometryBoxes = {}
  orientedGeometryProxyCount = 0
  for index = 1, math.min(MAX_GEOMETRY_BOXES, #candidates) do
    geometryBoxes[index] = candidates[index]
    if candidates[index].isOriented then
      orientedGeometryProxyCount = orientedGeometryProxyCount + 1
    end
  end
  geometryScanPosition = vec3(cameraPosition.x, cameraPosition.y, cameraPosition.z)

  if shouldLog then
    beamrtLog("I", string.format(
      "geometry proxies refreshed: %d uploaded (%d oriented, %d AABB fallback) from %d nearby candidates within %.1f m",
      #geometryBoxes,
      orientedGeometryProxyCount,
      #geometryBoxes - orientedGeometryProxyCount,
      #candidates,
      geometryRadius
    ))
  end
  return true
end

local function applyDebugShaderConsts()
  local effect = findObject(DEBUG_EFFECT_NAME)
  if not effect then
    return false
  end

  effect:setShaderConst("$debugMode", debugMode)
  effect:setShaderConst("$depthGain", depthGain)
  effect:setShaderConst("$positionScale", positionScale)
  effect:setShaderConst("$rayStepSize", rayStepSize)
  effect:setShaderConst("$rayThickness", rayThickness)
  effect:setShaderConst("$rayNormalBias", rayNormalBias)
  effect:setShaderConst("$rayMaxSteps", rayMaxSteps)
  effect:setShaderConst("$giStrength", giStrength)
  effect:setShaderConst("$giClamp", giClamp)
  effect:setShaderConst("$giFrameIndex", giFrameIndex)
  effect:setShaderConst("$giCellSize", giCellSize)
  effect:setShaderConst("$geometryBoxCount", #geometryBoxes)
  effect:setShaderConst("$geometryMaxDistance", geometryRadius)
  effect:setShaderConst("$surfelCount", #surfels)
  effect:setShaderConst("$surfelMaxDistance", surfelTraceDistance)
  effect:setShaderConst("$surfelVisibilityTolerance", surfelVisibilityTolerance)
  effect:setShaderConst("$worldGIStrength", worldGIStrength)
  for index = 0, MAX_GEOMETRY_BOXES - 1 do
    local geometryBox = geometryBoxes[index + 1]
    local boxMin = geometryBox and vector4String(geometryBox.min, index) or "0 0 0 0"
    local boxMax = geometryBox and vector4String(geometryBox.max, index) or "0 0 0 0"
    effect:setShaderConst("$geometryBoxMin" .. tostring(index), boxMin)
    effect:setShaderConst("$geometryBoxMax" .. tostring(index), boxMax)
    local obbCenterHalfX = geometryBox and string.format(
      "%.9g %.9g %.9g %.9g",
      geometryBox.obbCenter.x,
      geometryBox.obbCenter.y,
      geometryBox.obbCenter.z,
      geometryBox.obbHalf.x
    ) or "0 0 0 0"
    local obbAxisXHalfY = geometryBox and string.format(
      "%.9g %.9g %.9g %.9g",
      geometryBox.obbAxisX.x,
      geometryBox.obbAxisX.y,
      geometryBox.obbAxisX.z,
      geometryBox.obbHalf.y
    ) or "0 0 0 0"
    local obbAxisYHalfZ = geometryBox and string.format(
      "%.9g %.9g %.9g %.9g",
      geometryBox.obbAxisY.x,
      geometryBox.obbAxisY.y,
      geometryBox.obbAxisY.z,
      geometryBox.obbHalf.z
    ) or "0 0 0 0"
    effect:setShaderConst("$geometryObbCenterHalfX" .. tostring(index), obbCenterHalfX)
    effect:setShaderConst("$geometryObbAxisXHalfY" .. tostring(index), obbAxisXHalfY)
    effect:setShaderConst("$geometryObbAxisYHalfZ" .. tostring(index), obbAxisYHalfZ)
  end
  for index = 0, MAX_SURFELS - 1 do
    local surfel = surfels[index + 1]
    local positionRadius = surfel and string.format(
      "%.9g %.9g %.9g %.9g",
      surfel.position.x,
      surfel.position.y,
      surfel.position.z,
      surfel.radius
    ) or "0 0 0 0"
    local normalSource = surfel and string.format(
      "%.9g %.9g %.9g %.9g",
      surfel.normal.x,
      surfel.normal.y,
      surfel.normal.z,
      surfel.sourceId
    ) or "0 0 1 0"
    effect:setShaderConst("$surfelPositionRadius" .. tostring(index), positionRadius)
    effect:setShaderConst("$surfelNormalSource" .. tostring(index), normalSource)
  end
  return true
end

local function uploadSurfelGeometry(effect)
  for index = 0, MAX_SURFELS - 1 do
    local surfel = surfels[index + 1]
    local positionRadius = surfel and string.format(
      "%.9g %.9g %.9g %.9g",
      surfel.position.x,
      surfel.position.y,
      surfel.position.z,
      surfel.radius
    ) or "0 0 0 0"
    local normalSource = surfel and string.format(
      "%.9g %.9g %.9g %.9g",
      surfel.normal.x,
      surfel.normal.y,
      surfel.normal.z,
      surfel.sourceId
    ) or "0 0 1 0"
    effect:setShaderConst("$surfelPositionRadius" .. tostring(index), positionRadius)
    effect:setShaderConst("$surfelNormalSource" .. tostring(index), normalSource)
  end
end

function M._uploadGISceneVisibility(effect,force)
  local worldMeshCasters=require("ge/extensions/beamrt/worldMeshCasters")
  if not effect then return end
  local status=worldMeshCasters.getStatus()
  local generation=status.generation or 0
  if not force and M.sceneGIVisibility.revision==generation
      and M.sceneGIVisibility.lastEnabled==M.sceneGIVisibility.enabled then
    return
  end
  local triangles=M.sceneGIVisibility.enabled
    and worldMeshCasters.getOpaqueTriangles() or {}
  -- Partial map geometry is never presumed complete. The GI shader may
  -- reject paths proven blocked, but lack of a hit cannot certify a path.
  effect:setShaderConst("$sceneVisibilityEnabled",
    M.sceneGIVisibility.enabled and #triangles>0 and 1 or 0)
  effect:setShaderConst("$sceneVisibilityTriangleCount",#triangles)
  for i=0,11 do
    local tri=triangles[i+1]
    local zero={0,0,0}
    for _,part in ipairs({"A","B","C"}) do
      local v=tri and tri[part:lower()] or zero
      effect:setShaderConst("$sceneVisTri"..i..part,
        string.format("%.6f %.6f %.6f 0",v[1],v[2],v[3]))
    end
  end
  M.sceneGIVisibility.revision=generation
  M.sceneGIVisibility.lastEnabled=M.sceneGIVisibility.enabled
end

local function applyGIShaderConsts(forceGeometryRebind)
  local traceEffect = findObject(GI_EFFECT_NAME)
  if not traceEffect then
    return false
  end

  traceEffect:setShaderConst("$rayStepSize", rayStepSize)
  traceEffect:setShaderConst("$rayThickness", rayThickness)
  traceEffect:setShaderConst("$rayNormalBias", rayNormalBias)
  traceEffect:setShaderConst("$rayMaxSteps", rayMaxSteps)
  traceEffect:setShaderConst("$giClamp", giClamp)
  traceEffect:setShaderConst("$giFrameIndex", giFrameIndex)
  traceEffect:setShaderConst("$giAuxImageSize", PROGRESSIVE.inputPrep.imageSize)
  traceEffect:setShaderConst("$giCellSize", giCellSize)
  traceEffect:setShaderConst("$giPathCount", giPathCount)
  traceEffect:setShaderConst("$giSourceMode", giSourceMode)
  traceEffect:setShaderConst("$worldGIStrength", worldGIStrength)
  traceEffect:setShaderConst("$worldLeakSuppression", worldLeakSuppression)
  traceEffect:setShaderConst("$radianceCleanup", radianceCleanup)
  traceEffect:setShaderConst("$specularReject", specularReject)
  traceEffect:setShaderConst("$radianceSourceMode", radianceSourceMode)
  traceEffect:setShaderConst("$radianceChromaStrength", radianceChromaStrength)
  traceEffect:setShaderConst("$retroReject", retroReject)
  traceEffect:setShaderConst("$ptgiRadianceSourceMode", CLEAN_RADIANCE.selectedPTGISourceMode)
  traceEffect:setShaderConst("$giEstimatorMode", PROGRESSIVE.estimatorMode)
  traceEffect:setShaderConst("$giLocalization", PROGRESSIVE.localization)
  traceEffect:setShaderConst("$giSecondBounceStrength", PROGRESSIVE.secondBounceStrength)
  traceEffect:setShaderConst("$giHistoryValid", historyValid)
  traceEffect:setShaderConst("$giEmissiveBoost", PROGRESSIVE.emissiveBoost)
  traceEffect:setShaderConst("$giRayReach", PROGRESSIVE.rayReach)
  traceEffect:setShaderConst("$giRearRayReach", PROGRESSIVE.rearRayReach)
  traceEffect:setShaderConst("$giBlueNoiseStrength", PROGRESSIVE.blueNoiseStrength)
  traceEffect:setShaderConst("$giBlueNoiseMode", PROGRESSIVE.blueNoiseMode)
  traceEffect:setShaderConst("$giHitRefinementSteps", PROGRESSIVE.hitRefinementSteps)
  traceEffect:setShaderConst("$giTraceDebugMode", PROGRESSIVE.rayDebugMode)
  traceEffect:setShaderConst("$giMarcherMode", PROGRESSIVE.marcherMode)
  traceEffect:setShaderConst("$giScreenStride", PROGRESSIVE.screenRayStride)
  traceEffect:setShaderConst("$giScreenBudgetSteps", PROGRESSIVE.screenDdaMaxSteps)
  traceEffect:setShaderConst("$giScreenBudgetPaths", PROGRESSIVE.screenDdaMaxPaths)
  traceEffect:setShaderConst("$giHitValidationStrength", PROGRESSIVE.hitValidationStrength)
  traceEffect:setShaderConst("$giMinHitTravelPixels", PROGRESSIVE.minHitTravelPixels)
  traceEffect:setShaderConst("$giCandidateContinuation", PROGRESSIVE.candidateContinuation)
  traceEffect:setShaderConst("$giCandidateRetryCount", PROGRESSIVE.candidateRetryCount)
  traceEffect:setShaderConst("$giEmissiveSeparation", PROGRESSIVE.emissiveSeparation)
  traceEffect:setShaderConst("$surfelVisibilityTolerance", surfelVisibilityTolerance)
  traceEffect:setShaderConst("$surfelCacheReset", surfelCacheResetFrames > 0 and 1 or 0)
  M._uploadGISceneVisibility(traceEffect,forceGeometryRebind)
  if forceGeometryRebind or surfelGeometryDirtyGI then
    traceEffect:setShaderConst("$surfelCount", #surfels)
    traceEffect:setShaderConst("$surfelMaxDistance", surfelTraceDistance)
    uploadSurfelGeometry(traceEffect)
    surfelGeometryDirtyGI = false
  end

  setIfPresent(TEMPORAL_EFFECT_NAME, "$temporalBlend", temporalBlend)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$historyDepthTolerance", historyDepthTolerance)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$denoiseStrength", denoiseStrength)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$historyValid", historyValid)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$progressiveEnabled", PROGRESSIVE.enabled and 1 or 0)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$progressiveCurrentWeight", PROGRESSIVE.currentWeight)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$progressiveClampStrength", PROGRESSIVE.clampStrength)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$progressiveSampleCount", PROGRESSIVE.samples)
  local effectivePathCount = PROGRESSIVE.marcherMode > 0.5 and giSourceMode < 1.5
    and math.min(giPathCount, PROGRESSIVE.screenDdaMaxPaths) or giPathCount
  setIfPresent(TEMPORAL_EFFECT_NAME, "$progressivePathCount", effectivePathCount)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$lowPathRescue", PROGRESSIVE.lowPathRescue)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$svgfStrength", PROGRESSIVE.svgf.strength)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$svgfVarianceScale", PROGRESSIVE.svgf.varianceScale)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$giTraceDebugMode", PROGRESSIVE.rayDebugMode)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$echoHistoryGuard", PROGRESSIVE.echoHistoryGuard)
  setIfPresent(TEMPORAL_EFFECT_NAME, "$cameraMotion", PROGRESSIVE.cameraMotion)
  setIfPresent(PROGRESSIVE.svgf.effectName, "$historyValid", historyValid)
  setIfPresent(PROGRESSIVE.svgf.effectName, "$historyDepthTolerance", historyDepthTolerance)
  setIfPresent(PROGRESSIVE.svgf.effectName, "$momentsMaxHistory", PROGRESSIVE.svgf.maxHistory)
  for index, effectName in ipairs(PROGRESSIVE.svgf.atrousEffectNames) do
    setIfPresent(effectName, "$atrousStep", PROGRESSIVE.svgf.atrousSteps[index])
    setIfPresent(effectName, "$atrousStrength", PROGRESSIVE.svgf.strength)
    setIfPresent(effectName, "$atrousVarianceScale", PROGRESSIVE.svgf.varianceScale)
    setIfPresent(effectName, "$giTraceDebugMode", PROGRESSIVE.rayDebugMode)
  end
  setIfPresent(COMPOSE_EFFECT_NAME, "$giStrength", giStrength)
  setIfPresent(COMPOSE_EFFECT_NAME, "$lightingAccuracyMode", PROGRESSIVE.lightingAccuracyMode)
  setIfPresent(COMPOSE_EFFECT_NAME, "$contactShadowStrength", contactShadowStrength)
  setIfPresent(COMPOSE_EFFECT_NAME, "$bounceSaturation", bounceSaturation)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giExposure", giExposure)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giShadowFocus", giShadowFocus)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giReceiverTint", giReceiverTint)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giContrast", giContrast)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giEnergyLimit", giEnergyLimit)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giHighlightRolloff", giHighlightRolloff)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giRenderScale", giRenderScale)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giTraceDebugMode", PROGRESSIVE.rayDebugMode)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giLightingDiagnostic", PROGRESSIVE.lightingDiagnostic.mode)
  setIfPresent(COMPOSE_EFFECT_NAME, "$giLightingDiagnosticGain", PROGRESSIVE.lightingDiagnostic.gain)
  return true
end

local function applySurfelCacheShaderConsts(forceGeometryRebind)
  local cacheEffect = findObject(SURFEL_CACHE_EFFECT_NAME)
  if not cacheEffect then
    return false
  end

  cacheEffect:setShaderConst("$surfelVisibilityTolerance", surfelVisibilityTolerance)
  cacheEffect:setShaderConst("$surfelCacheBlend", surfelCacheBlend)
  cacheEffect:setShaderConst("$surfelCacheReset", surfelCacheResetFrames > 0 and 1 or 0)
  cacheEffect:setShaderConst("$radianceCleanup", radianceCleanup)
  cacheEffect:setShaderConst("$specularReject", specularReject)
  cacheEffect:setShaderConst("$radianceSourceMode", radianceSourceMode)
  cacheEffect:setShaderConst("$radianceChromaStrength", radianceChromaStrength)
  cacheEffect:setShaderConst("$retroReject", retroReject)
  cacheEffect:setShaderConst("$ptgiRadianceSourceMode", CLEAN_RADIANCE.selectedPTGISourceMode)
  cacheEffect:setShaderConst("$giEmissiveBoost", PROGRESSIVE.emissiveBoost)
  if forceGeometryRebind or surfelGeometryDirtyCache then
    cacheEffect:setShaderConst("$surfelCount", #surfels)
    uploadSurfelGeometry(cacheEffect)
    surfelGeometryDirtyCache = false
  end
  return true
end

function PROGRESSIVE.reflectionSampling.isFrozen()
  local status = PROGRESSIVE.lightingAudit.getStatus()
  return PROGRESSIVE.reflectionDiagnostic.mode > 0
    or type(status) == "table" and status.active == true and status.auditType == "reflection"
end

function PROGRESSIVE.reflectionHit.configured()
  return not PROGRESSIVE.reflectionConvergenceEnabled and PROGRESSIVE.reflectionHit.enabled and PROGRESSIVE.reflectionSampling.mode == 1
    and PROGRESSIVE.reflectionReconstruction.mode == 1 and not PROGRESSIVE.reflectionSampling.isFrozen()
end

function PROGRESSIVE.reflectionColor.configured()
  return not PROGRESSIVE.reflectionConvergenceEnabled and PROGRESSIVE.reflectionColor.enabled and PROGRESSIVE.reflectionSampling.mode == 1
    and PROGRESSIVE.reflectionReconstruction.mode == 1 and not PROGRESSIVE.reflectionSampling.isFrozen()
end

function PROGRESSIVE.reflectionColor.updateSizes()
  local color = PROGRESSIVE.reflectionColor
  local ok, view = pcall(function() return RenderViewManagerInstance:getView("main") end)
  if not ok then view = nil end
  local resolution = view and view.resolution
  local w = resolution and tonumber(resolution.x)
  local h = resolution and tonumber(resolution.y)
  if not w or not h or w ~= w or h ~= h or w < 1 or h < 1 or w > 32768 or h > 32768 then return end
  w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  local halfW, halfH = math.ceil(w / 2), math.ceil(h / 2)
  local quarterW, quarterH = math.ceil(halfW / 2), math.ceil(halfH / 2)
  local eighthW, eighthH = math.ceil(quarterW / 2), math.ceil(quarterH / 2)
  color.halfSize = string.format("%d %d", halfW, halfH)
  color.quarterSize = string.format("%d %d", quarterW, quarterH)
  color.eighthSize = string.format("%d %d", eighthW, eighthH)
  local half = findObject(color.halfEffectName)
  local atlas = findObject(color.atlasEffectName)
  if half and atlas then
    local atlasSize = string.format("%d %d", halfW, halfH + quarterH + eighthH)
    if half:getField("targetSize", 0) ~= color.halfSize then half:setField("targetSize", 0, color.halfSize) end
    if atlas:getField("targetSize", 0) ~= atlasSize then atlas:setField("targetSize", 0, atlasSize) end
    half:setShaderConst("$reflectionHalfSize", color.halfSize)
    atlas:setShaderConst("$reflectionHalfSize", color.halfSize)
    atlas:setShaderConst("$reflectionQuarterSize", color.quarterSize)
    atlas:setShaderConst("$reflectionEighthSize", color.eighthSize)
  end
  setIfPresent(REFLECTION_EFFECT_NAME, "$reflectionHalfSize", color.halfSize)
end

local function applyReflectionShaderConsts()
  local traceEffect = findObject(REFLECTION_EFFECT_NAME)
  if not traceEffect then
    return false
  end
  local frozen = PROGRESSIVE.reflectionSampling.isFrozen()
  local reflectionSource = PROGRESSIVE.reflectionSourceProbeTarget or "$backBuffer"
  if traceEffect:getField("texture", 2) ~= reflectionSource then traceEffect:setField("texture", 2, reflectionSource) end
  local colorSourceEffect = findObject(PROGRESSIVE.reflectionColor.halfEffectName)
  if colorSourceEffect and colorSourceEffect:getField("texture", 0) ~= reflectionSource then
    colorSourceEffect:setField("texture", 0, reflectionSource)
  end
  traceEffect:setShaderConst("$reflectionConvergenceEnabled", PROGRESSIVE.reflectionConvergenceEnabled and 1 or 0)
  traceEffect:setShaderConst("$reflectionSampleCellPixels", PROGRESSIVE.reflectionTuning.sampleCellPixels)
  traceEffect:setShaderConst("$reflectionNoiseSeed", PROGRESSIVE.reflectionTuning.noiseSeed)
  traceEffect:setShaderConst("$reflectionSourceFootprintScale", PROGRESSIVE.reflectionTuning.sourceFootprintScale)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionFilterRadiusScale", PROGRESSIVE.reflectionTuning.filterRadiusScale)
  -- Keep the experimental variance passes completely out of mirror, audit,
  -- and 128-frame convergence modes. No extra texture inputs on temporal.
  local varianceActive = PROGRESSIVE.reflectionVariance.enabled and PROGRESSIVE.reflectionSampling.mode > 0
    and PROGRESSIVE.reflectionReconstruction.mode > 0
    and PROGRESSIVE.reflectionDiagnostic.mode == 0
    and not PROGRESSIVE.reflectionConvergenceEnabled
  for _, name in ipairs({PROGRESSIVE.reflectionVariance.momentsEffectName,
      PROGRESSIVE.reflectionVariance.atrousEffectName, PROGRESSIVE.reflectionVariance.momentsCopyEffectName}) do
    local varianceEffect = findObject(name)
    if varianceEffect then varianceEffect.skip = false end
  end
  setIfPresent(PROGRESSIVE.reflectionVariance.momentsEffectName, "$reflectionHistoryValid", reflectionHistoryValid)
  setIfPresent(PROGRESSIVE.reflectionVariance.momentsEffectName, "$reflectionHistoryDepthTolerance", reflectionHistoryDepthTolerance)
  setIfPresent(PROGRESSIVE.reflectionVariance.momentsEffectName, "$reflectionCameraMotion", PROGRESSIVE.cameraMotion)
  setIfPresent(PROGRESSIVE.reflectionVariance.momentsEffectName, "$reflectionMaxRoughness", reflectionMaxRoughness)
  setIfPresent(PROGRESSIVE.reflectionVariance.momentsEffectName, "$reflectionMomentsMaxHistory", 32)
  setIfPresent(PROGRESSIVE.reflectionVariance.atrousEffectName, "$reflectionVarianceStrength", PROGRESSIVE.reflectionVariance.strength)
  setIfPresent(PROGRESSIVE.reflectionVariance.atrousEffectName, "$reflectionVarianceScale", PROGRESSIVE.reflectionVariance.scale)
  setIfPresent(PROGRESSIVE.reflectionVariance.atrousEffectName, "$reflectionMaxRoughness", reflectionMaxRoughness)
  local colorFilter = PROGRESSIVE.reflectionColor.configured()
  traceEffect:setShaderConst("$reflectionColorFilterEnabled", colorFilter and 1 or 0)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionColorFilterEnabled", colorFilter and 1 or 0)
  PROGRESSIVE.reflectionColor.updateSizes()
  local hitAware = PROGRESSIVE.reflectionHit.configured()
  local desiredFormat = (hitAware or PROGRESSIVE.reflectionConvergenceEnabled) and "GFXFormatR32G32B32A32F" or "GFXFormatR16G16B16A16F"
  if traceEffect:getField("targetFormat", 0) ~= desiredFormat then
    traceEffect:setField("targetFormat", 0, desiredFormat)
  end
  local desiredState = (hitAware or PROGRESSIVE.reflectionConvergenceEnabled) and PROGRESSIVE.reflectionHit.traceStateName or STATE_NAME
  if traceEffect:getField("stateBlock", 0) ~= desiredState then
    traceEffect:setField("stateBlock", 0, desiredState)
  end
  traceEffect:setShaderConst("$reflectionHitAwareEnabled", hitAware and 1 or 0)
  local stableSmooth = PROGRESSIVE.reflectionHit.enabled and PROGRESSIVE.reflectionSampling.mode == 1
    and PROGRESSIVE.reflectionReconstruction.mode == 1
  traceEffect:setShaderConst("$reflectionStableSmoothEnabled", stableSmooth and 1 or 0)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionHitAwareEnabled", hitAware and 1 or 0)
  setIfPresent(PROGRESSIVE.reflectionHit.inputsEffectName, "$reflectionHitAwareEnabled", hitAware and 1 or 0)
  setIfPresent(PROGRESSIVE.reflectionHit.copyEffectName, "$reflectionHitAwareEnabled", hitAware and 1 or 0)
  local temporalEffect = findObject(REFLECTION_TEMPORAL_EFFECT_NAME)
  if temporalEffect then temporalEffect.skip = PROGRESSIVE.reflectionConvergenceEnabled end
  if temporalEffect then temporalEffect:setField("texture", 3,
    hitAware and PROGRESSIVE.reflectionHit.inputsTarget or "#VelocityBuffer") end
  local metadataHistoryValid = reflectionHistoryWarmupFrames > 0 and PROGRESSIVE.motionCameraSnapshot
    and not PROGRESSIVE.cameraCutReason and 1 or 0
  setIfPresent(PROGRESSIVE.reflectionHit.inputsEffectName, "$reflectionHistoryValid", metadataHistoryValid)
  setIfPresent(PROGRESSIVE.reflectionHit.copyEffectName, "$reflectionHistoryValid", reflectionHistoryValid)
  setIfPresent(PROGRESSIVE.reflectionHit.copyEffectName, "$reflectionCameraMotion", PROGRESSIVE.cameraMotion)
  if PROGRESSIVE.reflectionHit.sync then PROGRESSIVE.reflectionHit.sync() end

  traceEffect:setShaderConst("$reflectionStepSize", reflectionStepSize)
  traceEffect:setShaderConst("$reflectionThickness", reflectionThickness)
  traceEffect:setShaderConst("$reflectionNormalBias", reflectionNormalBias)
  traceEffect:setShaderConst("$reflectionMaxSteps", reflectionMaxSteps)
  traceEffect:setShaderConst("$reflectionMaxDistance", reflectionMaxDistance)
  traceEffect:setShaderConst("$reflectionMaxRoughness", reflectionMaxRoughness)
  traceEffect:setShaderConst("$reflectionDebugMode", PROGRESSIVE.reflectionDiagnostic.mode)
  traceEffect:setShaderConst("$reflectionSamplingMode", PROGRESSIVE.reflectionSampling.mode)
  traceEffect:setShaderConst("$reflectionSampleIndex", frozen and 0 or PROGRESSIVE.reflectionSampling.sampleIndex)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionTemporalBlend", PROGRESSIVE.reflectionDiagnostic.mode > 0 and 1 or reflectionTemporalBlend)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionHistoryDepthTolerance", reflectionHistoryDepthTolerance)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionDenoiseStrength", PROGRESSIVE.reflectionDiagnostic.mode > 0 and 0 or reflectionDenoiseStrength)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionHistoryValid", reflectionHistoryValid)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionCameraMotion", PROGRESSIVE.cameraMotion)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionMaxRoughness", reflectionMaxRoughness)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionSamplingMode", PROGRESSIVE.reflectionSampling.mode)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionReconstructionMode", frozen
    and 0 or PROGRESSIVE.reflectionReconstruction.mode)
  setIfPresent(REFLECTION_TEMPORAL_EFFECT_NAME, "$reflectionFrameDelta", PROGRESSIVE.reflectionReconstruction.frameDelta)
  setIfPresent(REFLECTION_COMPOSE_EFFECT_NAME, "$reflectionStrength", reflectionStrength)
  setIfPresent(REFLECTION_COMPOSE_EFFECT_NAME, "$reflectionMaxRoughness", reflectionMaxRoughness)
  setIfPresent(REFLECTION_COMPOSE_EFFECT_NAME, "$reflectionDebugMode", PROGRESSIVE.reflectionDiagnostic.mode)
  setIfPresent(REFLECTION_COMPOSE_EFFECT_NAME, "$reflectionSamplingMode", PROGRESSIVE.reflectionSampling.mode)
  local composeEffect = findObject(REFLECTION_COMPOSE_EFFECT_NAME)
  if composeEffect then
    composeEffect:setField("texture", 1, PROGRESSIVE.reflectionDiagnostic.mode > 0
      and "#BeamRT_CurrentReflection" or (varianceActive
        and "#BeamRT_VarianceReflection" or "#BeamRT_TemporalReflection"))
  end
  return true
end

local function applyBufferDiagnosticShaderConsts()
  local applied = false
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    local effect = findObject(source.effectName)
    if effect then
      effect:setShaderConst("$diagnosticChannel", bufferDiagnosticChannel)
      effect:setShaderConst("$diagnosticGain", bufferDiagnosticGain)
      effect:setShaderConst("$diagnosticExposure", bufferDiagnosticExposure)
      effect:setShaderConst("$diagnosticHDRDecode", bufferDiagnosticHDRDecode and 1 or 0)
      applied = true
    end
  end
  return applied
end

function PROGRESSIVE.voxel.applyShaderConsts()
  local atlasEffect = findObject(PROGRESSIVE.voxel.effectName)
  local effect = findObject(PROGRESSIVE.voxel.displayEffectName)
  if not atlasEffect or not effect then return false end
  atlasEffect:setShaderConst("$giCellSize", PROGRESSIVE.voxel.cellSize)
  atlasEffect:setShaderConst("$geometryBoxCount", #geometryBoxes)
  atlasEffect:setShaderConst("$surfelCount", #surfels)
  for index = 0, MAX_GEOMETRY_BOXES - 1 do
    local geometryBox = geometryBoxes[index + 1]
    local boxMin = geometryBox and vector4String(geometryBox.min, index) or "0 0 0 0"
    local boxMax = geometryBox and vector4String(geometryBox.max, index) or "0 0 0 0"
    atlasEffect:setShaderConst("$geometryBoxMin" .. tostring(index), boxMin)
    atlasEffect:setShaderConst("$geometryBoxMax" .. tostring(index), boxMax)
    atlasEffect:setShaderConst("$geometryObbCenterHalfX" .. tostring(index), geometryBox and string.format(
      "%.9g %.9g %.9g %.9g", geometryBox.obbCenter.x, geometryBox.obbCenter.y,
      geometryBox.obbCenter.z, geometryBox.obbHalf.x) or "0 0 0 0")
    atlasEffect:setShaderConst("$geometryObbAxisXHalfY" .. tostring(index), geometryBox and string.format(
      "%.9g %.9g %.9g %.9g", geometryBox.obbAxisX.x, geometryBox.obbAxisX.y,
      geometryBox.obbAxisX.z, geometryBox.obbHalf.y) or "1 0 0 0")
    atlasEffect:setShaderConst("$geometryObbAxisYHalfZ" .. tostring(index), geometryBox and string.format(
      "%.9g %.9g %.9g %.9g", geometryBox.obbAxisY.x, geometryBox.obbAxisY.y,
      geometryBox.obbAxisY.z, geometryBox.obbHalf.z) or "0 1 0 0")
  end
  uploadSurfelGeometry(atlasEffect)
  effect:setShaderConst("$voxelCellSize", PROGRESSIVE.voxel.cellSize)
  effect:setShaderConst("$voxelDebugMode", PROGRESSIVE.voxel.debugMode)
  effect:setShaderConst("$voxelMaxSteps", PROGRESSIVE.voxel.maxSteps)
  return true
end

local function applyShaderConsts()
  applyDebugShaderConsts()
  applyGIShaderConsts()
  applySurfelCacheShaderConsts()
  applyReflectionShaderConsts()
  applyBufferDiagnosticShaderConsts()
  PROGRESSIVE.voxel.applyShaderConsts()
  if PROGRESSIVE.inputPrep.applyConsts then PROGRESSIVE.inputPrep.applyConsts() end
end

local function processPendingSurfelRefresh()
  local pending = pendingSurfelRefresh
  if not pending or (giSourceMode == 1 and not pending.shouldLog) then
    return false
  end

  local rayBudget = math.max(1, math.floor(surfelRefreshRaysPerFrame))
  for _ = 1, rayBudget do
    if pending.nextRay > #pending.rays or #pending.surfels >= MAX_SURFELS then
      break
    end

    local ray = pending.rays[pending.nextRay]
    pending.nextRay = pending.nextRay + 1
    local ok = castSurfelRay(
      pending.surfels,
      ray.origin,
      ray.target,
      ray.sourceName,
      ray.radius,
      pending.origin,
      pending.traceDistance
    )
    pending.raysCast = pending.raysCast + 1
    if not ok then
      pending.raycastFailures = pending.raycastFailures + 1
    end
  end

  if pending.nextRay <= #pending.rays and #pending.surfels < MAX_SURFELS then
    return false
  end

  -- The old completed set stays live until this atomic replacement. Only now
  -- do slot identities, the radiance atlas, and temporal GI become stale.
  surfels = pending.surfels
  surfelScanPosition = vec3(pending.origin.x, pending.origin.y, pending.origin.z)
  pendingSurfelRefresh = nil
  markSurfelGeometryDirty()
  surfelCacheResetFrames = 2
  historyValid = 0
  historyWarmupFrames = 0
  applyShaderConsts()
  if pending.shouldLog then
    beamrtLog("I", string.format(
      "world surfels refreshed: %d uploaded from %d detailed geometry rays within %.1f m (%d call failures)",
      #surfels,
      pending.raysCast,
      pending.traceDistance,
      pending.raycastFailures
    ))
  end
  return true
end

local function resetReflectionHistory(reason, shouldLog)
  reflectionHistoryValid = 0
  reflectionHistoryWarmupFrames = 0
  PROGRESSIVE.reflectionSampling.frame = 0
  PROGRESSIVE.reflectionSampling.sampleIndex = 0
  applyReflectionShaderConsts()
  if shouldLog then
    beamrtLog("I", "reflection history reset" .. (reason and (": " .. reason) or ""))
  end
end

local function resetTemporalHistory(reason, shouldLog)
  giFrameIndex = 0
  historyValid = 0
  historyWarmupFrames = 0
  PROGRESSIVE.samples = 0
  PROGRESSIVE.currentWeight = 1.0
  PROGRESSIVE.cameraSnapshot = nil
  PROGRESSIVE.motionCameraSnapshot = nil
  PROGRESSIVE.motionWindowSnapshot = nil
  PROGRESSIVE.motionWindowFrames = 0
  PROGRESSIVE.motionWindowStrength = 0.0
  PROGRESSIVE.motionWindowDistance = 0.0
  PROGRESSIVE.motionWindowRotation = 0.0
  PROGRESSIVE.motionWindowProjection = 0.0
  PROGRESSIVE.motionHoldFrames = 0
  PROGRESSIVE.motionActive = false
  PROGRESSIVE.cameraCutReason = nil
  PROGRESSIVE.cameraMotion = 0.0
  PROGRESSIVE.runtimeMode = PROGRESSIVE.enabled and "stationary progressive" or "temporal"
  PROGRESSIVE.lastReset = reason or "temporal reset"
  -- Coverage/debug modes share the GI ray parameters. Keep both constant
  -- blocks synchronized whenever a GI control resets the temporal sequence.
  applyShaderConsts()
  if shouldLog then
    beamrtLog("I", "temporal history reset" .. (reason and (": " .. reason) or ""))
  end
end

function CLEAN_RADIANCE.resetSourceDependentHistory(reason)
  surfelCacheResetFrames = math.max(surfelCacheResetFrames, 2)
  resetTemporalHistory(reason, true)
  applySurfelCacheShaderConsts()
  beamrtLog("I", "surfel radiance cache cleared: " .. tostring(reason))
end

function CLEAN_RADIANCE.fallbackToLegacy(reason)
  if CLEAN_RADIANCE.selectedPTGISource ~= "clean" then
    return false
  end
  CLEAN_RADIANCE.selectedPTGISource = "legacy"
  CLEAN_RADIANCE.selectedPTGISourceMode = 0
  CLEAN_RADIANCE.resetSourceDependentHistory("clean PTGI source invalidated")
  beamrtLog("W", "clean PTGI source became stale: " .. tostring(reason) .. "; falling back to legacy")
  return true
end

local function createStateBlock()
  for _, stateName in ipairs({PROGRESSIVE.inputPrep.stateName, PROGRESSIVE.inputPrep.traceStateName}) do
    local state = findObject(stateName)
    local isNew = not state
    if isNew then state = createObject("GFXStateBlockData") end
    state.zDefined = true
    state.zEnable = false
    state.zWriteEnable = false
    state.samplersDefined = true
    for slot = 0, 5 do
      state:setField("samplerStates", slot, stateName == PROGRESSIVE.inputPrep.traceStateName
        and slot == 2 and "SamplerClampLinear" or "SamplerClampPoint")
    end
    if isNew then state:registerObject(stateName) end
  end
  -- Reflection temporal reconstruction needs a coherent point-sampled
  -- depth/normal/roughness/F0 tuple at fractional Poisson offsets. Keep this
  -- separate because the trace pass deliberately uses linear backbuffer
  -- sampling in slot 2.
  local reflectionTemporalState = findObject("BeamRT_ReflectionTemporalState")
  local reflectionTemporalStateIsNew = not reflectionTemporalState
  if reflectionTemporalStateIsNew then
    reflectionTemporalState = createObject("GFXStateBlockData")
  end
  reflectionTemporalState.zDefined = true
  reflectionTemporalState.zEnable = false
  reflectionTemporalState.zWriteEnable = false
  reflectionTemporalState.samplersDefined = true
  reflectionTemporalState.blendDefined = true
  reflectionTemporalState.blendEnable = false
  reflectionTemporalState:setField("samplerStates", 0, "SamplerClampPoint")
  reflectionTemporalState:setField("samplerStates", 1, "SamplerClampPoint")
  reflectionTemporalState:setField("samplerStates", 2, "SamplerClampPoint")
  reflectionTemporalState:setField("samplerStates", 3, "SamplerClampPoint")
  reflectionTemporalState:setField("samplerStates", 4, "SamplerClampPoint")
  reflectionTemporalState:setField("samplerStates", 5, "SamplerClampPoint")
  if reflectionTemporalStateIsNew then
    reflectionTemporalState:registerObject("BeamRT_ReflectionTemporalState")
    beamrtLog("I", "created BeamRT_ReflectionTemporalState")
  end

  local hitTraceState = findObject(PROGRESSIVE.reflectionHit.traceStateName)
  if not hitTraceState then
    hitTraceState = createObject("GFXStateBlockData")
    hitTraceState:registerObject(PROGRESSIVE.reflectionHit.traceStateName)
  end
  hitTraceState.zDefined = true
  hitTraceState.zEnable = false
  hitTraceState.zWriteEnable = false
  hitTraceState.blendDefined = true
  hitTraceState.blendEnable = false
  hitTraceState.samplersDefined = true
  hitTraceState:setField("samplerStates", 0, "SamplerClampPoint")
  hitTraceState:setField("samplerStates", 1, "SamplerClampPoint")
  hitTraceState:setField("samplerStates", 2, "SamplerClampLinear")
  hitTraceState:setField("samplerStates", 3, "SamplerClampPoint")

  local state = findObject(STATE_NAME)
  if state then
    -- Hot object recreation can retain the v0.053 state block. Ensure the new
    -- prepass RT1 sampler is explicitly configured even without a full unload.
    state.samplersDefined = true
    state:setField("samplerStates", 5, "SamplerClampPoint")
    state:setField("samplerStates", 6, "SamplerClampPoint")
    state:setField("samplerStates", 7, "SamplerClampLinear")
    state:setField("samplerStates", 8, "SamplerClampPoint")
    state:setField("samplerStates", 9, "SamplerWrapPoint")
    state:setField("samplerStates", 10, "SamplerWrapPoint")
    state:setField("samplerStates", 11, "SamplerClampLinear")
    state:setField("samplerStates", 12, "SamplerClampPoint")
    return state
  end

  state = createObject("GFXStateBlockData")
  state.zDefined = true
  state.zEnable = false
  state.zWriteEnable = false
  state.samplersDefined = true
  state:setField("samplerStates", 0, "SamplerClampPoint")
  state:setField("samplerStates", 1, "SamplerClampPoint")
  state:setField("samplerStates", 2, "SamplerClampLinear")
  state:setField("samplerStates", 3, "SamplerClampPoint")
  state:setField("samplerStates", 4, "SamplerClampLinear")
  state:setField("samplerStates", 5, "SamplerClampPoint")
  state:setField("samplerStates", 6, "SamplerClampPoint")
  state:setField("samplerStates", 7, "SamplerClampLinear")
  state:setField("samplerStates", 8, "SamplerClampPoint")
  state:setField("samplerStates", 9, "SamplerWrapPoint")
  state:setField("samplerStates", 10, "SamplerWrapPoint")
  state:setField("samplerStates", 11, "SamplerClampLinear")
  state:setField("samplerStates", 12, "SamplerClampPoint")
  state:registerObject(STATE_NAME)
  beamrtLog("I", "created " .. STATE_NAME)
  return state
end

local function createShader(name, entry, samplerNames)
  if #samplerNames > 6 then
    error("BeamRT PostEffect shader exceeds six texture inputs: " .. tostring(name))
  end
  local shader = findObject(name)
  if shader then
    -- ShaderData objects can outlive a Lua-extension reload. Retarget the
    -- retained object so a hot reload cannot silently keep the previous
    -- reflection shader or its shorter sampler layout.
    shader.DXVertexShaderFile = entry
    shader.DXPixelShaderFile = entry
    for index, samplerName in ipairs(samplerNames) do
      shader:setField("samplerNames", index - 1, samplerName)
    end
    shader.pixVersion = 5.0
    return shader
  end

  shader = createObject("ShaderData")
  shader.DXVertexShaderFile = entry
  shader.DXPixelShaderFile = entry
  for index, samplerName in ipairs(samplerNames) do
    shader:setField("samplerNames", index - 1, samplerName)
  end
  shader.pixVersion = 5.0
  shader:registerObject(name)
  beamrtLog("I", "created " .. name .. " using " .. entry)
  return shader
end

local function createShaders()
  createShader(DEBUG_SHADER_NAME, DEBUG_SHADER_ENTRY, {
    "prepassTex", "prepassDepthTex", "backBufferTex"
  })
  createShader(GI_TRACE_SHADER_NAME, GI_TRACE_SHADER_ENTRY, {
    "prepassTex", "prepassDepthTex", "backBufferTex", "lightInfoTex", "auxiliaryTex", "materialSpecTex"
  })
  createShader(TEMPORAL_SHADER_NAME, TEMPORAL_SHADER_ENTRY, {
    "currentGITex", "prepassTex", "prepassDepthTex", "velocityTex", "historyTex", "historyMomentsTex"
  })
  createShader(PROGRESSIVE.svgf.shaderName, PROGRESSIVE.svgf.shaderEntry, {
    "currentGITex", "prepassTex", "prepassDepthTex", "velocityTex", "historyMomentsTex"
  })
  createShader(PROGRESSIVE.svgf.atrousShaderName, PROGRESSIVE.svgf.atrousShaderEntry, {
    "inputGITex", "prepassTex", "prepassDepthTex", "momentsTex"
  })
  createShader(PROGRESSIVE.voxel.atlasShaderName, PROGRESSIVE.voxel.atlasShaderEntry, {})
  createShader(PROGRESSIVE.voxel.displayShaderName, PROGRESSIVE.voxel.displayShaderEntry, {
    "voxelAtlasTex", "backBufferTex"
  })
  createShader(COMPOSE_SHADER_NAME, COMPOSE_SHADER_ENTRY, {
    "backBufferTex", "temporalGITex", "prepassTex", "prepassDepthTex", "giMomentsTex", "receiverResponseTex"
  })
  createShader(COPY_SHADER_NAME, COPY_SHADER_ENTRY, {"inputTex"})
  createShader(SURFEL_CACHE_SHADER_NAME, SURFEL_CACHE_SHADER_ENTRY, {
    "prepassTex", "prepassDepthTex", "backBufferTex", "lightInfoTex", "surfelRadianceTex", "materialSpecTex"
  })
  createShader(REFLECTION_TRACE_SHADER_NAME, REFLECTION_TRACE_SHADER_ENTRY, {
    "prepassTex", "prepassDepthTex", "backBufferTex", "materialSpecTex", "reflectionRadianceTex"
  })
  createShader(REFLECTION_TEMPORAL_SHADER_NAME, REFLECTION_TEMPORAL_SHADER_ENTRY, {
    "currentReflectionTex", "prepassTex", "prepassDepthTex", "velocityTex", "historyReflectionTex", "materialSpecTex"
  })
  createShader(REFLECTION_COMPOSE_SHADER_NAME, REFLECTION_COMPOSE_SHADER_ENTRY, {
    "backBufferTex", "temporalReflectionTex", "prepassTex", "materialSpecTex"
  })
  createShader(PROGRESSIVE.reflectionVariance.momentsShaderName, PROGRESSIVE.reflectionVariance.momentsShaderEntry, {
    "currentReflectionTex", "prepassTex", "prepassDepthTex", "velocityTex", "historyMomentsTex"
  })
  createShader(PROGRESSIVE.reflectionVariance.atrousShaderName, PROGRESSIVE.reflectionVariance.atrousShaderEntry, {
    "inputReflectionTex", "prepassTex", "prepassDepthTex", "reflectionMomentsTex", "materialSpecTex"
  })
  createShader(BUFFER_DIAGNOSTIC_SHADER_NAME, BUFFER_DIAGNOSTIC_SHADER_ENTRY, {"inputTex"})
  createShader(PROGRESSIVE.reflectionHit.inputsShaderName, PROGRESSIVE.reflectionHit.inputsShaderEntry, {
    "velocityTex", "historyHitTex"
  })
  createShader(PROGRESSIVE.reflectionHit.copyShaderName, PROGRESSIVE.reflectionHit.copyShaderEntry, {
    "currentReflectionTex", "prepassDepthTex", "hitInputsTex", "temporalReflectionTex"
  })
  createShader(PROGRESSIVE.reflectionColor.halfShaderName, PROGRESSIVE.reflectionColor.halfShaderEntry, {"sceneTex", "depthTex"})
  createShader(PROGRESSIVE.reflectionColor.atlasShaderName, PROGRESSIVE.reflectionColor.atlasShaderEntry, {"halfRadianceTex"})
  createShader(CLEAN_RADIANCE.shaderName, CLEAN_RADIANCE.shaderEntry, {
    "prepassDepthTex", "baseColorCacheTex", "metallicCacheTex", "lightInfoTex", "emissiveCacheTex"
  })
  createShader(PROGRESSIVE.inputPrep.receiverShaderName, PROGRESSIVE.inputPrep.receiverShaderEntry, {
    "backBufferTex", "prepassTex", "receiverLightInfoTex", "receiverMaterialSpecTex", "prepassDepthTex"
  })
  createShader(PROGRESSIVE.inputPrep.auxiliaryShaderName, PROGRESSIVE.inputPrep.auxiliaryShaderEntry, {
    "historyGITex", "historyMomentsTex", "velocityTex", "stbnNoiseTex", "blueNoiseTex", "surfelRadianceTex"
  })
end

local function createBufferDiagnosticEffects()
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    if not findObject(source.effectName) then
      local effect = createObject("PostEffect")
      effect.isEnabled = false
      effect.allowReflectPass = false
      effect:setField("renderTime", 0, "PFXAfterDiffuse")
      effect.renderPriority = 12000
      effect:setField("shader", 0, BUFFER_DIAGNOSTIC_SHADER_NAME)
      effect:setField("stateBlock", 0, STATE_NAME)
      effect:setField("texture", 0, source.target)
      effect:setField("target", 0, "$backBuffer")
      effect:registerObject(source.effectName)
      beamrtLog("I", "created temporary diagnostic " .. source.effectName .. " for " .. source.target)
    end
  end

end

function CLEAN_RADIANCE.markStale(reason)
  local staleReason = reason or "invalidated"
  CLEAN_RADIANCE.result.active = false
  CLEAN_RADIANCE.result.phase = "stale"
  CLEAN_RADIANCE.result.lastResult = staleReason
  CLEAN_RADIANCE.result.valid = false
  CLEAN_RADIANCE.result.stale = true
  CLEAN_RADIANCE.fallbackToLegacy(staleReason)
end

local function markMaterialCacheStale(key, reason)
  local result = materialCacheResults[key]
  if not result then
    return false
  end
  result.active = false
  result.phase = "stale"
  result.lastResult = reason or "invalidated"
  result.valid = false
  result.stale = true
  local affectsCleanRadiance = false
  for _, requiredKey in ipairs(CLEAN_RADIANCE.requiredMaterialCaches) do
    if requiredKey == key then
      affectsCleanRadiance = true
      break
    end
  end
  if affectsCleanRadiance then
    CLEAN_RADIANCE.markStale((MATERIAL_CACHE_CONFIGS[key] and MATERIAL_CACHE_CONFIGS[key].publicName or tostring(key))
      .. " cache became stale: " .. tostring(reason or "invalidated"))
  end
  return true
end

local function markAllMaterialCachesStale(reason)
  for key in pairs(MATERIAL_CACHE_CONFIGS) do
    markMaterialCacheStale(key, reason)
  end
end

local function createMaterialPublishEffect(config)
  local effect = findObject(config.publishEffectName)
  if effect then
    -- A publisher stays registered and enabled for the lifetime of the cache.
    -- skip/onThisFrame gate drawing without releasing its named target.
    effect.oneFrameOnly = true
    effect.onThisFrame = false
    effect.skip = true
    if not effect:isEnabled() then
      effect:enable()
      markMaterialCacheStale(config.key, "publisher was re-enabled")
    end
    return effect
  end

  -- This is deliberately an independent root. $backBuffer resolves/copies the
  -- active RenderView target, while $inTex is only reliable inside a chained
  -- PostEffect. During publication the main view has PostFX disabled, leaving
  -- the selected material probe as the only diffuse view allowed to execute.
  effect = createObject("PostEffect")
  effect.oneFrameOnly = true
  effect.onThisFrame = false
  effect.skip = true
  effect.isEnabled = true
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 11990
  effect:setField("shader", 0, "PFX_PassthruShader")
  effect:setField("stateBlock", 0, "PFX_DefaultBlitStateBlock")
  effect:setField("texture", 0, "$backBuffer")
  effect:setField("target", 0, config.cacheTarget)
  effect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  effect:setField("targetClear", 0, "PFXTargetClear_OnCreate")
  effect:setField("targetClearColor", 0, "0 0 0 0")
  effect:registerObject(config.publishEffectName)
  if not effect:isEnabled() then
    effect:enable()
  end
  markMaterialCacheStale(config.key, "publisher created; capture required")
  beamrtLog("I", "created dormant producer-view publisher " .. config.publishEffectName
    .. " ($backBuffer -> " .. config.cacheTarget .. ")")
  return effect
end

local function createMaterialPublishEffects()
  for _, config in pairs(MATERIAL_CACHE_CONFIGS) do
    createMaterialPublishEffect(config)
  end
end

function CLEAN_RADIANCE.createEffect(config)
  local effect = findObject(config.effectName)
  if effect then
    effect.oneFrameOnly = true
    effect.onThisFrame = false
    effect.skip = true
    effect:setShaderConst("$outputMode", config.outputMode)
    if not effect:isEnabled() then
      effect:enable()
      CLEAN_RADIANCE.markStale("clean-radiance target owner was re-enabled")
    end
    return effect
  end

  -- These targets follow the proven cache-owner lifetime rule: enabled keeps
  -- the NamedTexTarget allocated, while skip/onThisFrame prevent main-view
  -- execution except for an explicitly requested diagnostic build frame.
  effect = createObject("PostEffect")
  effect.oneFrameOnly = true
  effect.onThisFrame = false
  effect.skip = true
  effect.isEnabled = true
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 11980
  effect:setField("shader", 0, CLEAN_RADIANCE.shaderName)
  effect:setField("stateBlock", 0, STATE_NAME)
  effect:setField("texture", 0, "#prepass[Depth]")
  effect:setField("texture", 1, "#BeamRT_BaseColorCache[RT0]")
  effect:setField("texture", 2, "#BeamRT_MetallicCache[RT0]")
  effect:setField("texture", 3, "#lightinfo[RT0]")
  effect:setField("texture", 4, "#BeamRT_EmissiveCache[RT0]")
  effect:setField("target", 0, config.target)
  effect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  effect:setField("targetClear", 0, "PFXTargetClear_OnCreate")
  effect:setField("targetClearColor", 0, "0 0 0 0")
  effect:registerObject(config.effectName)
  effect:setShaderConst("$outputMode", config.outputMode)
  if not effect:isEnabled() then
    effect:enable()
  end
  beamrtLog("I", "created dormant clean-radiance diagnostic " .. config.effectName
    .. " -> " .. config.target)
  return effect
end

function CLEAN_RADIANCE.createEffects()
  for _, config in pairs(CLEAN_RADIANCE.outputs) do
    CLEAN_RADIANCE.createEffect(config)
  end
end

local function createSurfelCacheEffect()
  local effect = findObject(SURFEL_CACHE_EFFECT_NAME)
  if effect then
    effect.renderPriority = 10004
    CLEAN_RADIANCE.bindings.surfelCache = false
    return effect
  end

  effect = createObject("PostEffect")
  effect.isEnabled = false
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 10004
  effect:setField("shader", 0, SURFEL_CACHE_SHADER_NAME)
  effect:setField("stateBlock", 0, STATE_NAME)
  effect:setField("texture", 0, "#prepass[RT0]")
  effect:setField("texture", 1, "#prepass[Depth]")
  effect:setField("texture", 2, "$backBuffer")
  effect:setField("texture", 3, "#lightinfo[RT0]")
  effect:setField("texture", 4, "#BeamRT_SurfelRadianceHistory")
  effect:setField("texture", 5, "#prepass[RT1]")
  effect:setField("target", 0, "#BeamRT_SurfelRadianceCurrent")
  effect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  effect:setField("targetSize", 0, "32 4")

  local copyEffect = createObject("PostEffect")
  copyEffect:setField("shader", 0, COPY_SHADER_NAME)
  copyEffect:setField("stateBlock", 0, STATE_NAME)
  copyEffect:setField("texture", 0, "#BeamRT_SurfelRadianceCurrent")
  copyEffect:setField("target", 0, "#BeamRT_SurfelRadianceHistory")
  copyEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  copyEffect:setField("targetSize", 0, "32 4")
  copyEffect:registerObject(SURFEL_CACHE_COPY_EFFECT_NAME)

  effect:add(copyEffect)
  effect:registerObject(SURFEL_CACHE_EFFECT_NAME)
  CLEAN_RADIANCE.bindings.surfelCache = false
  beamrtLog("I", "created " .. SURFEL_CACHE_EFFECT_NAME .. " with persistent 32x4 radiance atlas")
  return effect
end

local function createDebugEffect()
  local effect = findObject(DEBUG_EFFECT_NAME)
  if effect then
    return effect
  end

  effect = createObject("PostEffect")
  effect.isEnabled = false
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 9999
  effect:setField("shader", 0, DEBUG_SHADER_NAME)
  effect:setField("stateBlock", 0, STATE_NAME)
  effect:setField("texture", 0, "#prepass[RT0]")
  effect:setField("texture", 1, "#prepass[Depth]")
  effect:setField("texture", 2, "$backBuffer")
  effect:setField("target", 0, "$backBuffer")
  effect:registerObject(DEBUG_EFFECT_NAME)
  beamrtLog("I", "created " .. DEBUG_EFFECT_NAME .. " (disabled by default)")
  return effect
end

function PROGRESSIVE.inputPrep.createEffects()
  local existing = findObject(PROGRESSIVE.inputPrep.receiverEffectName)
  local existingAuxiliary = findObject(PROGRESSIVE.inputPrep.auxiliaryEffectName)
  if existing and existingAuxiliary then return true end
  if existing then existing:delete() end
  existingAuxiliary = findObject(PROGRESSIVE.inputPrep.auxiliaryEffectName)
  if existingAuxiliary then existingAuxiliary:delete() end
  PROGRESSIVE.inputPrep.imageWidth = 0
  PROGRESSIVE.inputPrep.imageHeight = 0
  local receiver = createObject("PostEffect")
  receiver.isEnabled = false
  receiver.allowReflectPass = false
  receiver.renderPriority = 10003
  receiver:setField("renderTime", 0, "PFXAfterDiffuse")
  receiver:setField("shader", 0, PROGRESSIVE.inputPrep.receiverShaderName)
  receiver:setField("stateBlock", 0, PROGRESSIVE.inputPrep.stateName)
  receiver:setField("texture", 0, "$backBuffer")
  receiver:setField("texture", 1, "#prepass[RT0]")
  receiver:setField("texture", 2, "#lightinfo[RT0]")
  receiver:setField("texture", 3, "#prepass[RT1]")
  receiver:setField("texture", 4, "#prepass[Depth]")
  receiver:setField("target", 0, PROGRESSIVE.inputPrep.receiverTarget)
  receiver:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  receiver:setField("targetScale", 0, "1 1")
  receiver:setField("targetClear", 0, "PFXTargetClear_OnCreate")
  receiver:setField("targetClearColor", 0, "0 0 0 0")

  local auxiliary = createObject("PostEffect")
  auxiliary:setField("shader", 0, PROGRESSIVE.inputPrep.auxiliaryShaderName)
  auxiliary:setField("stateBlock", 0, PROGRESSIVE.inputPrep.stateName)
  auxiliary:setField("texture", 0, "#BeamRT_HistoryGI")
  auxiliary:setField("texture", 1, "#BeamRT_HistoryMoments")
  auxiliary:setField("texture", 2, "#VelocityBuffer")
  -- Match the shipped native RGB32 DDS layout; the loader rejects both DX10
  -- and alpha-format headers. BGRX storage preserves the decoded R/G samples.
  auxiliary:setField("texture", 3, "/shaders/beamrt/beamrtSTBN_128x128x64_rgb_atlas_linear_v094.dds")
  auxiliary:setField("texture", 4, "/shaders/common/postFx/gtao/noiseBlue.png")
  auxiliary:setField("texture", 5, "#BeamRT_SurfelRadianceCurrent")
  auxiliary:setField("target", 0, PROGRESSIVE.inputPrep.auxiliaryTarget)
  auxiliary:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  auxiliary:setField("targetSize", 0, "1152 1030")
  auxiliary:setField("targetClear", 0, "PFXTargetClear_OnCreate")
  auxiliary:setField("targetClearColor", 0, "0 0 0 0")
  auxiliary:registerObject(PROGRESSIVE.inputPrep.auxiliaryEffectName)
  receiver:add(auxiliary)
  receiver:registerObject(PROGRESSIVE.inputPrep.receiverEffectName)
  return true
end

local function createGIEffect()
  local effect = findObject(GI_EFFECT_NAME)
  if effect then
    effect.renderPriority = 10002
    effect:setField("stateBlock", 0, PROGRESSIVE.inputPrep.traceStateName)
    effect:setField("texture", 4, PROGRESSIVE.inputPrep.auxiliaryTarget)
    local temporalEffect = findObject(TEMPORAL_EFFECT_NAME)
    if temporalEffect then
      temporalEffect:setField("texture", 5, "#BeamRT_HistoryMoments")
    end
    local composeEffect = findObject(COMPOSE_EFFECT_NAME)
    if composeEffect then
      composeEffect:setField("texture", 1, PROGRESSIVE.svgf.atrousTargets[3])
      composeEffect:setField("texture", 4, "#BeamRT_CurrentMoments")
      composeEffect:setField("texture", 5, PROGRESSIVE.inputPrep.receiverTarget)
    end
    CLEAN_RADIANCE.bindings.gi = false
    return effect
  end

  effect = createObject("PostEffect")
  effect.isEnabled = false
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 10002
  effect:setField("shader", 0, GI_TRACE_SHADER_NAME)
  effect:setField("stateBlock", 0, PROGRESSIVE.inputPrep.traceStateName)
  effect:setField("texture", 0, "#prepass[RT0]")
  effect:setField("texture", 1, "#prepass[Depth]")
  effect:setField("texture", 2, "$backBuffer")
  effect:setField("texture", 3, "#lightinfo[RT0]")
  effect:setField("texture", 4, PROGRESSIVE.inputPrep.auxiliaryTarget)
  effect:setField("texture", 5, "#prepass[RT1]")
  effect:setField("target", 0, "#BeamRT_CurrentGI")
  effect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  local giScaleText = string.format("%.3g %.3g", giRenderScale, giRenderScale)
  effect:setField("targetScale", 0, giScaleText)

  local momentsEffect = createObject("PostEffect")
  momentsEffect:setField("shader", 0, PROGRESSIVE.svgf.shaderName)
  momentsEffect:setField("stateBlock", 0, STATE_NAME)
  momentsEffect:setField("texture", 0, "#BeamRT_CurrentGI")
  momentsEffect:setField("texture", 1, "#prepass[RT0]")
  momentsEffect:setField("texture", 2, "#prepass[Depth]")
  momentsEffect:setField("texture", 3, "#VelocityBuffer")
  momentsEffect:setField("texture", 4, "#BeamRT_HistoryMoments")
  momentsEffect:setField("target", 0, "#BeamRT_CurrentMoments")
  momentsEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  momentsEffect:setField("targetScale", 0, giScaleText)
  momentsEffect:registerObject(PROGRESSIVE.svgf.effectName)

  local temporalEffect = createObject("PostEffect")
  temporalEffect:setField("shader", 0, TEMPORAL_SHADER_NAME)
  temporalEffect:setField("stateBlock", 0, STATE_NAME)
  temporalEffect:setField("texture", 0, "#BeamRT_CurrentGI")
  temporalEffect:setField("texture", 1, "#prepass[RT0]")
  temporalEffect:setField("texture", 2, "#prepass[Depth]")
  temporalEffect:setField("texture", 3, "#VelocityBuffer")
  temporalEffect:setField("texture", 4, "#BeamRT_HistoryGI")
  temporalEffect:setField("texture", 5, "#BeamRT_HistoryMoments")
  temporalEffect:setField("target", 0, "#BeamRT_TemporalGI")
  temporalEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  temporalEffect:setField("targetScale", 0, giScaleText)
  temporalEffect:registerObject(TEMPORAL_EFFECT_NAME)

  local atrousEffects = {}
  for index, effectName in ipairs(PROGRESSIVE.svgf.atrousEffectNames) do
    local atrousEffect = createObject("PostEffect")
    atrousEffect:setField("shader", 0, PROGRESSIVE.svgf.atrousShaderName)
    atrousEffect:setField("stateBlock", 0, STATE_NAME)
    atrousEffect:setField("texture", 0, index == 1 and "#BeamRT_TemporalGI" or PROGRESSIVE.svgf.atrousTargets[index - 1])
    atrousEffect:setField("texture", 1, "#prepass[RT0]")
    atrousEffect:setField("texture", 2, "#prepass[Depth]")
    atrousEffect:setField("texture", 3, "#BeamRT_CurrentMoments")
    atrousEffect:setField("target", 0, PROGRESSIVE.svgf.atrousTargets[index])
    atrousEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
    atrousEffect:setField("targetScale", 0, giScaleText)
    atrousEffect:registerObject(effectName)
    atrousEffects[index] = atrousEffect
  end

  local composeEffect = createObject("PostEffect")
  composeEffect:setField("shader", 0, COMPOSE_SHADER_NAME)
  composeEffect:setField("stateBlock", 0, STATE_NAME)
  composeEffect:setField("texture", 0, "$backBuffer")
  composeEffect:setField("texture", 1, PROGRESSIVE.svgf.atrousTargets[3])
  composeEffect:setField("texture", 2, "#prepass[RT0]")
  composeEffect:setField("texture", 3, "#prepass[Depth]")
  composeEffect:setField("texture", 4, "#BeamRT_CurrentMoments")
  composeEffect:setField("texture", 5, PROGRESSIVE.inputPrep.receiverTarget)
  composeEffect:setField("target", 0, "$backBuffer")
  composeEffect:registerObject(COMPOSE_EFFECT_NAME)

  local copyEffect = createObject("PostEffect")
  copyEffect:setField("shader", 0, COPY_SHADER_NAME)
  copyEffect:setField("stateBlock", 0, STATE_NAME)
  copyEffect:setField("texture", 0, PROGRESSIVE.svgf.atrousTargets[3])
  copyEffect:setField("target", 0, "#BeamRT_HistoryGI")
  copyEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  copyEffect:setField("targetScale", 0, giScaleText)
  copyEffect:registerObject(COPY_EFFECT_NAME)

  local momentsCopyEffect = createObject("PostEffect")
  momentsCopyEffect:setField("shader", 0, COPY_SHADER_NAME)
  momentsCopyEffect:setField("stateBlock", 0, STATE_NAME)
  momentsCopyEffect:setField("texture", 0, "#BeamRT_CurrentMoments")
  momentsCopyEffect:setField("target", 0, "#BeamRT_HistoryMoments")
  momentsCopyEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  momentsCopyEffect:setField("targetScale", 0, giScaleText)
  momentsCopyEffect:registerObject(PROGRESSIVE.svgf.copyEffectName)

  copyEffect:add(momentsCopyEffect)
  composeEffect:add(copyEffect)
  atrousEffects[3]:add(composeEffect)
  atrousEffects[2]:add(atrousEffects[3])
  atrousEffects[1]:add(atrousEffects[2])
  temporalEffect:add(atrousEffects[1])
  momentsEffect:add(temporalEffect)
  effect:add(momentsEffect)
  effect:registerObject(GI_EFFECT_NAME)
  CLEAN_RADIANCE.bindings.gi = false
  beamrtLog("I", "created " .. GI_EFFECT_NAME .. " with moments, temporal, 3-pass atrous SVGF, compose, and history-copy passes (disabled by default)")
  return effect
end

function PROGRESSIVE.reflectionColor.createEffects()
  local color = PROGRESSIVE.reflectionColor
  local half = findObject(color.halfEffectName)
  local atlas = findObject(color.atlasEffectName)
  if half and atlas then PROGRESSIVE.reflectionColor.updateSizes(); return end
  if half then half:delete() end
  atlas = findObject(color.atlasEffectName)
  if atlas then atlas:delete() end
  half = createObject("PostEffect")
  half.isEnabled = false
  half.allowReflectPass = false
  half.renderPriority = 10001.75
  half:setField("renderTime", 0, "PFXAfterDiffuse")
  half:setField("shader", 0, color.halfShaderName)
  half:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  half:setField("texture", 0, "$backBuffer")
  half:setField("texture", 1, "#prepass[Depth]")
  half:setField("target", 0, color.halfTarget)
  half:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  half:setField("targetSize", 0, "1 1")
  atlas = createObject("PostEffect")
  atlas:setField("shader", 0, color.atlasShaderName)
  atlas:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  atlas.allowReflectPass = false
  atlas:setField("texture", 0, color.halfTarget)
  atlas:setField("target", 0, color.atlasTarget)
  atlas:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  atlas:setField("targetSize", 0, "1 3")
  atlas:registerObject(color.atlasEffectName)
  half:add(atlas)
  half:registerObject(color.halfEffectName)
  PROGRESSIVE.reflectionColor.updateSizes()
end

function PROGRESSIVE.reflectionHit.createInputs()
  local hit = PROGRESSIVE.reflectionHit
  local effect = findObject(hit.inputsEffectName)
  local isNew = not effect
  if not effect then
    effect = createObject("PostEffect")
    effect.isEnabled = false
    effect.allowReflectPass = false
    effect:setField("renderTime", 0, "PFXAfterDiffuse")
  end
  -- Native effects execute higher priorities first: GI 10002, pack 10001.5,
  -- then SSR 10001. Read previous geometry before this frame overwrites it.
  effect.renderPriority = 10001.5
  effect:setField("shader", 0, hit.inputsShaderName)
  effect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  effect:setField("texture", 0, "#VelocityBuffer")
  effect:setField("texture", 1, hit.historyTarget)
  effect:setField("target", 0, hit.inputsTarget)
  effect:setField("targetFormat", 0, "GFXFormatR32G32B32A32F")
  effect:setField("targetScale", 0, "1 1")
  -- Named targets must exist at native onAdd/registration time. Registering
  -- first leaves this motion-data pass without its off-screen target and can
  -- send its output into the scene instead. Reload to recreate old objects.
  if isNew then effect:registerObject(hit.inputsEffectName) end
end

function PROGRESSIVE.reflectionHit.createCopy(parent)
  local hit = PROGRESSIVE.reflectionHit
  local effect = findObject(hit.copyEffectName)
  if not effect then
    effect = createObject("PostEffect")
    effect.isEnabled = false
    effect:setField("shader", 0, hit.copyShaderName)
    effect.allowReflectPass = false
    effect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
    effect:setField("texture", 0, "#BeamRT_CurrentReflection")
    effect:setField("texture", 1, "#prepass[Depth]")
    effect:setField("texture", 2, hit.inputsTarget)
    effect:setField("texture", 3, "#BeamRT_TemporalReflection")
    effect:setField("target", 0, hit.historyTarget)
    effect:setField("targetFormat", 0, "GFXFormatR32G32B32A32F")
    effect:setField("targetScale", 0, "1 1")
    effect:registerObject(hit.copyEffectName)
    parent:add(effect)
  end
end

local function createReflectionEffect()
  PROGRESSIVE.reflectionColor.createEffects()
  PROGRESSIVE.reflectionHit.createInputs()
  local effect = findObject(REFLECTION_EFFECT_NAME)
  if effect and not findObject(PROGRESSIVE.reflectionVariance.momentsEffectName) then
    -- A prior extension reload can retain the old four-stage PostEffect tree.
    -- Recreate the reflection tree when installing these new child passes.
    for _, name in ipairs({PROGRESSIVE.reflectionHit.copyEffectName,
        REFLECTION_COPY_EFFECT_NAME, REFLECTION_COMPOSE_EFFECT_NAME,
        REFLECTION_TEMPORAL_EFFECT_NAME, REFLECTION_EFFECT_NAME}) do
      deleteObject(name)
    end
    effect = nil
  end
  if effect then
    effect.renderPriority = 10001
    effect:setField("targetScale", 0, "1 1")
    effect:setField("texture", 3, "#prepass[RT1]")
    effect:setField("texture", 4, PROGRESSIVE.reflectionColor.atlasTarget)
    local temporalEffect = findObject(REFLECTION_TEMPORAL_EFFECT_NAME)
    if temporalEffect then
      temporalEffect:setField("targetScale", 0, "1 1")
      temporalEffect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
      temporalEffect:setField("texture", 5, "#prepass[RT1]")
    end
    local composeEffect = findObject(REFLECTION_COMPOSE_EFFECT_NAME)
    if composeEffect then
      composeEffect:setField("targetScale", 0, "1 1")
      composeEffect:setField("texture", 1, PROGRESSIVE.reflectionDiagnostic.mode > 0
        and "#BeamRT_CurrentReflection" or (PROGRESSIVE.reflectionVariance.enabled
          and "#BeamRT_VarianceReflection" or "#BeamRT_TemporalReflection"))
      composeEffect:setField("texture", 3, "#prepass[RT1]")
    end
    local copyEffect = findObject(REFLECTION_COPY_EFFECT_NAME)
    if copyEffect then PROGRESSIVE.reflectionHit.createCopy(copyEffect) end
    return effect
  end

  effect = createObject("PostEffect")
  effect.isEnabled = false
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 10001
  effect:setField("shader", 0, REFLECTION_TRACE_SHADER_NAME)
  effect:setField("stateBlock", 0, STATE_NAME)
  effect:setField("texture", 0, "#prepass[RT0]")
  effect:setField("texture", 1, "#prepass[Depth]")
  effect:setField("texture", 2, "$backBuffer")
  effect:setField("texture", 3, "#prepass[RT1]")
  effect:setField("texture", 4, PROGRESSIVE.reflectionColor.atlasTarget)
  effect:setField("target", 0, "#BeamRT_CurrentReflection")
  effect:setField("targetScale", 0, "1 1")
  effect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")

  local momentsEffect = createObject("PostEffect")
  momentsEffect:setField("shader", 0, PROGRESSIVE.reflectionVariance.momentsShaderName)
  momentsEffect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  momentsEffect:setField("texture", 0, "#BeamRT_CurrentReflection")
  momentsEffect:setField("texture", 1, "#prepass[RT0]")
  momentsEffect:setField("texture", 2, "#prepass[Depth]")
  momentsEffect:setField("texture", 3, "#VelocityBuffer")
  momentsEffect:setField("texture", 4, "#BeamRT_HistoryReflectionMoments")
  momentsEffect:setField("target", 0, "#BeamRT_CurrentReflectionMoments")
  momentsEffect:setField("targetScale", 0, "1 1")
  momentsEffect:setField("targetFormat", 0, "GFXFormatR32G32B32A32F")
  momentsEffect:registerObject(PROGRESSIVE.reflectionVariance.momentsEffectName)

  local temporalEffect = createObject("PostEffect")
  temporalEffect:setField("shader", 0, REFLECTION_TEMPORAL_SHADER_NAME)
  temporalEffect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  temporalEffect:setField("texture", 0, "#BeamRT_CurrentReflection")
  temporalEffect:setField("texture", 1, "#prepass[RT0]")
  temporalEffect:setField("texture", 2, "#prepass[Depth]")
  temporalEffect:setField("texture", 3, "#VelocityBuffer")
  temporalEffect:setField("texture", 4, "#BeamRT_HistoryReflection")
  temporalEffect:setField("texture", 5, "#prepass[RT1]")
  temporalEffect:setField("target", 0, "#BeamRT_TemporalReflection")
  temporalEffect:setField("targetScale", 0, "1 1")
  temporalEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  temporalEffect:registerObject(REFLECTION_TEMPORAL_EFFECT_NAME)

  local atrousEffect = createObject("PostEffect")
  atrousEffect:setField("shader", 0, PROGRESSIVE.reflectionVariance.atrousShaderName)
  atrousEffect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  atrousEffect:setField("texture", 0, "#BeamRT_TemporalReflection")
  atrousEffect:setField("texture", 1, "#prepass[RT0]")
  atrousEffect:setField("texture", 2, "#prepass[Depth]")
  atrousEffect:setField("texture", 3, "#BeamRT_CurrentReflectionMoments")
  atrousEffect:setField("texture", 4, "#prepass[RT1]")
  atrousEffect:setField("target", 0, "#BeamRT_VarianceReflection")
  atrousEffect:setField("targetScale", 0, "1 1")
  atrousEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  atrousEffect:registerObject(PROGRESSIVE.reflectionVariance.atrousEffectName)

  local composeEffect = createObject("PostEffect")
  composeEffect:setField("shader", 0, REFLECTION_COMPOSE_SHADER_NAME)
  composeEffect:setField("stateBlock", 0, STATE_NAME)
  composeEffect:setField("texture", 0, "$backBuffer")
  composeEffect:setField("texture", 1, PROGRESSIVE.reflectionDiagnostic.mode > 0
    and "#BeamRT_CurrentReflection" or (PROGRESSIVE.reflectionVariance.enabled
      and "#BeamRT_VarianceReflection" or "#BeamRT_TemporalReflection"))
  composeEffect:setField("texture", 2, "#prepass[RT0]")
  composeEffect:setField("texture", 3, "#prepass[RT1]")
  composeEffect:setField("target", 0, "$backBuffer")
  composeEffect:setField("targetScale", 0, "1 1")
  composeEffect:registerObject(REFLECTION_COMPOSE_EFFECT_NAME)

  local copyEffect = createObject("PostEffect")
  copyEffect:setField("shader", 0, COPY_SHADER_NAME)
  copyEffect:setField("stateBlock", 0, STATE_NAME)
  copyEffect:setField("texture", 0, "#BeamRT_TemporalReflection")
  copyEffect:setField("target", 0, "#BeamRT_HistoryReflection")
  copyEffect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  copyEffect:registerObject(REFLECTION_COPY_EFFECT_NAME)
  PROGRESSIVE.reflectionHit.createCopy(copyEffect)

  local momentsCopyEffect = createObject("PostEffect")
  momentsCopyEffect:setField("shader", 0, COPY_SHADER_NAME)
  momentsCopyEffect:setField("stateBlock", 0, "BeamRT_ReflectionTemporalState")
  momentsCopyEffect:setField("texture", 0, "#BeamRT_CurrentReflectionMoments")
  momentsCopyEffect:setField("target", 0, "#BeamRT_HistoryReflectionMoments")
  momentsCopyEffect:setField("targetScale", 0, "1 1")
  momentsCopyEffect:setField("targetFormat", 0, "GFXFormatR32G32B32A32F")
  momentsCopyEffect:registerObject(PROGRESSIVE.reflectionVariance.momentsCopyEffectName)

  -- Moment history must copy only after all readers use the old history.
  copyEffect:add(momentsCopyEffect)
  composeEffect:add(copyEffect)
  atrousEffect:add(composeEffect)
  temporalEffect:add(atrousEffect)
  momentsEffect:add(temporalEffect)
  effect:add(momentsEffect)
  effect:registerObject(REFLECTION_EFFECT_NAME)
  beamrtLog("I", "created " .. REFLECTION_EFFECT_NAME .. " with premultiplied radiance, temporal reconstruction, conservative additive compose and history copy; native environment reflections retained")
  return effect
end

function PROGRESSIVE.voxel.createEffect()
  local effect = findObject(PROGRESSIVE.voxel.effectName)
  if effect then return effect end

  effect = createObject("PostEffect")
  effect.isEnabled = false
  effect.allowReflectPass = false
  effect:setField("renderTime", 0, "PFXAfterDiffuse")
  effect.renderPriority = 12010
  effect:setField("shader", 0, PROGRESSIVE.voxel.atlasShaderName)
  effect:setField("stateBlock", 0, STATE_NAME)
  effect:setField("target", 0, "#BeamRT_VoxelAtlas")
  effect:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
  effect:setField("targetSize", 0, "256 128")
  effect:setField("targetClear", 0, "PFXTargetClear_OnDraw")
  effect:setField("targetClearColor", 0, "0 0 0 0")

  local displayEffect = createObject("PostEffect")
  displayEffect:setField("shader", 0, PROGRESSIVE.voxel.displayShaderName)
  displayEffect:setField("stateBlock", 0, STATE_NAME)
  displayEffect:setField("texture", 0, "#BeamRT_VoxelAtlas[RT0]")
  displayEffect:setField("texture", 1, "$backBuffer")
  displayEffect:setField("target", 0, "$backBuffer")
  displayEffect:registerObject(PROGRESSIVE.voxel.displayEffectName)

  effect:add(displayEffect)
  effect:registerObject(PROGRESSIVE.voxel.effectName)
  beamrtLog("I", "created isolated scene-fed 32^3 voxel/DDA lab (disabled by default)")
  return effect
end

local debugCallbacks = {}

debugCallbacks.onEnabled = function()
  beamrtLog("I", "debug shader/effect enabled")
  return true
end

debugCallbacks.onDisabled = function()
  beamrtLog("I", "debug shader/effect disabled")
end

debugCallbacks.setShaderConsts = function()
  applyDebugShaderConsts()
end

local giCallbacks = {}

local surfelCacheCallbacks = {}
local reflectionCallbacks = {}
local bufferDiagnosticCallbacks = {}

PROGRESSIVE.voxel.callbacks = {}
PROGRESSIVE.voxel.callbacks.onEnabled = function()
  refreshGeometryProxies(true)
  if #surfels == 0 and not pendingSurfelRefresh then
    refreshSurfels(true)
  end
  PROGRESSIVE.voxel.applyShaderConsts()
  beamrtLog("I", "scene-fed voxel/DDA lab enabled: " .. PROGRESSIVE.voxel.debugName)
  return true
end
PROGRESSIVE.voxel.callbacks.onDisabled = function()
  beamrtLog("I", "temporary voxel/DDA lab disabled")
end
PROGRESSIVE.voxel.callbacks.setShaderConsts = function()
  PROGRESSIVE.voxel.applyShaderConsts()
end

bufferDiagnosticCallbacks.onEnabled = function()
  local source = BUFFER_DIAGNOSTIC_SOURCES[bufferDiagnosticSource]
  beamrtLog("I", "native-buffer diagnostic enabled: "
    .. (source and source.publicName or tostring(bufferDiagnosticSource))
    .. " / " .. bufferDiagnosticChannelName
    .. (bufferDiagnosticHDRDecode and " / BeamNG HDR decode" or " / raw"))
  return true
end

bufferDiagnosticCallbacks.setShaderConsts = function()
  applyBufferDiagnosticShaderConsts()
end

surfelCacheCallbacks.onEnabled = function()
  surfelCacheResetFrames = math.max(surfelCacheResetFrames, 2)
  surfelGeometryDirtyCache = true
  beamrtLog("I", "persistent surfel-radiance cache enabled")
  return true
end

surfelCacheCallbacks.onDisabled = function()
  surfelCacheResetFrames = 2
  beamrtLog("I", "persistent surfel-radiance cache disabled")
end

surfelCacheCallbacks.preProcess = function()
  applySurfelCacheShaderConsts()
  if surfelCacheResetFrames > 0 then
    surfelCacheResetFrames = surfelCacheResetFrames - 1
  end
end

surfelCacheCallbacks.setShaderConsts = function()
  applySurfelCacheShaderConsts()
end

reflectionCallbacks.onEnabled = function()
  resetReflectionHistory("reflection effect enabled", false)
  beamrtLog("I", "temporal screen-space reflections enabled")
  return true
end

reflectionCallbacks.onDisabled = function()
  resetReflectionHistory("reflection effect disabled", false)
  beamrtLog("I", "temporal screen-space reflections disabled")
end

reflectionCallbacks.preProcess = function()
  -- GI already measures this camera once at the earlier priority. SSR-only
  -- mode needs the same real-camera guard without double-ticking that window.
  if debugMode ~= MODE_IDS.diffusegi then PROGRESSIVE.updateCameraMotion() end
  if not PROGRESSIVE.motionCameraSnapshot then
    historyValid = 0
    historyWarmupFrames = 0
    reflectionHistoryValid = 0
    reflectionHistoryWarmupFrames = 0
    PROGRESSIVE.reflectionSampling.frame = 0
    PROGRESSIVE.reflectionSampling.sampleIndex = 0
    applyGIShaderConsts()
    applyReflectionShaderConsts()
    return
  end
  if PROGRESSIVE.cameraCutReason then
    reflectionHistoryWarmupFrames = 0
    reflectionHistoryValid = 0
    PROGRESSIVE.reflectionSampling.frame = 0
    PROGRESSIVE.reflectionSampling.sampleIndex = 0
  end
  reflectionHistoryValid = reflectionHistoryWarmupFrames > 0 and 1 or 0
  reflectionHistoryWarmupFrames = reflectionHistoryWarmupFrames + 1
  local sampling = PROGRESSIVE.reflectionSampling
  local frozen = sampling.isFrozen()
  sampling.sampleIndex = sampling.mode > 0 and not frozen and sampling.frame or 0
  -- Cache the sample selected for this render. setShaderConsts and UI setters
  -- can upload it repeatedly without advancing the independent SSR sequence.
  if applyReflectionShaderConsts() and sampling.mode > 0 and not frozen then
    sampling.frame = (sampling.frame + 1) % 16777216
  end
end

reflectionCallbacks.setShaderConsts = function()
  applyReflectionShaderConsts()
end

PROGRESSIVE.reflectionHit.callbacks.preProcess = function()
  -- Refresh cold/cut flags before the earlier pack. Do not measure the camera
  -- or advance the ray sequence here: the trace owns that once per frame.
  applyReflectionShaderConsts()
end

PROGRESSIVE.reflectionHit.callbacks.setShaderConsts = function()
  applyReflectionShaderConsts()
end

PROGRESSIVE.reflectionColor.callbacks.preProcess = function()
  PROGRESSIVE.reflectionColor.updateSizes()
end
PROGRESSIVE.reflectionColor.callbacks.setShaderConsts = PROGRESSIVE.reflectionColor.callbacks.preProcess

giCallbacks.onEnabled = function()
  surfelGeometryDirtyGI = true
  resetTemporalHistory("GI effect enabled", false)
  beamrtLog("I", "multi-ray PTGI lighting enabled")
  return true
end

giCallbacks.onDisabled = function()
  historyValid = 0
  historyWarmupFrames = 0
  -- Enabling calls resetTemporalHistory; also discard the frame reference now
  -- so an unexpected next preProcess cannot measure across a disabled gap.
  PROGRESSIVE.motionCameraSnapshot = nil
  PROGRESSIVE.motionWindowSnapshot = nil
  PROGRESSIVE.motionActive = false
  PROGRESSIVE.cameraMotion = 0.0
  beamrtLog("I", "temporal GI shader/effect disabled")
end

giCallbacks.preProcess = function()
  -- Keep the off-screen lighting cache centered around the player without
  -- raycasting every frame. This makes the beauty mode usable while driving.
  surfelRefreshCheckFrames = surfelRefreshCheckFrames + 1
  if giSourceMode ~= 1 and not pendingSurfelRefresh and surfelRefreshCheckFrames >= 120 then
    surfelRefreshCheckFrames = 0
    local cameraPosition = getCurrentCameraPosition()
    if cameraPosition and (not surfelScanPosition
      or pointDistanceSquared(cameraPosition, surfelScanPosition) >= surfelRefreshDistance * surfelRefreshDistance) then
      refreshSurfels(false)
    end
  end
  if not PROGRESSIVE.prepareFrame() then
    historyValid = 0
    historyWarmupFrames = 0
    reflectionHistoryValid = 0
    reflectionHistoryWarmupFrames = 0
    PROGRESSIVE.reflectionSampling.frame = 0
    PROGRESSIVE.reflectionSampling.sampleIndex = 0
    applyGIShaderConsts()
    applyReflectionShaderConsts()
    return
  end
  historyValid = historyWarmupFrames > 0 and 1 or 0
  historyWarmupFrames = historyWarmupFrames + 1
  giFrameIndex = (giFrameIndex + 1) % 4096
  applyGIShaderConsts()
end

giCallbacks.setShaderConsts = function()
  applyGIShaderConsts()
end

PROGRESSIVE.inputPrep.callbacks.preProcess = function()
  PROGRESSIVE.inputPrep.applyConsts()
end

PROGRESSIVE.inputPrep.callbacks.setShaderConsts = function()
  PROGRESSIVE.inputPrep.applyConsts()
end

local function installCallbacks()
  rawset(_G, DEBUG_CALLBACKS_NAME, debugCallbacks)
  rawset(_G, GI_CALLBACKS_NAME, giCallbacks)
  rawset(_G, SURFEL_CACHE_CALLBACKS_NAME, surfelCacheCallbacks)
  rawset(_G, REFLECTION_CALLBACKS_NAME, reflectionCallbacks)
  rawset(_G, PROGRESSIVE.reflectionHit.inputsEffectName .. "Callbacks", PROGRESSIVE.reflectionHit.callbacks)
  rawset(_G, PROGRESSIVE.reflectionColor.halfEffectName .. "Callbacks", PROGRESSIVE.reflectionColor.callbacks)
  rawset(_G, PROGRESSIVE.inputPrep.callbacksName, PROGRESSIVE.inputPrep.callbacks)
  rawset(_G, PROGRESSIVE.voxel.callbacksName, PROGRESSIVE.voxel.callbacks)
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    rawset(_G, source.effectName .. "Callbacks", bufferDiagnosticCallbacks)
  end
end

local function createObjects()
  installCallbacks()
  createStateBlock()
  createShaders()
  createDebugEffect()
  createBufferDiagnosticEffects()
  createMaterialPublishEffects()
  CLEAN_RADIANCE.createEffects()
  createSurfelCacheEffect()
  PROGRESSIVE.inputPrep.createEffects()
  createGIEffect()
  createReflectionEffect()
  PROGRESSIVE.voxel.createEffect()
  markSurfelGeometryDirty()
  applyShaderConsts()
end

local function effectIsEnabled(name)
  local effect = findObject(name)
  return effect and effect:isEnabled() or false
end

local function setEffectEnabled(name, shouldEnable)
  local effect = findObject(name)
  if not effect then
    return false
  end
  if shouldEnable and not effect:isEnabled() then
    effect:enable()
  elseif not shouldEnable and effect:isEnabled() then
    effect:disable()
  end
  return true
end

function PROGRESSIVE.reflectionHit.sync()
  local selected = enabledRequested and (debugMode == MODE_IDS.reflections
    or debugMode == MODE_IDS.diffusegi and reflectionOverlayEnabled
      and PROGRESSIVE.rayDebugMode < 0.5 and PROGRESSIVE.lightingDiagnostic.mode < 0.5)
  local active = selected and PROGRESSIVE.reflectionHit.configured()
  setEffectEnabled(PROGRESSIVE.reflectionHit.inputsEffectName, active)
  setEffectEnabled(PROGRESSIVE.reflectionHit.copyEffectName, active)
  setEffectEnabled(PROGRESSIVE.reflectionColor.halfEffectName, selected and PROGRESSIVE.reflectionColor.configured())
end

local function syncEffectEnablement()
  local useGI = enabledRequested and debugMode == MODE_IDS.diffusegi
  local useGIDiagnostic = useGI and (PROGRESSIVE.rayDebugMode > 0.5
    or PROGRESSIVE.lightingDiagnostic.mode > 0.5)
  local useSurfelCache = useGI and giSourceMode ~= 1 and PROGRESSIVE.rayDebugMode < 0.5
  local useReflections = enabledRequested and (
    debugMode == MODE_IDS.reflections
    or (debugMode == MODE_IDS.diffusegi and reflectionOverlayEnabled and not useGIDiagnostic))
  local useBufferDiagnostic = enabledRequested and debugMode == MODE_IDS.bufferdiag
  local useVoxelDDA = enabledRequested and debugMode == MODE_IDS.voxeldda
  setEffectEnabled(DEBUG_EFFECT_NAME, enabledRequested and not useGI and not useReflections and not useBufferDiagnostic and not useVoxelDDA)
  setEffectEnabled(SURFEL_CACHE_EFFECT_NAME, useSurfelCache)
  setEffectEnabled(PROGRESSIVE.inputPrep.receiverEffectName, useGI)
  setEffectEnabled(GI_EFFECT_NAME, useGI)
  setEffectEnabled(REFLECTION_EFFECT_NAME, useReflections)
  PROGRESSIVE.reflectionHit.sync()
  setEffectEnabled(PROGRESSIVE.voxel.effectName, useVoxelDDA)
  for sourceKey, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    setEffectEnabled(source.effectName, useBufferDiagnostic and sourceKey == bufferDiagnosticSource)
  end
end

local function setNormalBeamRTEffectsEnabled(shouldEnableFromState)
  if shouldEnableFromState then
    syncEffectEnablement()
    return
  end

  setEffectEnabled(DEBUG_EFFECT_NAME, false)
  setEffectEnabled(SURFEL_CACHE_EFFECT_NAME, false)
  setEffectEnabled(PROGRESSIVE.inputPrep.receiverEffectName, false)
  setEffectEnabled(GI_EFFECT_NAME, false)
  setEffectEnabled(REFLECTION_EFFECT_NAME, false)
  setEffectEnabled(PROGRESSIVE.reflectionHit.inputsEffectName, false)
  setEffectEnabled(PROGRESSIVE.reflectionHit.copyEffectName, false)
  setEffectEnabled(PROGRESSIVE.reflectionColor.halfEffectName, false)
  setEffectEnabled(PROGRESSIVE.voxel.effectName, false)
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    setEffectEnabled(source.effectName, false)
  end
end

local function deleteObject(name)
  local object = findObject(name)
  if object then
    object:delete()
  end
end

local function destroyObjects()
  setEffectEnabled(PROGRESSIVE.reflectionColor.halfEffectName, false)
  setEffectEnabled(PROGRESSIVE.reflectionHit.inputsEffectName, false)
  setEffectEnabled(PROGRESSIVE.reflectionHit.copyEffectName, false)
  CLEAN_RADIANCE.bindings.gi = false
  CLEAN_RADIANCE.bindings.surfelCache = false
  for _, config in pairs(MATERIAL_CACHE_CONFIGS) do
    setEffectEnabled(config.publishEffectName, false)
  end
  for _, config in pairs(CLEAN_RADIANCE.outputs) do
    setEffectEnabled(config.effectName, false)
  end
  setEffectEnabled(DEBUG_EFFECT_NAME, false)
  setEffectEnabled(SURFEL_CACHE_EFFECT_NAME, false)
  setEffectEnabled(PROGRESSIVE.inputPrep.receiverEffectName, false)
  setEffectEnabled(GI_EFFECT_NAME, false)
  setEffectEnabled(REFLECTION_EFFECT_NAME, false)
  setEffectEnabled(PROGRESSIVE.voxel.effectName, false)
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    setEffectEnabled(source.effectName, false)
  end
  deleteObject(GI_EFFECT_NAME)
  deleteObject(PROGRESSIVE.inputPrep.receiverEffectName)
  deleteObject(PROGRESSIVE.inputPrep.auxiliaryEffectName)
  deleteObject(TEMPORAL_EFFECT_NAME)
  deleteObject(COMPOSE_EFFECT_NAME)
  deleteObject(COPY_EFFECT_NAME)
  deleteObject(PROGRESSIVE.svgf.effectName)
  deleteObject(PROGRESSIVE.svgf.copyEffectName)
  for _, effectName in ipairs(PROGRESSIVE.svgf.atrousEffectNames) do
    deleteObject(effectName)
  end
  deleteObject(SURFEL_CACHE_EFFECT_NAME)
  deleteObject(SURFEL_CACHE_COPY_EFFECT_NAME)
  deleteObject(REFLECTION_EFFECT_NAME)
  deleteObject(REFLECTION_TEMPORAL_EFFECT_NAME)
  deleteObject(REFLECTION_COMPOSE_EFFECT_NAME)
  deleteObject(REFLECTION_COPY_EFFECT_NAME)
  deleteObject(PROGRESSIVE.reflectionVariance.momentsEffectName)
  deleteObject(PROGRESSIVE.reflectionVariance.atrousEffectName)
  deleteObject(PROGRESSIVE.reflectionVariance.momentsCopyEffectName)
  deleteObject(DEBUG_EFFECT_NAME)
  deleteObject(PROGRESSIVE.voxel.effectName)
  deleteObject(PROGRESSIVE.voxel.displayEffectName)
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    deleteObject(source.effectName)
  end
  for _, config in pairs(MATERIAL_CACHE_CONFIGS) do
    deleteObject(config.publishEffectName)
  end
  for _, config in pairs(CLEAN_RADIANCE.outputs) do
    deleteObject(config.effectName)
  end
  deleteObject(DEBUG_SHADER_NAME)
  deleteObject(GI_TRACE_SHADER_NAME)
  deleteObject(TEMPORAL_SHADER_NAME)
  deleteObject(COMPOSE_SHADER_NAME)
  deleteObject(PROGRESSIVE.inputPrep.receiverShaderName)
  deleteObject(PROGRESSIVE.inputPrep.auxiliaryShaderName)
  deleteObject(COPY_SHADER_NAME)
  deleteObject(SURFEL_CACHE_SHADER_NAME)
  deleteObject(REFLECTION_TRACE_SHADER_NAME)
  deleteObject(REFLECTION_TEMPORAL_SHADER_NAME)
  deleteObject(REFLECTION_COMPOSE_SHADER_NAME)
  deleteObject(PROGRESSIVE.reflectionVariance.momentsShaderName)
  deleteObject(PROGRESSIVE.reflectionVariance.atrousShaderName)
  deleteObject(PROGRESSIVE.reflectionHit.inputsEffectName)
  deleteObject(PROGRESSIVE.reflectionHit.copyEffectName)
  deleteObject(PROGRESSIVE.reflectionHit.inputsShaderName)
  deleteObject(PROGRESSIVE.reflectionHit.copyShaderName)
  deleteObject(PROGRESSIVE.reflectionColor.halfEffectName)
  deleteObject(PROGRESSIVE.reflectionColor.atlasEffectName)
  deleteObject(PROGRESSIVE.reflectionColor.halfShaderName)
  deleteObject(PROGRESSIVE.reflectionColor.atlasShaderName)
  deleteObject(BUFFER_DIAGNOSTIC_SHADER_NAME)
  deleteObject(CLEAN_RADIANCE.shaderName)
  deleteObject(PROGRESSIVE.svgf.shaderName)
  deleteObject(PROGRESSIVE.svgf.atrousShaderName)
  deleteObject(PROGRESSIVE.voxel.atlasShaderName)
  deleteObject(PROGRESSIVE.voxel.displayShaderName)
  deleteObject("BeamRT_ReflectionTemporalState")
  deleteObject(PROGRESSIVE.reflectionHit.traceStateName)
  deleteObject(PROGRESSIVE.inputPrep.stateName)
  deleteObject(PROGRESSIVE.inputPrep.traceStateName)
  deleteObject(STATE_NAME)
  rawset(_G, DEBUG_CALLBACKS_NAME, nil)
  rawset(_G, GI_CALLBACKS_NAME, nil)
  rawset(_G, SURFEL_CACHE_CALLBACKS_NAME, nil)
  rawset(_G, REFLECTION_CALLBACKS_NAME, nil)
  rawset(_G, PROGRESSIVE.reflectionHit.inputsEffectName .. "Callbacks", nil)
  rawset(_G, PROGRESSIVE.reflectionColor.halfEffectName .. "Callbacks", nil)
  rawset(_G, PROGRESSIVE.inputPrep.callbacksName, nil)
  rawset(_G, PROGRESSIVE.voxel.callbacksName, nil)
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    rawset(_G, source.effectName .. "Callbacks", nil)
  end
end

local function finiteNumber(value)
  local numericValue = tonumber(value)
  if not numericValue or numericValue ~= numericValue or numericValue == math.huge or numericValue == -math.huge then
    return nil
  end
  return numericValue
end

local function getRenderView(name)
  if not RenderViewManagerInstance or type(RenderViewManagerInstance.getView) ~= "function" then
    return nil, "RenderViewManagerInstance:getView is unavailable"
  end
  local ok, view = pcall(RenderViewManagerInstance.getView, RenderViewManagerInstance, name)
  if not ok or not view then
    return nil, "RenderView '" .. tostring(name) .. "' is unavailable"
  end
  return view
end

function PROGRESSIVE.inputPrep.applyConsts()
  local view = getRenderView("main")
  local width = view and math.floor((tonumber(view.resolution.x) or 1) * giRenderScale + 0.000001)
    or PROGRESSIVE.inputPrep.imageWidth
  local height = view and math.floor((tonumber(view.resolution.y) or 1) * giRenderScale + 0.000001)
    or PROGRESSIVE.inputPrep.imageHeight
  width = math.max(1, width or 1)
  height = math.max(1, height or 1)
  local auxiliary = findObject(PROGRESSIVE.inputPrep.auxiliaryEffectName)
  if width ~= PROGRESSIVE.inputPrep.imageWidth or height ~= PROGRESSIVE.inputPrep.imageHeight then
    PROGRESSIVE.inputPrep.imageWidth = width
    PROGRESSIVE.inputPrep.imageHeight = height
    PROGRESSIVE.inputPrep.imageSize = string.format("%d %d", width, height)
    if auxiliary then
      auxiliary:setField("targetSize", 0, string.format("%d %d", math.max(width, 1152), height * 2 + 1028))
    end
  end
  if auxiliary then
    auxiliary:setShaderConst("$giImageSize", PROGRESSIVE.inputPrep.imageSize)
    auxiliary:setShaderConst("$historyValid", historyWarmupFrames > 0 and 1 or 0)
  end
  setIfPresent(GI_EFFECT_NAME, "$giAuxImageSize", PROGRESSIVE.inputPrep.imageSize)
  setIfPresent(PROGRESSIVE.inputPrep.receiverEffectName, "$giReceiverTint", giReceiverTint)
end

local function getOrCreateRenderView(name)
  if not RenderViewManagerInstance or type(RenderViewManagerInstance.getOrCreateView) ~= "function" then
    return nil, "RenderViewManagerInstance:getOrCreateView is unavailable"
  end
  local ok, view = pcall(RenderViewManagerInstance.getOrCreateView, RenderViewManagerInstance, name)
  if not ok or not view then
    return nil, "RenderView '" .. tostring(name) .. "' could not be created"
  end
  return view
end

function CLEAN_RADIANCE.captureCameraSnapshot(view)
  if not view then
    return nil, "main RenderView is unavailable"
  end
  local ok, snapshot = pcall(function()
    -- Use the real camera transform, not projection/frustum data, so TAA
    -- projection jitter cannot invalidate a stationary capture.
    local matrix = type(getCameraTransform) == "function" and getCameraTransform() or view.cameraMatrix
    local position = getCurrentCameraPosition()
    local forward = matrix and normalizedAxis(matrix:getColumn(1)) or nil
    local up = matrix and normalizedAxis(matrix:getColumn(2)) or nil
    if not position or not forward or not up then
      error("camera transform could not be read")
    end
    return {
      position = {x = position.x, y = position.y, z = position.z},
      forward = {x = forward.x, y = forward.y, z = forward.z},
      up = {x = up.x, y = up.y, z = up.z},
      fov = tonumber(view.fov),
      resolution = tostring(view.resolution),
      resolutionWidth = tonumber(view.resolution.x) or 0,
      resolutionHeight = tonumber(view.resolution.y) or 0,
    }
  end)
  if not ok then
    return nil, tostring(snapshot)
  end
  return snapshot
end

function CLEAN_RADIANCE.fovChanged(referenceFov, currentFov)
  local referenceNumber = tonumber(referenceFov)
  local currentNumber = tonumber(currentFov)
  if referenceNumber and currentNumber then
    return math.abs(currentNumber - referenceNumber) > CLEAN_RADIANCE.fovToleranceDegrees
  end
  return tostring(referenceFov) ~= tostring(currentFov)
end

function PROGRESSIVE.fovPixelShift(reference, current)
  local referenceFov, currentFov = tonumber(reference.fov), tonumber(current.fov)
  if not referenceFov or not currentFov then
    return tostring(reference.fov) == tostring(current.fov) and 0 or math.huge
  end
  local oldScale = math.tan(math.rad(math.max(0.1, math.min(179, referenceFov))) * 0.5)
  local newScale = math.tan(math.rad(math.max(0.1, math.min(179, currentFov))) * 0.5)
  local extent = math.max(reference.resolutionWidth or 0, reference.resolutionHeight or 0,
    current.resolutionWidth or 0, current.resolutionHeight or 0, 1080)
  return math.abs(oldScale / newScale - 1) * extent * 0.5
end

function CLEAN_RADIANCE.compareSnapshotValues(reference, current, fovTolerancePixels)
  if not reference then
    return false, "camera snapshot is missing"
  end
  if not current then
    return false, "current camera snapshot is missing"
  end
  if current.resolution ~= reference.resolution then
    return false, "resolution changed from " .. tostring(reference.resolution)
      .. " to " .. tostring(current.resolution)
  end
  local projectionChanged = fovTolerancePixels
    and PROGRESSIVE.fovPixelShift(reference, current) > fovTolerancePixels
    or not fovTolerancePixels and CLEAN_RADIANCE.fovChanged(reference.fov, current.fov)
  if projectionChanged then
    return false, "FOV changed from " .. tostring(reference.fov) .. " to " .. tostring(current.fov)
  end

  local dx = current.position.x - reference.position.x
  local dy = current.position.y - reference.position.y
  local dz = current.position.z - reference.position.z
  local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
  if distance > CLEAN_RADIANCE.positionTolerance then
    return false, string.format("camera moved %.3f m", distance)
  end

  local forwardDot = math.max(-1, math.min(1,
    current.forward.x * reference.forward.x
      + current.forward.y * reference.forward.y
      + current.forward.z * reference.forward.z))
  local upDot = math.max(-1, math.min(1,
    current.up.x * reference.up.x
      + current.up.y * reference.up.y
      + current.up.z * reference.up.z))
  local rotationDegrees = math.deg(math.acos(math.min(forwardDot, upDot)))
  if rotationDegrees > CLEAN_RADIANCE.orientationToleranceDegrees then
    return false, string.format("camera rotated %.3f degrees", rotationDegrees)
  end
  return true
end

function CLEAN_RADIANCE.compareCameraSnapshot(view)
  local current, captureError = CLEAN_RADIANCE.captureCameraSnapshot(view)
  if not current then
    return false, captureError
  end
  return CLEAN_RADIANCE.compareSnapshotValues(CLEAN_RADIANCE.result.cameraSnapshot, current)
end

function PROGRESSIVE.updateCameraMotion()
  local view = getRenderView("main")
  local current = view and CLEAN_RADIANCE.captureCameraSnapshot(view) or nil
  PROGRESSIVE.cameraCutReason = nil
  if not current then
    PROGRESSIVE.cameraMotion = 1.0
    PROGRESSIVE.motionCameraSnapshot = nil
    PROGRESSIVE.motionWindowSnapshot = nil
    PROGRESSIVE.motionActive = false
    return false
  end

  local previous = PROGRESSIVE.motionCameraSnapshot
  PROGRESSIVE.motionCameraSnapshot = current
  if not previous then
    PROGRESSIVE.cameraMotion = 0.0
    PROGRESSIVE.motionWindowSnapshot = current
    PROGRESSIVE.motionWindowFrames = 0
    PROGRESSIVE.motionWindowStrength = 0.0
    PROGRESSIVE.motionWindowDistance = 0.0
    PROGRESSIVE.motionWindowRotation = 0.0
    PROGRESSIVE.motionWindowProjection = 0.0
    PROGRESSIVE.motionHoldFrames = 0
    PROGRESSIVE.motionActive = false
    return true
  end

  local function measure(reference)
    local dx = current.position.x - reference.position.x
    local dy = current.position.y - reference.position.y
    local dz = current.position.z - reference.position.z
    local forwardDot = math.max(-1, math.min(1,
      current.forward.x * reference.forward.x
        + current.forward.y * reference.forward.y
        + current.forward.z * reference.forward.z))
    local upDot = math.max(-1, math.min(1,
      current.up.x * reference.up.x
        + current.up.y * reference.up.y
        + current.up.z * reference.up.z))
    return math.sqrt(dx * dx + dy * dy + dz * dz),
      math.deg(math.acos(math.min(forwardDot, upDot))),
      PROGRESSIVE.fovPixelShift(reference, current)
  end
  local distance, rotationDegrees, projectionPixels = measure(previous)
  if current.resolution ~= previous.resolution
    or current.resolutionWidth ~= previous.resolutionWidth
    or current.resolutionHeight ~= previous.resolutionHeight then
    PROGRESSIVE.cameraCutReason = "resolution changed"
  elseif distance > 5 then
    PROGRESSIVE.cameraCutReason = string.format("camera cut moved %.3f m", distance)
  elseif rotationDegrees > 45 then
    PROGRESSIVE.cameraCutReason = string.format("camera cut rotated %.3f degrees", rotationDegrees)
  elseif projectionPixels >= 8 then
    PROGRESSIVE.cameraCutReason = "large FOV change"
  end
  if PROGRESSIVE.cameraCutReason then
    PROGRESSIVE.cameraMotion = 1.0
    PROGRESSIVE.motionWindowSnapshot = current
    PROGRESSIVE.motionWindowFrames = 0
    PROGRESSIVE.motionWindowStrength = 0.0
    PROGRESSIVE.motionWindowDistance = 0.0
    PROGRESSIVE.motionWindowRotation = 0.0
    PROGRESSIVE.motionWindowProjection = 0.0
    PROGRESSIVE.motionHoldFrames = 0
    PROGRESSIVE.motionActive = false
    return true
  end

  local positionMotion = math.max(0, math.min(1, (distance - 0.001) / 0.029))
  local rotationMotion = math.max(0, math.min(1, (rotationDegrees - 0.01) / 0.24))
  -- RenderView FOV breathes by thousandths of a degree even at rest. Judge
  -- projection changes by their visible pixel displacement, and let deliberate
  -- zoom use the guarded moving-camera history instead of clearing every frame.
  local projectionMotion = math.max(0, math.min(1,
    (projectionPixels - 0.35) / 1.65))
  local frameMotion = math.max(positionMotion, rotationMotion, projectionMotion)
  local windowMotion = 0.0
  PROGRESSIVE.motionWindowSnapshot = PROGRESSIVE.motionWindowSnapshot or previous
  PROGRESSIVE.motionWindowFrames = (PROGRESSIVE.motionWindowFrames or 0) + 1
  PROGRESSIVE.motionWindowDistance = (PROGRESSIVE.motionWindowDistance or 0) + distance
  PROGRESSIVE.motionWindowRotation = (PROGRESSIVE.motionWindowRotation or 0) + rotationDegrees
  PROGRESSIVE.motionWindowProjection = (PROGRESSIVE.motionWindowProjection or 0) + projectionPixels
  PROGRESSIVE.motionHoldFrames = math.max((PROGRESSIVE.motionHoldFrames or 0) - 1, 0)
  -- A bounded reference window detects coherent sub-deadzone drift without
  -- treating bounded transform/FOV jitter as camera movement. Keep the motion
  -- state until the next window can confirm that the camera has settled.
  if PROGRESSIVE.motionWindowFrames >= 8 then
    local windowDistance, windowRotation, windowProjection = measure(PROGRESSIVE.motionWindowSnapshot)
    windowMotion = math.max(
      math.max(0, math.min(1, (windowDistance - 0.001) / 0.029)),
      math.max(0, math.min(1, (windowRotation - 0.002) / 0.048)),
      math.max(0, math.min(1, (windowProjection - 0.35) / 1.65)))
    -- Once movement has been established, continued coherent drift can be
    -- smaller than the entry deadzone. Net travel must account for most of
    -- the path travelled in this window, so reversing/bounded camera jitter
    -- still lets the moving state settle instead of keeping it latched.
    if PROGRESSIVE.motionActive and (
      windowDistance > 0.000001 and windowDistance >= PROGRESSIVE.motionWindowDistance * 0.8
      or windowRotation > 0.00001 and windowRotation >= PROGRESSIVE.motionWindowRotation * 0.8
      or windowProjection > 0.01 and windowProjection >= PROGRESSIVE.motionWindowProjection * 0.8) then
      windowMotion = math.max(windowMotion, 0.01)
    end
    PROGRESSIVE.motionWindowSnapshot = current
    PROGRESSIVE.motionWindowFrames = 0
    PROGRESSIVE.motionWindowDistance = 0.0
    PROGRESSIVE.motionWindowRotation = 0.0
    PROGRESSIVE.motionWindowProjection = 0.0
    -- Window displacement decides whether motion is coherent; it is not a
    -- per-frame velocity. Preserve the established guard strength for faster
    -- motion and give slow drift only a small nonzero motion signal.
    PROGRESSIVE.motionWindowStrength = windowMotion > 0.001 and 0.01 or 0.0
  end
  if frameMotion > 0.001 or windowMotion > 0.001 then
    PROGRESSIVE.motionHoldFrames = 8
  end
  PROGRESSIVE.motionActive = PROGRESSIVE.motionHoldFrames > 0
  PROGRESSIVE.cameraMotion = math.max(frameMotion, PROGRESSIVE.motionWindowStrength or 0)
  return true
end

function PROGRESSIVE.prepareFrame()
  PROGRESSIVE.updateCameraMotion()
  local view, viewError = getRenderView("main")
  if not view then
    PROGRESSIVE.runtimeMode = "unavailable"
    PROGRESSIVE.samples = 0
    PROGRESSIVE.currentWeight = 1.0
    PROGRESSIVE.cameraSnapshot = nil
    PROGRESSIVE.lastReset = viewError or "main RenderView unavailable"
    return false
  end
  local current = PROGRESSIVE.motionCameraSnapshot
  if not current then
    PROGRESSIVE.runtimeMode = "unavailable"
    PROGRESSIVE.samples = 0
    PROGRESSIVE.currentWeight = 1.0
    PROGRESSIVE.cameraSnapshot = nil
    PROGRESSIVE.lastReset = "camera snapshot failed"
    return false
  end

  if PROGRESSIVE.cameraCutReason then
    local previousSamples = PROGRESSIVE.samples
    PROGRESSIVE.samples = 0
    PROGRESSIVE.currentWeight = 1.0
    PROGRESSIVE.cameraSnapshot = current
    PROGRESSIVE.lastReset = PROGRESSIVE.cameraCutReason
    giFrameIndex = 0
    historyValid = 0
    historyWarmupFrames = 0
    if previousSamples > giPathCount then
      beamrtLog("I", "progressive PTGI reset after " .. tostring(previousSamples)
        .. " samples: " .. tostring(PROGRESSIVE.cameraCutReason))
    end
  end
  if not PROGRESSIVE.enabled then
    PROGRESSIVE.runtimeMode = "temporal"
    PROGRESSIVE.currentWeight = temporalBlend
    PROGRESSIVE.cameraSnapshot = current
    return true
  end

  local matches = not PROGRESSIVE.cameraSnapshot
    or CLEAN_RADIANCE.compareSnapshotValues(PROGRESSIVE.cameraSnapshot, current, 0.75)
  -- Both per-frame motion and cumulative exposure drift use short,
  -- depth/normal/clamp-guarded history. Only a cut or projection discontinuity
  -- above clears history and restarts the sampler sequence.
  if PROGRESSIVE.motionActive or not matches then
    if not matches then
      PROGRESSIVE.motionActive = true
      PROGRESSIVE.motionHoldFrames = 8
      PROGRESSIVE.cameraMotion = math.max(PROGRESSIVE.cameraMotion, 0.01)
    end
    PROGRESSIVE.runtimeMode = "motion temporal"
    PROGRESSIVE.samples = 0
    PROGRESSIVE.currentWeight = temporalBlend
    PROGRESSIVE.cameraSnapshot = current
    PROGRESSIVE.lastReset = "camera moving; using guarded temporal history"
    return true
  end

  local effectivePathCount = PROGRESSIVE.marcherMode > 0.5 and giSourceMode < 1.5
    and math.min(giPathCount, PROGRESSIVE.screenDdaMaxPaths) or giPathCount
  if PROGRESSIVE.runtimeMode == "motion temporal" and historyWarmupFrames > 0
    and not PROGRESSIVE.cameraCutReason then
    -- The temporal result already represents several effective batches. Seed
    -- the stationary exposure from that finite history so stopping does not
    -- replace it with a noisy, full-weight single frame.
    PROGRESSIVE.samples = math.min(math.max(PROGRESSIVE.maxSamples - effectivePathCount, 0),
      math.floor(effectivePathCount * (1 / math.max(temporalBlend, 0.001) - 1) + 0.5))
    PROGRESSIVE.cameraSnapshot = current
  end
  PROGRESSIVE.runtimeMode = "stationary progressive"
  if not PROGRESSIVE.cameraSnapshot then
    PROGRESSIVE.cameraSnapshot = current
  end

  local remaining = math.max(PROGRESSIVE.maxSamples - PROGRESSIVE.samples, 0)
  local batchSamples = math.min(effectivePathCount, remaining)
  if batchSamples > 0 then
    PROGRESSIVE.currentWeight = batchSamples / math.max(PROGRESSIVE.samples + batchSamples, 1)
    PROGRESSIVE.samples = PROGRESSIVE.samples + batchSamples
  else
    PROGRESSIVE.currentWeight = 0.0
  end
  return true
end

function PROGRESSIVE.status()
  return {
    enabled = PROGRESSIVE.enabled,
    samples = PROGRESSIVE.samples,
    maxSamples = PROGRESSIVE.maxSamples,
    currentWeight = PROGRESSIVE.currentWeight,
    clampStrength = PROGRESSIVE.clampStrength,
    lastReset = PROGRESSIVE.lastReset,
    estimator = PROGRESSIVE.estimatorName,
    localization = PROGRESSIVE.localization,
    secondBounceStrength = PROGRESSIVE.secondBounceStrength,
    emissiveBoost = PROGRESSIVE.emissiveBoost,
    rayReach = PROGRESSIVE.rayReach,
    rearRayReach = PROGRESSIVE.rearRayReach,
    lowPathRescue = PROGRESSIVE.lowPathRescue,
    runtimeMode = PROGRESSIVE.runtimeMode,
    blueNoiseStrength = PROGRESSIVE.blueNoiseStrength,
    blueNoiseSource = PROGRESSIVE.blueNoiseSource,
    svgfStrength = PROGRESSIVE.svgf.strength,
    svgfVarianceScale = PROGRESSIVE.svgf.varianceScale,
    svgfMaxHistory = PROGRESSIVE.svgf.maxHistory,
    hitRefinementSteps = PROGRESSIVE.hitRefinementSteps,
    rayMarcher = PROGRESSIVE.marcherName,
    screenRayStride = PROGRESSIVE.screenRayStride,
    screenDdaMaxPaths = PROGRESSIVE.screenDdaMaxPaths,
    screenDdaMaxSteps = PROGRESSIVE.screenDdaMaxSteps,
    hitValidationStrength = PROGRESSIVE.hitValidationStrength,
    minHitTravelPixels = PROGRESSIVE.minHitTravelPixels,
    echoHistoryGuard = PROGRESSIVE.echoHistoryGuard,
    cameraMotion = PROGRESSIVE.cameraMotion,
    candidateContinuation = PROGRESSIVE.candidateContinuation,
    candidateRetryCount = PROGRESSIVE.candidateRetryCount,
    emissiveSeparation = PROGRESSIVE.emissiveSeparation,
    rayHitDiagnostic = PROGRESSIVE.rayDebugName,
  }
end

function CLEAN_RADIANCE.validateGenerations()
  local sources = CLEAN_RADIANCE.result.sourceGenerations
  if type(sources) ~= "table" then
    return false, "clean-radiance source generations are missing"
  end
  local sharedGeneration = nil
  for key, config in pairs(MATERIAL_CACHE_CONFIGS) do
    local result = materialCacheResults[key]
    local expected = sources[key]
    if not result or not result.valid or result.stale then
      return false, config.publicName .. " cache is stale or invalid"
    end
    if expected == nil or result.generation ~= expected then
      return false, config.publicName .. " cache generation changed"
    end
    if sharedGeneration and expected ~= sharedGeneration then
      return false, "material-cache generation mismatch"
    end
    sharedGeneration = expected
  end
  return true
end

function CLEAN_RADIANCE.validateUsable(checkCamera)
  if not CLEAN_RADIANCE.result.valid then
    return false, CLEAN_RADIANCE.result.lastResult or "clean-radiance cache is invalid"
  end
  if CLEAN_RADIANCE.result.stale then
    return false, CLEAN_RADIANCE.result.lastResult or "clean-radiance cache is stale"
  end
  local generationsMatch, generationReason = CLEAN_RADIANCE.validateGenerations()
  if not generationsMatch then
    return false, generationReason
  end
  if not CLEAN_RADIANCE.bindings.gi or not findObject(GI_EFFECT_NAME) then
    return false, "GI path does not have the clean-radiance target bound"
  end
  if not CLEAN_RADIANCE.bindings.surfelCache or not findObject(SURFEL_CACHE_EFFECT_NAME) then
    return false, "surfel-cache path does not have the clean-radiance target bound"
  end
  for _, config in pairs(CLEAN_RADIANCE.outputs) do
    local owner = findObject(config.effectName)
    if not owner or not owner:isEnabled() then
      return false, config.publicName .. " target owner is missing or disabled"
    end
  end
  if checkCamera then
    local mainView, mainError = getRenderView("main")
    if not mainView then
      return false, mainError
    end
    local cameraMatches, cameraReason = CLEAN_RADIANCE.compareCameraSnapshot(mainView)
    if not cameraMatches then
      return false, cameraReason
    end
  end
  return true
end

function CLEAN_RADIANCE.validateSelectedSource()
  if CLEAN_RADIANCE.selectedPTGISource ~= "clean" then
    return true
  end
  local usable, reason = CLEAN_RADIANCE.validateUsable(true)
  if usable then
    return true
  end
  CLEAN_RADIANCE.markStale(reason)
  return false
end

local function setMaterialDebugMode(mode)
  local materialDebug = rawget(_G, "util_materialDebugViz")
  if not materialDebug and extensions and type(extensions.load) == "function" then
    pcall(extensions.load, "util_materialDebugViz")
    materialDebug = rawget(_G, "util_materialDebugViz")
  end
  if not materialDebug or type(materialDebug.set) ~= "function" then
    return false, "util_materialDebugViz.set is unavailable"
  end
  local ok, err = pcall(materialDebug.set, mode)
  return ok, ok and nil or tostring(err)
end

local function copyRenderViewField(destination, source, fieldName)
  local ok, err = pcall(function()
    destination[fieldName] = source[fieldName]
  end)
  if not ok then
    return false, fieldName .. ": " .. tostring(err)
  end
  return true
end

local function synchronizeMaterialProbeCamera(probeView, mainView)
  for _, fieldName in ipairs({"cameraMatrix", "frustum", "fov", "resolution", "viewPort"}) do
    local ok, err = copyRenderViewField(probeView, mainView, fieldName)
    if not ok then
      return false, err
    end
  end
  return true
end

local function getOrCreateMaterialProbeView(config, mainView)
  local probeView, errorMessage = getOrCreateRenderView(config.probeViewName)
  if not probeView then
    return nil, errorMessage
  end

  local ok, configureError = pcall(function()
    probeView.luaOwned = true
    probeView.renderCubemap = false
    probeView.renderEditorIcons = false
    probeView.namedTexTargetColor = config.probeTargetName
    probeView.usePostEffects = false
    probeView.active = false
  end)
  if not ok then
    return nil, "could not configure RenderView '" .. config.probeViewName .. "': " .. tostring(configureError)
  end

  local cameraOk, cameraError = synchronizeMaterialProbeCamera(probeView, mainView)
  if not cameraOk then
    return nil, "camera synchronization failed at " .. tostring(cameraError)
  end
  return probeView
end

local function finishMaterialCachePublication(resultMessage, completed)
  local publication = materialCachePublication
  if not publication then
    return false
  end

  local config = publication.config
  local result = materialCacheResults[config.key]

  -- Ordering is intentional: make the permanently-enabled publisher dormant
  -- before allowing any other RenderView to run PostFX again. Disabling the
  -- PostEffect would release the named target and destroy the frozen cache.
  local publishEffect = findObject(config.publishEffectName)
  if publishEffect then
    publishEffect.onThisFrame = false
    publishEffect.skip = true
  end
  if publication.probeView then
    pcall(function() publication.probeView.active = false end)
    pcall(function() publication.probeView.usePostEffects = false end)
  end
  local materialOk, materialErr = setMaterialDebugMode("Material_None")
  if not materialOk then
    beamrtLog("E", "could not restore Material_None after " .. config.publicName
      .. " publication: " .. tostring(materialErr))
  end
  if publication.mainView then
    pcall(function() publication.mainView.usePostEffects = publication.mainUsePostEffects end)
  end

  modeName = publication.modeName
  debugMode = publication.debugMode
  enabledRequested = publication.enabledRequested
  materialCachePublication = nil
  syncEffectEnablement()

  result.active = false
  result.lastResult = resultMessage or "completed"
  if completed then
    local snapshot, snapshotError = CLEAN_RADIANCE.captureCameraSnapshot(publication.mainView)
    if not snapshot then
      completed = false
      result.lastResult = "camera snapshot failed: " .. tostring(snapshotError)
    else
      local cameraMatches, cameraReason = CLEAN_RADIANCE.compareSnapshotValues(
        publication.cameraSnapshot,
        snapshot)
      if not cameraMatches then
        completed = false
        result.lastResult = "camera changed during material-cache capture: " .. tostring(cameraReason)
      else
        result.cameraSnapshot = snapshot
      end
    end
  end
  if completed then
    result.phase = "frozen"
    result.valid = true
    result.stale = false
    result.generation = (result.generation or 0) + 1
    local resolutionOk, resolution = pcall(function() return tostring(publication.mainView.resolution) end)
    result.resolution = resolutionOk and resolution or nil
  else
    result.phase = "stale"
    result.valid = false
    result.stale = true
    result.cameraSnapshot = nil
  end
  beamrtLog(completed and "I" or "W", config.publicName .. " producer publication ended; "
    .. config.cacheTarget .. (completed and " is frozen and valid (" or " is stale (")
    .. result.lastResult .. ")")
  return true
end

local function processMaterialCachePublication()
  if not materialCachePublication then
    return
  end
  materialCachePublication.captureUpdates = materialCachePublication.captureUpdates + 1
  local result = materialCacheResults[materialCachePublication.config.key]
  if materialCachePublication.captureUpdates == 1 then
    result.phase = "capture frame"
    return
  end
  local completedKey = materialCachePublication.config.key
  finishMaterialCachePublication("completed one producer-view capture frame", true)

  if CLEAN_RADIANCE.materialBatch then
    local completedResult = materialCacheResults[completedKey]
    if not completedResult or not completedResult.valid or completedResult.stale then
      beamrtLog("E", "Material V2 batch aborted because " .. tostring(completedKey) .. " did not publish cleanly")
      CLEAN_RADIANCE.materialBatch = nil
      return
    end
    -- A batch is one coherent material snapshot. Give every channel the same
    -- generation even if earlier manual captures had different per-cache counts.
    completedResult.generation = CLEAN_RADIANCE.materialBatch.generation

    CLEAN_RADIANCE.materialBatch.index = CLEAN_RADIANCE.materialBatch.index + 1
    local nextKey = CLEAN_RADIANCE.materialBatch.keys[CLEAN_RADIANCE.materialBatch.index]
    if not nextKey then
      beamrtLog("I", "Material V2 batch complete; all evaluated material caches are frozen")
      CLEAN_RADIANCE.materialBatch = nil
      return
    end

    local mainView = getRenderView("main")
    local snapshot = mainView and CLEAN_RADIANCE.captureCameraSnapshot(mainView) or nil
    local cameraMatches, cameraReason = CLEAN_RADIANCE.compareSnapshotValues(
      CLEAN_RADIANCE.materialBatch.cameraSnapshot, snapshot)
    if not cameraMatches then
      beamrtLog("E", "Material V2 batch aborted because the camera moved: " .. tostring(cameraReason))
      CLEAN_RADIANCE.materialBatch = nil
      return
    end

    beamrtLog("I", "Material V2 batch continuing with " .. tostring(nextKey))
    if not M.publishMaterialCache(nextKey) then
      beamrtLog("E", "Material V2 batch could not arm " .. tostring(nextKey))
      CLEAN_RADIANCE.materialBatch = nil
    end
  end
end

function CLEAN_RADIANCE.finishBuild(resultMessage, completed)
  if not CLEAN_RADIANCE.build then
    return false
  end

  -- Freeze all clean-radiance diagnostic targets without disabling their owning PostEffects.
  -- Disabling would release the targets, exactly as it did for material caches.
  for _, config in pairs(CLEAN_RADIANCE.outputs) do
    local effect = findObject(config.effectName)
    if effect then
      effect.onThisFrame = false
      effect.skip = true
    end
  end

  local build = CLEAN_RADIANCE.build
  CLEAN_RADIANCE.build = nil
  CLEAN_RADIANCE.result.active = false
  if completed then
    local sourceGenerations = build.sourceGenerations or {}
    for key, generation in pairs(sourceGenerations) do
      local current = materialCacheResults[key]
      if not current or not current.valid or current.stale or current.generation ~= generation then
        completed = false
        resultMessage = key .. " cache generation changed during clean-radiance build"
        break
      end
    end
  end

  CLEAN_RADIANCE.result.lastResult = resultMessage or "completed"

  if completed then
    local snapshot, snapshotError = CLEAN_RADIANCE.captureCameraSnapshot(build.mainView)
    if not snapshot then
      completed = false
      resultMessage = "camera snapshot failed: " .. tostring(snapshotError)
    else
      local cameraMatches, cameraReason = CLEAN_RADIANCE.compareSnapshotValues(build.cameraSnapshot, snapshot)
      if not cameraMatches then
        completed = false
        resultMessage = "camera changed during clean-radiance build: " .. tostring(cameraReason)
      else
        CLEAN_RADIANCE.result.cameraSnapshot = snapshot
      end
    end
  end

  if completed then
    CLEAN_RADIANCE.result.phase = "frozen"
    CLEAN_RADIANCE.result.valid = true
    CLEAN_RADIANCE.result.stale = false
    CLEAN_RADIANCE.result.generation = (CLEAN_RADIANCE.result.generation or 0) + 1
    CLEAN_RADIANCE.result.sourceGenerations = build.sourceGenerations
    local resolutionOk, resolution = pcall(function() return tostring(build.mainView.resolution) end)
    CLEAN_RADIANCE.result.resolution = resolutionOk and resolution or nil
  else
    CLEAN_RADIANCE.result.phase = "stale"
    CLEAN_RADIANCE.result.valid = false
    CLEAN_RADIANCE.result.stale = true
    CLEAN_RADIANCE.result.cameraSnapshot = nil
  end
  beamrtLog(completed and "I" or "W", "clean-radiance diagnostic build ended; targets are "
    .. (completed and "frozen and valid (" or "stale (") .. CLEAN_RADIANCE.result.lastResult .. ")")
  return true
end

function CLEAN_RADIANCE.processBuild()
  if not CLEAN_RADIANCE.build then
    return
  end
  CLEAN_RADIANCE.build.captureUpdates = CLEAN_RADIANCE.build.captureUpdates + 1
  if CLEAN_RADIANCE.build.captureUpdates == 1 then
    CLEAN_RADIANCE.result.phase = "render frame"
    return
  end
  CLEAN_RADIANCE.finishBuild("completed one main-view material-aware source frame", true)
end

function M.setMode(requestedMode)
  local normalizedMode = type(requestedMode) == "string" and string.lower(requestedMode) or nil
  local modeId = normalizedMode and MODE_IDS[normalizedMode] or nil
  if modeId == nil then
    beamrtLog("E", "unknown mode '" .. tostring(requestedMode) .. "'; expected off, lighting, reflections, bufferdiag, voxeldda, normals, depth, roughness, position, raymarch, geometry, orientedgeometry, surfels, surfelcompare, surfelradiance, or hybridcoverage")
    return false
  end
  if PROGRESSIVE.reflectionDiagnostic.mode > 0 and modeId ~= MODE_IDS.reflections then
    M.setReflectionDiagnostic("off", false)
  end

  local enteringGI = modeId == MODE_IDS.diffusegi and debugMode ~= MODE_IDS.diffusegi
  local enteringReflections = modeId == MODE_IDS.reflections and debugMode ~= MODE_IDS.reflections
  modeName = normalizedMode
  debugMode = modeId
  if debugMode == MODE_IDS.bufferdiag and not enabledRequested then
    enabledRequested = true
    beamrtLog("I", "bufferdiag selected; BeamRT auto-enabled for the diagnostic pass")
  end
  if debugMode == MODE_IDS.voxeldda and not enabledRequested then
    enabledRequested = true
    beamrtLog("I", "voxeldda selected; BeamRT auto-enabled for the isolated DDA lab")
  end
  if debugMode == MODE_IDS.geometry or debugMode == MODE_IDS.orientedgeometry then
    refreshGeometryProxies(true)
  end
  if (debugMode == MODE_IDS.surfels or debugMode == MODE_IDS.surfelcompare or debugMode == MODE_IDS.surfelradiance or debugMode == MODE_IDS.hybridcoverage) and #surfels == 0 and not pendingSurfelRefresh then
    refreshSurfels(true)
  end
  if enteringGI then
    if giSourceMode ~= 1 and #surfels == 0 and not pendingSurfelRefresh then
      refreshSurfels(true)
    end
    resetTemporalHistory("entered diffusegi mode", false)
    if reflectionOverlayEnabled then
      -- The overlay remains enabled, but its sampled backbuffer now includes
      -- the GI compose pass. Never reuse reflection history made from the
      -- differently lit pre-GI image.
      resetReflectionHistory("entered diffusegi mode with reflection overlay", false)
    end
  end
  if enteringReflections then
    resetReflectionHistory("entered reflections mode", false)
  end
  applyShaderConsts()
  syncEffectEnablement()
  beamrtLog("I", "selected mode " .. modeName .. " (" .. tostring(debugMode) .. ")")
  return true
end

function M._normalizeBufferDiagnosticToken(value)
  if type(value) ~= "string" then
    return nil
  end
  return string.lower(value):gsub("[%s_%-]", "")
end

function M.setBufferDiagnostic(requestedSource, requestedChannel)
  local sourceToken = M._normalizeBufferDiagnosticToken(requestedSource)
  local sourceKey = sourceToken and BUFFER_DIAGNOSTIC_SOURCE_ALIASES[sourceToken] or nil
  if not sourceKey then
    beamrtLog("E", "unknown buffer diagnostic source '" .. tostring(requestedSource)
      .. "'; expected a registered native/material/clean source such as lightinfo0, baseColorCache, opacityCache, emissiveCache, roughnessCache, ambientOcclusionCache, normalsWSCache, clearCoatCache, clearCoatRoughnessCache, emitterClass, gtaoOutput, or ssaoMask")
    return false
  end

  local channelName = requestedChannel == nil
    and bufferDiagnosticChannelName
    or M._normalizeBufferDiagnosticToken(requestedChannel)
  local channel = channelName and BUFFER_DIAGNOSTIC_CHANNELS[channelName] or nil
  if channel == nil then
    beamrtLog("E", "unknown buffer diagnostic channel '" .. tostring(requestedChannel)
      .. "'; expected rgb, r, g, b, or a")
    return false
  end

  local source = BUFFER_DIAGNOSTIC_SOURCES[sourceKey]
  if not findObject(source.effectName) then
    beamrtLog("W", "diagnostic PostEffect was missing; recreating BeamRT objects")
    createObjects()
  end
  if not findObject(source.effectName) then
    beamrtLog("E", "cannot enable " .. source.publicName .. ": diagnostic effect creation failed")
    return false
  end

  bufferDiagnosticSource = sourceKey
  bufferDiagnosticChannelName = channelName
  bufferDiagnosticChannel = channel
  applyBufferDiagnosticShaderConsts()
  syncEffectEnablement()
  if enabledRequested and debugMode == MODE_IDS.bufferdiag and not effectIsEnabled(source.effectName) then
    beamrtLog("E", "diagnostic effect failed to enable for " .. source.publicName
      .. "; normal BeamRT effects remain disabled until setMode('lighting') is called")
    return false
  end
  beamrtLog("I", "buffer diagnostic selected " .. source.publicName .. " " .. source.target
    .. " channel=" .. channelName
    .. "; a solid black result can mean either valid zero data or an unavailable target—check beamng.log for named-texture binding warnings")
  return true
end

function M.setBufferDiagnosticGain(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1000000 then
    beamrtLog("E", "buffer diagnostic gain must be a finite number from 0 through 1000000")
    return false
  end
  bufferDiagnosticGain = numericValue
  applyBufferDiagnosticShaderConsts()
  beamrtLog("I", "buffer diagnostic gain set to " .. tostring(bufferDiagnosticGain))
  return true
end

function M.setBufferDiagnosticExposure(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < -20 or numericValue > 20 then
    beamrtLog("E", "buffer diagnostic exposure must be a finite number from -20 through 20 stops")
    return false
  end
  bufferDiagnosticExposure = numericValue
  applyBufferDiagnosticShaderConsts()
  beamrtLog("I", "buffer diagnostic exposure set to " .. tostring(bufferDiagnosticExposure) .. " stops")
  return true
end

function M.setBufferDiagnosticHDR(enabled)
  local requested = enabled
  if type(requested) == "string" then
    local normalized = string.lower(requested)
    if normalized == "hdr" or normalized == "decoded" or normalized == "on" or normalized == "true" then
      requested = true
    elseif normalized == "raw" or normalized == "off" or normalized == "false" then
      requested = false
    end
  elseif type(requested) == "number" then
    requested = requested ~= 0
  end
  if type(requested) ~= "boolean" then
    beamrtLog("E", "buffer diagnostic HDR mode must be true/false or 'hdr'/'raw'")
    return false
  end
  bufferDiagnosticHDRDecode = requested
  applyBufferDiagnosticShaderConsts()
  beamrtLog("I", "buffer diagnostic view set to " .. (bufferDiagnosticHDRDecode and "BeamNG HDR-decoded" or "raw"))
  return true
end

function M.setBufferDiagnosticView(view)
  return M.setBufferDiagnosticHDR(view)
end

function M.getBufferDiagnostic()
  local source = BUFFER_DIAGNOSTIC_SOURCES[bufferDiagnosticSource]
  return {
    source = source and source.publicName or bufferDiagnosticSource,
    target = source and source.target or nil,
    channel = bufferDiagnosticChannelName,
    gain = bufferDiagnosticGain,
    exposure = bufferDiagnosticExposure,
    view = bufferDiagnosticHDRDecode and "hdr" or "raw",
    active = enabledRequested and debugMode == MODE_IDS.bufferdiag,
  }
end

function M.exitBufferDiagnostic()
  return M.setMode("lighting")
end

function M._normalizeMaterialCacheKey(requestedKey)
  if type(requestedKey) ~= "string" then
    return nil
  end
  local normalized = string.lower(requestedKey):gsub("[^a-z0-9]", "")
  if normalized == "base" or normalized == "basecolour" then
    normalized = "basecolor"
  elseif normalized == "ao" or normalized == "ambientocclusion" then
    normalized = "ambientocclusion"
  elseif normalized == "normal" or normalized == "normals" or normalized == "worldnormal" or normalized == "worldnormals" then
    normalized = "normalsws"
  elseif normalized == "coat" then
    normalized = "clearcoat"
  elseif normalized == "coatroughness" or normalized == "clearcoatrough" then
    normalized = "clearcoatroughness"
  end
  return MATERIAL_CACHE_CONFIGS[normalized] and normalized or nil
end

function M._copyMaterialCacheResult(key)
  local result = materialCacheResults[key]
  local config = MATERIAL_CACHE_CONFIGS[key]
  if not result or not config then
    return nil
  end
  local effect = findObject(config.publishEffectName)
  local status = {
    source = config.publicName,
    active = result.active,
    phase = result.phase,
    target = result.target,
    lastResult = result.lastResult,
    valid = result.valid,
    stale = result.stale,
    resolution = result.resolution,
    generation = result.generation,
    cameraSnapshot = result.cameraSnapshot,
    publisherEnabled = effect and effect:isEnabled() or false,
  }
  if effect then
    status.publisherSkipped = effect.skip
    status.publisherOnThisFrame = effect.onThisFrame
  end
  return status
end

function M.publishMaterialCache(requestedKey)
  local key = M._normalizeMaterialCacheKey(requestedKey)
  local config = key and MATERIAL_CACHE_CONFIGS[key] or nil
  if not config then
    beamrtLog("E", "unknown material cache '" .. tostring(requestedKey)
      .. "'; expected baseColor, opacity, metallic, emissive, roughness, ambientOcclusion, normalsWS, clearCoat, or clearCoatRoughness")
    return false
  end
  if materialCachePublication then
    beamrtLog("W", materialCachePublication.config.publicName .. " producer publication is already active")
    return false
  end

  local publishEffect = findObject(config.publishEffectName) or createMaterialPublishEffect(config)
  if not publishEffect then
    beamrtLog("E", "could not create " .. config.publishEffectName)
    return false
  end
  publishEffect.oneFrameOnly = true
  publishEffect.onThisFrame = false
  publishEffect.skip = true
  if not publishEffect:isEnabled() then
    publishEffect:enable()
    markMaterialCacheStale(key, "publisher was disabled; capture required")
  end
  if not findObject("PFX_PassthruShader") or not findObject("PFX_DefaultBlitStateBlock") then
    beamrtLog("E", "producer publication requires BeamNG's PFX_PassthruShader and PFX_DefaultBlitStateBlock")
    return false
  end

  local mainView, mainError = getRenderView("main")
  if not mainView then
    beamrtLog("E", config.publicName .. " publication cannot start: " .. tostring(mainError))
    return false
  end
  local probeView, probeError = getOrCreateMaterialProbeView(config, mainView)
  if not probeView then
    beamrtLog("E", config.publicName .. " publication cannot start: " .. tostring(probeError))
    return false
  end
  local captureCameraSnapshot, cameraSnapshotError = CLEAN_RADIANCE.captureCameraSnapshot(mainView)
  if not captureCameraSnapshot then
    beamrtLog("E", config.publicName .. " publication cannot snapshot the camera: "
      .. tostring(cameraSnapshotError))
    return false
  end

  materialCachePublication = {
    config = config,
    mainView = mainView,
    probeView = probeView,
    mainUsePostEffects = mainView.usePostEffects,
    modeName = modeName,
    debugMode = debugMode,
    enabledRequested = enabledRequested,
    captureUpdates = 0,
    cameraSnapshot = captureCameraSnapshot,
  }
  markMaterialCacheStale(key, "new publication started")
  local result = materialCacheResults[key]
  result.active = true
  result.phase = "arming producer view"
  result.lastResult = "in progress"
  result.valid = false
  result.stale = true

  -- Isolate the global PostEffect manager to the producer view for one frame.
  setNormalBeamRTEffectsEnabled(false)
  local setupOk, setupError = pcall(function()
    mainView.usePostEffects = false
    probeView.usePostEffects = true

    local materialOk, materialError = setMaterialDebugMode(config.materialMode)
    if not materialOk then
      error(materialError)
    end

    local cameraOk, cameraError = synchronizeMaterialProbeCamera(probeView, mainView)
    if not cameraOk then
      error("camera synchronization failed at " .. tostring(cameraError))
    end

    -- Arm last, after every other view/material state is ready. The effect
    -- remains enabled permanently; these two fields are its render gate.
    publishEffect.skip = false
    publishEffect.onThisFrame = true
    probeView.active = true
  end)

  if not setupOk then
    beamrtLog("E", config.publicName .. " publication setup failed: " .. tostring(setupError))
    finishMaterialCachePublication("setup failed", false)
    return false
  end

  result.phase = "armed"
  beamrtLog("I", config.publicName .. " producer publication armed: isolated " .. config.probeViewName
    .. " will publish its $backBuffer to " .. config.cacheTarget .. " for one frame")
  return true
end

function M.publishMaterialV2Caches()
  if materialCachePublication or CLEAN_RADIANCE.materialBatch then
    beamrtLog("W", "a material-cache publication or Material V2 batch is already active")
    return false
  end
  local mainView, mainError = getRenderView("main")
  if not mainView then
    beamrtLog("E", "Material V2 batch cannot start: " .. tostring(mainError))
    return false
  end
  local snapshot, snapshotError = CLEAN_RADIANCE.captureCameraSnapshot(mainView)
  if not snapshot then
    beamrtLog("E", "Material V2 batch cannot snapshot the camera: " .. tostring(snapshotError))
    return false
  end
  local nextGeneration = 1
  for _, result in pairs(materialCacheResults) do
    nextGeneration = math.max(nextGeneration, (result.generation or 0) + 1)
  end
  CLEAN_RADIANCE.materialBatch = {
    generation = nextGeneration,
    keys = {
      "basecolor", "opacity", "metallic", "roughness", "ambientocclusion",
      "normalsws", "emissive", "clearcoat", "clearcoatroughness"
    },
    index = 1,
    cameraSnapshot = snapshot,
  }
  beamrtLog("I", "Material V2 batch started; keep the camera fixed until all nine captures finish")
  if not M.publishMaterialCache(CLEAN_RADIANCE.materialBatch.keys[1]) then
    CLEAN_RADIANCE.materialBatch = nil
    return false
  end
  return true
end

function M.cancelMaterialV2Batch()
  CLEAN_RADIANCE.materialBatch = nil
  if materialCachePublication then
    return finishMaterialCachePublication("Material V2 batch cancelled", false)
  end
  return true
end

function M.publishBaseColorCache()
  return M.publishMaterialCache("basecolor")
end

function M.publishOpacityCache()
  return M.publishMaterialCache("opacity")
end

function M.publishMetallicCache()
  return M.publishMaterialCache("metallic")
end

function M.publishEmissiveCache()
  return M.publishMaterialCache("emissive")
end

function M.publishRoughnessCache()
  return M.publishMaterialCache("roughness")
end

function M.publishAmbientOcclusionCache()
  return M.publishMaterialCache("ambientocclusion")
end

function M.publishNormalsWSCache()
  return M.publishMaterialCache("normalsws")
end

function M.publishClearCoatCache()
  return M.publishMaterialCache("clearcoat")
end

function M.publishClearCoatRoughnessCache()
  return M.publishMaterialCache("clearcoatroughness")
end

function M.cancelMaterialCachePublication()
  CLEAN_RADIANCE.materialBatch = nil
  if not materialCachePublication then
    return false
  end
  return finishMaterialCachePublication("cancelled", false)
end

function M.cancelBaseColorPublication()
  if not materialCachePublication or materialCachePublication.config.key ~= "basecolor" then
    return false
  end
  return M.cancelMaterialCachePublication()
end

function M.cancelMetallicPublication()
  if not materialCachePublication or materialCachePublication.config.key ~= "metallic" then
    return false
  end
  return M.cancelMaterialCachePublication()
end

M.cancelMetallicCachePublication = M.cancelMetallicPublication

function M.cancelEmissivePublication()
  if not materialCachePublication or materialCachePublication.config.key ~= "emissive" then
    return false
  end
  return M.cancelMaterialCachePublication()
end

M.cancelEmissiveCachePublication = M.cancelEmissivePublication

function M.getBaseColorPublication()
  return M._copyMaterialCacheResult("basecolor")
end

function M.getOpacityPublication()
  return M._copyMaterialCacheResult("opacity")
end

function M.getMetallicPublication()
  return M._copyMaterialCacheResult("metallic")
end

M.getMetallicCachePublication = M.getMetallicPublication

function M.getEmissivePublication()
  return M._copyMaterialCacheResult("emissive")
end

M.getEmissiveCachePublication = M.getEmissivePublication

function M.getRoughnessPublication() return M._copyMaterialCacheResult("roughness") end
function M.getAmbientOcclusionPublication() return M._copyMaterialCacheResult("ambientocclusion") end
function M.getNormalsWSPublication() return M._copyMaterialCacheResult("normalsws") end
function M.getClearCoatPublication() return M._copyMaterialCacheResult("clearcoat") end
function M.getClearCoatRoughnessPublication() return M._copyMaterialCacheResult("clearcoatroughness") end

function M.getMaterialCachePublication(requestedKey)
  if requestedKey == nil then
    local summary = {
      active = materialCachePublication and materialCachePublication.config.publicName or nil,
      batch = CLEAN_RADIANCE.materialBatch and {index = CLEAN_RADIANCE.materialBatch.index, total = #CLEAN_RADIANCE.materialBatch.keys} or nil,
    }
    for key, config in pairs(MATERIAL_CACHE_CONFIGS) do
      summary[config.publicName] = M._copyMaterialCacheResult(key)
    end
    return summary
  end
  local key = M._normalizeMaterialCacheKey(requestedKey)
  return key and M._copyMaterialCacheResult(key) or nil
end

function M.invalidateMaterialCaches(reason)
  local message = reason or "explicit graphics/shader invalidation"
  if materialCachePublication then
    finishMaterialCachePublication(message .. " during capture", false)
  end
  markAllMaterialCachesStale(message)
  beamrtLog("W", "all published material caches marked stale: " .. message)
  return true
end

function M.refreshCleanRadianceDiagnostics()
  if materialCachePublication then
    beamrtLog("E", "finish the active material-cache publication before building clean radiance")
    return false
  end
  if CLEAN_RADIANCE.build then
    beamrtLog("W", "clean-radiance diagnostic build is already active")
    return false
  end

  local mainView, mainError = getRenderView("main")
  if not mainView then
    beamrtLog("E", "clean-radiance build cannot start: " .. tostring(mainError))
    return false
  end
  if not mainView.usePostEffects then
    beamrtLog("E", "clean-radiance build requires main RenderView PostFX to be enabled")
    return false
  end

  local buildCameraSnapshot, cameraSnapshotError = CLEAN_RADIANCE.captureCameraSnapshot(mainView)
  if not buildCameraSnapshot then
    beamrtLog("E", "clean-radiance build cannot snapshot the camera: " .. tostring(cameraSnapshotError))
    return false
  end

  local currentResolution = tostring(mainView.resolution)
  local cacheResolution = nil
  local cacheGeneration = nil
  local sourceGenerations = {}
  for _, key in ipairs(CLEAN_RADIANCE.requiredMaterialCaches) do
    local config = MATERIAL_CACHE_CONFIGS[key]
    local result = materialCacheResults[key]
    if not result or not result.valid or result.stale then
      beamrtLog("E", config.publicName .. " cache is not valid; publish BaseColor, Metallic, and Emissive first")
      return false
    end
    local cameraMatches, cameraReason = CLEAN_RADIANCE.compareSnapshotValues(
      result.cameraSnapshot,
      buildCameraSnapshot)
    if not cameraMatches then
      beamrtLog("E", config.publicName .. " cache camera does not match the clean-radiance build: "
        .. tostring(cameraReason) .. "; recapture all three caches without moving the camera")
      return false
    end
    if result.resolution ~= currentResolution then
      beamrtLog("E", config.publicName .. " cache resolution no longer matches the main RenderView")
      return false
    end
    if cacheResolution and result.resolution ~= cacheResolution then
      beamrtLog("E", "material-cache resolutions disagree; recapture BaseColor, Metallic, and Emissive")
      return false
    end
    cacheResolution = result.resolution
    sourceGenerations[key] = result.generation
    if cacheGeneration and result.generation ~= cacheGeneration then
      beamrtLog("E", "material-cache generations disagree; recapture BaseColor, Metallic, and Emissive once each")
      return false
    end
    cacheGeneration = result.generation
  end

  CLEAN_RADIANCE.markStale("clean-radiance rebuild started")
  CLEAN_RADIANCE.build = {
    mainView = mainView,
    captureUpdates = 0,
    sourceGenerations = sourceGenerations,
    cameraSnapshot = buildCameraSnapshot,
  }
  CLEAN_RADIANCE.result.active = true
  CLEAN_RADIANCE.result.phase = "arming main view"
  CLEAN_RADIANCE.result.lastResult = "in progress"
  CLEAN_RADIANCE.result.valid = false
  CLEAN_RADIANCE.result.stale = true

  local setupOk, setupError = pcall(function()
    for _, config in pairs(CLEAN_RADIANCE.outputs) do
      local effect = findObject(config.effectName) or CLEAN_RADIANCE.createEffect(config)
      if not effect then
        error("could not create " .. config.effectName)
      end
      effect.oneFrameOnly = true
      effect.onThisFrame = false
      effect.skip = true
      effect:setShaderConst("$outputMode", config.outputMode)
      if not effect:isEnabled() then
        effect:enable()
      end
    end
    -- Arm last so every fixed input/output binding and mode is ready before
    -- the next main-view PFXAfterDiffuse frame begins.
    for _, config in pairs(CLEAN_RADIANCE.outputs) do
      local effect = findObject(config.effectName)
      effect.skip = false
      effect.onThisFrame = true
    end
  end)

  if not setupOk then
    beamrtLog("E", "clean-radiance diagnostic setup failed: " .. tostring(setupError))
    CLEAN_RADIANCE.finishBuild("setup failed", false)
    return false
  end

  CLEAN_RADIANCE.result.phase = "armed"
  beamrtLog("I", "clean-radiance diagnostics armed for one main-view frame; live PTGI remains unchanged")
  return true
end

M.buildCleanRadianceDiagnostics = M.refreshCleanRadianceDiagnostics
M.refreshCleanRadiance = M.refreshCleanRadianceDiagnostics

function M.cancelCleanRadianceDiagnostics()
  if not CLEAN_RADIANCE.build then
    return false
  end
  return CLEAN_RADIANCE.finishBuild("cancelled", false)
end

function M.getCleanRadianceDiagnostics()
  CLEAN_RADIANCE.validateSelectedSource()
  local owners = {}
  for key, config in pairs(CLEAN_RADIANCE.outputs) do
    local effect = findObject(config.effectName)
    local owner = {
      name = config.publicName,
      target = config.target .. "[RT0]",
      enabled = effect and effect:isEnabled() or false,
    }
    if effect then
      -- Assign these explicitly so a meaningful false value is not collapsed
      -- to nil by Lua's `and/or` expression convention.
      owner.skipped = effect.skip
      owner.onThisFrame = effect.onThisFrame
    end
    owners[key] = owner
  end
  local cleanUsable, unusableReason = CLEAN_RADIANCE.validateUsable(true)
  local feedsPTGI = CLEAN_RADIANCE.selectedPTGISource == "clean" and cleanUsable
  return {
    active = CLEAN_RADIANCE.result.active,
    phase = CLEAN_RADIANCE.result.phase,
    lastResult = CLEAN_RADIANCE.result.lastResult,
    valid = CLEAN_RADIANCE.result.valid,
    stale = CLEAN_RADIANCE.result.stale,
    resolution = CLEAN_RADIANCE.result.resolution,
    generation = CLEAN_RADIANCE.result.generation,
    sourceGenerations = CLEAN_RADIANCE.result.sourceGenerations,
    colorSpace = "linear material/lighting working space; no gamma or HDR conditioning",
    selectedSource = CLEAN_RADIANCE.selectedPTGISource,
    feedsPTGI = feedsPTGI,
    unusableReason = cleanUsable and nil or unusableReason,
    bindings = {
      gi = CLEAN_RADIANCE.bindings.gi,
      surfelCache = CLEAN_RADIANCE.bindings.surfelCache,
    },
    cameraTolerance = {
      positionMeters = CLEAN_RADIANCE.positionTolerance,
      orientationDegrees = CLEAN_RADIANCE.orientationToleranceDegrees,
      fovDegrees = CLEAN_RADIANCE.fovToleranceDegrees,
    },
    outputs = owners,
  }
end

function M.setPTGIRadianceSource(requestedSource)
  if type(requestedSource) ~= "string" then
    beamrtLog("E", "PTGI radiance source must be 'legacy' or 'clean'")
    return false
  end
  local normalized = string.lower(requestedSource):gsub("[%s_%-]", "")
  if normalized ~= "legacy" and normalized ~= "clean" then
    beamrtLog("E", "unknown PTGI radiance source '" .. tostring(requestedSource)
      .. "'; expected legacy or clean")
    return false
  end

  if normalized == "clean" then
    beamrtLog("W", "frozen clean source is diagnostic-only with the six-input renderer; use the live source for PTGI")
    return false
  end

  if CLEAN_RADIANCE.selectedPTGISource == normalized then
    return true
  end
  CLEAN_RADIANCE.selectedPTGISource = normalized
  CLEAN_RADIANCE.selectedPTGISourceMode = normalized == "clean" and 1 or 0
  CLEAN_RADIANCE.resetSourceDependentHistory("PTGI radiance-source change")
  beamrtLog("I", "PTGI radiance source selected: " .. normalized)
  return true
end

function M.getPTGIRadianceSource()
  CLEAN_RADIANCE.validateSelectedSource()
  return CLEAN_RADIANCE.selectedPTGISource
end

function M.refreshGeometry()
  local refreshed = refreshGeometryProxies(true)
  applyDebugShaderConsts()
  return refreshed
end

function M.setGeometryRadius(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 5 or numericValue > 500 then
    beamrtLog("E", "geometry radius must be a finite number from 5 through 500 world units")
    return false
  end
  geometryRadius = numericValue
  refreshGeometryProxies(true)
  applyDebugShaderConsts()
  return true
end

function M.setGeometryMaxObjectExtent(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 1 or numericValue > 1000 then
    beamrtLog("E", "geometry maximum object extent must be a finite number from 1 through 1000 world units")
    return false
  end
  geometryMaxObjectExtent = numericValue
  refreshGeometryProxies(true)
  applyDebugShaderConsts()
  return true
end

function M.getGeometryProxyCount()
  return #geometryBoxes
end

function M.getOrientedGeometryProxyCount()
  return orientedGeometryProxyCount
end

function M.dumpGeometry()
  beamrtLog("I", string.format(
    "geometry proxy dump: %d boxes (%d oriented, %d AABB fallback), radius %.1f m, max object extent %.1f m",
    #geometryBoxes,
    orientedGeometryProxyCount,
    #geometryBoxes - orientedGeometryProxyCount,
    geometryRadius,
    geometryMaxObjectExtent
  ))
  if geometryScanPosition then
    beamrtLog("I", "scan position " .. vector4String(geometryScanPosition, 1))
  end
  for index, geometryBox in ipairs(geometryBoxes) do
    beamrtLog("I", string.format(
      "proxy %02d: %s '%s' min(%s) max(%s) OBB=%s center(%s) half(%s) axisX(%s) axisY(%s)",
      index - 1,
      geometryBox.className,
      geometryBox.name,
      vector4String(geometryBox.min, 0),
      vector4String(geometryBox.max, 0),
      geometryBox.isOriented and "local-box" or "AABB-fallback",
      vector4String(geometryBox.obbCenter, 0),
      vector4String(geometryBox.obbHalf, 0),
      vector4String(geometryBox.obbAxisX, 0),
      vector4String(geometryBox.obbAxisY, 0)
    ))
  end
  return #geometryBoxes
end

function M.refreshSurfels()
  local refreshed = refreshSurfels(true)
  return refreshed
end

function M.setSurfelTraceDistance(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 5 or numericValue > 250 then
    beamrtLog("E", "surfel trace distance must be a finite number from 5 through 250 world units")
    return false
  end
  surfelTraceDistance = numericValue
  surfelGeometryDirtyGI = true
  applyGIShaderConsts()
  beamrtLog("I", "surfel trace distance set to " .. tostring(surfelTraceDistance) .. " m; call refreshSurfels() to rebuild")
  return true
end

function M.setSurfelRadius(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.1 or numericValue > 20 then
    beamrtLog("E", "surfel base radius must be a finite number from 0.1 through 20 world units")
    return false
  end
  surfelBaseRadius = numericValue
  beamrtLog("I", "surfel base radius set to " .. tostring(surfelBaseRadius) .. " m; call refreshSurfels() to rebuild")
  return true
end

function M.getSurfelCount()
  return #surfels
end

function M.dumpSurfels()
  beamrtLog("I", string.format(
    "world surfel dump: %d samples, trace distance %.1f m, base radius %.2f m",
    #surfels,
    surfelTraceDistance,
    surfelBaseRadius
  ))
  if surfelScanPosition then
    beamrtLog("I", "surfel scan position " .. vector4String(surfelScanPosition, 1))
  end
  for index, surfel in ipairs(surfels) do
    beamrtLog("I", string.format(
      "surfel %02d: source=%s position(%s) normal(%s) radius=%.3f",
      index - 1,
      surfel.sourceName,
      vector4String(surfel.position, 0),
      vector4String(surfel.normal, 0),
      surfel.radius
    ))
  end
  return #surfels
end

function M.setGISource(requestedSource)
  local normalizedSource = type(requestedSource) == "string" and string.lower(requestedSource) or nil
  local sourceModes = {
    hybrid = 0,
    screen = 1,
    screenspace = 1,
    surfels = 2,
    surfel = 2,
    world = 2,
  }
  local sourceMode = normalizedSource and sourceModes[normalizedSource] or nil
  if sourceMode == nil then
    beamrtLog("E", "unknown GI source '" .. tostring(requestedSource) .. "'; expected hybrid, screen, or surfels")
    return false
  end
  local previousSourceMode = giSourceMode
  giSourceMode = sourceMode
  if giSourceMode ~= 1 and #surfels == 0 and not pendingSurfelRefresh then
    refreshSurfels(true)
  end
  if previousSourceMode == 1 and giSourceMode ~= 1 then
    surfelCacheResetFrames = math.max(surfelCacheResetFrames, 2)
    surfelGeometryDirtyCache = true
  end
  resetTemporalHistory("GI source changed", false)
  syncEffectEnablement()
  local canonicalSource = sourceMode == 0 and "hybrid" or (sourceMode == 1 and "screen" or "surfels")
  rayBackendRegistry.syncFromGISource(canonicalSource)
  beamrtLog("I", "GI source set to " .. normalizedSource .. " (" .. tostring(giSourceMode) .. ")")
  return true
end

function M.getGISource()
  if giSourceMode == 1 then return "screen" end
  if giSourceMode == 2 then return "surfels" end
  return "hybrid"
end

function M.setWorldGIStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 4 then
    beamrtLog("E", "world GI strength must be a finite number from 0 through 4")
    return false
  end
  worldGIStrength = numericValue
  resetTemporalHistory("world GI strength changed", false)
  beamrtLog("I", "world GI strength set to " .. tostring(worldGIStrength))
  return true
end

function M.setSurfelVisibilityTolerance(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.05 or numericValue > 10 then
    beamrtLog("E", "surfel visibility tolerance must be a finite number from 0.05 through 10 world units")
    return false
  end
  surfelVisibilityTolerance = numericValue
  resetTemporalHistory("surfel visibility tolerance changed", false)
  beamrtLog("I", "surfel visibility tolerance set to " .. tostring(surfelVisibilityTolerance) .. " world units")
  return true
end

function M.setSurfelCacheBlend(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.01 or numericValue > 1 then
    beamrtLog("E", "surfel cache blend must be a finite number from 0.01 through 1")
    return false
  end
  surfelCacheBlend = numericValue
  applySurfelCacheShaderConsts()
  beamrtLog("I", "surfel cache current-frame blend set to " .. tostring(surfelCacheBlend))
  return true
end

function M.setSurfelRefreshDistance(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 2 or numericValue > 100 then
    beamrtLog("E", "surfel refresh distance must be a finite number from 2 through 100 world units")
    return false
  end
  surfelRefreshDistance = numericValue
  beamrtLog("I", "automatic surfel refresh distance set to " .. tostring(surfelRefreshDistance) .. " m")
  return true
end

function M.setSurfelRefreshRaysPerFrame(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or nil
  if not integerValue or integerValue < 1 or integerValue > 32 then
    beamrtLog("E", "surfel refresh rays per frame must be a finite integer from 1 through 32")
    return false
  end
  surfelRefreshRaysPerFrame = integerValue
  beamrtLog("I", "surfel refresh budget set to " .. tostring(surfelRefreshRaysPerFrame) .. " detailed rays/frame")
  return true
end

function M.setGIStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 4 then
    beamrtLog("E", "GI strength must be a finite number from 0 through 4")
    return false
  end
  giStrength = numericValue
  applyShaderConsts()
  beamrtLog("I", "GI strength set to " .. tostring(giStrength))
  return true
end

-- Toggle only the final GI/light composition; ray tracing and the GI
-- history remain untouched. This is intended for controlled A/B comparisons.
function M.setLightingComposeModel(requestedMode)
  local modes = {legacy = 0, conservative = 1}
  local normalized = type(requestedMode) == "string" and string.lower(requestedMode) or requestedMode
  local requested = modes[normalized]
  if requested == nil and type(normalized) == "number" then
    if normalized == 0 or normalized == 1 then requested = normalized end
  end
  if requested == nil then
    beamrtLog("E", "lighting composition model must be 'legacy' or 'conservative'")
    return false
  end
  PROGRESSIVE.lightingAccuracyMode = requested
  applyGIShaderConsts()
  beamrtLog("I", "lighting composition model set to " .. (requested == 0 and "legacy" or "conservative"))
  return true
end

function M.getLightingComposeModel()
  return PROGRESSIVE.lightingAccuracyMode == 0 and "legacy" or "conservative"
end

function M.setContactShadowStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "contact shadow strength must be a finite number from 0 through 1")
    return false
  end
  contactShadowStrength = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "contact shadow strength set to " .. tostring(contactShadowStrength))
  return true
end

function M.setBounceSaturation(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 4 then
    beamrtLog("E", "bounce saturation must be a finite number from 0 through 4")
    return false
  end
  bounceSaturation = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "bounce saturation set to " .. tostring(bounceSaturation))
  return true
end

function M.setGIExposure(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < -8 or numericValue > 8 then
    beamrtLog("E", "GI exposure must be a finite number from -8 through 8 stops")
    return false
  end
  giExposure = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "GI exposure set to " .. tostring(giExposure) .. " stops")
  return true
end

function M.setGIShadowFocus(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "GI shadow focus must be a finite number from 0 through 1")
    return false
  end
  giShadowFocus = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "GI shadow focus set to " .. tostring(giShadowFocus))
  return true
end

function M.setGIReceiverTint(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "GI receiver tint must be a finite number from 0 through 1")
    return false
  end
  giReceiverTint = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "GI receiver tint set to " .. tostring(giReceiverTint))
  return true
end

function M.setGIContrast(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.25 or numericValue > 4 then
    beamrtLog("E", "GI contrast must be a finite number from 0.25 through 4")
    return false
  end
  giContrast = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "GI contrast set to " .. tostring(giContrast))
  return true
end

function M.setGIEnergyLimit(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.1 or numericValue > 32 then
    beamrtLog("E", "GI energy limit must be a finite number from 0.1 through 32")
    return false
  end
  giEnergyLimit = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "GI energy limit set to " .. tostring(giEnergyLimit))
  return true
end

function M.setGIHighlightRolloff(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "GI highlight rolloff must be a finite number from 0 through 1")
    return false
  end
  giHighlightRolloff = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "GI highlight rolloff set to " .. tostring(giHighlightRolloff))
  return true
end

function M.setGIClamp(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue <= 0 then
    beamrtLog("E", "GI clamp must be a finite number greater than zero")
    return false
  end
  giClamp = numericValue
  resetTemporalHistory("GI clamp changed", false)
  beamrtLog("I", "GI clamp set to " .. tostring(giClamp))
  return true
end

function M.setGICellSize(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.005 or numericValue > 1 then
    beamrtLog("E", "GI cell size must be a finite number from 0.005 through 1 world unit")
    return false
  end
  giCellSize = numericValue
  resetTemporalHistory("GI sample cell size changed", false)
  beamrtLog("I", "GI sample cell size set to " .. tostring(giCellSize) .. " world units")
  return true
end

function M.setTemporalBlend(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.02 or numericValue > 1 then
    beamrtLog("E", "temporal blend must be a finite number from 0.02 through 1")
    return false
  end
  temporalBlend = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "temporal current-frame blend set to " .. tostring(temporalBlend))
  return true
end

function M.setHistoryDepthTolerance(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.0001 or numericValue > 0.25 then
    beamrtLog("E", "history depth tolerance must be a finite number from 0.0001 through 0.25")
    return false
  end
  historyDepthTolerance = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "history depth tolerance set to " .. tostring(historyDepthTolerance))
  return true
end

function M.setDenoiseStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "denoise strength must be a finite number from 0 through 1")
    return false
  end
  denoiseStrength = numericValue
  applyGIShaderConsts()
  beamrtLog("I", "denoise strength set to " .. tostring(denoiseStrength))
  return true
end

function M.setGIPathCount(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or nil
  if not integerValue or integerValue < 1 or integerValue > 32 then
    beamrtLog("E", "GI path count must be a finite integer from 1 through 32")
    return false
  end
  giPathCount = integerValue
  resetTemporalHistory("GI path count changed", false)
  beamrtLog("I", "GI path count set to " .. tostring(giPathCount))
  return true
end

function M.setProgressiveAccumulation(value)
  local enabled = value
  if type(value) == "string" then
    local normalized = string.lower(value)
    enabled = normalized == "on" or normalized == "true" or normalized == "1" or normalized == "progressive"
  elseif type(value) == "number" then
    enabled = value ~= 0
  end
  if type(enabled) ~= "boolean" then
    beamrtLog("E", "progressive accumulation expects true/false or on/off")
    return false
  end
  PROGRESSIVE.enabled = enabled
  resetTemporalHistory("progressive accumulation changed", false)
  beamrtLog("I", "progressive PTGI accumulation " .. (enabled and "enabled" or "disabled"))
  return true
end

function M.setProgressiveMaxSamples(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or nil
  if not integerValue or integerValue < 1 or integerValue > 65536 then
    beamrtLog("E", "progressive sample ceiling must be a finite integer from 1 through 65536")
    return false
  end
  PROGRESSIVE.maxSamples = integerValue
  resetTemporalHistory("progressive sample ceiling changed", false)
  beamrtLog("I", "progressive sample ceiling set to " .. tostring(integerValue))
  return true
end

function M.setProgressiveClampStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "progressive clamp strength must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.clampStrength = numericValue
  resetTemporalHistory("progressive clamp changed", false)
  beamrtLog("I", "progressive neighborhood clamp set to " .. tostring(numericValue))
  return true
end

function M.setGIEstimator(value)
  if type(value) ~= "string" then
    beamrtLog("E", "GI estimator must be 'legacy' or 'corrected'")
    return false
  end
  local normalized = string.lower(value):gsub("[%s_%-]", "")
  if normalized == "legacy" or normalized == "old" then
    PROGRESSIVE.estimatorMode = 0
    PROGRESSIVE.estimatorName = "legacy"
  elseif normalized == "corrected" or normalized == "cosinecorrected" or normalized == "physical" then
    PROGRESSIVE.estimatorMode = 1
    PROGRESSIVE.estimatorName = "corrected"
  else
    beamrtLog("E", "unknown GI estimator '" .. tostring(value) .. "'; expected legacy or corrected")
    return false
  end
  resetTemporalHistory("GI estimator changed", false)
  beamrtLog("I", "GI estimator set to " .. PROGRESSIVE.estimatorName)
  return true
end

function M.setGILocalization(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "GI localization must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.localization = numericValue
  resetTemporalHistory("GI localization changed", false)
  beamrtLog("I", "GI localization set to " .. tostring(numericValue))
  return true
end

function M.setSecondBounceStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 8 then
    beamrtLog("E", "second-bounce strength must be a finite number from 0 through 8")
    return false
  end
  PROGRESSIVE.secondBounceStrength = numericValue
  resetTemporalHistory("second-bounce strength changed", false)
  beamrtLog("I", "experimental previous-GI bounce set to " .. tostring(numericValue))
  return true
end

function M.setEmissiveBoost(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 32 then
    beamrtLog("E", "emissive boost must be a finite number from 0 through 32")
    return false
  end
  PROGRESSIVE.emissiveBoost = numericValue
  surfelCacheResetFrames = math.max(surfelCacheResetFrames, 2)
  resetTemporalHistory("emissive boost changed", false)
  applySurfelCacheShaderConsts()
  beamrtLog("I", "clean-source native emissive boost set to " .. tostring(numericValue))
  return true
end

function M.setRayReach(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.05 or numericValue > 1 then
    beamrtLog("E", "ray reach must be a finite number from 0.05 through 1")
    return false
  end
  PROGRESSIVE.rayReach = numericValue
  resetTemporalHistory("ray reach changed", false)
  beamrtLog("I", "screen-ray reach set to " .. tostring(numericValue)
    .. " of the configured ray-step distance")
  return true
end

function M.setRearRayReach(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.02 or numericValue > 1 then
    beamrtLog("E", "rear ray reach must be a finite number from 0.02 through 1")
    return false
  end
  PROGRESSIVE.rearRayReach = numericValue
  resetTemporalHistory("rear ray reach changed", false)
  beamrtLog("I", "camera-facing/rear ray reach set to " .. tostring(numericValue)
    .. " of the forward ray budget")
  return true
end

function M.setLowPathRescue(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "low-path rescue must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.lowPathRescue = numericValue
  resetTemporalHistory("low-path rescue changed", false)
  beamrtLog("I", "low-path bilateral reconstruction set to " .. tostring(numericValue))
  return true
end

function M.setBlueNoiseStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "blue-noise strength must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.blueNoiseStrength = numericValue
  resetTemporalHistory("blue-noise sequence changed", false)
  beamrtLog("I", PROGRESSIVE.blueNoiseSource .. " blue-noise sequence strength set to " .. tostring(numericValue))
  return true
end

function M.setBlueNoiseSource(value)
  if type(value) ~= "string" then
    beamrtLog("E", "blue-noise source must be 'stbn' or 'beamng'")
    return false
  end
  local token = string.lower(value):gsub("[%s_%-]", "")
  if token == "stbn" or token == "beamrt" or token == "spatiotemporal" then
    PROGRESSIVE.blueNoiseMode = 1
    PROGRESSIVE.blueNoiseSource = "stbn"
  elseif token == "beamng" or token == "gtao" or token == "native" then
    PROGRESSIVE.blueNoiseMode = 0
    PROGRESSIVE.blueNoiseSource = "beamng"
  else
    beamrtLog("E", "blue-noise source must be 'stbn' or 'beamng'")
    return false
  end
  resetTemporalHistory("blue-noise source changed", false)
  beamrtLog("I", "blue-noise source set to " .. PROGRESSIVE.blueNoiseSource)
  if PROGRESSIVE.blueNoiseMode == 1 then
    beamrtLog("W", "custom scalar atlas is experimental; directional STBN quality is not validated")
  end
  return true
end

function M.setHitRefinementSteps(value)
  local numericValue = finiteNumber(value)
  if not numericValue then
    beamrtLog("E", "hit refinement steps must be an integer from -1 through 6")
    return false
  end
  local integerValue = math.floor(numericValue)
  if integerValue < -1 or integerValue > 6 then
    beamrtLog("E", "hit refinement steps must be an integer from -1 through 6")
    return false
  end
  PROGRESSIVE.hitRefinementSteps = integerValue
  resetTemporalHistory("ray-hit refinement changed", false)
  beamrtLog("I", "front/behind crossing refinement set to " .. tostring(integerValue)
    .. (integerValue < 0 and " (exact legacy thickness-only hit path)"
      or (integerValue == 0 and " (bracket accepted without bisection)" or " bisection steps")))
  return true
end

function M.setHitValidationStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "hit-validation strength must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.hitValidationStrength = numericValue
  resetTemporalHistory("screen-hit validation changed", false)
  beamrtLog("I", "screen-hit validation strength set to " .. tostring(numericValue)
    .. (numericValue <= 0.0001 and " (v0.063 compatibility)" or ""))
  return true
end

function M.setMinHitTravelPixels(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 8 then
    beamrtLog("E", "minimum hit travel must be a finite number from 0 through 8 pixels")
    return false
  end
  PROGRESSIVE.minHitTravelPixels = numericValue
  resetTemporalHistory("minimum hit travel changed", false)
  beamrtLog("I", "minimum screen-hit travel set to " .. tostring(numericValue) .. " pixels")
  return true
end

function M.setCandidateContinuation(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "candidate continuation must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.candidateContinuation = numericValue
  resetTemporalHistory("candidate continuation changed", false)
  beamrtLog("I", "multi-candidate continuation set to " .. tostring(numericValue)
    .. (numericValue <= 0.5 and " (v0.064 stop-on-first-candidate behavior)" or ""))
  return true
end

function M.setCandidateRetryCount(value)
  local numericValue = finiteNumber(value)
  if not numericValue then
    beamrtLog("E", "candidate retry count must be an integer from 0 through 8")
    return false
  end
  local integerValue = math.floor(numericValue)
  if integerValue < 0 or integerValue > 8 then
    beamrtLog("E", "candidate retry count must be an integer from 0 through 8")
    return false
  end
  PROGRESSIVE.candidateRetryCount = integerValue
  resetTemporalHistory("candidate retry count changed", false)
  beamrtLog("I", "recoverable candidate retry budget set to " .. tostring(integerValue))
  return true
end

function M.setEmissiveSeparation(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "emissive separation must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.emissiveSeparation = numericValue
  resetTemporalHistory("emissive hit weighting changed", false)
  beamrtLog("I", "emissive hit separation set to " .. tostring(numericValue)
    .. (numericValue <= 0.0001 and " (v0.064 combined hit weighting)" or ""))
  return true
end

function M.setEchoHistoryGuard(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "echo-history guard must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.echoHistoryGuard = numericValue
  resetTemporalHistory("echo-history guard changed", false)
  beamrtLog("I", "motion-aware echo-history guard set to " .. tostring(numericValue)
    .. (numericValue <= 0.0001 and " (v0.063 compatibility)" or ""))
  return true
end

function M.setRayHitDiagnostic(value)
  if type(value) ~= "string" then
    beamrtLog("E", "ray-hit diagnostic must be off, hits, steps, distance, normals, confidence, error, rejection, direction, or viewalignment")
    return false
  end
  local token = string.lower(value):gsub("[%s_%-]", "")
  local modes = {
    off = 0, hits = 1, hit = 1, steps = 2, distance = 3, normals = 4, normal = 4,
    confidence = 5, conf = 5, error = 6, deptherror = 6,
    rejection = 7, reject = 7, reason = 7,
    direction = 8, directions = 8, raydirection = 8,
    viewalignment = 9, alignment = 9, view = 9,
  }
  local selected = modes[token]
  if selected == nil then
    beamrtLog("E", "ray-hit diagnostic must be off, hits, steps, distance, normals, confidence, error, rejection, direction, or viewalignment")
    return false
  end
  if selected > 0 then M.setReflectionDiagnostic("off", false) end
  PROGRESSIVE.rayDebugMode = selected
  PROGRESSIVE.rayDebugName = token
  if selected > 0 then
    -- A manual ray view owns the compose input; discard any lighting-view
    -- override before publishing the new diagnostic constants.
    M.setLightingDiagnostic("off")
  end
  resetTemporalHistory("ray-hit diagnostic changed", false)
  if selected > 0 then
    M.setMode("lighting")
    M.enable()
  end
  applyShaderConsts()
  syncEffectEnablement()
  beamrtLog("I", "raw production-ray diagnostic set to " .. token)
  return true
end

function M.setRayMarcher(value)
  if type(value) ~= "string" then
    beamrtLog("E", "ray marcher must be 'linear' or 'screendda'")
    return false
  end
  local token = string.lower(value):gsub("[%s_%-]", "")
  if token == "linear" or token == "world" or token == "worldstep" then
    PROGRESSIVE.marcherMode = 0
    PROGRESSIVE.marcherName = "linear"
  elseif token == "screendda" or token == "screen" or token == "pixel" then
    PROGRESSIVE.marcherMode = 1
    PROGRESSIVE.marcherName = "screendda"
  else
    beamrtLog("E", "ray marcher must be 'linear' or 'screendda'")
    return false
  end
  resetTemporalHistory("ray marcher changed", false)
  local budgetText = PROGRESSIVE.marcherMode > 0.5 and string.format(
    " (bounded near-field experiment: %d path, %d screen steps maximum)",
    PROGRESSIVE.screenDdaMaxPaths, PROGRESSIVE.screenDdaMaxSteps) or ""
  beamrtLog("I", "ray marcher set to " .. PROGRESSIVE.marcherName .. budgetText)
  return true
end

function M.setScreenRayStride(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.5 or numericValue > 8 then
    beamrtLog("E", "screen-ray stride must be a finite number from 0.5 through 8 pixels")
    return false
  end
  PROGRESSIVE.screenRayStride = numericValue
  resetTemporalHistory("screen-ray stride changed", false)
  beamrtLog("I", "screen-space DDA stride set to " .. tostring(numericValue) .. " pixels")
  return true
end

function M.setScreenDdaMaxPaths(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or 0
  if integerValue < 1 or integerValue > 8 then
    beamrtLog("E", "screen DDA path budget must be an integer from 1 through 8")
    return false
  end
  PROGRESSIVE.screenDdaMaxPaths = integerValue
  resetTemporalHistory("screen DDA path budget changed", false)
  applyGIShaderConsts()
  beamrtLog("I", "screen DDA path budget set to " .. tostring(integerValue))
  return true
end

function M.setScreenDdaMaxSteps(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or 0
  if integerValue < 8 or integerValue > 128 then
    beamrtLog("E", "screen DDA step budget must be an integer from 8 through 128")
    return false
  end
  PROGRESSIVE.screenDdaMaxSteps = integerValue
  resetTemporalHistory("screen DDA step budget changed", false)
  applyGIShaderConsts()
  beamrtLog("I", "screen DDA step budget set to " .. tostring(integerValue))
  return true
end

function M.setSVGFDenoiser(enabled)
  return M.setSVGFStrength(enabled and 1.0 or 0.0)
end

function M.setSVGFStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "SVGF-style variance guidance must be a finite number from 0 through 1")
    return false
  end
  PROGRESSIVE.svgf.strength = numericValue
  resetTemporalHistory("variance-guided denoiser changed", false)
  beamrtLog("I", "SVGF-style moments/variance guidance set to " .. tostring(numericValue))
  return true
end

function M.setSVGFVarianceScale(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 32 then
    beamrtLog("E", "SVGF variance scale must be a finite number from 0 through 32")
    return false
  end
  PROGRESSIVE.svgf.varianceScale = numericValue
  resetTemporalHistory("variance scale changed", false)
  beamrtLog("I", "SVGF variance response scale set to " .. tostring(numericValue))
  return true
end

function M.setSVGFMaxHistory(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or 0
  if integerValue < 1 or integerValue > 256 then
    beamrtLog("E", "SVGF moment history must be an integer from 1 through 256")
    return false
  end
  PROGRESSIVE.svgf.maxHistory = integerValue
  resetTemporalHistory("moment history length changed", false)
  beamrtLog("I", "SVGF moment history set to " .. tostring(integerValue) .. " frames")
  return true
end

function M.setVoxelDDADiagnostic(value)
  if type(value) ~= "string" then
    beamrtLog("E", "voxel DDA diagnostic must be hit, normal, steps, or occupancy")
    return false
  end
  local token = string.lower(value):gsub("[%s_%-]", "")
  local modes = {hit = 0, hits = 0, occupancyhit = 0, normal = 1, normals = 1, steps = 2, heat = 2, occupancy = 3, cells = 3}
  local selected = modes[token]
  if selected == nil then
    beamrtLog("E", "voxel DDA diagnostic must be hit, normal, steps, or occupancy")
    return false
  end
  PROGRESSIVE.voxel.debugMode = selected
  PROGRESSIVE.voxel.debugName = token
  PROGRESSIVE.voxel.applyShaderConsts()
  M.setMode("voxeldda")
  beamrtLog("I", "voxel DDA diagnostic set to " .. token)
  return true
end

function M.setVoxelCellSize(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.05 or numericValue > 20 then
    beamrtLog("E", "voxel cell size must be a finite number from 0.05 through 20")
    return false
  end
  PROGRESSIVE.voxel.cellSize = numericValue
  PROGRESSIVE.voxel.applyShaderConsts()
  beamrtLog("I", "temporary voxel cell size set to " .. tostring(numericValue) .. " m")
  return true
end

function M.setVoxelMaxSteps(value)
  local numericValue = finiteNumber(value)
  local integerValue = numericValue and math.floor(numericValue) or 0
  if integerValue < 1 or integerValue > 128 then
    beamrtLog("E", "voxel DDA max steps must be an integer from 1 through 128")
    return false
  end
  PROGRESSIVE.voxel.maxSteps = integerValue
  PROGRESSIVE.voxel.applyShaderConsts()
  beamrtLog("I", "temporary voxel DDA max steps set to " .. tostring(integerValue))
  return true
end

function M.getExperimentalStatus()
  return {
    blueNoiseStrength = PROGRESSIVE.blueNoiseStrength,
    blueNoiseSource = PROGRESSIVE.blueNoiseSource,
    hitRefinementSteps = PROGRESSIVE.hitRefinementSteps,
    rayHitDiagnostic = PROGRESSIVE.rayDebugName,
    rayMarcher = PROGRESSIVE.marcherName,
    screenRayStride = PROGRESSIVE.screenRayStride,
    screenDdaMaxSteps = PROGRESSIVE.screenDdaMaxSteps,
    screenDdaMaxPaths = PROGRESSIVE.screenDdaMaxPaths,
    hitValidationStrength = PROGRESSIVE.hitValidationStrength,
    minHitTravelPixels = PROGRESSIVE.minHitTravelPixels,
    echoHistoryGuard = PROGRESSIVE.echoHistoryGuard,
    svgfStrength = PROGRESSIVE.svgf.strength,
    svgfVarianceScale = PROGRESSIVE.svgf.varianceScale,
    svgfMaxHistory = PROGRESSIVE.svgf.maxHistory,
    voxelDDA = {
      mode = PROGRESSIVE.voxel.debugName,
      cellSize = PROGRESSIVE.voxel.cellSize,
      maxSteps = PROGRESSIVE.voxel.maxSteps,
      active = enabledRequested and debugMode == MODE_IDS.voxeldda,
      syntheticOnly = false,
      geometryBoxes = #geometryBoxes,
      surfels = #surfels,
    },
  }
end

function M.getProgressiveStatus()
  return PROGRESSIVE.status()
end

function M.setLightingDiagnostic(value)
  local name = type(value) == "string" and string.lower(value) or ""
  local modes = {off = 0, raw = 1, filtered = 2, contribution = 3, receiver = 4,
    direct = 5, roughness = 6, f0 = 7, reflectance = 8,
    contact = 9, attenuation = 10, giweight = 11, identity = 12}
  if modes[name] == nil then
    beamrtLog("E", "lighting diagnostic must be off, raw, filtered, contribution, receiver, direct, roughness, f0, reflectance, contact, attenuation, giweight, or identity")
    return false
  end
  if modes[name] > 0 then M.setReflectionDiagnostic("off", false) end
  if modes[name] > 0 and PROGRESSIVE.rayDebugMode > 0 then
    PROGRESSIVE.rayDebugMode = 0
    PROGRESSIVE.rayDebugName = "off"
    resetTemporalHistory("lighting diagnostic replaced ray-hit diagnostic", false)
  end
  PROGRESSIVE.lightingDiagnostic.mode = modes[name]
  PROGRESSIVE.lightingDiagnostic.name = name
  if modes[name] > 0 then
    if debugMode ~= MODE_IDS.diffusegi then M.setMode("lighting") end
    if not enabledRequested then M.enable() end
  end
  local composeEffect = findObject(COMPOSE_EFFECT_NAME)
  if composeEffect then
    -- Use the same established GI sampler for raw and filtered views. This
    -- removes a separate, unverified slot-7 read from the raw diagnostic.
    local sources = {raw = "#BeamRT_CurrentGI", direct = "#lightinfo[RT0]",
      roughness = "#prepass[RT0]", f0 = "#prepass[RT1]",
      reflectance = PROGRESSIVE.inputPrep.receiverTarget}
    composeEffect:setField("texture", 1, sources[name] or PROGRESSIVE.svgf.atrousTargets[3])
  end
  applyGIShaderConsts()
  syncEffectEnablement()
  return true
end

function M.setReflectionDiagnostic(value, restorePrevious)
  local token = type(value) == "string" and string.lower(value):gsub("[%s_%-]", "") or value
  local aliases = {off = 0, none = 0, receiver = 1, normal = 1, normals = 1,
    validity = 2, valid = 2, hits = 2, hit = 2, hituv = 3, uv = 3,
    hitdepth = 4, depth = 4, rawcolor = 5, raw = 5, color = 5,
    composite = 6, contribution = 6, sourceuv = 7, source = 7,
    rejection = 8, reject = 8, reason = 8, direction = 9, raydirection = 9}
  local selected = type(token) == "number" and token or aliases[token]
  local names = {[0] = "off", "receiver", "validity", "hituv", "hitdepth",
    "rawcolor", "composite", "sourceuv", "rejection", "direction"}
  if not selected or not names[selected] then
    beamrtLog("E", "reflection diagnostic must be off, receiver, validity, hituv, hitdepth, rawcolor, composite, sourceuv, rejection, or direction (0-9)")
    return false
  end
  local state = PROGRESSIVE.reflectionDiagnostic
  if selected == state.mode then return true end
  local previous = state.previous
  if selected > 0 and state.mode == 0 then
    previous = {mode = modeName, enabled = enabledRequested, reflectionsEnabled = reflectionOverlayEnabled,
      diagnostic = PROGRESSIVE.lightingDiagnostic.name, rayHitDiagnostic = PROGRESSIVE.rayDebugName}
    M.setLightingDiagnostic("off")
    M.setRayHitDiagnostic("off")
    state.previous = previous
  end
  state.mode, state.name = selected, names[selected]
  if selected > 0 then
    M.setReflectionsEnabled(false)
    M.setMode("reflections")
    M.enable()
  else
    state.previous = nil
    if previous and restorePrevious ~= false then
      M.setLightingDiagnostic(previous.diagnostic)
      M.setRayHitDiagnostic(previous.rayHitDiagnostic)
      M.setReflectionsEnabled(previous.reflectionsEnabled)
      M.setMode(previous.mode)
      if previous.enabled then M.enable() else M.disable() end
    end
  end
  resetReflectionHistory("reflection diagnostic changed", false)
  applyReflectionShaderConsts()
  syncEffectEnablement()
  beamrtLog("I", "reflection diagnostic set to " .. state.name)
  return true
end

function M.getReflectionDiagnosticState()
  local state = PROGRESSIVE.reflectionDiagnostic
  local previous = state.previous
  return {mode = state.mode, name = state.name, active = state.mode > 0,
    temporalBypassed = state.mode > 0, denoiseDisabled = state.mode > 0,
    previous = previous and {mode = previous.mode, enabled = previous.enabled,
      reflectionsEnabled = previous.reflectionsEnabled, diagnostic = previous.diagnostic,
      rayHitDiagnostic = previous.rayHitDiagnostic} or nil}
end

function M.restoreReflectionDiagnosticState(snapshot)
  if type(snapshot) ~= "table" or not M.setReflectionDiagnostic(snapshot.name) then return false end
  if PROGRESSIVE.reflectionDiagnostic.mode > 0 and type(snapshot.previous) == "table" then
    local previous = snapshot.previous
    PROGRESSIVE.reflectionDiagnostic.previous = {mode = previous.mode, enabled = previous.enabled,
      reflectionsEnabled = previous.reflectionsEnabled, diagnostic = previous.diagnostic,
      rayHitDiagnostic = previous.rayHitDiagnostic}
  end
  return true
end

function M.getLightingAuditState()
  return {enabled = enabledRequested, tunerOpen = tuningWindowOpen[0],
    mode = modeName, reflectionsEnabled = reflectionOverlayEnabled,
    diagnostic = PROGRESSIVE.lightingDiagnostic.name, rayHitDiagnostic = PROGRESSIVE.rayDebugName,
    reflectionDiagnostic = PROGRESSIVE.reflectionDiagnostic.name,
    reflectionDiagnosticMode = PROGRESSIVE.reflectionDiagnostic.mode}
end

function M.getTextureBindingStatus()
  local result = {requiredCapacity = 6, packed = true, effects = {}}
  for _, name in ipairs({GI_EFFECT_NAME, TEMPORAL_EFFECT_NAME, COMPOSE_EFFECT_NAME,
    PROGRESSIVE.inputPrep.receiverEffectName, PROGRESSIVE.inputPrep.auxiliaryEffectName,
    REFLECTION_EFFECT_NAME, REFLECTION_TEMPORAL_EFFECT_NAME, REFLECTION_COMPOSE_EFFECT_NAME,
    PROGRESSIVE.reflectionHit.inputsEffectName, PROGRESSIVE.reflectionHit.copyEffectName}) do
    local effect = findObject(name)
    if effect then
      local capacity
      for _, method in ipairs({"getFieldsForEditor", "getFields"}) do
        local ok, fields = pcall(function()
          if type(effect[method]) == "function" then return effect[method](effect) end
        end)
        if ok and type(fields) == "table" then
          local descriptor = fields.texture
          if not descriptor then
            for _, field in pairs(fields) do
              if type(field) == "table" and (field.name == "texture" or field.fieldName == "texture") then
                descriptor = field
                break
              end
            end
          end
          if type(descriptor) == "table" then
            capacity = tonumber(descriptor.elementCount or descriptor.arraySize)
          end
        end
        if capacity then break end
      end
      local entry = {name = name, nativeCapacity = capacity, textures = {}}
      for slot = 0, math.min(capacity or 6, 6) - 1 do
        entry.textures[#entry.textures + 1] = {slot = slot, target = effect:getField("texture", slot)}
      end
      result.effects[#result.effects + 1] = entry
      if capacity then result.nativeCapacity = capacity end
    end
  end
  return result
end

function M.runLightingAudit(includeInputs)
  if extensions and extensions.beamrt_reflectionSourceProbe
    and extensions.beamrt_reflectionSourceProbe.getStatus().active then
    return false, "reflection source diagnostic is running"
  end
  if extensions and extensions.beamrt_reflectionConvergence
    and extensions.beamrt_reflectionConvergence.getStatus().active then
    return false, "reflection convergence diagnostic is running"
  end
  if materialCachePublication or CLEAN_RADIANCE.build then
    beamrtLog("E", "lighting audit must wait for the current material/radiance capture to finish")
    return false, "another BeamRT capture is running"
  end
  local mode = (includeInputs == "compare" or includeInputs == "reflection") and includeInputs or includeInputs == true
  local ok, result = PROGRESSIVE.lightingAudit.start(M, mode)
  beamrtLog(ok and "I" or "E", "lighting audit: " .. tostring(result))
  return ok, result
end

function M.runReflectionAudit()
  return M.runLightingAudit("reflection")
end

function M.cancelLightingAudit()
  return PROGRESSIVE.lightingAudit.cancel(M, "cancelled by user")
end

function M.getLightingAuditStatus()
  return PROGRESSIVE.lightingAudit.getStatus()
end

function M.setGIRenderScale(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.5 or numericValue > 1.0 then
    beamrtLog("E", "GI render scale must be a finite number from 0.5 through 1.0")
    return false
  end
  giRenderScale = numericValue
  local scaleText = string.format("%.3g %.3g", giRenderScale, giRenderScale)
  for _, objectName in ipairs({GI_EFFECT_NAME, PROGRESSIVE.svgf.effectName, TEMPORAL_EFFECT_NAME,
    PROGRESSIVE.svgf.atrousEffectNames[1], PROGRESSIVE.svgf.atrousEffectNames[2],
    PROGRESSIVE.svgf.atrousEffectNames[3], COPY_EFFECT_NAME, PROGRESSIVE.svgf.copyEffectName}) do
    local object = findObject(objectName)
    if object then object:setField("targetScale", 0, scaleText) end
  end
  resetTemporalHistory("GI render scale changed", false)
  beamrtLog("I", "GI render scale set to " .. tostring(giRenderScale))
  return true
end

function M.setWorldLeakSuppression(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "world leak suppression must be a finite number from 0 through 1")
    return false
  end
  worldLeakSuppression = numericValue
  resetTemporalHistory("world leak suppression changed", false)
  beamrtLog("I", "world leak suppression set to " .. tostring(worldLeakSuppression))
  return true
end

local function invalidateRadianceSource(reason)
  -- The cache contains post-selection radiance, so any source/cleanup control
  -- must invalidate temporal GI and the persistent atlas before an A/B is valid.
  surfelCacheResetFrames = 2
  resetTemporalHistory(reason, false)
end

function M.setRadianceCleanup(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "radiance cleanup must be a finite number from 0 through 1")
    return false
  end
  radianceCleanup = numericValue
  invalidateRadianceSource("radiance cleanup changed")
  beamrtLog("I", "radiance cleanup set to " .. tostring(radianceCleanup)
    .. (radianceCleanup <= 0 and " (raw legacy path)" or ""))
  return true
end

function M.setSpecularReject(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "specular rejection must be a finite number from 0 through 1")
    return false
  end
  specularReject = numericValue
  invalidateRadianceSource("specular rejection changed")
  beamrtLog("I", "specular rejection set to " .. tostring(specularReject))
  return true
end

function M.setRadianceSource(value)
  if type(value) ~= "string" then
    beamrtLog("E", "radiance source must be 'directdiffuse'/'lightinfo' or 'legacy'/'backbuffer'")
    return false
  end
  local normalized = string.lower(value):gsub("[%s_%-]", "")
  if normalized == "directdiffuse" or normalized == "lightinfo" or normalized == "lightinfo0" then
    radianceSourceMode = 1
    radianceSourceName = "directdiffuse"
  elseif normalized == "legacy" or normalized == "backbuffer" or normalized == "cleanedbackbuffer" then
    radianceSourceMode = 0
    radianceSourceName = "legacy"
  else
    beamrtLog("E", "unknown radiance source '" .. tostring(value)
      .. "'; expected directdiffuse/lightinfo or legacy/backbuffer")
    return false
  end
  invalidateRadianceSource("radiance source changed")
  beamrtLog("I", "radiance source set to " .. radianceSourceName
    .. (radianceSourceMode == 1
      and " (lightinfo0.rgb energy; component-wise de-lit material estimate; prepass1.a retro rejection)"
      or " (cleaned final HDR backbuffer fallback)"))
  return true
end

function M.getRadianceSource()
  return radianceSourceName
end

function M.setRadianceChromaStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "radiance chroma strength must be a finite number from 0 through 1")
    return false
  end
  radianceChromaStrength = numericValue
  invalidateRadianceSource("radiance chroma strength changed")
  beamrtLog("I", "radiance chroma strength set to " .. tostring(radianceChromaStrength))
  return true
end

function M.setRetroReject(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "retro rejection must be a finite number from 0 through 1")
    return false
  end
  retroReject = numericValue
  invalidateRadianceSource("retro rejection changed")
  beamrtLog("I", "retro rejection set to " .. tostring(retroReject))
  return true
end

function M.getSettings()
  return {
    version = VERSION,
    mode = modeName,
    giSource = M.getGISource(),
    ptgiRadianceSource = CLEAN_RADIANCE.selectedPTGISource,
    radianceSource = radianceSourceName,
    progressiveEnabled = PROGRESSIVE.enabled,
    progressiveMaxSamples = PROGRESSIVE.maxSamples,
    progressiveClampStrength = PROGRESSIVE.clampStrength,
    progressiveSamples = PROGRESSIVE.samples,
    giEstimator = PROGRESSIVE.estimatorName,
    giLocalization = PROGRESSIVE.localization,
    secondBounceStrength = PROGRESSIVE.secondBounceStrength,
    emissiveBoost = PROGRESSIVE.emissiveBoost,
    rayReach = PROGRESSIVE.rayReach,
    rearRayReach = PROGRESSIVE.rearRayReach,
    lowPathRescue = PROGRESSIVE.lowPathRescue,
    blueNoiseStrength = PROGRESSIVE.blueNoiseStrength,
    blueNoiseSource = PROGRESSIVE.blueNoiseSource,
    svgfStrength = PROGRESSIVE.svgf.strength,
    svgfVarianceScale = PROGRESSIVE.svgf.varianceScale,
    svgfMaxHistory = PROGRESSIVE.svgf.maxHistory,
    hitRefinementSteps = PROGRESSIVE.hitRefinementSteps,
    rayMarcher = PROGRESSIVE.marcherName,
    screenRayStride = PROGRESSIVE.screenRayStride,
    screenDdaMaxPaths = PROGRESSIVE.screenDdaMaxPaths,
    screenDdaMaxSteps = PROGRESSIVE.screenDdaMaxSteps,
    hitValidationStrength = PROGRESSIVE.hitValidationStrength,
    minHitTravelPixels = PROGRESSIVE.minHitTravelPixels,
    echoHistoryGuard = PROGRESSIVE.echoHistoryGuard,
    candidateContinuation = PROGRESSIVE.candidateContinuation,
    candidateRetryCount = PROGRESSIVE.candidateRetryCount,
    emissiveSeparation = PROGRESSIVE.emissiveSeparation,
    giStrength = giStrength,
    worldGIStrength = worldGIStrength,
    worldLeakSuppression = worldLeakSuppression,
    radianceCleanup = radianceCleanup,
    specularReject = specularReject,
    radianceChromaStrength = radianceChromaStrength,
    retroReject = retroReject,
    bounceSaturation = bounceSaturation,
    contactShadowStrength = contactShadowStrength,
    giExposure = giExposure,
    giShadowFocus = giShadowFocus,
    giReceiverTint = giReceiverTint,
    giContrast = giContrast,
    giEnergyLimit = giEnergyLimit,
    giHighlightRolloff = giHighlightRolloff,
    giClamp = giClamp,
    temporalBlend = temporalBlend,
    denoiseStrength = denoiseStrength,
    historyDepthTolerance = historyDepthTolerance,
    giCellSize = giCellSize,
    rayStepSize = rayStepSize,
    rayThickness = rayThickness,
    rayNormalBias = rayNormalBias,
    rayMaxSteps = rayMaxSteps,
    giPathCount = giPathCount,
    giRenderScale = giRenderScale,
    surfelTraceDistance = surfelTraceDistance,
    surfelBaseRadius = surfelBaseRadius,
    surfelVisibilityTolerance = surfelVisibilityTolerance,
    surfelCacheBlend = surfelCacheBlend,
    surfelRefreshDistance = surfelRefreshDistance,
    surfelRefreshRaysPerFrame = surfelRefreshRaysPerFrame,
    reflectionsEnabled = reflectionOverlayEnabled,
    reflectionSamplingMode = PROGRESSIVE.reflectionSampling.name,
    reflectionReconstruction = PROGRESSIVE.reflectionReconstruction.name,
    reflectionHitAwareEnabled = PROGRESSIVE.reflectionHit.enabled,
    reflectionColorFilterEnabled = PROGRESSIVE.reflectionColor.enabled,
    reflectionSampleCellPixels = PROGRESSIVE.reflectionTuning.sampleCellPixels,
    reflectionNoiseSeed = PROGRESSIVE.reflectionTuning.noiseSeed,
    reflectionFilterRadiusScale = PROGRESSIVE.reflectionTuning.filterRadiusScale,
    reflectionSourceFootprintScale = PROGRESSIVE.reflectionTuning.sourceFootprintScale,
    reflectionStrength = reflectionStrength,
    reflectionMaxRoughness = reflectionMaxRoughness,
    reflectionStepSize = reflectionStepSize,
    reflectionThickness = reflectionThickness,
    reflectionNormalBias = reflectionNormalBias,
    reflectionTemporalBlend = reflectionTemporalBlend,
    reflectionDenoiseStrength = reflectionDenoiseStrength,
  }
end

function M.settingsCommand()
  local command = string.format(
    "beamrt_main.setProgressiveAccumulation(%s); beamrt_main.setProgressiveMaxSamples(%d); beamrt_main.setProgressiveClampStrength(%.4g); beamrt_main.setGIEstimator('%s'); beamrt_main.setGILocalization(%.4g); beamrt_main.setSecondBounceStrength(%.4g); beamrt_main.setEmissiveBoost(%.4g); beamrt_main.setRayReach(%.4g); beamrt_main.setRearRayReach(%.4g); beamrt_main.setLowPathRescue(%.4g); beamrt_main.setHitRefinementSteps(%d); beamrt_main.setRayMarcher('%s'); beamrt_main.setScreenRayStride(%.4g); beamrt_main.setHitValidationStrength(%.4g); beamrt_main.setMinHitTravelPixels(%.4g); beamrt_main.setCandidateContinuation(%.4g); beamrt_main.setCandidateRetryCount(%d); beamrt_main.setEmissiveSeparation(%.4g); beamrt_main.setEchoHistoryGuard(%.4g); beamrt_main.setBlueNoiseStrength(%.4g); beamrt_main.setSVGFStrength(%.4g); beamrt_main.setSVGFVarianceScale(%.4g); beamrt_main.setSVGFMaxHistory(%d); beamrt_main.setRadianceSource('%s'); beamrt_main.setRadianceChromaStrength(%.4g); beamrt_main.setRetroReject(%.4g); beamrt_main.setGIStrength(%.4g); beamrt_main.setWorldGIStrength(%.4g); beamrt_main.setWorldLeakSuppression(%.4g); beamrt_main.setRadianceCleanup(%.4g); beamrt_main.setSpecularReject(%.4g); beamrt_main.setBounceSaturation(%.4g); beamrt_main.setContactShadowStrength(%.4g); beamrt_main.setGIExposure(%.4g); beamrt_main.setGIShadowFocus(%.4g); beamrt_main.setGIReceiverTint(%.4g); beamrt_main.setGIContrast(%.4g); beamrt_main.setGIEnergyLimit(%.4g); beamrt_main.setGIHighlightRolloff(%.4g); beamrt_main.setGIClamp(%.4g); beamrt_main.setTemporalBlend(%.4g); beamrt_main.setDenoiseStrength(%.4g); beamrt_main.setHistoryDepthTolerance(%.4g); beamrt_main.setGICellSize(%.4g); beamrt_main.setGIPathCount(%d); beamrt_main.setGIRenderScale(%.4g); beamrt_main.setRayStepSize(%.4g); beamrt_main.setRayThickness(%.4g); beamrt_main.setRayNormalBias(%.4g); beamrt_main.setRaySteps(%d); beamrt_main.setSurfelTraceDistance(%.4g); beamrt_main.setSurfelRadius(%.4g); beamrt_main.setSurfelVisibilityTolerance(%.4g); beamrt_main.setSurfelCacheBlend(%.4g); beamrt_main.setSurfelRefreshDistance(%.4g); beamrt_main.setSurfelRefreshRaysPerFrame(%d); beamrt_main.refreshSurfels()",
    tostring(PROGRESSIVE.enabled), PROGRESSIVE.maxSamples, PROGRESSIVE.clampStrength,
    PROGRESSIVE.estimatorName, PROGRESSIVE.localization, PROGRESSIVE.secondBounceStrength, PROGRESSIVE.emissiveBoost,
    PROGRESSIVE.rayReach, PROGRESSIVE.rearRayReach, PROGRESSIVE.lowPathRescue,
    PROGRESSIVE.hitRefinementSteps, PROGRESSIVE.marcherName, PROGRESSIVE.screenRayStride,
    PROGRESSIVE.hitValidationStrength, PROGRESSIVE.minHitTravelPixels, PROGRESSIVE.candidateContinuation,
    PROGRESSIVE.candidateRetryCount, PROGRESSIVE.emissiveSeparation, PROGRESSIVE.echoHistoryGuard,
    PROGRESSIVE.blueNoiseStrength, PROGRESSIVE.svgf.strength,
    PROGRESSIVE.svgf.varianceScale, PROGRESSIVE.svgf.maxHistory,
    radianceSourceName, radianceChromaStrength, retroReject,
    giStrength, worldGIStrength, worldLeakSuppression, radianceCleanup, specularReject, bounceSaturation, contactShadowStrength,
    giExposure, giShadowFocus, giReceiverTint, giContrast, giEnergyLimit, giHighlightRolloff, giClamp,
    temporalBlend, denoiseStrength, historyDepthTolerance, giCellSize,
    giPathCount, giRenderScale, rayStepSize, rayThickness, rayNormalBias, rayMaxSteps,
    surfelTraceDistance, surfelBaseRadius, surfelVisibilityTolerance,
    surfelCacheBlend, surfelRefreshDistance, surfelRefreshRaysPerFrame
  )
  return command .. string.format(
    "; beamrt_main.setBlueNoiseSource('%s'); beamrt_main.setReflectionsEnabled(%s); beamrt_main.setReflectionSamplingMode('%s'); beamrt_main.setReflectionReconstruction('%s'); beamrt_main.setReflectionHitAwareEnabled(%s); beamrt_main.setReflectionStrength(%.4g); beamrt_main.setReflectionMaxRoughness(%.4g); beamrt_main.setReflectionStepSize(%.4g); beamrt_main.setReflectionThickness(%.4g); beamrt_main.setReflectionNormalBias(%.4g); beamrt_main.setReflectionTemporalBlend(%.4g); beamrt_main.setReflectionDenoiseStrength(%.4g); beamrt_main.setScreenDdaMaxPaths(%d); beamrt_main.setScreenDdaMaxSteps(%d); beamrt_main.setPTGIRadianceSource('%s'); beamrt_main.setMode('%s')",
    PROGRESSIVE.blueNoiseSource, tostring(reflectionOverlayEnabled), PROGRESSIVE.reflectionSampling.name,
    PROGRESSIVE.reflectionReconstruction.name, tostring(PROGRESSIVE.reflectionHit.enabled),
    reflectionStrength, reflectionMaxRoughness, reflectionStepSize, reflectionThickness,
    reflectionNormalBias, reflectionTemporalBlend, reflectionDenoiseStrength,
    PROGRESSIVE.screenDdaMaxPaths, PROGRESSIVE.screenDdaMaxSteps,
    CLEAN_RADIANCE.selectedPTGISource, modeName)
    .. "; beamrt_main.setReflectionColorFilterEnabled(" .. tostring(PROGRESSIVE.reflectionColor.enabled) .. ")"
    .. string.format("; beamrt_main.setReflectionSampleCellPixels(%.4g); beamrt_main.setReflectionNoiseSeed(%d); beamrt_main.setReflectionFilterRadiusScale(%.4g); beamrt_main.setReflectionSourceFootprintScale(%.4g)",
      PROGRESSIVE.reflectionTuning.sampleCellPixels, PROGRESSIVE.reflectionTuning.noiseSeed,
      PROGRESSIVE.reflectionTuning.filterRadiusScale, PROGRESSIVE.reflectionTuning.sourceFootprintScale)
end

function M.printSettings()
  local command = M.settingsCommand()
  beamrtLog("I", "current tuning command: " .. command)
  return command
end

function M.applySettings(settings)
  if type(settings) ~= "table" then
    beamrtLog("E", "settings must be a table")
    return false
  end

  local setters = {
    {"progressiveEnabled", M.setProgressiveAccumulation},
    {"progressiveMaxSamples", M.setProgressiveMaxSamples},
    {"progressiveClampStrength", M.setProgressiveClampStrength},
    {"giEstimator", M.setGIEstimator},
    {"giLocalization", M.setGILocalization},
    {"secondBounceStrength", M.setSecondBounceStrength},
    {"emissiveBoost", M.setEmissiveBoost},
    {"rayReach", M.setRayReach},
    {"rearRayReach", M.setRearRayReach},
    {"lowPathRescue", M.setLowPathRescue},
    {"blueNoiseStrength", M.setBlueNoiseStrength},
    {"blueNoiseSource", M.setBlueNoiseSource},
    {"svgfStrength", M.setSVGFStrength},
    {"svgfVarianceScale", M.setSVGFVarianceScale},
    {"svgfMaxHistory", M.setSVGFMaxHistory},
    {"hitRefinementSteps", M.setHitRefinementSteps},
    {"rayMarcher", M.setRayMarcher},
    {"screenRayStride", M.setScreenRayStride},
    {"screenDdaMaxPaths", M.setScreenDdaMaxPaths},
    {"screenDdaMaxSteps", M.setScreenDdaMaxSteps},
    {"hitValidationStrength", M.setHitValidationStrength},
    {"minHitTravelPixels", M.setMinHitTravelPixels},
    {"echoHistoryGuard", M.setEchoHistoryGuard},
    {"candidateContinuation", M.setCandidateContinuation},
    {"candidateRetryCount", M.setCandidateRetryCount},
    {"emissiveSeparation", M.setEmissiveSeparation},
    {"ptgiRadianceSource", M.setPTGIRadianceSource},
    {"radianceSource", M.setRadianceSource},
    {"radianceChromaStrength", M.setRadianceChromaStrength},
    {"retroReject", M.setRetroReject},
    {"giStrength", M.setGIStrength},
    {"worldGIStrength", M.setWorldGIStrength},
    {"worldLeakSuppression", M.setWorldLeakSuppression},
    {"radianceCleanup", M.setRadianceCleanup},
    {"specularReject", M.setSpecularReject},
    {"bounceSaturation", M.setBounceSaturation},
    {"contactShadowStrength", M.setContactShadowStrength},
    {"giExposure", M.setGIExposure},
    {"giShadowFocus", M.setGIShadowFocus},
    {"giReceiverTint", M.setGIReceiverTint},
    {"giContrast", M.setGIContrast},
    {"giEnergyLimit", M.setGIEnergyLimit},
    {"giHighlightRolloff", M.setGIHighlightRolloff},
    {"giClamp", M.setGIClamp},
    {"temporalBlend", M.setTemporalBlend},
    {"denoiseStrength", M.setDenoiseStrength},
    {"historyDepthTolerance", M.setHistoryDepthTolerance},
    {"giCellSize", M.setGICellSize},
    {"rayStepSize", M.setRayStepSize},
    {"rayThickness", M.setRayThickness},
    {"rayNormalBias", M.setRayNormalBias},
    {"rayMaxSteps", M.setRaySteps},
    {"giPathCount", M.setGIPathCount},
    {"giRenderScale", M.setGIRenderScale},
    {"surfelTraceDistance", M.setSurfelTraceDistance},
    {"surfelBaseRadius", M.setSurfelRadius},
    {"surfelVisibilityTolerance", M.setSurfelVisibilityTolerance},
    {"surfelCacheBlend", M.setSurfelCacheBlend},
    {"surfelRefreshDistance", M.setSurfelRefreshDistance},
    {"surfelRefreshRaysPerFrame", M.setSurfelRefreshRaysPerFrame},
    {"reflectionsEnabled", M.setReflectionsEnabled},
    {"reflectionSamplingMode", M.setReflectionSamplingMode},
    {"reflectionReconstruction", M.setReflectionReconstruction},
    {"reflectionHitAwareEnabled", M.setReflectionHitAwareEnabled},
    {"reflectionColorFilterEnabled", M.setReflectionColorFilterEnabled},
    {"reflectionSampleCellPixels", M.setReflectionSampleCellPixels},
    {"reflectionNoiseSeed", M.setReflectionNoiseSeed},
    {"reflectionFilterRadiusScale", M.setReflectionFilterRadiusScale},
    {"reflectionSourceFootprintScale", M.setReflectionSourceFootprintScale},
    {"reflectionStrength", M.setReflectionStrength},
    {"reflectionMaxRoughness", M.setReflectionMaxRoughness},
    {"reflectionStepSize", M.setReflectionStepSize},
    {"reflectionThickness", M.setReflectionThickness},
    {"reflectionNormalBias", M.setReflectionNormalBias},
    {"reflectionTemporalBlend", M.setReflectionTemporalBlend},
    {"reflectionDenoiseStrength", M.setReflectionDenoiseStrength},
  }

  local success = true
  for _, entry in ipairs(setters) do
    local value = settings[entry[1]]
    if value ~= nil and not entry[2](value) then
      success = false
    end
  end
  if settings.giSource ~= nil and not M.setGISource(settings.giSource) then
    success = false
  end
  if settings.mode ~= nil and not M.setMode(settings.mode) then
    success = false
  end
  refreshSurfels(false)
  resetTemporalHistory("tuning settings applied", false)
  applyShaderConsts()
  return success
end

function M.applyPreset(name)
  local normalizedName = type(name) == "string" and string.lower(name) or ""
  local preset = TUNING_PRESETS[normalizedName]
  if not preset then
    beamrtLog("E", "unknown tuning preset '" .. tostring(name) .. "'; expected experimental, userbest, cinematic, maxquality, beautymax, beautyreflect, ptgiplay, ptgiplayreflect, ptgimax, ptgimaxreflect, ultra, showcase, balanced, clean, or performance")
    return false
  end
  -- Presets remain reflection-free unless their name explicitly includes the
  -- reflection overlay.
  if preset.reflectionsEnabled == nil then
    M.setReflectionsEnabled(false)
  end
  local result = M.applySettings(preset)
  beamrtLog("I", "applied " .. normalizedName .. " tuning preset")
  return result
end

function M.applyExperimentalPreset()
  local ok = M.applyPreset("experimental")
  if not ok then return false end
  M.setMode("lighting")
  M.enable()
  M.openTuner()
  return true
end

function M.saveTuning()
  local ok, result = pcall(jsonWriteFile, TUNING_FILE, M.getSettings(), true)
  if not ok or result == false then
    beamrtLog("E", "failed to save tuning to " .. TUNING_FILE)
    return false
  end
  beamrtLog("I", "saved tuning to " .. TUNING_FILE)
  return true
end

function M.loadTuning()
  local ok, settings = pcall(jsonReadFile, TUNING_FILE)
  if not ok or type(settings) ~= "table" then
    beamrtLog("E", "no valid saved tuning found at " .. TUNING_FILE)
    return false
  end
  local result = M.applySettings(settings)
  beamrtLog("I", "loaded tuning from " .. TUNING_FILE)
  return result
end

function M.resetHistory()
  resetTemporalHistory("manual request", true)
  if reflectionOverlayEnabled or debugMode == MODE_IDS.reflections then
    resetReflectionHistory("manual request", true)
  end
  return true
end

function M.setReflectionsEnabled(value)
  if type(value) ~= "boolean" then
    beamrtLog("E", "reflections enabled must be a boolean")
    return false
  end
  if reflectionOverlayEnabled == value then
    return true
  end
  reflectionOverlayEnabled = value
  if reflectionOverlayEnabled then
    resetReflectionHistory("reflection overlay enabled", false)
  else
    reflectionHistoryValid = 0
    reflectionHistoryWarmupFrames = 0
    PROGRESSIVE.reflectionSampling.frame = 0
    PROGRESSIVE.reflectionSampling.sampleIndex = 0
  end
  syncEffectEnablement()
  beamrtLog("I", "reflection overlay " .. (reflectionOverlayEnabled and "enabled" or "disabled"))
  return true
end

function M.setReflectionSamplingMode(value)
  local token = type(value) == "string" and string.lower(value) or value
  local selected = token == "mirror" and 0 or token == "ggx" and 1 or token
  if selected ~= 0 and selected ~= 1 then
    beamrtLog("E", "reflection sampling mode must be mirror (0) or ggx (1)")
    return false
  end
  local sampling = PROGRESSIVE.reflectionSampling
  if selected == sampling.mode then return true end
  sampling.mode, sampling.name = selected, selected == 1 and "ggx" or "mirror"
  resetReflectionHistory("reflection sampling mode changed", false)
  beamrtLog("I", "reflection sampling set to " .. sampling.name)
  return true
end

function M.getReflectionSamplingState()
  local sampling = PROGRESSIVE.reflectionSampling
  return {mode = sampling.mode, name = sampling.name, frame = sampling.frame,
    sampleIndex = sampling.sampleIndex, frozen = sampling.isFrozen()}
end

function M.setReflectionReconstruction(value)
  local token = type(value) == "string" and string.lower(value) or value
  local selected = token == "legacy" and 0 or token == "playable" and 1 or token
  if selected ~= 0 and selected ~= 1 then
    beamrtLog("E", "reflection reconstruction must be legacy (0) or playable (1)")
    return false
  end
  local reconstruction = PROGRESSIVE.reflectionReconstruction
  if selected == reconstruction.mode then return true end
  reconstruction.mode, reconstruction.name = selected, selected == 1 and "playable" or "legacy"
  resetReflectionHistory("reflection reconstruction changed", false)
  beamrtLog("I", "reflection reconstruction set to " .. reconstruction.name)
  return true
end

function M.getReflectionReconstructionState()
  local reconstruction = PROGRESSIVE.reflectionReconstruction
  return {mode = reconstruction.mode, name = reconstruction.name, frameDelta = reconstruction.frameDelta,
    frozen = PROGRESSIVE.reflectionSampling.isFrozen()}
end

function M.setReflectionHitAwareEnabled(value)
  if type(value) ~= "boolean" then
    beamrtLog("E", "reflection hit-aware enabled must be a boolean")
    return false
  end
  if PROGRESSIVE.reflectionHit.enabled == value then return true end
  PROGRESSIVE.reflectionHit.enabled = value
  resetReflectionHistory("reflection hit-aware selection changed", false)
  beamrtLog("I", "reflection hit-aware reconstruction " .. (value and "enabled" or "disabled"))
  return true
end

function M.getReflectionHitState()
  return {enabled = PROGRESSIVE.reflectionHit.enabled,
    configured = PROGRESSIVE.reflectionHit.configured(),
    active = effectIsEnabled(PROGRESSIVE.reflectionHit.inputsEffectName),
    frozen = PROGRESSIVE.reflectionSampling.isFrozen(),
    metadataTarget = PROGRESSIVE.reflectionHit.historyTarget,
    smoothMirrorThreshold = 0.035}
end

function M.setReflectionColorFilterEnabled(value)
  if type(value) ~= "boolean" then
    beamrtLog("E", "reflection color filter must be true/false")
    return false
  end
  if value == PROGRESSIVE.reflectionColor.enabled then return true end
  PROGRESSIVE.reflectionColor.enabled = value
  resetReflectionHistory("reflection color filter changed", false)
  beamrtLog("I", "reflection color filter " .. (value and "enabled" or "disabled"))
  return true
end

-- Numeric experiment controls share validation, but never reset GI history.
PROGRESSIVE.reflectionTuning.set = function(key, value, minimum, maximum, integer)
  local number = finiteNumber(value)
  if not number or number < minimum or number > maximum or (integer and number ~= math.floor(number)) then
    beamrtLog("E", "reflection " .. key .. " must be " .. (integer and "an integer" or "a finite number")
      .. " from " .. minimum .. " through " .. maximum)
    return false
  end
  if PROGRESSIVE.reflectionTuning[key] == number then return true end
  PROGRESSIVE.reflectionTuning[key] = number
  resetReflectionHistory("reflection " .. key .. " changed", false)
  beamrtLog("I", "reflection " .. key .. " set to " .. tostring(number))
  return true
end

function M.setReflectionSampleCellPixels(value)
  return PROGRESSIVE.reflectionTuning.set("sampleCellPixels", value, 0.25, 4.0, false)
end
function M.setReflectionNoiseSeed(value)
  return PROGRESSIVE.reflectionTuning.set("noiseSeed", value, 0, 65535, true)
end
function M.setReflectionFilterRadiusScale(value)
  return PROGRESSIVE.reflectionTuning.set("filterRadiusScale", value, 0.25, 3.0, false)
end
function M.setReflectionSourceFootprintScale(value)
  return PROGRESSIVE.reflectionTuning.set("sourceFootprintScale", value, 0.0, 2.0, false)
end
function M.resetReflectionTuning()
  M.setReflectionSampleCellPixels(1.0)
  M.setReflectionNoiseSeed(0)
  M.setReflectionFilterRadiusScale(1.0)
  M.setReflectionSourceFootprintScale(1.0)
  return true
end

-- Transient diagnostic gate; deliberately not saved as a gameplay setting.
-- The companion convergence module owns mean/moment passes and restoration.
function M.setReflectionConvergenceEnabled(value)
  if type(value) ~= "boolean" then return false end
  if value == PROGRESSIVE.reflectionConvergenceEnabled then return true end
  PROGRESSIVE.reflectionConvergenceEnabled = value
  resetReflectionHistory("raw convergence diagnostic changed", false)
  return true
end

function M.getReflectionConvergenceEnabled() return PROGRESSIVE.reflectionConvergenceEnabled end

-- Only the three owned diagnostic targets may replace the source, never a
-- shader sampler index or an arbitrary external filename. Not a saved setting.
function M.setReflectionSourceProbeTarget(target)
  if target ~= nil and target ~= "#BeamRT_SourceProbeNative" and target ~= "#BeamRT_SourceProbeLive"
    and target ~= "#BeamRT_SourceProbeFrozen" then return false end
  if target == PROGRESSIVE.reflectionSourceProbeTarget then return true end
  PROGRESSIVE.reflectionSourceProbeTarget = target
  resetReflectionHistory("reflection source diagnostic changed", false)
  return true
end

function M.getReflectionSourceProbeTarget() return PROGRESSIVE.reflectionSourceProbeTarget end

function M.setReflectionStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 2 then
    beamrtLog("E", "reflection strength must be a finite number from 0 through 2")
    return false
  end
  reflectionStrength = numericValue
  applyReflectionShaderConsts()
  beamrtLog("I", "reflection strength set to " .. tostring(reflectionStrength))
  return true
end

function M.setReflectionMaxRoughness(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.05 or numericValue > 1 then
    beamrtLog("E", "reflection maximum roughness must be a finite number from 0.05 through 1")
    return false
  end
  reflectionMaxRoughness = numericValue
  resetReflectionHistory("reflection roughness cutoff changed", false)
  beamrtLog("I", "reflection maximum roughness set to " .. tostring(reflectionMaxRoughness))
  return true
end

function M.setReflectionStepSize(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.05 or numericValue > 2.0 then
    beamrtLog("E", "reflection step size must be a finite number from 0.05 through 2.0")
    return false
  end
  reflectionStepSize = numericValue
  resetReflectionHistory("reflection step size changed", false)
  beamrtLog("I", "reflection step size set to " .. tostring(reflectionStepSize))
  return true
end

function M.setReflectionThickness(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0.02 or numericValue > 2.0 then
    beamrtLog("E", "reflection thickness must be a finite number from 0.02 through 2.0")
    return false
  end
  reflectionThickness = numericValue
  resetReflectionHistory("reflection thickness changed", false)
  beamrtLog("I", "reflection thickness set to " .. tostring(reflectionThickness))
  return true
end

function M.setReflectionNormalBias(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 0.25 then
    beamrtLog("E", "reflection normal bias must be a finite number from 0 through 0.25")
    return false
  end
  reflectionNormalBias = numericValue
  resetReflectionHistory("reflection normal bias changed", false)
  beamrtLog("I", "reflection normal bias set to " .. tostring(reflectionNormalBias))
  return true
end

function M.setReflectionTemporalBlend(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "reflection temporal current-frame weight must be a finite number from 0 through 1")
    return false
  end
  reflectionTemporalBlend = numericValue
  resetReflectionHistory("reflection temporal weight changed", false)
  beamrtLog("I", "reflection temporal current-frame weight set to " .. tostring(reflectionTemporalBlend))
  return true
end

function M.setReflectionDenoiseStrength(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 or numericValue > 1 then
    beamrtLog("E", "reflection denoise strength must be a finite number from 0 through 1")
    return false
  end
  reflectionDenoiseStrength = numericValue
  resetReflectionHistory("reflection denoise changed", false)
  beamrtLog("I", "reflection denoise strength set to " .. tostring(reflectionDenoiseStrength))
  return true
end

-- Opt-in, reversible variance-guided GGX filtering. Mirror, diagnostic,
-- and convergence tests always stay on the original output path.
function M.setReflectionVarianceEnabled(enabled)
  PROGRESSIVE.reflectionVariance.enabled = not not enabled
  resetReflectionHistory("reflection variance experiment changed", true)
  return PROGRESSIVE.reflectionVariance.enabled
end

function M.setReflectionVarianceStrength(value)
  local n = tonumber(value)
  if not n then return false end
  PROGRESSIVE.reflectionVariance.strength = math.max(0.0, math.min(1.0, n))
  resetReflectionHistory("reflection variance strength changed", false)
  return PROGRESSIVE.reflectionVariance.strength
end

function M.resetReflectionHistory()
  resetReflectionHistory("manual request", true)
  return true
end

function M.setRayStepSize(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue <= 0 then
    beamrtLog("E", "ray step size must be a finite number greater than zero")
    return false
  end
  rayStepSize = numericValue
  resetTemporalHistory("ray step size changed", false)
  beamrtLog("I", "ray step size set to " .. tostring(rayStepSize) .. " world units")
  return true
end

function M.setRayThickness(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue <= 0 then
    beamrtLog("E", "ray thickness must be a finite number greater than zero")
    return false
  end
  rayThickness = numericValue
  resetTemporalHistory("ray thickness changed", false)
  beamrtLog("I", "ray thickness set to " .. tostring(rayThickness) .. " world units")
  return true
end

function M.setRayNormalBias(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 then
    beamrtLog("E", "ray normal bias must be a finite number greater than or equal to zero")
    return false
  end
  rayNormalBias = numericValue
  resetTemporalHistory("ray normal bias changed", false)
  beamrtLog("I", "ray normal bias set to " .. tostring(rayNormalBias) .. " world units")
  return true
end

function M.setRaySteps(value)
  local numericValue = finiteNumber(value)
  if not numericValue then
    beamrtLog("E", "ray steps must be a finite integer from 1 through 512")
    return false
  end
  local integerValue = math.floor(numericValue)
  if integerValue < 1 or integerValue > 512 then
    beamrtLog("E", "ray steps must be a finite integer from 1 through 512")
    return false
  end
  rayMaxSteps = integerValue
  resetTemporalHistory("ray step count changed", false)
  beamrtLog("I", "ray steps set to " .. tostring(rayMaxSteps))
  return true
end

function M.setPositionScale(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue <= 0 then
    beamrtLog("E", "position scale must be a finite number greater than zero")
    return false
  end
  positionScale = numericValue
  applyDebugShaderConsts()
  beamrtLog("I", "position scale set to " .. tostring(positionScale))
  return true
end

function M.setDepthGain(value)
  local numericValue = finiteNumber(value)
  if not numericValue or numericValue < 0 then
    beamrtLog("E", "depth gain must be a finite number greater than or equal to zero")
    return false
  end
  depthGain = numericValue
  applyDebugShaderConsts()
  beamrtLog("I", "depth gain set to " .. tostring(depthGain))
  return true
end

local function syncTuningPointers()
  tuningPointers.giStrength[0] = giStrength
  tuningPointers.worldGIStrength[0] = worldGIStrength
  tuningPointers.bounceSaturation[0] = bounceSaturation
  tuningPointers.contactShadowStrength[0] = contactShadowStrength
  tuningPointers.giClamp[0] = giClamp
  tuningPointers.giExposure[0] = giExposure
  tuningPointers.giShadowFocus[0] = giShadowFocus
  tuningPointers.giReceiverTint[0] = giReceiverTint
  tuningPointers.giContrast[0] = giContrast
  tuningPointers.giEnergyLimit[0] = giEnergyLimit
  tuningPointers.giHighlightRolloff[0] = giHighlightRolloff
  tuningPointers.temporalBlend[0] = temporalBlend
  tuningPointers.denoiseStrength[0] = denoiseStrength
  tuningPointers.historyDepthTolerance[0] = historyDepthTolerance
  tuningPointers.giCellSize[0] = giCellSize
  tuningPointers.rayStepSize[0] = rayStepSize
  tuningPointers.rayThickness[0] = rayThickness
  tuningPointers.rayNormalBias[0] = rayNormalBias
  tuningPointers.rayMaxSteps[0] = rayMaxSteps
  tuningPointers.giPathCount[0] = giPathCount
  tuningPointers.surfelTraceDistance[0] = surfelTraceDistance
  tuningPointers.surfelBaseRadius[0] = surfelBaseRadius
  tuningPointers.surfelVisibilityTolerance[0] = surfelVisibilityTolerance
  tuningPointers.surfelCacheBlend[0] = surfelCacheBlend
  tuningPointers.surfelRefreshDistance[0] = surfelRefreshDistance
  tuningPointers.surfelRefreshRaysPerFrame[0] = surfelRefreshRaysPerFrame
  tuningPointers.worldLeakSuppression[0] = worldLeakSuppression
  tuningPointers.radianceCleanup[0] = radianceCleanup
  tuningPointers.specularReject[0] = specularReject
  tuningPointers.radianceChromaStrength[0] = radianceChromaStrength
  tuningPointers.retroReject[0] = retroReject
  tuningPointers.progressiveMaxSamples[0] = PROGRESSIVE.maxSamples
  tuningPointers.progressiveClampStrength[0] = PROGRESSIVE.clampStrength
  tuningPointers.giLocalization[0] = PROGRESSIVE.localization
  tuningPointers.secondBounceStrength[0] = PROGRESSIVE.secondBounceStrength
  tuningPointers.emissiveBoost[0] = PROGRESSIVE.emissiveBoost
  tuningPointers.rayReach[0] = PROGRESSIVE.rayReach
  tuningPointers.rearRayReach[0] = PROGRESSIVE.rearRayReach
  tuningPointers.lowPathRescue[0] = PROGRESSIVE.lowPathRescue
  tuningPointers.blueNoiseStrength[0] = PROGRESSIVE.blueNoiseStrength
  tuningPointers.svgfStrength[0] = PROGRESSIVE.svgf.strength
  tuningPointers.svgfVarianceScale[0] = PROGRESSIVE.svgf.varianceScale
  tuningPointers.svgfMaxHistory[0] = PROGRESSIVE.svgf.maxHistory
  tuningPointers.hitRefinementSteps[0] = PROGRESSIVE.hitRefinementSteps
  tuningPointers.screenRayStride[0] = PROGRESSIVE.screenRayStride
  tuningPointers.hitValidationStrength[0] = PROGRESSIVE.hitValidationStrength
  tuningPointers.minHitTravelPixels[0] = PROGRESSIVE.minHitTravelPixels
  tuningPointers.echoHistoryGuard[0] = PROGRESSIVE.echoHistoryGuard
  tuningPointers.candidateContinuation[0] = PROGRESSIVE.candidateContinuation
  tuningPointers.candidateRetryCount[0] = PROGRESSIVE.candidateRetryCount
  tuningPointers.emissiveSeparation[0] = PROGRESSIVE.emissiveSeparation
  tuningPointers.reflectionStrength[0] = reflectionStrength
  tuningPointers.reflectionMaxRoughness[0] = reflectionMaxRoughness
  tuningPointers.reflectionStepSize[0] = reflectionStepSize
  tuningPointers.reflectionThickness[0] = reflectionThickness
  tuningPointers.reflectionNormalBias[0] = reflectionNormalBias
  tuningPointers.reflectionTemporalBlend[0] = reflectionTemporalBlend
  tuningPointers.reflectionDenoiseStrength[0] = reflectionDenoiseStrength
  tuningPointers.reflectionSampleCellPixels[0] = PROGRESSIVE.reflectionTuning.sampleCellPixels
  tuningPointers.reflectionNoiseSeed[0] = PROGRESSIVE.reflectionTuning.noiseSeed
  tuningPointers.reflectionFilterRadiusScale[0] = PROGRESSIVE.reflectionTuning.filterRadiusScale
  tuningPointers.reflectionSourceFootprintScale[0] = PROGRESSIVE.reflectionTuning.sourceFootprintScale
end

local function tuningTooltip(text)
  if im.IsItemHovered() then
    im.SetTooltip(text)
  end
end

local function tuningSliderFloat(label, pointer, minimum, maximum, format, setter, tooltip)
  im.TextUnformatted(label)
  tuningTooltip(tooltip)
  im.PushItemWidth(-118)
  if im.SliderFloat("##Slider" .. label, pointer, minimum, maximum, format) then
    if not setter(pointer[0]) then syncTuningPointers() end
  end
  tuningTooltip(tooltip)
  im.PopItemWidth()
  im.SameLine()
  im.PushItemWidth(108)
  if im.InputFloat("##Exact" .. label, pointer, 0, 0, format, im.InputTextFlags_EnterReturnsTrue) then
    if not setter(pointer[0]) then syncTuningPointers() end
  end
  tuningTooltip("Exact entry. Type a value and press Enter. This can exceed the practical slider range when the underlying control permits it.")
  im.PopItemWidth()
end

local function tuningSliderInt(label, pointer, minimum, maximum, setter, tooltip)
  im.TextUnformatted(label)
  tuningTooltip(tooltip)
  im.PushItemWidth(-118)
  if im.SliderInt("##Slider" .. label, pointer, minimum, maximum) then
    if not setter(pointer[0]) then syncTuningPointers() end
  end
  tuningTooltip(tooltip)
  im.PopItemWidth()
  im.SameLine()
  im.PushItemWidth(108)
  if im.InputInt("##Exact" .. label, pointer, 1, 16, im.InputTextFlags_EnterReturnsTrue) then
    if not setter(pointer[0]) then syncTuningPointers() end
  end
  tuningTooltip("Exact entry. Type a value and press Enter. The accepted ceiling depends on this control.")
  im.PopItemWidth()
end

local function drawTuningWindow()
  if not tuningWindowOpen[0] then return end

  im.SetNextWindowSize(im.ImVec2(650, 850), im.Cond_FirstUseEver)
  if not im.Begin("BeamRT PTGI Tuner v" .. VERSION, tuningWindowOpen) then
    im.End()
    return
  end

  im.TextColored(im.ImVec4(0.35, 0.85, 1.0, 1.0), "LIVE BEAUTY TUNING")
  im.TextUnformatted("Hover any control for guidance. Changes are applied immediately.")
  im.Separator()

  local lightingActive = enabledRequested and debugMode == MODE_IDS.diffusegi
  im.TextColored(
    lightingActive and im.ImVec4(0.3, 1.0, 0.45, 1.0) or im.ImVec4(1.0, 0.65, 0.25, 1.0),
    lightingActive and "Status: PTGI lighting active" or "Status: PTGI lighting not active"
  )
  if im.Button("Start / Apply PTGI") then M.start() end
  im.SameLine()
  if im.Button("Disable BeamRT") then M.disable() end
  im.SameLine()
  if im.Button("Reset History") then M.resetHistory() end
  if im.Button("Capture Lighting Audit") then M.runLightingAudit() end
  tuningTooltip("Keep the camera still. Saves six local views of the current lighting stages, then restores your settings automatically.")
  im.SameLine()
  if im.Button("Capture Reflection Audit") then M.runReflectionAudit() end
  tuningTooltip("Keep the camera still. Saves native, SSR beauty, receiver, validity, hit UV, hit depth, raw color, and composite views; restores all BeamRT settings afterward.")
  if im.CollapsingHeader1("Reflection diagnostics") then
    im.TextUnformatted("Current SSR view: " .. PROGRESSIVE.reflectionDiagnostic.name)
    for index, view in ipairs({{"Receiver", "receiver"}, {"Validity", "validity"},
      {"Hit UV", "hituv"}, {"Hit depth", "hitdepth"}, {"Raw color", "rawcolor"},
      {"Composite", "composite"}, {"Source UV", "sourceuv"},
      {"Rejection", "rejection"}, {"Direction", "direction"}}) do
      if index % 3 ~= 1 then im.SameLine() end
      if im.Button(view[1] .. "##SSRDiagnostic") then M.setReflectionDiagnostic(view[2]) end
    end
    if im.Button("Restore previous view##SSRDiagnostic") then M.setReflectionDiagnostic("off") end
    tuningTooltip("Diagnostics use the current full-resolution SSR trace with temporal display and denoising bypassed. Off restores the preceding mode, enabled state, overlay, and GI diagnostic.")
  end

  im.TextUnformatted("Presets")
  if im.Button("SCREEN DDA AUDIT") then M.applyPreset("experimental"); syncTuningPointers() end
  tuningTooltip("Intersection experiment, not a beauty preset: half resolution, one path, and a bounded 32-step Screen DDA. Use Balanced or Cinematic for normal rendering.")
  im.SameLine()
  if im.Button("YOUR BEST") then M.applyPreset("userbest"); syncTuningPointers() end
  tuningTooltip("Recreates what the loaded v0.040 shader actually rendered from your supplied values: full resolution, 16 paths, and 128 steps. The old shader capped the accepted 32/512 uniforms internally.")
  im.SameLine()
  if im.Button("CINEMATIC") then M.applyPreset("cinematic"); syncTuningPointers() end
  tuningTooltip("The new recommended beauty preset: shaped, shadow-focused bounce at a saner 16-path/128-step workload.")
  im.SameLine()
  if im.Button("MAX 32x200") then M.applyPreset("maxquality"); syncTuningPointers() end
  tuningTooltip("Laboratory stress preset: 32 paths, full resolution, 200 steps. It can be roughly 100x the old v0.030 trace workload and may stall slower GPUs.")
  im.SameLine()
  if im.Button("BEAUTY MAX") then M.applyPreset("beautymax"); syncTuningPointers() end
  tuningTooltip("Accuracy-first screenshot preset: 32 paths at full resolution, corrected estimator, native noise plus a long Weyl sequence, confidence-aware reconstruction, and the linear screen path. Intentionally excludes experimental DDA and coarse world surfels.")
  im.SameLine()
  if im.Button("BEAUTY + REFLECTIONS") then M.applyPreset("beautyreflect"); syncTuningPointers() end
  tuningTooltip("Beauty Max plus conservative SSR augmentation. Preserves native base lighting and fallback; not an exact native cubemap replacement.")

  if im.Button("PTGI DDA") then M.applyPreset("ptgiplay"); syncTuningPointers() end
  tuningTooltip("Playable full-resolution Screen DDA preset with visible color transport, guarded second bounce, and direct-diffuse source cleanup. One path converges temporally instead of brute-forcing linear samples.")
  im.SameLine()
  if im.Button("PTGI DDA + REFL") then M.applyPreset("ptgiplayreflect"); syncTuningPointers() end
  tuningTooltip("PTGI DDA plus SSR augmentation with near-plane-correct tracing. Native reflections remain as fallback; exact lobe replacement is not yet available.")
  im.SameLine()
  if im.Button("PTGI DDA MAX") then M.applyPreset("ptgimax"); syncTuningPointers() end
  tuningTooltip("Quality-oriented Screen DDA: two 48-step paths, fixed motion-aware second bounce, and the new three-scale edge-aware reconstruction. No reflection overlay.")
  im.SameLine()
  if im.Button("PTGI MAX + REFL") then M.applyPreset("ptgimaxreflect"); syncTuningPointers() end
  tuningTooltip("PTGI DDA Max plus close-range SSR, finite history and native specular weighting. Additive augmentation preserves base lighting; native environment reflections remain.")
  im.SameLine()
  if im.Button("ULTRA") then M.applyPreset("ultra"); syncTuningPointers() end
  tuningTooltip("16 paths at full resolution with 96 steps. This is the maximum-beauty stress preset and can be dramatically slower.")
  
  if im.Button("Showcase") then M.applyPreset("showcase"); syncTuningPointers() end
  tuningTooltip("8 paths at 75% resolution: a visible quality jump without using the full Ultra workload.")
  im.SameLine()
  if im.Button("Balanced") then M.applyPreset("balanced"); syncTuningPointers() end
  tuningTooltip("The v0.031 defaults: moderate cost and a restrained image.")
  im.SameLine()
  if im.Button("Clean / Stable") then M.applyPreset("clean"); syncTuningPointers() end
  tuningTooltip("Lower temporal current-frame weight and subtler contact shading. Best for still shots and slow camera movement.")
  im.SameLine()
  if im.Button("Performance") then M.applyPreset("performance"); syncTuningPointers() end
  tuningTooltip("Shorter, fewer ray steps and lighter contact shading. Use this to establish a fast baseline.")

  if im.CollapsingHeader1("Beauty and lighting", im.TreeNodeFlags_DefaultOpen) then
    im.PushItemWidth(-1)
    tuningSliderFloat("GI intensity", tuningPointers.giStrength, 0.0, 4.0, "%.2f", M.setGIStrength,
      "Overall indirect-light amount. Raise this first when the effect is too subtle; excessive values flatten direct-light contrast.")
    tuningSliderFloat("World-cache contribution", tuningPointers.worldGIStrength, 0.0, 4.0, "%.2f", M.setWorldGIStrength,
      "Strength of persistent surfel lighting used when the visible screen ray misses. High values can smear coarse cached color.")
    tuningSliderFloat("Bounce color", tuningPointers.bounceSaturation, 0.0, 4.0, "%.2f", M.setBounceSaturation,
      "Color separation in indirect light. 1.0 is neutral; 1.15-1.35 makes colored walls and lights more obvious.")
    tuningSliderFloat("Contact grounding", tuningPointers.contactShadowStrength, 0.0, 1.0, "%.2f", M.setContactShadowStrength,
      "Short-range G-buffer occlusion around tires, undersides, creases, and nearby objects. Set to zero if halos appear.")
    tuningSliderFloat("Indirect exposure", tuningPointers.giExposure, -3.0, 3.0, "%.2f stops", M.setGIExposure,
      "Photographic gain after GI reconstruction. One stop doubles the indirect light. Use this before raising ray count.")
    tuningSliderFloat("Shadow focus", tuningPointers.giShadowFocus, 0.0, 1.0, "%.2f", M.setGIShadowFocus,
      "Keeps bounce light in dark regions while protecting directly lit paint, sky, and highlights from a flat overlay.")
    tuningSliderFloat("Receiver color", tuningPointers.giReceiverTint, 0.0, 1.0, "%.2f", M.setGIReceiverTint,
      "Tints arriving bounce by the receiving surface's approximate color, making colored walls and vehicle panels feel grounded.")
    tuningSliderFloat("Indirect contrast", tuningPointers.giContrast, 0.50, 2.0, "%.2f", M.setGIContrast,
      "Shapes GI around an 18% luminance pivot. Above 1 adds depth and prevents the smoky gray veil; below 1 lifts dark bounce.")
    tuningSliderFloat("Energy ceiling", tuningPointers.giEnergyLimit, 0.25, 8.0, "%.2fx", M.setGIEnergyLimit,
      "Multiplier for the old fixed indirect-light budget. Raise this when GI intensity appears to stop changing; exact entry accepts up to 32.")
    tuningSliderFloat("Highlight rolloff", tuningPointers.giHighlightRolloff, 0.0, 1.0, "%.2f", M.setGIHighlightRolloff,
      "Blends hard clipping into a smooth filmic shoulder. High values suppress fireflies and harsh neon clipping without flattening all GI.")
    tuningSliderFloat("Radiance clamp", tuningPointers.giClamp, 0.5, 32.0, "%.2f", M.setGIClamp,
      "Maximum sampled HDR bounce radiance. Higher values preserve bright colored lights but may expose fireflies.")
    im.Separator()
    im.TextUnformatted("Screen-space reflections: " .. (reflectionOverlayEnabled and "ON" or "OFF"))
    im.TextUnformatted("SSR augments native reflections; it does not replace the cubemap.")
    if im.Button(reflectionOverlayEnabled and "Disable reflections" or "Enable reflections") then
      M.setReflectionsEnabled(not reflectionOverlayEnabled)
    end
    tuningTooltip("Adds the BeamRT reflection pass after GI. Manual GI ray/lighting diagnostics temporarily suppress this overlay and restore the selected preference when switched off. Screen-space reflections cannot show off-screen objects or the back side of geometry.")
    im.TextUnformatted("Reflection sampling: " .. PROGRESSIVE.reflectionSampling.name)
    if im.Button("Mirror SSR") then M.setReflectionSamplingMode("mirror") end
    tuningTooltip("Uses the existing mirror ray. Mirror is the startup default; existing tuning presets preserve your selected reflection sampling mode.")
    im.SameLine()
    if im.Button("GGX SSR") then M.setReflectionSamplingMode("ggx") end
    tuningTooltip("Samples a material roughness lobe over rendered frames. Switching sampling clears SSR history; GI history stays intact. Reflection diagnostics and reflection audits freeze sample zero for consistent hit inspection.")
    im.TextUnformatted("GGX reconstruction: " .. PROGRESSIVE.reflectionReconstruction.name)
    if im.Button("Playable filter") then M.setReflectionReconstruction("playable") end
    tuningTooltip("Uses a short, bounded average to reduce GGX noise while moving. No long exposure or extra rays. Existing presets preserve your selected filter; mirror SSR keeps its existing reconstruction.")
    im.SameLine()
    if im.Button("Legacy filter") then M.setReflectionReconstruction("legacy") end
    tuningTooltip("Restores the previous GGX reconstruction for a quick comparison. Switching filters resets SSR history and keeps GI history intact.")
    if im.Button(PROGRESSIVE.reflectionHit.enabled and "Hit-aware ON" or "Hit-aware OFF") then
      M.setReflectionHitAwareEnabled(not PROGRESSIVE.reflectionHit.enabled)
    end
    tuningTooltip("Playable GGX checks reflected-source depth and motion, and protects near-polished hit layers. Almost mirror-smooth surfaces use a stable mirror approximation. Uses the same ray count but adds two geometry helper passes and 32-bit buffers. Turn off to compare with v0.096; legacy/mirror and frozen audits bypass this path.")
    if im.Button(PROGRESSIVE.reflectionColor.enabled and "Color filter ON" or "Color filter OFF") then
      M.setReflectionColorFilterEnabled(not PROGRESSIVE.reflectionColor.enabled)
    end
    tuningTooltip("Playable GGX: depth-aware 2x/4x/8x source color levels and subpixel valid history color. Rough surfaces get softer cleanup; polished reflections keep source detail. Adds two color passes, no rays or long exposure. OFF restores v0.098 color filtering; hit/depth metadata stays point sampled.")
    tuningSliderFloat("Reflection intensity", tuningPointers.reflectionStrength, 0.0, 1.25, "%.2f", M.setReflectionStrength,
      "Scales material response, including the trace's GGX weight when GGX sampling is selected. Reduce this if the pass competes with BeamNG's native probes.")
    tuningSliderFloat("Reflection roughness cutoff", tuningPointers.reflectionMaxRoughness, 0.08, 0.55, "%.2f", M.setReflectionMaxRoughness,
      "Only surfaces smoother than this receive SSR augmentation. The conservative presets stay near 0.32-0.35; native environment response and clearcoat remain available.")
    tuningSliderFloat("Reflection step length", tuningPointers.reflectionStepSize, 0.10, 0.75, "%.2f m", M.setReflectionStepSize,
      "Coarse search distance before five-step hit refinement. Smaller finds thin geometry more reliably but costs more.")
    tuningSliderFloat("Reflection hit thickness", tuningPointers.reflectionThickness, 0.05, 0.75, "%.2f m", M.setReflectionThickness,
      "Maximum refined depth mismatch. The old 0.55 m default accepted unrelated rear geometry; keep this near 0.22-0.28 m.")
    tuningSliderFloat("Reflection normal bias", tuningPointers.reflectionNormalBias, 0.0, 0.15, "%.3f m", M.setReflectionNormalBias,
      "Offsets the ray origin to avoid self hits. Too much detaches the reflection from the receiver.")
    tuningSliderFloat("Reflection current-frame weight", tuningPointers.reflectionTemporalBlend, 0.05, 1.0, "%.2f", M.setReflectionTemporalBlend,
      "Higher reacts faster and trails less; lower is steadier. Playable GGX treats this as a 60 FPS response control and keeps a short, frame-time-corrected rolling history. Mirror misses receive one finite grace frame; legacy GGX keeps its previous averaging.")
    tuningSliderFloat("Rough-reflection reconstruction", tuningPointers.reflectionDenoiseStrength, 0.0, 1.0, "%.2f", M.setReflectionDenoiseStrength,
      "Blends toward the depth/normal/roughness/F0-aware filter. Playable GGX doubles this blend up to full reconstruction without adding samples; zero still disables spatial filtering. Rougher receivers use a broader reconstruction footprint.")
    im.TextUnformatted("Reflection pattern controls (GGX)")
    tuningSliderFloat("Reflection noise cell", tuningPointers.reflectionSampleCellPixels, 0.25, 4.0, "%.2f px", M.setReflectionSampleCellPixels,
      "Noise seed grid only, not ray resolution or GI world cells. 1 px keeps independent per-pixel seeds. Larger values share GGX samples across pixels and can make checker patches WORSE. Below 1 changes the seed pattern; it does not add subpixel rays. Polished mirror approximations are unaffected.")
    tuningSliderInt("Reflection noise seed", tuningPointers.reflectionNoiseSeed, 0, 255, M.setReflectionNoiseSeed,
      "Changes GGX's spatial random pattern without adding rays or changing material roughness. Seed 0 is the original pattern. If patches move with the seed, sampling contributes; this alone cannot prove the cause. Exact entry accepts 0..65535.")
    tuningSliderFloat("Reflection filter radius", tuningPointers.reflectionFilterRadiusScale, 0.25, 3.0, "%.2fx", M.setReflectionFilterRadiusScale,
      "Playable GGX only: scales the existing 13-tap edge-aware footprint, not tap count. 1 is original; try 1.5. Larger can soften details or create sparse-filter artifacts. Depth, normal, material and hit-layer gates remain. No extra rays or long exposure.")
    tuningSliderFloat("Reflected color softness", tuningPointers.reflectionSourceFootprintScale, 0.0, 2.0, "%.2fx", M.setReflectionSourceFootprintScale,
      "Playable GGX with Color filter ON: scales the depth-aware source-color footprint. 0 uses raw hit color, 1 is original, 2 is broader (still capped at 8 source pixels). Nearly polished surfaces keep source detail. No geometry, hit metadata or native reflection changes.")
    if im.Button("Reset reflection pattern controls") then M.resetReflectionTuning(); syncTuningPointers() end
    tuningTooltip("Resets only these four controls: noise cell 1 px, seed 0, filter radius 1x, color softness 1x. Keeps all other tuning and GI history.")
    im.PopItemWidth()
  end

  if im.CollapsingHeader1("Noise and temporal stability", im.TreeNodeFlags_DefaultOpen) then
    im.TextColored(im.ImVec4(0.35, 0.85, 1.0, 1.0), string.format(
      "Long exposure: %s | %s | %d / %d samples | next-frame weight %.6f",
      PROGRESSIVE.enabled and "ON" or "OFF", PROGRESSIVE.runtimeMode,
      PROGRESSIVE.samples, PROGRESSIVE.maxSamples, PROGRESSIVE.currentWeight))
    if im.Button(PROGRESSIVE.enabled and "Disable long exposure" or "Enable long exposure") then
      M.setProgressiveAccumulation(not PROGRESSIVE.enabled)
      syncTuningPointers()
    end
    im.SameLine()
    if im.Button("Restart accumulation") then M.resetHistory(); syncTuningPointers() end
    im.PushItemWidth(-1)
    tuningSliderInt("Accumulated sample ceiling", tuningPointers.progressiveMaxSamples, 64, 4096, M.setProgressiveMaxSamples,
      "Total stationary samples retained by the running average. Exact entry accepts up to 65536. Four paths/frame reaches 4096 samples in 1024 frames.")
    tuningSliderFloat("Progressive history clamp", tuningPointers.progressiveClampStrength, 0.0, 1.0, "%.2f", M.setProgressiveClampStrength,
      "0 preserves a mathematically clean running average while stationary. Raise this only if fireflies persist; high values bias the long exposure toward each new frame.")
    tuningSliderFloat("Current-frame weight", tuningPointers.temporalBlend, 0.02, 0.40, "%.3f", M.setTemporalBlend,
      "Used when long exposure is disabled and during camera movement, including slow drift. After the camera settles, progressive accumulation starts from the finite temporal history and computes each batch weight from its effective sample count.")
    tuningSliderFloat("Spatial denoise", tuningPointers.denoiseStrength, 0.0, 1.0, "%.2f", M.setDenoiseStrength,
      "Blends toward the depth/normal-aware 3x3 estimate before history accumulation. Usually keep near 1.0.")
    tuningSliderFloat("Low-path rescue", tuningPointers.lowPathRescue, 0.0, 1.0, "%.2f", M.setLowPathRescue,
      "Adds a cheap depth/normal-aware outer reconstruction ring when paths are low. Strongest at 4 paths, fades by 12, and costs far less than tracing 12 additional paths.")
    tuningSliderFloat("Blue-noise sampling", tuningPointers.blueNoiseStrength, 0.0, 1.0, "%.2f", M.setBlueNoiseStrength,
      "Zero restores legacy hash directions. One uses only the selected noise sequence. Intermediate values choose between complete strategies without interpolating ray coordinates.")
    im.TextUnformatted("Noise source: " .. PROGRESSIVE.blueNoiseSource)
    if im.Button("EXPERIMENTAL ATLAS") then M.setBlueNoiseSource("stbn"); syncTuningPointers() end
    tuningTooltip("Custom scalar RG atlas, not validated directional STBN. Its 64 slices now receive a fresh phase each cycle. Native noise remains the recommended baseline.")
    im.SameLine()
    if im.Button("NATIVE NOISE") then M.setBlueNoiseSource("beamng"); syncTuningPointers() end
    tuningTooltip("Recommended: BeamNG's 2D blue-noise mask with integer Weyl phases over 4096 frames. Better transformed-direction metrics than the custom atlas; game appearance settings are unchanged.")
    tuningSliderFloat("SVGF-style variance guide", tuningPointers.svgfStrength, 0.0, 1.0, "%.2f", M.setSVGFStrength,
      "Experimental temporal luminance moments guide the bilateral filter and history clamp. This is a lightweight prototype, not full multi-pass SVGF.")
    tuningSliderFloat("Variance response", tuningPointers.svgfVarianceScale, 0.0, 12.0, "%.2f", M.setSVGFVarianceScale,
      "Controls how strongly measured temporal variance increases reconstruction. Too high can look soft or unstable around bright edges.")
    tuningSliderInt("Moment history", tuningPointers.svgfMaxHistory, 1, 128, M.setSVGFMaxHistory,
      "Frames retained by the first/second luminance moments. Longer histories estimate noise better but react more slowly to lighting changes.")
    tuningSliderFloat("History depth rejection", tuningPointers.historyDepthTolerance, 0.001, 0.05, "%.4f", M.setHistoryDepthTolerance,
      "Lower rejects stale history more aggressively at moving edges. Higher is steadier but can create ghost trails.")
    tuningSliderFloat("World sample cell", tuningPointers.giCellSize, 0.005, 0.08, "%.4f", M.setGICellSize,
      "World-space seed scale. Smaller values hide repeating blocks; very small values can increase high-frequency shimmer.")
    im.PopItemWidth()
  end

  if im.CollapsingHeader1("Radiance source cleanup", im.TreeNodeFlags_DefaultOpen) then
    im.TextColored(im.ImVec4(0.35, 0.85, 1.0, 1.0),
      "PTGI input: " .. CLEAN_RADIANCE.selectedPTGISource .. " | legacy estimator input: " .. radianceSourceName)
    if im.Button("PTGI: LIVE LEGACY") then M.setPTGIRadianceSource("legacy") end
    tuningTooltip("Uses the live legacy/directdiffuse selector below. This is independent from the Monte Carlo estimator choice.")
    im.SameLine()
    if im.Button("PTGI: FROZEN CLEAN") then M.setPTGIRadianceSource("clean") end
    tuningTooltip("Uses the accepted frozen CleanRadiance cache only when its camera and generations remain valid.")
    if im.Button("DIRECT DIFFUSE (LIGHTINFO)") then
      M.setRadianceSource("directdiffuse")
      M.setRadianceCleanup(1.0)
      syncTuningPointers()
    end
    tuningTooltip("Uses #lightinfo[RT0].rgb as direct-light energy and component-wise de-lights the cleaned scene sample to estimate material reflectance. Known specular light-buffer channels remain excluded.")
    im.SameLine()
    if im.Button("LEGACY BACKBUFFER") then
      M.setRadianceSource("legacy")
      syncTuningPointers()
    end
    tuningTooltip("Preserved fallback: samples the final HDR image and applies the v0.051 neighborhood cleanup.")
    if im.Button("CLEAN DIFFUSE SOURCE") then
      M.setRadianceCleanup(1.0)
      M.setSpecularReject(0.85)
      syncTuningPointers()
    end
    tuningTooltip("Recommended v0.051 path. Clears temporal and surfel history before rebuilding with cleaned radiance.")
    im.SameLine()
    if im.Button("RAW SOURCE (A/B)") then
      M.setRadianceCleanup(0.0)
      syncTuningPointers()
    end
    tuningTooltip("Exact legacy sampling path. Use briefly to confirm whether a reflection-shaped echo comes from source radiance.")
    im.PushItemWidth(-1)
    tuningSliderFloat("Radiance cleanup", tuningPointers.radianceCleanup, 0.0, 1.0, "%.2f", M.setRadianceCleanup,
      "0 is byte-for-byte legacy backbuffer radiance. 1 uses the full diffuse-like neighborhood estimator.")
    tuningSliderFloat("Specular rejection", tuningPointers.specularReject, 0.0, 1.0, "%.2f", M.setSpecularReject,
      "Uses hit roughness plus local luminance gradients to distrust view-dependent glossy energy while retaining broad color on rough surfaces.")
    tuningSliderFloat("Material color carry", tuningPointers.radianceChromaStrength, 0.0, 1.0, "%.2f", M.setRadianceChromaStrength,
      "How strongly the component-wise de-lit material estimate retains chroma. Low-confidence dark channels fall back toward a neutral scalar estimate.")
    tuningSliderFloat("Retro rejection", tuningPointers.retroReject, 0.0, 1.0, "%.2f", M.setRetroReject,
      "Downweights ordinary opaque pixels whose prepass RT1 alpha marks retroreflectivity, preventing plates and signs from becoming GI emitters.")
    im.Separator()
    im.TextUnformatted("Transport estimator: " .. PROGRESSIVE.estimatorName)
    if im.Button("LEGACY ESTIMATOR") then M.setGIEstimator("legacy") end
    tuningTooltip("Exact v0.060 receiver/emitter cosine behavior for A/B.")
    im.SameLine()
    if im.Button("COSINE-CORRECTED") then M.setGIEstimator("corrected") end
    tuningTooltip("Experimental: cosine-weighted ray generation already contains receiver NdotL, so this removes the duplicate receiver cosine and keeps only a soft hit-facing gate.")
    tuningSliderFloat("Bounce localization", tuningPointers.giLocalization, 0.0, 1.0, "%.2f", M.setGILocalization,
      "0 preserves the broad v0.060 distance weighting. 1 strongly favors nearby hits, producing more local pools of bounce instead of a uniform ambient veil.")
    tuningSliderFloat("Previous-GI second bounce", tuningPointers.secondBounceStrength, 0.0, 1.0, "%.2f", M.setSecondBounceStrength,
      "Experimental feedback bounce from the previous accumulated GI at a hit. 0 disables it. Exact entry accepts up to 8, but values above 1 can explode or glow.")
    tuningSliderFloat("Native emissive bounce", tuningPointers.emissiveBoost, 0.0, 8.0, "%.2fx", M.setEmissiveBoost,
      "Clean-source only. 1 preserves native Material_Emissive energy, 0 removes it, and higher values make real emissive signs/lights cast stronger colored bounce. Exact entry accepts up to 32.")
    tuningSliderFloat("Emissive hit separation", tuningPointers.emissiveSeparation, 0.0, 1.0, "%.2f", M.setEmissiveSeparation,
      "v0.065 clean-source transport: 1 treats Material_Emissive as emitted radiance and removes the extra reflector-facing cosine. 0 restores v0.064 combined weighting.")
    im.PopItemWidth()
  end

  if im.CollapsingHeader1("Ray quality and cost", im.TreeNodeFlags_DefaultOpen) then
    im.TextColored(im.ImVec4(1.0, 0.65, 0.25, 1.0),
      "Sliders cover practical ranges; type exact values in the right-hand boxes and press Enter."
    )
    im.TextUnformatted("Stable single-ray diagnostic: " .. PROGRESSIVE.rayDebugName)
    if im.Button("RAY DEBUG OFF") then M.setRayHitDiagnostic("off") end
    im.SameLine()
    if im.Button("HITS") then M.setRayHitDiagnostic("hits") end
    im.SameLine()
    if im.Button("STEPS") then M.setRayHitDiagnostic("steps") end
    im.SameLine()
    if im.Button("DISTANCE") then M.setRayHitDiagnostic("distance") end
    im.SameLine()
    if im.Button("HIT NORMALS") then M.setRayHitDiagnostic("normals") end
    im.SameLine()
    if im.Button("CONFIDENCE") then M.setRayHitDiagnostic("confidence") end
    im.SameLine()
    if im.Button("DEPTH ERROR") then M.setRayHitDiagnostic("error") end
    im.SameLine()
    if im.Button("REJECT REASON") then M.setRayHitDiagnostic("rejection") end
    im.SameLine()
    if im.Button("RAY DIRECTION") then M.setRayHitDiagnostic("direction") end
    im.SameLine()
    if im.Button("VIEW ALIGNMENT") then M.setRayHitDiagnostic("viewalignment") end
    tuningTooltip("Bypasses temporal denoising and composition. v0.071 uses one deterministic world-oriented ray. RAY DIRECTION must remain world-stable; VIEW ALIGNMENT shows rear-facing red, forward-facing green, and transverse blue.")
    im.TextUnformatted("Marcher: " .. PROGRESSIVE.marcherName)
    if im.Button("LINEAR WORLD STEPS") then M.setRayMarcher("linear") end
    tuningTooltip("Accepted v0.062 path with the new crossing bracket/refinement layered on top. Use as the A/B baseline.")
    im.SameLine()
    if im.Button("SCREEN PIXEL DDA") then M.setRayMarcher("screendda") end
    tuningTooltip("Experimental near-field audit only. It advances at a true pixel stride, but is capped because no Hi-Z depth hierarchy is available. Misses may fall through to the world cache.")
    im.TextColored(im.ImVec4(1.0, 0.65, 0.25, 1.0), string.format(
      "Screen DDA budget: %d path, %d screen steps (not a beauty marcher)",
      PROGRESSIVE.screenDdaMaxPaths, PROGRESSIVE.screenDdaMaxSteps))
    im.PushItemWidth(-1)
    tuningSliderInt("Hit refinement steps", tuningPointers.hitRefinementSteps, -1, 6, M.setHitRefinementSteps,
      "Bisection passes after the marcher brackets a front-to-behind depth crossing. -1 is the exact legacy thickness-only path, zero accepts the bracket without refinement, and five is the validation default.")
    tuningSliderFloat("Screen DDA stride", tuningPointers.screenRayStride, 0.5, 4.0, "%.2f px", M.setScreenRayStride,
      "Pixel spacing for the screen marcher. 1 is the correctness baseline; 2-4 are faster but can skip thin screen-space coverage.")
    tuningSliderFloat("Hit validation", tuningPointers.hitValidationStrength, 0.0, 1.0, "%.2f", M.setHitValidationStrength,
      "v0.064 echo guard for candidate screen hits. 0 reproduces v0.063 hit acceptance; 1 applies depth/facing/edge/local-continuity confidence and lets weak hits fall through to the world representation.")
    tuningSliderFloat("Minimum hit travel", tuningPointers.minHitTravelPixels, 0.0, 4.0, "%.2f px", M.setMinHitTravelPixels,
      "Rejects near-origin/self intersections whose projected travel is too small. Start near 1 pixel; raise only if self-echo remains visible.")
    tuningSliderFloat("Candidate continuation", tuningPointers.candidateContinuation, 0.0, 1.0, "%.2f", M.setCandidateContinuation,
      "v0.065: 1 keeps tracing after recoverable self/backface/depth/discontinuity candidates. 0 restores v0.064 stop-on-first-candidate behavior.")
    tuningSliderInt("Candidate retry budget", tuningPointers.candidateRetryCount, 0, 8, M.setCandidateRetryCount,
      "Maximum recoverable rejected candidates skipped by one ray before it gives up. Four is the v0.065 default.")
    tuningSliderFloat("Echo history guard", tuningPointers.echoHistoryGuard, 0.0, 1.0, "%.2f", M.setEchoHistoryGuard,
      "Motion-only temporal guard. At zero the v0.063 history path is preserved. Higher values reject stale history when moving pixels have weak current GI support and clamp history earlier during motion.")
    im.PopItemWidth()
    im.TextUnformatted(string.format("GI resolution: %d%%", math.floor(giRenderScale * 100 + 0.5)))
    if im.Button("Half res") then M.setGIRenderScale(0.5) end
    tuningTooltip("One quarter of full-resolution pixels. Fastest and most dependent on reconstruction.")
    im.SameLine()
    if im.Button("75% res") then M.setGIRenderScale(0.75) end
    tuningTooltip("2.25x as many GI pixels as half resolution. Recommended high-quality mode.")
    im.SameLine()
    if im.Button("Full res") then M.setGIRenderScale(1.0) end
    tuningTooltip("Four times as many GI pixels as half resolution. Maximum edge detail and GPU cost.")
    im.PushItemWidth(-1)
    tuningSliderInt("Paths per pixel", tuningPointers.giPathCount, 1, 16, M.setGIPathCount,
      "Practical slider range is 1-16; exact entry accepts up to 32. More paths directly reduce current-frame stochastic noise.")
    tuningSliderFloat("Overall ray reach", tuningPointers.rayReach, 0.05, 1.0, "%.2f", M.setRayReach,
      "Multiplies the ray-step budget. Lower values prioritize nearby bounce and can make 8 paths cost closer to 4 long paths. 1 restores the full v0.061 reach.")
    tuningSliderFloat("Rear / camera-facing reach", tuningPointers.rearRayReach, 0.02, 1.0, "%.2f", M.setRearRayReach,
      "Further shortens rays aimed back toward the camera, while retaining a small nearby radius for color bounce behind the visible surface. 1 disables directional shortening.")
    tuningSliderInt("Ray steps", tuningPointers.rayMaxSteps, 8, 128, M.setRaySteps,
      "Practical slider range is 8-128; exact entry accepts up to 512. More steps reach farther and cost scales nearly linearly until rays exit early.")
    tuningSliderFloat("Step length", tuningPointers.rayStepSize, 0.20, 1.50, "%.2f m", M.setRayStepSize,
      "Distance advanced per screen ray step. Smaller is more accurate but needs more steps to cover the same distance.")
    tuningSliderFloat("Hit thickness", tuningPointers.rayThickness, 0.15, 2.0, "%.2f m", M.setRayThickness,
      "Depth-hit tolerance. Too low creates holes; too high leaks light across unrelated surfaces.")
    tuningSliderFloat("Normal bias", tuningPointers.rayNormalBias, 0.0, 0.25, "%.3f m", M.setRayNormalBias,
      "Moves ray origins away from the receiver. Increase slightly for self-hit acne; too much detaches contact lighting.")
    im.PopItemWidth()
  end

  if im.CollapsingHeader1("Persistent world cache", im.TreeNodeFlags_DefaultOpen) then
    im.TextUnformatted("GI source: " .. M.getGISource())
    if im.Button("Hybrid") then M.setGISource("hybrid") end
    tuningTooltip("Use visible screen hits first and persistent world surfels as fallback. Recommended.")
    im.SameLine()
    if im.Button("Screen only") then M.setGISource("screen") end
    tuningTooltip("Easier to debug and often sharper, but loses off-screen lighting.")
    im.SameLine()
    if im.Button("World only") then M.setGISource("surfels") end
    tuningTooltip("Shows cache contribution alone; sparse and not intended as the final beauty mode.")
    im.PushItemWidth(-1)
    tuningSliderFloat("Trace distance", tuningPointers.surfelTraceDistance, 10.0, 150.0, "%.0f m", M.setSurfelTraceDistance,
      "CPU cache-build reach. Changes take effect after Refresh World Cache.")
    tuningSliderFloat("Surfel radius", tuningPointers.surfelBaseRadius, 0.25, 8.0, "%.2f m", M.setSurfelRadius,
      "World-disc size. Smaller is sharper but leaves holes; values above roughly 2.5 m can look like colored smoke even with leak suppression.")
    tuningSliderFloat("Leak suppression", tuningPointers.worldLeakSuppression, 0.0, 1.0, "%.2f", M.setWorldLeakSuppression,
      "Fades the edges of large world-cache discs and penalizes oversized discs. Keep near 0.9 for beauty; zero restores the old fog-prone behavior.")
    tuningSliderFloat("Visibility tolerance", tuningPointers.surfelVisibilityTolerance, 0.1, 5.0, "%.2f m", M.setSurfelVisibilityTolerance,
      "Depth agreement required when learning visible surfel radiance. Lower is safer; higher fills the cache more easily.")
    tuningSliderFloat("Cache update speed", tuningPointers.surfelCacheBlend, 0.01, 1.0, "%.2f", M.setSurfelCacheBlend,
      "Current-frame weight for visible cache entries. Lower is cleaner/slower; higher responds quickly but can flicker.")
    tuningSliderFloat("Auto-refresh travel", tuningPointers.surfelRefreshDistance, 2.0, 30.0, "%.1f m", M.setSurfelRefreshDistance,
      "Camera travel before the slow 32-ray CPU world snapshot recenters.")
    tuningSliderInt("Refresh rays/frame", tuningPointers.surfelRefreshRaysPerFrame, 1, 16, M.setSurfelRefreshRaysPerFrame,
      "Detailed Engine.castRay budget per frame while a pending cache is built. Exact entry supports up to 32.")
    im.PopItemWidth()
    if im.Button("Refresh World Cache") then M.refreshSurfels(); syncTuningPointers() end
    im.SameLine()
    im.TextUnformatted("Surfels: " .. tostring(#surfels) .. " / " .. tostring(MAX_SURFELS))
  end

  im.Separator()
  if im.Button("Save My Tuning") then M.saveTuning() end
  tuningTooltip("Saves the current values to " .. TUNING_FILE .. " in the BeamNG user folder.")
  im.SameLine()
  if im.Button("Load My Tuning") then M.loadTuning(); syncTuningPointers() end
  im.SameLine()
  if im.Button("Copy Values") then im.SetClipboardText(M.settingsCommand()) end
  tuningTooltip("Copies a complete GELUA command so the exact look can be shared or pasted into the handoff.")
  im.SameLine()
  if im.Button("Refresh Sliders") then syncTuningPointers() end

  im.TextColored(im.ImVec4(1.0, 0.78, 0.3, 1.0),
    "CINEMATIC is the recommended next test. YOUR BEST preserves your exact baseline; 32x512 is a stress test, not the main beauty lever."
  )
  im.End()
end

function M.openTuner()
  syncTuningPointers()
  tuningWindowOpen[0] = true
  return true
end

function M.closeTuner()
  tuningWindowOpen[0] = false
  return true
end

function M.toggleTuner()
  if not tuningWindowOpen[0] then syncTuningPointers() end
  tuningWindowOpen[0] = not tuningWindowOpen[0]
  return tuningWindowOpen[0]
end

function M.enable()
  local selectedDiagnostic = BUFFER_DIAGNOSTIC_SOURCES[bufferDiagnosticSource]
  if not findObject(DEBUG_EFFECT_NAME)
    or not findObject(GI_EFFECT_NAME)
    or not findObject(PROGRESSIVE.inputPrep.receiverEffectName)
    or not findObject(PROGRESSIVE.inputPrep.auxiliaryEffectName)
    or not findObject(SURFEL_CACHE_EFFECT_NAME)
    or not findObject(REFLECTION_EFFECT_NAME)
    or not findObject(PROGRESSIVE.reflectionHit.inputsEffectName)
    or not findObject(PROGRESSIVE.reflectionHit.copyEffectName)
    or not findObject(PROGRESSIVE.reflectionColor.halfEffectName)
    or not findObject(PROGRESSIVE.reflectionColor.atlasEffectName)
    or not findObject(PROGRESSIVE.voxel.effectName)
    or not findObject(BUFFER_DIAGNOSTIC_SHADER_NAME)
    or not selectedDiagnostic
    or not findObject(selectedDiagnostic.effectName) then
    beamrtLog("W", "BeamRT effects were missing; recreating objects")
    createObjects()
  end
  enabledRequested = true
  if debugMode == MODE_IDS.diffusegi then
    resetTemporalHistory("enable requested", false)
  elseif debugMode == MODE_IDS.reflections then
    resetReflectionHistory("enable requested", false)
  end
  applyShaderConsts()
  syncEffectEnablement()
  beamrtLog("I", "enable requested; current mode is " .. modeName)
  return true
end

-- One-command entry point for the user-facing beauty mode.
function M.start()
  M.setMode("lighting")
  M.openTuner()
  return M.enable()
end

function M.disable()
  enabledRequested = false
  syncEffectEnablement()
  beamrtLog("I", "disable requested")
  return true
end

function M.toggle()
  local diagnosticEnabled = false
  for _, source in pairs(BUFFER_DIAGNOSTIC_SOURCES) do
    diagnosticEnabled = diagnosticEnabled or effectIsEnabled(source.effectName)
  end
  if enabledRequested or effectIsEnabled(DEBUG_EFFECT_NAME) or effectIsEnabled(GI_EFFECT_NAME) or effectIsEnabled(SURFEL_CACHE_EFFECT_NAME) or effectIsEnabled(REFLECTION_EFFECT_NAME) or effectIsEnabled(PROGRESSIVE.voxel.effectName) or diagnosticEnabled then
    M.disable()
    return false
  end
  M.enable()
  return true
end

function M.getVersion()
  return VERSION
end

function M.rebuildSceneDatabase(providerName, options)
  local name = providerName or "decalRoads"
  local ok, result = sceneDatabase.rebuild(name, options)
  if ok and name == "decalRoads" then
    beamrtLog("I", string.format(
      "DecalRoad provider: %d cached / %d scene, %d bulk + %d fallback in %.3f s",
      tonumber(result.cachedRoads) or 0,
      tonumber(result.sceneRoads) or 0,
      tonumber(result.bulkRoads) or 0,
      tonumber(result.fallbackRoads) or 0,
      tonumber(result.buildSeconds) or 0
    ))
  elseif not ok then
    beamrtLog("E", "scene provider rebuild failed: " .. tostring(result))
  end
  return ok, result
end

-- Conservative opt-in: secondary GI paths to cached world surfels are
-- rejected ONLY when a manually verified opaque world triangle intersects.
-- Legacy GI and screen-space paths are not otherwise reweighted.
function M.setSceneVisibilityGIEnabled(enabled)
  if type(enabled) ~= "boolean" then
    return false,"enabled must be boolean"
  end
  M.sceneGIVisibility.enabled=enabled
  M.sceneGIVisibility.revision=-1
  applyGIShaderConsts(true)
  beamrtLog("I", "GI opaque-triangle visibility " ..
    (enabled and "enabled (experimental)" or "disabled"))
  return true
end

function M.getSceneVisibilityGIStatus()
  local worldMeshCasters=require("ge/extensions/beamrt/worldMeshCasters")
  local provider=sceneDatabase.getProvider("visibility")
  local status=provider.getStats()
  status.enabled=M.sceneGIVisibility.enabled
  status.shader="beamrtGITraceP_v082.hlsl"
  status.effectiveOpaqueTriangles=M.sceneGIVisibility.enabled
    and #worldMeshCasters.getOpaqueTriangles() or 0
  status.scope="cached world surfel bounce rays only"
  return status
end

-- CPU inspection path for GI light-source visibility. This does not
-- override native direct lighting: it reports available segment evidence,
-- including uncertain alpha geometry and unimported scene limitations.
function M.auditWorldSurfelLightPath(surfelIndex, lightIndex)
  local i=tonumber(surfelIndex) or 1
  local j=tonumber(lightIndex) or 1
  if i%1~=0 or j%1~=0 or i<1 or j<1 then
    return {status="invalid",error="indices must be positive integers"}
  end
  local surfel=surfels[i]
  if not surfel then return {status="unavailable",error="world surfel not cached at index "..i} end
  local lightProvider=sceneDatabase.getProvider("lights")
  local light=(lightProvider.getRecords() or {})[j]
  if not light or not light.position then
    return {status="unavailable",error="light position not in provider cache at index "..j}
  end
  local provider=sceneDatabase.getProvider("visibility")
  local evidence=provider.traceSegment(surfel.position,light.position,
                                        {includeApproximateBoxes=true})
  evidence.surfelIndex=i
  evidence.lightIndex=j
  evidence.lightType=light.type
  evidence.lightName=light.name
  evidence.directLightingModified=false
  return evidence
end

function M.querySceneVisibility(fromWorld,toWorld,opts)
  local provider=sceneDatabase.getProvider("visibility")
  return provider.traceSegment(fromWorld,toWorld,opts)
end

function M.getSceneDatabaseStats()
  return sceneDatabase.getStats()
end

function M.getSceneProvider(name)
  return sceneDatabase.getProvider(name)
end

function M.captureVehicleGeometry(vehicleId)
  local provider = sceneDatabase.getProvider("vehicles")
  local id = vehicleId or (be and be:getPlayerVehicleID(0))
  local record, err = provider.capture(id)
  if not record then
    beamrtLog("E", "vehicle GPUMesh capture failed: " .. tostring(err))
    return nil
  end
  beamrtLog("I", string.format("vehicle GPUMesh cached: id=%d vertices=%d indices=%d",
    record.id, record.vertices, record.indices))
  local materialProvider = sceneDatabase.getProvider("materials")
  if materialProvider and type(materialProvider.ingestNames) == "function" then
    local materialOk, materialStats = materialProvider.ingestNames(record.materialNames)
    if not materialOk then
      beamrtLog("W", "some vehicle materials could not be acquired; inspect material provider stats")
    elseif materialStats then
      beamrtLog("I", "vehicle material records acquired: " .. tostring(materialStats.captured or 0))
    end
  end
  if #(record.acquisitionWarnings or {}) > 0 then
    beamrtLog("W", "vehicle GPUMesh acquired with " .. tostring(#record.acquisitionWarnings) .. " optional-buffer/submesh warnings")
  end
  return record
end

function M.captureMaterial(materialName)
  local provider = sceneDatabase.getProvider("materials")
  local record, err = provider.capture(materialName)
  if not record then
    beamrtLog("E", "material capture failed: " .. tostring(err))
    return nil
  end
  return record
end

function M.selectRayBackend(name)
  local ok, backendOrError = rayBackendRegistry.select(name)
  if not ok then
    beamrtLog("E", "ray backend selection failed: " .. tostring(backendOrError))
    return false, backendOrError
  end
  local backend = backendOrError
  if backend.giSource and not M.setGISource(backend.giSource) then
    return false, "backend GI source could not be activated"
  end
  beamrtLog("I", "ray backend selected: " .. tostring(name))
  return true, backend
end

function M.getRayBackendStatus()
  local name, descriptor = rayBackendRegistry.getActive()
  return {active = name, descriptor = descriptor, available = rayBackendRegistry.list()}
end

local function validateMaterialCachePublisherLifetimes()
  local mainView = getRenderView("main")
  local currentResolution = mainView and tostring(mainView.resolution) or nil
  for key, config in pairs(MATERIAL_CACHE_CONFIGS) do
    local result = materialCacheResults[key]
    local effect = findObject(config.publishEffectName)
    if result.valid and (not effect or not effect:isEnabled()) then
      markMaterialCacheStale(key, "publisher missing or disabled; backing target was released")
    elseif result.valid and result.resolution and currentResolution and result.resolution ~= currentResolution then
      markMaterialCacheStale(key, "main RenderView resolution changed")
    end
  end
end

local function validateCleanRadianceLifetimes()
  local mainView = getRenderView("main")
  local currentResolution = mainView and tostring(mainView.resolution) or nil

  if CLEAN_RADIANCE.build then
    for _, key in ipairs(CLEAN_RADIANCE.requiredMaterialCaches) do
      local cacheResult = materialCacheResults[key]
      if not cacheResult or not cacheResult.valid or cacheResult.stale then
        CLEAN_RADIANCE.finishBuild("a required material cache became stale during build", false)
        break
      end
    end
  end

  if CLEAN_RADIANCE.result.valid then
    for _, config in pairs(CLEAN_RADIANCE.outputs) do
      local effect = findObject(config.effectName)
      if not effect or not effect:isEnabled() then
        CLEAN_RADIANCE.markStale("diagnostic target owner missing or disabled")
        break
      end
    end
    if CLEAN_RADIANCE.result.valid and CLEAN_RADIANCE.result.resolution and currentResolution
      and CLEAN_RADIANCE.result.resolution ~= currentResolution then
      CLEAN_RADIANCE.markStale("main RenderView resolution changed")
    end
  end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  local frameDelta = finiteNumber(dtReal)
  if not frameDelta or frameDelta <= 0 then frameDelta = finiteNumber(dtRaw) end
  if not frameDelta or frameDelta <= 0 then frameDelta = 1 / 60 end
  PROGRESSIVE.reflectionReconstruction.frameDelta = math.min(math.max(frameDelta, 1 / 240), 1 / 15)
  -- Timing belongs to the current render. Shader/UI callbacks only read it;
  -- an interrupted active reflection history must start fresh after the gap.
  if frameDelta > 0.25 and effectIsEnabled(REFLECTION_EFFECT_NAME) then
    resetReflectionHistory("reflection render interrupted", false)
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  processMaterialCachePublication()
  validateMaterialCachePublisherLifetimes()
  CLEAN_RADIANCE.processBuild()
  validateCleanRadianceLifetimes()
  CLEAN_RADIANCE.validateSelectedSource()
  processPendingSurfelRefresh()
  PROGRESSIVE.lightingAudit.update(M, dtReal)
  sceneDatabase.update()
  drawTuningWindow()
end

function M.onSettingsChanged()
  PROGRESSIVE.lightingAudit.cancel(M, "graphics/settings changed during audit")
  -- Graphics/device changes flow through the general settings hook. Be
  -- conservative: a frozen diagnostic cache is cheap to recapture, while
  -- silently trusting a released/recreated render target is misleading.
  if materialCachePublication then
    finishMaterialCachePublication("settings changed during capture", false)
  end
  if CLEAN_RADIANCE.build then
    CLEAN_RADIANCE.finishBuild("settings changed during build", false)
  end
  markAllMaterialCachesStale("settings/graphics state changed")
  resetTemporalHistory("settings/graphics state changed", false)
  resetReflectionHistory("settings/graphics state changed", false)
end

function M.onFileChanged(filename, changeType)
  if changeType ~= "modified" or type(filename) ~= "string" then
    return
  end
  local lowerName = string.lower(filename)
  if lowerName:match("%.hlsl$") or lowerName:match("%.materials?%.json$") then
    PROGRESSIVE.lightingAudit.cancel(M, "shader/material changed during audit")
    if materialCachePublication then
      finishMaterialCachePublication("shader/material changed during capture", false)
    end
    if CLEAN_RADIANCE.build then
      CLEAN_RADIANCE.finishBuild("shader/material changed during build", false)
    end
    markAllMaterialCachesStale("shader/material source changed")
    resetTemporalHistory("shader/material source changed", false)
    resetReflectionHistory("shader/material source changed", false)
  end
end

function M.onExtensionLoaded()
  beamrtLog("I", "extension load (v" .. VERSION .. ")")
  setExtensionUnloadMode(M, "manual")
  createObjects()
  local bindingStatus = M.getTextureBindingStatus()
  beamrtLog("I", "PostEffect texture capacity: " .. tostring(bindingStatus.nativeCapacity or "unavailable")
    .. "; BeamRT binds only slots 0-5")
  sceneDatabase.scheduleLevelBuild(120)
end

function M.onClientStartMission()
  if extensions and extensions.beamrt_reflectionSourceProbe then extensions.beamrt_reflectionSourceProbe.cancel("mission changed") end
  if extensions and extensions.beamrt_reflectionConvergence then
    extensions.beamrt_reflectionConvergence.cancel("mission changed")
  end
  PROGRESSIVE.lightingAudit.cancel(M, "mission changed during audit")
  if materialCachePublication then
    finishMaterialCachePublication("mission changed", false)
  end
  if CLEAN_RADIANCE.build then
    CLEAN_RADIANCE.finishBuild("mission changed", false)
  end
  markAllMaterialCachesStale("mission changed")
  geometryBoxes = {}
  geometryScanPosition = nil
  orientedGeometryProxyCount = 0
  surfels = {}
  surfelScanPosition = nil
  pendingSurfelRefresh = nil
  markSurfelGeometryDirty()
  surfelCacheResetFrames = 2
  surfelRefreshCheckFrames = 0
  resetTemporalHistory("mission changed", false)
  resetReflectionHistory("mission changed", false)
  sceneDatabase.invalidate("mission started")
  sceneDatabase.scheduleLevelBuild(120)
end

function M.onExtensionUnloaded()
  if extensions and extensions.beamrt_reflectionSourceProbe then extensions.beamrt_reflectionSourceProbe.cancel("BeamRT unloaded") end
  if extensions and extensions.beamrt_reflectionConvergence then
    extensions.beamrt_reflectionConvergence.cancel("BeamRT unloaded")
  end
  beamrtLog("I", "extension unload")
  PROGRESSIVE.lightingAudit.cancel(M, "extension unloaded")
  if materialCachePublication then
    finishMaterialCachePublication("extension unloaded", false)
  end
  if CLEAN_RADIANCE.build then
    CLEAN_RADIANCE.finishBuild("extension unloaded", false)
  end
  markAllMaterialCachesStale("extension unloaded")
  enabledRequested = false
  geometryBoxes = {}
  geometryScanPosition = nil
  orientedGeometryProxyCount = 0
  surfels = {}
  surfelScanPosition = nil
  pendingSurfelRefresh = nil
  markSurfelGeometryDirty()
  surfelCacheResetFrames = 2
  surfelRefreshCheckFrames = 0
  reflectionHistoryValid = 0
  reflectionHistoryWarmupFrames = 0
  PROGRESSIVE.reflectionSampling.frame = 0
  PROGRESSIVE.reflectionSampling.sampleIndex = 0
  sceneDatabase.invalidate("extension unloaded")
  if RenderViewManagerInstance and type(RenderViewManagerInstance.getView) == "function"
    and type(RenderViewManagerInstance.destroyView) == "function" then
    for _, config in pairs(MATERIAL_CACHE_CONFIGS) do
      local ok, probeView = pcall(RenderViewManagerInstance.getView, RenderViewManagerInstance, config.probeViewName)
      if ok and probeView then
        pcall(function()
          probeView.active = false
          probeView.usePostEffects = false
          RenderViewManagerInstance:destroyView(probeView)
        end)
      end
    end
  end
  destroyObjects()
end

return M
