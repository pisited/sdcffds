-- Four deterministic quality tiers, independent of the current saved tuning.
-- These are bounded starting points, not claims of in-game visual validation.
-- Diagnostic/convergence controls remain separate from the gameplay presets.
local M = {}

local entries = {
  {id = "performance", label = "Performance", description = "Lowest bounded ray budget; reflection history helpers and local repair off."},
  {id = "balanced", label = "Balanced", description = "Practical full-resolution GI and GGX reflections with receiver-aware history."},
  {id = "quality", label = "Quality", description = "More trace coverage and experimental small-footprint reflection repair."},
  {id = "cinematic", label = "Cinematic", description = "Highest bounded two-path budget; experimental local repair, not a 32-path stress test."},
}

-- Keep the lighting model and render resolution consistent across tiers, so
-- increasing quality does not silently mean a stronger GI exposure or a
-- different world-geometry source. Older linear 16/32-path presets are not
-- suitable as ordinary gameplay tiers and intentionally are not reproduced.
local common = {
  mode = "lighting", giSource = "screen",
  giRenderScale = 1.0, giEstimator = "corrected", giLocalization = 0.60,
  rayMarcher = "screendda", screenRayStride = 1.0,
  rayStepSize = 0.20, rayThickness = 0.55, rayNormalBias = 0.035,
  giStrength = 1.65, giClamp = 10.0, giCellSize = 0.005,
  historyDepthTolerance = 0.004, denoiseStrength = 0.90,
  contactShadowStrength = 0.0, bounceSaturation = 1.45,
  giExposure = 0.40, giShadowFocus = 0.86, giReceiverTint = 0.58,
  giContrast = 1.12, giEnergyLimit = 2.25, giHighlightRolloff = 0.90,
  worldGIStrength = 0.0, worldLeakSuppression = 0.96,
  radianceCleanup = 1.0, specularReject = 0.92,
  radianceSource = "directdiffuse", radianceChromaStrength = 0.75, retroReject = 1.0,
  progressiveEnabled = true, progressiveClampStrength = 0.10,
  secondBounceStrength = 0.22, emissiveBoost = 4.0,
  rearRayReach = 0.25, lowPathRescue = 0.70,
  blueNoiseStrength = 1.0, blueNoiseSource = "beamng",
  svgfStrength = 1.0, svgfVarianceScale = 4.0, svgfMaxHistory = 32,
  hitValidationStrength = 1.0, minHitTravelPixels = 2.0,
  candidateContinuation = 0.90, emissiveSeparation = 1.0, echoHistoryGuard = 1.0,
  surfelTraceDistance = 80.0, surfelBaseRadius = 1.25,
  surfelVisibilityTolerance = 0.8, surfelCacheBlend = 0.10,
  surfelRefreshDistance = 6.0, surfelRefreshRaysPerFrame = 4,

  reflectionsEnabled = true, reflectionSamplingMode = "ggx",
  reflectionReconstruction = "playable", reflectionColorFilterEnabled = true,
  reflectionStrength = 0.75, reflectionNormalBias = 0.04,
  reflectionSampleCellPixels = 1.0, reflectionNoiseSeed = 0,
  reflectionFilterRadiusScale = 1.0, reflectionSourceFootprintScale = 1.0,
  reflectionHitAwareEnabled = true, reflectionReceiverHistoryEnabled = true,
  reflectionSourceReconstructionEnabled = true,
  -- The live legacy/playable comparison with variance enabled showed coarse
  -- patches; the responsible stage is not yet isolated. Keep this experiment
  -- out of the four presets until that comparison is resolved.
  reflectionVarianceEnabled = false, reflectionVariancePasses = 1,
  reflectionVarianceStrength = 0.65,
  reflectionLocalResolveEnabled = false, reflectionLocalResolveStrength = 0.35,
}

local tiers = {
  performance = {
    giPathCount = 1, rayMaxSteps = 32, screenDdaMaxPaths = 1, screenDdaMaxSteps = 16,
    rayReach = 0.60, temporalBlend = 0.12, progressiveMaxSamples = 512,
    hitRefinementSteps = 2, candidateRetryCount = 1,
    reflectionMaxRoughness = 0.28, reflectionStepSize = 0.42,
    reflectionThickness = 0.28, reflectionTemporalBlend = 0.35,
    reflectionDenoiseStrength = 0.35,
    reflectionHitAwareEnabled = false, reflectionReceiverHistoryEnabled = false,
  },
  balanced = {
    giPathCount = 1, rayMaxSteps = 48, screenDdaMaxPaths = 1, screenDdaMaxSteps = 24,
    rayReach = 0.70, temporalBlend = 0.10, progressiveMaxSamples = 1024,
    hitRefinementSteps = 3, candidateRetryCount = 2,
    reflectionMaxRoughness = 0.32, reflectionStepSize = 0.35,
    reflectionThickness = 0.28, reflectionTemporalBlend = 0.30,
    reflectionDenoiseStrength = 0.40,
  },
  quality = {
    giPathCount = 1, rayMaxSteps = 64, screenDdaMaxPaths = 1, screenDdaMaxSteps = 32,
    rayReach = 0.75, temporalBlend = 0.085, progressiveMaxSamples = 2048,
    hitRefinementSteps = 3, candidateRetryCount = 3,
    reflectionMaxRoughness = 0.34, reflectionStepSize = 0.30,
    reflectionThickness = 0.24, reflectionTemporalBlend = 0.25,
    reflectionDenoiseStrength = 0.45, reflectionLocalResolveEnabled = true,
  },
  cinematic = {
    giPathCount = 2, rayMaxSteps = 64, screenDdaMaxPaths = 2, screenDdaMaxSteps = 48,
    rayReach = 0.75, temporalBlend = 0.075, progressiveMaxSamples = 2048,
    progressiveClampStrength = 0.08, svgfVarianceScale = 3.25,
    hitRefinementSteps = 4, candidateRetryCount = 3,
    reflectionMaxRoughness = 0.35, reflectionStepSize = 0.28,
    reflectionThickness = 0.24, reflectionTemporalBlend = 0.22,
    reflectionDenoiseStrength = 0.50, reflectionLocalResolveEnabled = true,
  },
}

-- Compatibility names resolve to one of the four visible tiers. In
-- particular, "experimental" is now a Balanced alias, not a fifth preset or
-- permission to enable every diagnostic/unfinished rendering path.
local aliases = {
  experimental = "balanced", userbest = "quality", maxquality = "cinematic",
  beautymax = "cinematic", beautyreflect = "cinematic",
  ptgiplay = "balanced", ptgiplayreflect = "balanced",
  ptgimax = "quality", ptgimaxreflect = "quality",
  ultra = "quality", showcase = "quality", clean = "quality",
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

function M.list()
  return copy(entries)
end

function M.resolve(name)
  if type(name) ~= "string" then return nil, nil end
  local normalized = string.lower(name):match("^%s*(.-)%s*$")
  local canonical = aliases[normalized] or normalized
  local tier = tiers[canonical]
  if not tier then return nil, nil end
  local result = copy(common)
  for key, value in pairs(tier) do result[key] = copy(value) end
  return result, canonical
end

return M
