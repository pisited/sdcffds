-- Opt-in, rendering-only controller. Never changes integrated SSR, the stock
-- water shader, motion-blur settings, the mod manager or external extensions.
local M = {}
local pipeline = require('ge/extensions/beamrt/coherentPipeline')
local compatibility = require('ge/extensions/beamrt/rendererCompatibility')
local motion = require('ge/extensions/beamrt/coherentVehicleMotion')
local requested = false
local reason = 'Not enabled. Experimental; game appearance has not been verified.'
local options = {}
local noiseRestore
local noiseSettings = {renderScale=1, traceQuality=1, stochasticRayCount=16,
  stochasticSSR=true, samplingMode=1, stochasticTemporalRate=1,
  temporalDenoising=true, temporalStrength=0.98, nativeTemporal=true,
  traceSubpixelJitter=true, geometryReconstruction=true, virtualReprojection=true,
  roughStability=true, stochasticReuse=0.5, filteredColor=true, adaptiveResolution=false}

for id, parameter in pairs(pipeline.parameters) do options[id] = parameter.default end
-- Preserve the contributed traversal constants, not obsolete pre-hierarchy defaults.
for id, value in pairs(pipeline.retiredValues) do options[id] = value end
options.qualityPreset = 0 -- no fifth preset family; settings are transient
options.interleavedHistory = false -- complete native-resolution history first
options.stochasticResolution = 1
options.renderScale = 0.5
options.traceQuality = 1
options.stochasticRayCount = 6 -- intermediate gameplay baseline; 8 and 16 remain explicit
options.skyReflection = false -- a miss is not proof of visible sky
options.overhangFill = false -- screen-space enclosure estimate, not visibility
options.puddleStrength = 0
options.waterColorStrength = 0 -- keep the engine-rendered water color; no added cyan/blue grade
options.terrainMaskEnable = false
options.terrainRuntimeBake = false
options.engineVelocity = false -- do not bind an unverified/unproduced engine target
options.fillEngineVelocityHole = false -- never force the global vehicle velocity flag
options.skyModelVersion = 2
options.virtualParallaxScale = 1 -- flat-mirror translation reference, separately tunable
pipeline.values = options
pipeline.enabled = false

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

function M.getOptions()
  local result = {}
  for key, value in pairs(options) do result[key] = value end
  return result
end

function M.getStatus()
  local ok, runtime = pcall(pipeline.getRuntimeStatus)
  runtime = ok and runtime or {}
  local accumulationConfigured = options.temporalDenoising == true and options.temporalStrength > 0.0001
  local accumulationScheduled = requested and accumulationConfigured and runtime.accumulationScheduled == true
  return {requested = requested, active = requested and runtime.passesEnabled == true,
    reason = reason, frame = runtime.frame or 0, historyWarmup = runtime.historyWarmup,
    cameraHistoryReady = runtime.cameraHistoryReady == true,
    accumulationConfigured = accumulationConfigured, accumulationScheduled = accumulationScheduled,
    accumulationReady = accumulationScheduled and runtime.cameraHistoryReady == true
      and (runtime.historyWarmup or 2) <= 0,
    freshSampling = accumulationConfigured and options.stochasticTemporalRate > 0,
    noiseRestoreAvailable = noiseRestore ~= nil,
    waterMapAvailable = runtime.waterMapAvailable == true,
    waterMapReason = runtime.waterMapReason,
    nativeSettingsChanged = false, gameAppearanceVerified = false,
    gpuExecutionVerified = false, sceneColorSource = runtime.sceneColorSource,
    materialResponseActive=requested and runtime.materialResponseActive==true,options = M.getOptions()}
end

function M.setSceneColorSource(source)
  if source ~= '$backBuffer' and source ~= '#BeamRT_PTGI_LitScene' then return false,'Unknown scene producer.' end
  local ok,why=pcall(pipeline.setSceneColorSource,source)
  if not ok then M.disable('Scene producer binding failed: '..tostring(why));return false,tostring(why) end
  return true
end

function M.disable(why)
  requested, pipeline.enabled = false, false
  motion.clear()
  local ok, released = pcall(pipeline.release)
  reason = why or 'Coherent SSR disabled.'
  if not ok or not released then
    reason = reason .. ' Owned-object cleanup incomplete; retry disable before enabling another backend.'
    return false, reason
  end
  return true
end

function M.enable()
  local state = compatibility.check()
  if not state.safe then return false, state.reason end
  local stopped, failure = M.disable('Preparing Coherent SSR')
  if not stopped then return false, failure end
  pipeline.values, pipeline.enabled = options, true
  local ok, err = pcall(pipeline.enable, pipeline)
  local statusOK, runtime = pcall(pipeline.getRuntimeStatus)
  if not ok or not statusOK or not runtime.passesEnabled then
    local detail = not ok and tostring(err) or 'Required passes were not created/enabled.'
    M.disable('Coherent SSR startup failed: ' .. detail)
    return false, reason
  end
  requested = true
  reason = 'Owned pass graph enabled; history warming. GPU output and appearance are not yet verified.'
  return true
end

function M.setParameter(id, value)
  local parameter = type(id) == 'string' and pipeline.parameters[id]
  if not parameter or id == 'qualityPreset' or id == 'fillEngineVelocityHole' then
    return false, 'Unknown or managed Coherent SSR parameter.'
  end
  if (id=='nativeMaterialResponse' and value==true and (not options.hdrComposite or options.terrainMaskEnable))
    or (options.nativeMaterialResponse and ((id=='hdrComposite' and value==false) or (id=='terrainMaskEnable' and value==true))) then
    return false,'Native material response needs HDR composition and the terrain mask disabled (shared six-slot budget).'
  end
  if parameter.type == 'bool' then
    if type(value) ~= 'boolean' then return false, 'Expected boolean.' end
  else
    if not finite(value) then return false, 'Expected a finite number.' end
    if parameter.min and value < parameter.min or parameter.max and value > parameter.max then
      return false, 'Value outside the documented range.'
    end
    if parameter.type == 'combo' or parameter.step == 1 then
      if value ~= math.floor(value) then return false, 'Expected an integer choice.' end
    end
  end
  if options[id] == value then return true end
  local ok, err = pcall(pipeline.setParameter, pipeline, id, value)
  if not ok then M.disable('Coherent SSR parameter update failed: ' .. tostring(err)); return false, reason end
  pipeline.resetHistory()
  return true
end

function M.resetHistory()
  pipeline.resetHistory()
  motion.clear()
end

local function applyNoiseSettings(values)
  for id, value in pairs(values) do
    local ok, failure = M.setParameter(id, value)
    if not ok then return false, failure end
  end
  return true
end

function M.applyNoiseQuality()
  if not noiseRestore then
    noiseRestore = {}
    for id in pairs(noiseSettings) do noiseRestore[id] = options[id] end
  end
  -- An explicit, reversible sampling action, not an appearance/brightness preset.
  -- Does not start rendering or change any native setting.
  return applyNoiseSettings(noiseSettings)
end

function M.restoreNoiseQuality()
  if not noiseRestore then return false, 'No cleanup settings to restore.' end
  local ok, failure = applyNoiseSettings(noiseRestore)
  if ok then noiseRestore = nil end
  return ok, failure
end

function M.update(dt)
  if not requested then return end
  local state = compatibility.check()
  if not state.safe then M.disable(state.reason); return end
  if not finite(dt) or dt <= 0 then dt = 1 / 60 end
  if dt > 0.25 then M.resetHistory() end
  local ok, err = pcall(function()
    pipeline.update(pipeline, math.min(dt, 0.25))
    pipeline.onPreRender(pipeline, motion.capture(dt))
    if not pipeline.getRuntimeStatus().passesEnabled then error('Required owned pass lost/disabled.') end
  end)
  if not ok then M.disable('Coherent SSR stopped: ' .. tostring(err)); return end
  reason = 'Owned passes enabled. Compare stillness, driving and disocclusion; visual quality is unverified.'
end

M.release = M.disable
return M
