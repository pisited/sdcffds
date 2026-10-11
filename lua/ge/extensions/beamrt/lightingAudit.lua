-- Local, native-resolution captures. Only BeamRT state is changed or recorded.
local M = {}
local active, lastResult
local stages = {
  {name = "01-native", diagnostic = "off", native = true, warmup = 2.0},
  {name = "02-GI-beauty", diagnostic = "off", warmup = 1.5},
  {name = "03-raw-GI", diagnostic = "raw", warmup = 1.5},
  {name = "04-filtered-GI", diagnostic = "filtered", warmup = 1.5},
  {name = "05-visible-indirect", diagnostic = "contribution", warmup = 1.5},
  {name = "06-material-response", diagnostic = "receiver", warmup = 1.5},
}
local inputStages = {
  {name = "07-direct-light", diagnostic = "direct", warmup = 1.0},
  {name = "08-roughness", diagnostic = "roughness", warmup = 1.0},
  {name = "09-specular-f0", diagnostic = "f0", warmup = 1.0},
  {name = "10-reflectance-estimate", diagnostic = "reflectance", warmup = 1.0},
}
local reflectionStages = {
  {name = "01-native", reflectionDiagnostic = "off", native = true, warmup = 2.0},
  {name = "02-SSR-beauty", reflectionDiagnostic = "off", warmup = 1.5},
  {name = "03-receiver", reflectionDiagnostic = "receiver", warmup = 1.0},
  {name = "04-validity", reflectionDiagnostic = "validity", warmup = 1.0},
  {name = "05-hituv", reflectionDiagnostic = "hituv", warmup = 1.0},
  {name = "06-hitdepth", reflectionDiagnostic = "hitdepth", warmup = 1.0},
  {name = "07-rawcolor", reflectionDiagnostic = "rawcolor", warmup = 1.0},
  {name = "08-composite", reflectionDiagnostic = "composite", warmup = 1.0},
}

local function report(level, message)
  if log then log(level, "beamrt.lightingAudit", message) end
end

local function cameraState()
  if not core_camera then return nil end
  local p, q = core_camera.getPosition(), core_camera.getQuat()
  return {p.x, p.y, p.z, q.x, q.y, q.z, q.w, core_camera.getFovDeg()}
end

local function cameraMoved(original)
  if not original then return false end
  local now = cameraState()
  if not now then return false end
  local distance = 0
  for i = 1, 3 do distance = distance + (now[i] - original[i]) ^ 2 end
  local dot = 0
  for i = 4, 7 do dot = dot + now[i] * original[i] end
  return distance > 0.0004 or math.abs(dot) < 0.99999
    or math.abs(now[8] - original[8]) > 0.05
end

local function accumulation(main)
  if type(main.getProgressiveStatus) ~= "function" then return nil end
  local s = main.getProgressiveStatus()
  return {enabled = s.enabled, samples = s.samples, maxSamples = s.maxSamples,
    runtimeMode = s.runtimeMode, lastReset = s.lastReset}
end

local function checked(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then error(result, 0) end
  if result == false then error("BeamRT rejected an audit state change", 0) end
  return result
end

local function restore(main, run)
  local failures = {}
  local function attempt(name, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok or result == false then failures[#failures + 1] = name end
  end
  if type(main.setReflectionDiagnostic) == "function" then
    attempt("clear reflection diagnostic", main.setReflectionDiagnostic, "off", false)
  end
  attempt("settings", main.applySettings, run.saved.settings)
  attempt("diagnostic", main.setLightingDiagnostic, run.saved.state.diagnostic or "off")
  attempt("ray-hit diagnostic", main.setRayHitDiagnostic, run.saved.state.rayHitDiagnostic or "off")
  if run.saved.reflectionDiagnostic and type(main.restoreReflectionDiagnosticState) == "function" then
    attempt("reflection diagnostic", main.restoreReflectionDiagnosticState, run.saved.reflectionDiagnostic)
  end
  -- Restore mode after the diagnostic setter, which may select lighting mode.
  attempt("mode", main.setMode, run.saved.settings.mode)
  attempt("enabled", run.saved.state.enabled and main.enable or main.disable)
  attempt("tuner", run.saved.state.tunerOpen and main.openTuner or main.closeTuner)
  if #failures > 0 then
    report("E", "audit restoration failed for " .. table.concat(failures, ", "))
    return false
  end
  return true
end

local function writeManifest(run, outcome, reason)
  local manifest = {version = 1, beamrtVersion = run.saved.version,
    outcome = outcome, reason = reason, originalSettings = run.saved.settings,
    textureBindings = run.saved.textureBindings,
    originalState = {enabled = run.saved.state.enabled, tunerOpen = run.saved.state.tunerOpen,
      mode = run.saved.state.mode, reflectionsEnabled = run.saved.state.reflectionsEnabled,
      diagnostic = run.saved.state.diagnostic,
      rayHitDiagnostic = run.saved.state.rayHitDiagnostic,
      reflectionDiagnostic = run.saved.state.reflectionDiagnostic,
      reflectionDiagnosticMode = run.saved.state.reflectionDiagnosticMode},
    originalReflectionDiagnostic = run.saved.reflectionDiagnostic,
    originalReflectionSampling = run.saved.reflectionSampling,
    reflectionSamplingRestorePolicy = "Selected mode/settings restored; SSR history and sequence restart intentionally.",
    stages = run.captures,
    auditType = run.kind, restored = run.restored}
  local ok, result = pcall(jsonWriteFile, run.directory .. "/manifest.json", manifest, true)
  if not ok or result == false then report("E", "could not write local lighting audit manifest") end
end

local function finish(main, outcome, reason)
  local run = active
  if not run then return false end
  active = nil
  run.restored = restore(main, run)
  if not run.restored then outcome, reason = "error", "state restoration failed" end
  writeManifest(run, outcome, reason)
  lastResult = {active = false, outcome = outcome, reason = reason,
    directory = run.directory, captures = #run.captures, total = #run.stages,
    auditType = run.kind, restored = run.restored}
  report(outcome == "complete" and "I" or "W", run.kind .. " audit " .. outcome .. ": "
    .. run.directory .. (reason and (" (" .. reason .. ")") or ""))
  return true
end

local function setStage(main, run)
  local stage = run.stages[run.stage]
  if stage.native then
    checked(main.disable)
  elseif run.kind == "reflection" then
    if run.stage == 2 then
      checked(main.setMode, "reflections")
      checked(main.setReflectionsEnabled, false)
      checked(main.enable)
    end
    checked(main.setReflectionDiagnostic, stage.reflectionDiagnostic, false)
  elseif run.stage == 2 then
    checked(main.setMode, "lighting")
    checked(main.setReflectionsEnabled, false)
    checked(main.setLightingDiagnostic, stage.diagnostic)
    checked(main.enable)
  else
    checked(main.setLightingDiagnostic, stage.diagnostic)
  end
  run.phase, run.elapsed, run.pollElapsed, run.job = "warmup", 0, 0, nil
  report("I", run.kind .. " audit " .. stage.name)
end

function M.start(main, includeInputs)
  if active then return false, "lighting audit is already running" end
  local required = {"getSettings", "getVersion", "getLightingAuditState", "applySettings", "setMode",
    "setReflectionsEnabled", "setLightingDiagnostic", "setRayHitDiagnostic", "enable", "disable",
    "openTuner", "closeTuner"}
  if includeInputs == "reflection" then
    for _, name in ipairs({"setReflectionDiagnostic", "getReflectionDiagnosticState",
      "restoreReflectionDiagnosticState", "setReflectionTemporalBlend", "setReflectionDenoiseStrength",
      "resetReflectionHistory"}) do required[#required + 1] = name end
  end
  for _, name in ipairs(required) do
    if type(main[name]) ~= "function" then return false, "missing BeamRT audit API: " .. name end
  end
  local ok, api = pcall(require, "screenshot")
  if not ok or type(api.createScreenshotTracked) ~= "function"
    or type(api.getScreenshotJobsSnapshotJson) ~= "function" then
    return false, "native tracked screenshot API is unavailable"
  end
  local saved = {settings = main.getSettings(), state = main.getLightingAuditState(), version = main.getVersion()}
  if type(main.getReflectionDiagnosticState) == "function" then
    saved.reflectionDiagnostic = main.getReflectionDiagnosticState()
  end
  if type(main.getReflectionSamplingState) == "function" then
    saved.reflectionSampling = main.getReflectionSamplingState()
  end
  if type(main.getTextureBindingStatus) == "function" then
    saved.textureBindings = main.getTextureBindingStatus()
  end
  if type(saved.settings) ~= "table" or type(saved.state) ~= "table"
    or type(saved.state.enabled) ~= "boolean" or type(saved.state.tunerOpen) ~= "boolean" then
    return false, "BeamRT audit state cannot be saved reliably"
  end
  local base = "/screenshots/beamrt-audit/" .. os.date("%Y-%m-%d_%H-%M-%S")
  local directory, suffix = base, 0
  while FS:directoryExists(directory) do
    suffix = suffix + 1
    directory = base .. "_" .. suffix
  end
  -- A fresh installation has no beamrt-audit parent. BeamNG requires the
  -- recursive flag to create both that parent and the dated capture folder.
  -- The native return code is not a boolean; verify the resulting directory.
  FS:directoryCreate(directory, true)
  if not FS:directoryExists(directory) then
    return false, "could not create local audit directory: " .. tostring(FS:expandFilename(directory))
  end
  local selectedStages = {}
  if includeInputs == "reflection" then
    for _, stage in ipairs(reflectionStages) do selectedStages[#selectedStages + 1] = stage end
  else
    for index, stage in ipairs(stages) do
      if includeInputs ~= "compare" or index <= 2 then
        selectedStages[#selectedStages + 1] = stage
      end
    end
    if includeInputs == true then
      for _, stage in ipairs(inputStages) do selectedStages[#selectedStages + 1] = stage end
    end
  end
  active = {saved = saved, directory = directory, screenshot = api, stage = 1,
    stages = selectedStages, kind = includeInputs == "reflection" and "reflection" or "lighting",
    captures = {}, elapsed = 0, camera = cameraState()}
  local setupOk, err = pcall(function()
    checked(main.closeTuner)
    if type(main.setReflectionDiagnostic) == "function" then checked(main.setReflectionDiagnostic, "off", false) end
    checked(main.setRayHitDiagnostic, "off")
    if active.kind == "reflection" then
      checked(main.setLightingDiagnostic, "off")
      checked(main.setReflectionTemporalBlend, 1)
      checked(main.setReflectionDenoiseStrength, 0)
      checked(main.resetReflectionHistory)
    end
    setStage(main, active)
  end)
  if not setupOk then finish(main, "error", tostring(err)); return false, tostring(err) end
  report("I", "local " .. active.kind .. " audit started; keep the camera still until all "
    .. #active.stages .. " captures finish")
  return true, directory
end

function M.update(main, dtReal)
  local run = active
  if not run then return end
  local ok, err = pcall(function()
    if cameraMoved(run.camera) then error("camera moved; restart from a stationary view", 0) end
    local dt = math.max(0, tonumber(dtReal) or 0)
    run.elapsed = run.elapsed + dt
    if run.phase == "warmup" then
      if run.elapsed < run.stages[run.stage].warmup then return end
      local stage = run.stages[run.stage]
      local filename = FS:expandFilename(run.directory .. "/" .. stage.name)
      run.pending = {name = stage.name, diagnostic = stage.diagnostic,
        reflectionDiagnostic = stage.reflectionDiagnostic,
        filename = filename .. ".png", settings = main.getSettings(),
        accumulation = accumulation(main)}
      if type(main.getReflectionSamplingState) == "function" then
        run.pending.reflectionSampling = main.getReflectionSamplingState()
      end
      -- Direct tracked capture does not collect player/camera/system metadata.
      run.job = run.screenshot.createScreenshotTracked({filename = filename,
        writeJPG = false, superSampling = 1, tiles = 1, overlap = 0,
        rescaleFactor = 1, upload = false, jobType = "full", bufferType = "color",
        objectTypeWhitelistMask = 0, objectTypeBlacklistMask = 0,
        shadowCasterObjectTypeWhitelistMask = 0, shadowCasterObjectTypeBlacklistMask = 0})
      if not run.job or run.job == 0 then error("native screenshot job was rejected", 0) end
      run.phase, run.elapsed, run.pollElapsed = "saving", 0, 0
      return
    end
    if run.elapsed > 15 then error("native screenshot save timed out", 0) end
    run.pollElapsed = run.pollElapsed + dt
    if run.pollElapsed < 0.1 then return end
    run.pollElapsed = 0
    local jobs = jsonDecode(run.screenshot.getScreenshotJobsSnapshotJson())
    if type(jobs) ~= "table" then error("native screenshot job status is unavailable", 0) end
    for _, job in ipairs(jobs) do
      if job.id == run.job then
        if job.phase == "error" or (job.result ~= nil and job.result ~= 0) then
          error("native screenshot save failed", 0)
        end
        if job.phase ~= "done" or job.result ~= 0 then return end
        local filename = type(job.filename) == "string" and job.filename ~= ""
          and job.filename or run.pending.filename
        if not FS:fileExists(filename) then
          if not FS:fileExists(run.pending.filename) then return end
          filename = run.pending.filename
        end
        run.pending.filename = filename
        run.captures[#run.captures + 1] = run.pending
        run.pending = nil
        run.stage = run.stage + 1
        if run.stage > #run.stages then finish(main, "complete"); return end
        setStage(main, run)
        return
      end
    end
  end)
  if not ok then finish(main, "error", tostring(err)) end
end

function M.cancel(main, reason)
  return finish(main, "cancelled", reason or "cancelled")
end

function M.getStatus()
  if not active then return lastResult or {active = false} end
  return {active = true, stage = active.stages[active.stage].name, phase = active.phase,
    auditType = active.kind, directory = active.directory, captures = #active.captures, total = #active.stages}
end

return M
