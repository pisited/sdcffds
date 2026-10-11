-- BeamRT independent sunlight visibility prototype v0.102.
-- Load separately: extensions.load("beamrt_shadowRenderer")
-- Produces #BeamRT_SunShadowVisibility without changing BeamRT GI or final lighting.
local M = {}
local worldBoxCasters = require("ge/extensions/beamrt/worldBoxCasters")
local worldMeshCasters = require("ge/extensions/beamrt/worldMeshCasters")
local offscreenMeshEnabled = false
local offscreenEnabled = false
-- Probe v011 showed hits with the reversed engine sun vector. Limit this
-- correction to opt-in world-box geometry until screen-space is revalidated.
local offscreenSunDirection = "reversed"
local TRACE_SHADER = "BeamRT_SunShadowTraceShader"
local PREVIEW_SHADER = "BeamRT_SunShadowPreviewShader"
local STATE = "BeamRT_SunShadowState"
local TRACE_FX = "BeamRT_SunShadowFx"
local COMPARE_FX = "BeamRT_SunShadowCompareFx"
local PREVIEW_FX = "BeamRT_SunShadowPreviewFx"
local TARGET = "#BeamRT_SunShadowVisibility"
local COMPARE_TARGET = "#BeamRT_SunShadowVisibilityCompare"

local modes = {
  playable = {steps = 24, distance = 18.0, bias = 0.055, thickness = 0.24, refineSteps = 3, scale = "0.5 0.5"},
  cinematic = {steps = 96, distance = 55.0, bias = 0.035, thickness = 0.12, refineSteps = 5, scale = "1 1"},
}
local views = {
  off = -1, classification = 0, visibility = 1, beamrt = 1, coverage = 2,
  incidence = 3, native = 4, difference = 5, sun = 6, identity = 7,
  scene = 8, split = 9, hitdistance = 10, deptherror = 11, selfplane = 12,
  hybrid = 13, hybridweight = 14, hybridsource = 15, hybridscene = 16,
  worldbox = 17, worldboxprobe = 18, worldmesh = 19,
}
local hitModels = {legacy = 0, refined = 1, validated = 2, geometric = 3}
local modelSplitViews = {classification = 0, visibility = 1, coverage = 2,
  incidence = 3, difference = 4, rawdifference = 5, modelid = 6,
  hitdistance = 7, deptherror = 8, selfplane = 9}
local telemetryViews = {hitdistance = true, deptherror = true, selfplane = true}
local worldBoxViews = {worldbox = true, worldboxprobe = true, worldmesh = true}
local quality = "playable"
local hitModel = "validated" -- legacy v004, refined v005, validated v006, geometric v007
-- Experimental preview only: native mask semantics are not yet calibrated.
local hybrid = {nativePolarity = "normal", minConfidence = 0.95, detailStrength = 0.35}
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
  kind = "views",
  modelLeft = "validated",
  modelRight = "refined",
  modelView = "classification",
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
    "shaders/beamrt/beamrtSunShadowTraceP_v013.hlsl",
    {"prepassTex", "prepassDepthTex"})
  makeShader(PREVIEW_SHADER,
    "shaders/beamrt/beamrtSunShadowPreviewP_v012.hlsl",
    {"shadowDataTex", "backBufferTex", "nativeSunTex", "compareShadowDataTex"})

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

  if not find(COMPARE_FX) then
    local fx = createObject("PostEffect")
    fx.isEnabled = false
    fx.allowReflectPass = false
    fx.renderPriority = 10009
    fx:setField("renderTime", 0, "PFXAfterDiffuse")
    fx:setField("shader", 0, TRACE_SHADER)
    fx:setField("stateBlock", 0, STATE)
    fx:setField("texture", 0, "#prepass[RT0]")
    fx:setField("texture", 1, "#prepass[Depth]")
    fx:setField("target", 0, COMPARE_TARGET)
    fx:setField("targetFormat", 0, "GFXFormatR16G16B16A16F")
    fx:setField("targetScale", 0, modes[quality].scale)
    fx:setField("targetClear", 0, "PFXTargetClear_OnCreate")
    fx:setField("targetClearColor", 0, "1 0 0 0")
    fx:registerObject(COMPARE_FX)
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
    fx:setField("texture", 3, COMPARE_TARGET)
    fx:setField("target", 0, "$backBuffer")
    fx:registerObject(PREVIEW_FX)
  end
end

local function modelComparisonActive()
  return active and view == "split" and split.enabled and
    split.kind == "models"
end

local function telemetryRequested()
  if modelComparisonActive() then
    return telemetryViews[split.modelView] == true
  end
  if view == "split" and split.enabled and split.kind == "views" then
    return telemetryViews[split.left] == true or
           telemetryViews[split.right] == true
  end
  return telemetryViews[view] == true
end

local function worldBoxDiagnosticRequested()
  if view == "split" and split.enabled and split.kind == "views" then
    return worldBoxViews[split.left] == true or
           worldBoxViews[split.right] == true
  end
  return worldBoxViews[view] == true
end

local function worldBoxProbeRequested()
  if view == "split" and split.enabled and split.kind == "views" then
    return split.left == "worldboxprobe" or
           split.right == "worldboxprobe"
  end
  return view == "worldboxprobe"
end

local function worldMeshDiagnosticRequested()
  if view == "split" and split.enabled and split.kind == "views" then
    return split.left == "worldmesh" or split.right == "worldmesh"
  end
  return view == "worldmesh"
end

local function currentTraceDiagnostic()
  if modelComparisonActive() and split.modelView == "modelid" then return 1 end
  if worldMeshDiagnosticRequested() then return 5 end
  if worldBoxProbeRequested() then return 4 end
  if worldBoxDiagnosticRequested() then return 3 end
  return telemetryRequested() and 2 or 0
end

local function updateEffectStates()
  setEnabled(TRACE_FX, active)
  setEnabled(COMPARE_FX, modelComparisonActive())
  setEnabled(PREVIEW_FX, active and view ~= "off")
end

local function applyTracerConsts(trace, settings, model)
  if not trace then return end
  trace:setShaderConst("$shadowRaySteps", settings.steps)
  trace:setShaderConst("$shadowRayDistance", settings.distance)
  trace:setShaderConst("$shadowNormalBias", settings.bias)
  trace:setShaderConst("$shadowThickness", settings.thickness)
  trace:setShaderConst("$shadowHitModel", hitModels[model])
  trace:setShaderConst("$shadowRefineSteps", settings.refineSteps)
  -- Diagnostic 0 stores visibility, 1 stores a unique model ID, and
  -- 2 stores per-hit telemetry. Other modes retain the original RGBA layout.
  trace:setShaderConst("$shadowTraceDiagnostic", currentTraceDiagnostic())
  local slots = worldBoxCasters.getSlots()
  trace:setShaderConst("$shadowWorldBoxEnabled", offscreenEnabled and 1 or 0)
  trace:setShaderConst("$shadowWorldBoxCount",
    offscreenEnabled and #slots or 0)
  trace:setShaderConst("$shadowWorldBoxSunSign",
    offscreenSunDirection == "reversed" and -1 or 1)
  local mesh = worldMeshCasters.getTriangles()
  trace:setShaderConst("$shadowMeshEnabled", offscreenMeshEnabled and 1 or 0)
  trace:setShaderConst("$shadowMeshTriangleCount",
    offscreenMeshEnabled and #mesh or 0)
  for i = 0, 11 do
    local tri = mesh[i + 1]
    local zero = {0, 0, 0}
    for _, part in ipairs({"A", "B", "C"}) do
      local vertex = tri and tri[part:lower()] or zero
      trace:setShaderConst("$shadowMeshTri" .. i .. part,
        string.format("%.5f %.5f %.5f 0", vertex[1], vertex[2], vertex[3]))
    end
  end
  for index = 0, 3 do
    local b = slots[index + 1]
    local lo = b and b.lo or {0, 0, 0}
    local hi = b and b.hi or {0, 0, 0}
    trace:setShaderConst("$shadowWorldBoxMin" .. index,
      string.format("%.5f %.5f %.5f 0", lo[1], lo[2], lo[3]))
    trace:setShaderConst("$shadowWorldBoxMax" .. index,
      string.format("%.5f %.5f %.5f 0", hi[1], hi[2], hi[3]))
  end
end

local function apply()
  local preview = find(PREVIEW_FX)
  local settings = modes[quality]
  -- The primary target contains the left algorithm during model A/B;
  -- otherwise it holds the globally selected hit model as before.
  applyTracerConsts(find(TRACE_FX), settings,
    modelComparisonActive() and split.modelLeft or hitModel)
  applyTracerConsts(find(COMPARE_FX), settings, split.modelRight)
  if preview then
    preview:setShaderConst("$shadowViewMode", math.max(views[view], 0))
    preview:setShaderConst("$hybridInvertNative",
      hybrid.nativePolarity == "inverted" and 1 or 0)
    preview:setShaderConst("$hybridMinConfidence", hybrid.minConfidence)
    preview:setShaderConst("$hybridDetailStrength", hybrid.detailStrength)
    preview:setShaderConst("$modelSplitEnabled", modelComparisonActive() and 1 or 0)
    preview:setShaderConst("$modelSplitViewMode", modelSplitViews[split.modelView])
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
rawset(_G, COMPARE_FX .. "Callbacks", callbacks)
rawset(_G, PREVIEW_FX .. "Callbacks", callbacks)

function M.enable()
  makeObjects()
  active = true
  updateEffectStates()
  apply()
  return true
end

function M.disable()
  active = false
  updateEffectStates()
  return true
end

function M.setQuality(requested)
  if not modes[requested] then
    if type(log) == "function" then log("E", "BeamRT.Shadow", "Expected playable or cinematic") end
    return false
  end
  quality = requested
  for _, name in ipairs({TRACE_FX, COMPARE_FX}) do
    local trace = find(name)
    if trace then
      trace:setField("targetScale", 0, modes[quality].scale)
    end
  end
  apply()
  return true
end

-- Models use the same main tracing budget. Only candidate refinement /
-- neighborhood validation differs. No additional full-screen GPU pass.
function M.setHitModel(requested)
  if requested ~= "legacy" and requested ~= "refined" and
     requested ~= "validated" and requested ~= "geometric" then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "Expected 'legacy', 'refined', 'validated', or 'geometric'")
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
  updateEffectStates()
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
  -- One trace can't output both telemetry and visibility simultaneously.
  if telemetryViews[requested] ~= telemetryViews[split.right] and
     requested ~= "scene" and split.right ~= "scene" then return false end
  if worldBoxViews[requested] ~= worldBoxViews[split.right] and
     requested ~= "scene" and split.right ~= "scene" then return false end
  if worldBoxViews[requested] and worldBoxViews[split.right] and
     requested ~= split.right then return false end
  split.left = requested
  apply()
  return true
end

function M.setSplitRight(requested)
  if not validComparisonMode(requested) then return false end
  if telemetryViews[requested] ~= telemetryViews[split.left] and
     requested ~= "scene" and split.left ~= "scene" then return false end
  if worldBoxViews[requested] ~= worldBoxViews[split.left] and
     requested ~= "scene" and split.left ~= "scene" then return false end
  if worldBoxViews[requested] and worldBoxViews[split.left] and
     requested ~= split.left then return false end
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
  -- Also accept hit-model names directly for the intuitive A/B command.
  if hitModels[left] ~= nil and hitModels[right] ~= nil then
    return M.compareModels(left, right, position)
  end
  if not validComparisonMode(left) or not validComparisonMode(right) then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "Split sources must be scene, beamrt, native, classification, difference, coverage, incidence, sun, or identity")
    end
    return false
  end
  if position ~= nil and not finiteNumber(position) then return false end
  -- A single output target cannot simultaneously encode a normal visibility
  -- mask and per-hit metrics; scene can share either encoding.
  if telemetryViews[left] ~= telemetryViews[right] and
     left ~= "scene" and right ~= "scene" then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "Use two telemetry modes together or pair one with scene")
    end
    return false
  end
  if worldBoxViews[left] ~= worldBoxViews[right] and
     left ~= "scene" and right ~= "scene" then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "World-box diagnostic changes trace encoding; pair with scene only")
    end
    return false
  end
  if worldBoxViews[left] and worldBoxViews[right] and
     left ~= right then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "worldbox/worldboxprobe/worldmesh have different encodings; pair with scene")
    end
    return false
  end
  split.left, split.right = left, right
  split.kind = "views"
  if position ~= nil then split.position = clamp(position, 0, 1) end
  M.setView("split")
  if not active then M.enable() end
  apply()
  return true
end

-- Two full-frame shadow traces in the SAME frame: primary = left model,
-- secondary = right model. Disable the secondary pass in other views.
function M.compareModels(left, right, position)
  if hitModels[left] == nil or hitModels[right] == nil then
    if type(log) == "function" then
      log("E", "BeamRT.Shadow", "Expected legacy/refined/validated/geometric for both sides")
    end
    return false
  end
  if position ~= nil and not finiteNumber(position) then return false end
  split.modelLeft, split.modelRight = left, right
  split.kind = "models"
  if position ~= nil then split.position = clamp(position, 0, 1) end
  M.setView("split")
  if not active then M.enable() end
  apply()
  return true
end

function M.setModelSplitLeft(requested)
  if hitModels[requested] == nil then return false end
  split.modelLeft = requested
  apply()
  return true
end

function M.setModelSplitRight(requested)
  if hitModels[requested] == nil then return false end
  split.modelRight = requested
  apply()
  return true
end

function M.setModelSplitView(requested)
  if modelSplitViews[requested] == nil then return false end
  split.modelView = requested
  apply()
  return true
end

-- Native shadow encoding is NOT established by the existing source buffer.
-- Compare the raw "native" view before enabling hybrid as a diagnostic.
function M.setHybridNativePolarity(requested)
  if requested ~= "normal" and requested ~= "inverted" then return false end
  hybrid.nativePolarity = requested
  apply()
  return true
end

function M.setHybridMinConfidence(value)
  if not finiteNumber(value) then return false end
  hybrid.minConfidence = clamp(value, 0.0, 0.999)
  apply()
  return true
end

function M.setHybridDetailStrength(value)
  if not finiteNumber(value) then return false end
  hybrid.detailStrength = clamp(value, 0.0, 1.0)
  apply()
  return true
end

-- Actual triangle geometry, separate from coarse box placeholders.
-- World-space vertices: static mesh positions, not camera-space coordinates.
function M.setOffscreenTriangle(index, ax, ay, az, bx, by, bz, cx, cy, cz)
  local ok,err = worldMeshCasters.set(index,ax,ay,az,bx,by,bz,cx,cy,cz)
  if ok then offscreenMeshEnabled = true; apply() end
  return ok,err
end

function M.loadOffscreenTriangles(triangleList)
  local ok,err = worldMeshCasters.load(triangleList)
  if ok then offscreenMeshEnabled = true; apply() end
  return ok,err
end

function M.loadOffscreenTrianglesJson(path)
  local ok,err = worldMeshCasters.loadJson(path)
  if ok then offscreenMeshEnabled = true; apply() end
  return ok,err
end

function M.setOffscreenMeshEnabled(enabled)
  if type(enabled)~="boolean" then return false,"enabled must be boolean" end
  offscreenMeshEnabled = enabled
  apply()
  return true
end

function M.clearOffscreenTriangles()
  offscreenMeshEnabled = false
  worldMeshCasters.clear()
  apply()
  return true
end

-- Validates the GPU triangle path using EXACTLY the previously selected box.
-- This is a calibration test, not extraction of the object's visual mesh.
function M.testTrianglesFromOffscreenBox(index)
  local i = tonumber(index) or 1
  if i % 1 ~= 0 then return false,"integer box index required" end
  local box = worldBoxCasters.getSlots()[i]
  local ok,err = worldMeshCasters.testFromBox(box)
  if ok then
    -- Avoid double-counting the same box through two ray paths.
    offscreenEnabled = false
    offscreenMeshEnabled = true
    apply()
  end
  return ok,err
end

-- World-box sunlight polarity, independent from screen-space trace settings.
-- Does not change the original forward/reversed worldboxprobe channels.
function M.setOffscreenSunDirection(direction)
  if direction ~= "normal" and direction ~= "reversed" then
    return false, "expected 'normal' or 'reversed'"
  end
  offscreenSunDirection = direction
  apply()
  return true
end

-- World-space static casters persist after the SOURCE object leaves
-- the camera frustum. They are coarse AABB proxies, not the real mesh.
function M.setOffscreenEnabled(enabled)
  if type(enabled) ~= "boolean" then return false, "enabled must be boolean" end
  offscreenEnabled = enabled
  apply()
  return true
end

function M.clearOffscreenBoxes()
  worldBoxCasters.clear()
  offscreenEnabled = false
  apply()
  return true
end

function M.setOffscreenBox(index, minX, minY, minZ, maxX, maxY, maxZ)
  local ok, err = worldBoxCasters.set(index,
    minX, minY, minZ, maxX, maxY, maxZ)
  if ok then
    offscreenEnabled = true
    apply()
  end
  return ok, err
end

function M.captureOffscreenObject(name, replace)
  if replace == nil then replace = true end
  local ok, err = worldBoxCasters.captureObject(name, replace)
  if ok then
    offscreenEnabled = true
    apply()
  end
  return ok, err
end

function M.captureOffscreenNearby(radius)
  local ok, result = worldBoxCasters.captureNearby(radius)
  if ok then
    offscreenEnabled = true
    apply()
  end
  return ok, result
end

function M.getStatus()
  return {enabled = active, quality = quality, view = view, target = TARGET,
    hitModel = hitModel, refineSteps = modes[quality].refineSteps,
    steps = modes[quality].steps, distance = modes[quality].distance,
    traceObject = find(TRACE_FX) ~= nil, previewObject = find(PREVIEW_FX) ~= nil,
    compareTraceObject = find(COMPARE_FX) ~= nil,
    compareTraceEnabled = modelComparisonActive(),
    traceDiagnostic = currentTraceDiagnostic(),
    hybrid = {nativePolarity = hybrid.nativePolarity,
      minConfidence = hybrid.minConfidence,
      detailStrength = hybrid.detailStrength,
      diagnosticOnly = true},
    offscreen = {enabled = offscreenEnabled,
      meshEnabled = offscreenMeshEnabled,
      mesh = worldMeshCasters.getStatus(),
      sunDirection = offscreenSunDirection,
      probeActive = currentTraceDiagnostic() == 4,
      proxyCasters = worldBoxCasters.getStatus(),
      source = "static TSStatic world-space AABBs, not sun-view depth"},
    split = {enabled = split.enabled, position = split.position,
      kind = split.kind, left = split.left, right = split.right,
      modelLeft = split.modelLeft, modelRight = split.modelRight,
      modelView = split.modelView, lineWidth = split.lineWidth}}
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
  for _, name in ipairs({PREVIEW_FX, COMPARE_FX, TRACE_FX,
      PREVIEW_SHADER, TRACE_SHADER, STATE}) do
    local object = find(name)
    if object then object:delete() end
  end
  rawset(_G, TRACE_FX .. "Callbacks", nil)
  rawset(_G, COMPARE_FX .. "Callbacks", nil)
  rawset(_G, PREVIEW_FX .. "Callbacks", nil)
end

return M
