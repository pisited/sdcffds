-- Inert early-engine hook factory. An explicit reviewed queued-Lua caller must
-- construct and arm it. No import/new side effects, GI calls, or direct quit.
local M = {}

local function finite(value)
  return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function copy(value)
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end

local function sourcePath(value)
  assert(type(value) == 'string' and #value <= 2048, 'invalid_bootstrap_source')
  local path = value:gsub('\\', '/')
  assert(path:match('^[A-Za-z]:/') and not path:find('[%z\1-\31<>"|?*]')
    and not path:sub(3):find(':', 1, true) and not path:find('//', 1, true), 'invalid_bootstrap_source')
  for component in path:sub(4):gmatch('[^/]+') do
    assert(component ~= '.' and component ~= '..' and not component:match('[ .]$'), 'invalid_bootstrap_source')
    local stem = component:match('^([^.]*)'):upper()
    assert(stem ~= 'CON' and stem ~= 'PRN' and stem ~= 'AUX' and stem ~= 'NUL'
      and not stem:match('^COM[1-9]$') and not stem:match('^LPT[1-9]$'), 'invalid_bootstrap_source')
  end
  assert(path:sub(-14) == '/bootstrap.lua', 'unexpected_bootstrap_source')
  return path
end

function M.new(config, environment)
  assert(type(config) == 'table' and type(config.bootstrap) == 'table'
    and type(config.bootstrap.controller) == 'table' and type(environment) == 'table', 'explicit_configuration_required')
  local token = config.bootstrap.controller.token
  assert(type(token) == 'string' and #token == 32 and token:match('^[0-9a-f]+$'), 'invalid_run_token')
  assert(config.bootstrap.controller.expectedLevel == 'west_coast_usa', 'invalid_expected_level')
  assert(finite(config.timeout) and config.timeout >= 1 and config.timeout <= 30, 'invalid_shim_timeout')
  local timeout, path, env = config.timeout, sourcePath(config.bootstrapSourcePath), environment
  local settings = copy(config.bootstrap)
  settings.controller = copy(config.bootstrap.controller)
  local state = {phase='unarmed', reason='', armed=false, bootstrapLoads=0, bootstrapCalls=0,
    bootstrapInstalled=false, claimed=false, reentrancyObserved=false, lastTime=0}
  local shim, proxy, hooks, run = {}, nil, nil, nil
  local busy, pending, beganAt = false, nil, nil

  local function fail(reason)
    if state.phase == 'failed' or state.phase == 'rejected' then return false end
    state.phase, state.reason = state.armed and 'failed' or 'rejected', reason
    -- Only a returned, armed controller can request a normal owned-run quit.
    -- Bootstrap handles any failure after its own claim but before return.
    if state.claimed and run then pcall(run.controller.abort, reason) end
    return false
  end

  local function guarded(action)
    if busy then
      state.reentrancyObserved, pending = true, pending or 'early_shim_reentrant'
      return false
    end
    busy = true
    local ok, result = pcall(action)
    if not ok then result = fail('early_shim_error') end
    if pending then result = fail(pending); pending = nil end
    busy = false
    return ok and result or false
  end

  local function clock()
    if type(env.os) ~= 'table' or type(env.os.clockhp) ~= 'function' then return nil end
    local ok, value = pcall(env.os.clockhp)
    if not ok or not finite(value) or value < 0 or (state.armed and value < state.lastTime) then return nil end
    state.lastTime = value
    return value
  end

  local function beforeMission()
    if type(env.getMissionFilename) ~= 'function' then return false end
    local ok, filename = pcall(env.getMissionFilename)
    if not ok or filename ~= '' then return false end
    -- The installed engine initializes -1 and switches to 0 at mission prestart.
    -- Never recover by inferring that an already-loading world is a fresh run.
    return env.worldReadyState == nil or env.worldReadyState == -1
  end

  local function available()
    return type(env.dofile) == 'function' and type(env.io) == 'table' and type(env.io.open) == 'function'
      and type(env.jsonDecode) == 'function' and type(env.jsonEncode) == 'function'
      and type(env.Engine) == 'table' and type(env.Engine.getStartingArgs) == 'function'
      and type(env.newExtensionProxy) == 'function' and type(env.setExtensionUnloadMode) == 'function'
      and type(env.quit) == 'function'
      and type(env.core_levels) == 'table' and type(env.core_levels.getLevelName) == 'function'
      and type(env.core_modmanager) == 'table' and type(env.core_modmanager.isReady) == 'function'
      and type(env.core_gamestate) == 'table' and type(env.core_gamestate.loading) == 'function'
      and type(env.core_gamestate.getGameState) == 'function'
      and (env.beamrt_main == nil and type(env.extensions) == 'table' and type(env.extensions.load) == 'function'
        or type(env.beamrt_main) == 'table' and type(env.beamrt_main.start) == 'function'
          and type(env.beamrt_main.getLightingAuditState) == 'function')
  end

  local function inspectRun(value)
    if type(value) ~= 'table' or type(value.controller) ~= 'table'
      or type(value.controller.abort) ~= 'function' or type(value.controller.status) ~= 'function' then return false end
    run = value -- Keep ownership-capable references even if later validation fails.
    local ok, status = pcall(run.controller.status)
    state.claimed = ok and type(status) == 'table' and status.armed == true
    if not state.claimed then return false end
    return type(value.hooks) == 'table' and type(value.proxy) == 'table' and type(value.runtime) == 'table'
  end

  local function attemptBootstrap()
      if state.phase ~= 'waiting_api' then return false end
      local function withinDeadline()
        local now = clock()
        if not now then return fail('early_clock_invalid') end
        if pending then return fail(pending) end
        if now - beganAt >= timeout then return fail('early_api_timeout') end
        return true
      end
      if not withinDeadline() then return false end
      if not beforeMission() then return fail('early_mission_already_started') end
      if pending then return fail(pending) end
      if not available() then return true end
      state.phase, state.bootstrapLoads = 'bootstrapping', 1
      local loaded, bootstrap = pcall(env.dofile, path)
      if not loaded or type(bootstrap) ~= 'function' then return fail('early_bootstrap_load_failed') end
      if pending then return fail(pending) end
      if not withinDeadline() then return false end
      if not beforeMission() then return fail('early_mission_already_started') end
      if pending then return fail(pending) end
      state.bootstrapCalls = 1
      local invoked, result = pcall(bootstrap, settings, env)
      local valid = invoked and inspectRun(result)
      if pending then return fail(pending) end
      if not valid then return fail('early_bootstrap_refused') end
      if not withinDeadline() then return false end
      if not beforeMission() then return fail('early_mission_already_started') end
      if pending then return fail(pending) end
      state.phase, state.bootstrapInstalled = 'handed_off', true
      -- The bootstrap registered its own virtual hooks. This proxy is passive
      -- after handoff so mission/update/render events are delivered only once.
      return true
  end

  function shim.update()
    return guarded(attemptBootstrap)
  end

  function shim.arm(requestedToken)
    return guarded(function()
      if state.phase ~= 'unarmed' then return fail('early_rearm_refused') end
      if requestedToken ~= token then return fail('early_token_mismatch') end
      local now = clock()
      if not now then return fail('early_clock_invalid') end
      if pending then return fail(pending) end
      if not beforeMission() then return fail('early_mission_already_started') end
      if pending then return fail(pending) end
      if type(env.newExtensionProxy) ~= 'function' or type(env.setExtensionUnloadMode) ~= 'function' then
        return fail('early_proxy_unavailable')
      end
      local created, value = pcall(env.newExtensionProxy, nil, 'beamrtEarlyUnattended')
      if not created or type(value) ~= 'table' or type(value.submitEventSinks) ~= 'function'
          or type(value.extName) ~= 'string' or #value.extName > 128
          or not value.extName:match('^beamrtEarlyUnattended_virtual_%d+$') then
        return fail('early_proxy_invalid')
      end
      proxy = value
      hooks = {
        onUpdate=function() return shim.update() end,
        onClientStartMission=function()
          if state.phase == 'handed_off' or state.phase == 'failed' or state.phase == 'rejected' then return false end
          return guarded(function() return fail('early_mission_event') end)
        end,
        onClientEndMission=function()
          if state.phase == 'handed_off' or state.phase == 'failed' or state.phase == 'rejected' then return false end
          return guarded(function() return fail('early_mission_ended') end)
        end,
        onSerialize=function()
          guarded(function() return fail('early_serialization_refused') end); return nil
        end,
        onDeserialized=function() return guarded(function() return fail('early_deserialization_refused') end) end
      }
      state.armed, state.phase, beganAt = true, 'waiting_api', now
      local installed, result = pcall(proxy.submitEventSinks, proxy, {hooks})
      if not installed or result == false then return fail('early_hook_install_failed') end
      if pending then return fail(pending) end
      -- __manuallyLoaded__ on a virtual proxy is not an unload exception. The
      -- installed freeroam loader drops every name absent from this in-memory
      -- manual-unload list; no persistent settings or active files are changed.
      local retained, modeResult = pcall(env.setExtensionUnloadMode, proxy.extName, 'manual')
      if not retained or modeResult == false then return fail('early_proxy_retention_failed') end
      if pending then return fail(pending) end
      -- A stock -level may begin loading before the first update. Explicit arm
      -- therefore attempts immediately when APIs are ready instead of adding an
      -- avoidable frame of delay. Queue drain ordering is still not guaranteed.
      return attemptBootstrap()
    end)
  end

  function shim.status() return copy(state) end
  function shim.retainedRun() return run end
  function shim.retainedProxy() return proxy end
  return shim
end

return M
