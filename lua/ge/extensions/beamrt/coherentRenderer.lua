-- Opt-in, rendering-only controller. Never changes integrated SSR, the stock
-- water shader, motion-blur settings, the mod manager or external extensions.
local M = {}
local pipeline = require('ge/extensions/beamrt/coherentPipeline')
local compatibility = require('ge/extensions/beamrt/rendererCompatibility')
local motion = require('ge/extensions/beamrt/coherentVehicleMotion')
local requested = false
local reason = 'Not enabled. Experimental; game appearance has not been verified.'
local options = {}

for id, parameter in pairs(pipeline.parameters) do options[id] = parameter.default end
-- Preserve the contributed traversal constants, not obsolete pre-hierarchy defaults.
for id, value in pairs(pipeline.retiredValues) do options[id] = value end
options.qualityPreset = 0 -- no fifth preset family; settings are transient
options.interleavedHistory = false -- complete native-resolution history first
options.stochasticResolution = 1
options.renderScale = 0.5
options.traceQuality = 1
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
  return {requested = requested, active = requested and runtime.passesEnabled == true,
    reason = reason, frame = runtime.frame or 0, historyWarmup = runtime.historyWarmup,
    cameraHistoryReady = runtime.cameraHistoryReady == true,
    waterMapAvailable = runtime.waterMapAvailable == true,
    waterMapReason = runtime.waterMapReason,
    nativeSettingsChanged = false, gameAppearanceVerified = false,
    gpuExecutionVerified = false, options = M.getOptions()}
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
