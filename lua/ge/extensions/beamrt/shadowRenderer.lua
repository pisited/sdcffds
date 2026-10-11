-- BeamRT independent sunlight visibility prototype v0.102.
-- Load separately: extensions.load("beamrt_shadowRenderer")
-- Produces #BeamRT_SunShadowVisibility without changing BeamRT GI or final lighting.
local M = {}
local TRACE_SHADER = "BeamRT_SunShadowTraceShader"
local PREVIEW_SHADER = "BeamRT_SunShadowPreviewShader"
local STATE = "BeamRT_SunShadowState"
local TRACE_FX = "BeamRT_SunShadowFx"
local PREVIEW_FX = "BeamRT_SunShadowPreviewFx"
local TARGET = "#BeamRT_SunShadowVisibility"

local modes = {
  playable = {steps = 24, distance = 18.0, bias = 0.055, thickness = 0.24, refineSteps = 3, scale = "0.5 0.5"},
  cinematic = {steps = 96, distance = 55.0, bias = 0.035, thickness = 0.12, refineSteps = 5, scale = "1 1"},
}
local views = {
  off = -1, classification = 0, visibility = 1, beamrt = 1, coverage = 2,
  incidence = 3, native = 4, difference = 5, sun = 6, identity = 7,
  scene = 8, split = 9,
}
local quality = "playable"
local hitModel = "refined" -- legacy (v004) or refined (v005), same tracing budget
local view = "off"
local active = false
local split = {
  enabled = false,
  position = 0.5,
  left = "classification",
  right = "difference",
  lineWidth = 2.0,
  lineColor = {1.0, 1.0, 1.0, 1.0},
  restoreView = "classification",
}

local function validComparisonMode(name)
  return type(name) == "string" and views[name] ~= nil
     and name ~= "off" and name ~= "split"
end

local function finiteNumber(v)
  return type(v) == "number" and v == v
     and v ~= math.huge and v ~= -math.huge
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function find(name)
  return scenetree and scenetree.findObject and scenetree.findObject(name) or nil
end

local function setEnabled(name, enabled)
  local fx = find(name)
  if not fx then return false end
  if enabled then fx:enable() else fx:disable() end
  return true
end

local function makeShader(name, path, samplers)
  local shader = find(name)
  if not shader then
    shader = createObject("ShaderData")
    shader.DXVertexShaderFile = path
    shader.DXPixelShaderFile = path
    for i, sampler in ipairs(samplers) do
      shader:setField("samplerNames", i - 1, sampler)
    end
    shader.pixVersion = 5.0
    shader:registerObject(name)
  else
    shader.DXVertexShaderFile = path
    shader.DXPixelShaderFile = path
  end
end

local function makeObjects()
  if not find(STATE) then
    local state = createObject("GFXStateBlockData")
    state.zDefined = true
    state.zEnable = false
    state.zWriteEnable = false
    state.blendDefined = true
    state.blendEnable = false
    state.samplersDefined = true
    state:setField("samplerStates", 0, "SamplerClampPoint")
    state:setField("samplerStates", 1, "SamplerClampPoint")
    state:setField("samplerStates", 2, "SamplerClampPoint")
    state:registerObject(STATE)
  end

  makeShader(TRACE_SHADER,
    "shaders/beamrt/beamrtSunShadowTraceP_v005.hlsl",
    {"prepassTex", "prepassDepthTex"})
  makeShader(PREVIEW_SHADER,
    "shaders/beamrt/beamrtSunShadowPreviewP_v003.hlsl",
    {"shadowDataTex", "backBufferTex", "nativeSunTex"})

  if not find(TRACE_FX) then
    local fx = createObject("PostEffect")
    fx.isEnabled = false
    fx.allowReflectPass = false
    fx.renderPriority = 10010
    fx:setField("renderTime", 0, "PFXAfterDiffuse")
    fx:setField("shader", 0, TRACE_SHADER)
    fx:setField("stateBlock", 0, STATE)
    fx:setField("texture", 0, "#prepass[RT0]")
    fx:setField("texture", 1, "#prepass[Depth]")
    fx:setField("target", 0, TARGET)
    fx:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
    fx:setField("targetScale", 0, modes[quality].scale)
    fx:setField("targetClear", 0, "PFXTargetClear_OnCreate")
    fx:setField("targetClearColor", 0, "1 0 0 0")
    fx:registerObject(TRACE_FX)
  end

  if not find(PREVIEW_FX) then
    local fx = createObject("PostEffect")
    fx.isEnabled = false
    fx.allowReflectPass = false
    fx.renderPriority = 9980
    fx:setField("renderTime", 0, "PFXAfterDiffuse")
    fx:setField("shader", 0, PREVIEW_SHADER)
    fx:setField("stateBlock", 0, STATE)
    fx:setField("texture", 0, TARGET)
    fx:setField("texture", 1, "$backBuffer")
    fx:setField("texture", 2, "#sunShadowMask[RT0]")
    fx:setField("target", 0, "$backBuffer")
    fx:registerObject(PREVIEW_FX)
  end
end

local function apply()
  local trace = find(TRACE_FX)
  local preview = find(PREVIEW_FX)
  local settings = modes[quality]
  if trace then
    trace:setShaderConst("$shadowRaySteps", settings.steps)
    trace:setShaderConst("$shadowRayDistance", settings.distance)
    trace:setShaderConst("$shadowNormalBias", settings.bias)
    trace:setShaderConst("$shadowThickness", settings.thickness)
    trace:setShaderConst("$shadowHitModel", hitModel == "refined" and 1 or 0)
    trace:setShaderConst("$shadowRefineSteps", settings.refineSteps)
  end
  if preview then
    preview:setShaderConst("$shadowViewMode", math.max(views[view], 0))
    preview:setShaderConst("$splitEnabled", split.enabled and 1 or 0)
    preview:setShaderConst("$splitPosition", split.position)
    preview:setShaderConst("$splitLeftMode", views[split.left])
    preview:setShaderConst("$splitRightMode", views[split.right])
    preview:setShaderConst("$splitLineWidth", split.lineWidth)
    preview:setShaderConst("$splitLineColor",
      string.format("%.5f %.5f %.5f %.5f",
        split.lineColor[1], split.lineColor[2],
        split.lineColor[3], split.lineColor[4]))
  end
end

local callbacks = {}
callbacks.setShaderConsts = apply
rawset(_G, TRACE_FX .. "Callbacks", callbacks)
rawset(_G, PREVIEW_FX .. "Callbacks", callbacks)

function M.enable()
  makeObjects()
  active = true
  setEnabled(TRACE_FX, true)
  setEnabled(PREVIEW_FX, view ~= "off")
  apply()
  return true
end

function M.disable()
  active = false
  setEnabled(PREVIEW_FX, false)
  setEnabled(TRACE_FX, false)
  return true
end

function M.setQuality(requested)
  if not modes[requested] then
    if type(log) == "function" then log("E", "BeamRT.Shadow", "Expected playable or cinematic") end
    return false
  end
  quality = requested
  local trace = find(TRACE_FX)
  if trace then
    trace:setField("targetScale", 0, modes[quality].scale)
  end
  apply()
  return true
end

-- Toggle identical tracing inputs and budgets to compare the v004 hit rule
-- against the refined depth-bracket solver. This does not run two GPU passes.
function M.setHitModel(requested)
  if requested ~= "legacy" and requested ~= "refined" then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "Expected hit model 'legacy' or 'refined'")
    end
    return false
  end
  hitModel = requested
  apply()
  return true
end

function M.setView(requested)
  if views[requested] == nil then
    if type(log) == "function" then log("E", "BeamRT.Shadow", "Unknown view: " .. tostring(requested)) end
    return false
  end
  if requested == "split" then
    if view ~= "split" and view ~= "off" then split.restoreView = view end
    split.enabled = true
  else
    split.enabled = false
    if requested ~= "off" then split.restoreView = requested end
  end
  view = requested
  if active then setEnabled(PREVIEW_FX, view ~= "off") end
  apply()
  return true
end

function M.setSplitEnabled(enabled)
  if type(enabled) ~= "boolean" then return false end
  if enabled then
    return M.setView("split")
  end
  return M.setView(split.restoreView)
end

function M.setSplitPosition(position)
  if not finiteNumber(position) then return false end
  split.position = clamp(position, 0.0, 1.0)
  apply()
  return true
end

function M.setSplitLeft(requested)
  if not validComparisonMode(requested) then return false end
  split.left = requested
  apply()
  return true
end

function M.setSplitRight(requested)
  if not validComparisonMode(requested) then return false end
  split.right = requested
  apply()
  return true
end

function M.setSplitLineWidth(width)
  if not finiteNumber(width) then return false end
  split.lineWidth = clamp(width, 0.0, 32.0)
  apply()
  return true
end

function M.setSplitLineColor(r, g, b, a)
  if a == nil then a = 1.0 end
  if not finiteNumber(r) or not finiteNumber(g)
    or not finiteNumber(b) or not finiteNumber(a) then return false end
  split.lineColor = {
    clamp(r, 0, 1), clamp(g, 0, 1),
    clamp(b, 0, 1), clamp(a, 0, 1)}
  apply()
  return true
end

function M.compare(left, right, position)
  if not validComparisonMode(left) or not validComparisonMode(right) then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "Split sources must be scene, beamrt, native, classification, difference, coverage, incidence, sun, or identity")
    end
    return false
  end
  if position ~= nil and not finiteNumber(position) then return false end
  split.left, split.right = left, right
  if position ~= nil then split.position = clamp(position, 0, 1) end
  M.setView("split")
  if not active then M.enable() end
  apply()
  return true
end

function M.getStatus()
  return {enabled = active, quality = quality, view = view, target = TARGET,
    hitModel = hitModel, refineSteps = modes[quality].refineSteps,
    steps = modes[quality].steps, distance = modes[quality].distance,
    traceObject = find(TRACE_FX) ~= nil, previewObject = find(PREVIEW_FX) ~= nil,
    split = {enabled = split.enabled, position = split.position,
      left = split.left, right = split.right,
      lineWidth = split.lineWidth}}
end

function M.onExtensionLoaded()
  if type(setExtensionUnloadMode) == "function" then
    setExtensionUnloadMode(M, "manual")
  end
  makeObjects()
  apply()
end

function M.onExtensionUnloaded()
  M.disable()
  for _, name in ipairs({PREVIEW_FX, TRACE_FX, PREVIEW_SHADER, TRACE_SHADER, STATE}) do
    local object = find(name)
    if object then object:delete() end
  end
  rawset(_G, TRACE_FX .. "Callbacks", nil)
  rawset(_G, PREVIEW_FX .. "Callbacks", nil)
end

return M
