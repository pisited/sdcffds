-- Inert engine adapter factory. Import/new do not read files, install hooks, or start GI.
-- The explicit caller supplies a fresh, reviewed physical run directory. This is not
-- a general launcher, ownership proof, atomic claim, or permission source.
local M = {}
local SCOPE = 'beamrt-unattended-observation-v1'
local MAX_JSON = 4096

local function integer(value, low, high)
  return type(value) == 'number' and value == value and value % 1 == 0 and value >= low and value <= high
end

local function hex(value, count)
  return type(value) == 'string' and #value == count and value:match('^[0-9a-f]+$') ~= nil
end

local function absoluteDirectory(value)
  assert(type(value) == 'string' and #value <= 1024, 'invalid_run_directory')
  local path = value:gsub('\\', '/')
  assert(path:match('^[A-Za-z]:/') and not path:find('[%z\1-\31<>"|?*]')
    and not path:sub(3):find(':', 1, true) and not path:find('//', 1, true), 'invalid_run_directory')
  path = path:gsub('/$', '')
  assert(#path > 3, 'invalid_run_directory')
  for component in path:sub(4):gmatch('[^/]+') do
    assert(component ~= '.' and component ~= '..' and not component:match('[ .]$'), 'invalid_run_directory')
    local stem = component:match('^([^.]*)'):upper()
    assert(stem ~= 'CON' and stem ~= 'PRN' and stem ~= 'AUX' and stem ~= 'NUL'
      and not stem:match('^COM[1-9]$') and not stem:match('^LPT[1-9]$'), 'invalid_run_directory')
  end
  return path
end

local function exactKeys(value, names)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not names[key] then return false end end
  return true
end

function M.new(config, environment)
  assert(type(config) == 'table' and type(config.controller) == 'table', 'explicit_configuration_required')
  local env = environment or _G
  assert(type(env) == 'table', 'explicit_environment_required')
  local token = config.controller.token
  assert(hex(token, 32) and config.controller.expectedLevel == 'west_coast_usa', 'invalid_run_identity')
  local directory = absoluteDirectory(config.runDirectory)
  local paths = {
    approval = directory .. '/launch-approval.json', process = directory .. '/process-context.json',
    started = directory .. '/started.json', ack = directory .. '/driver-ack.json',
    events = directory .. '/unattended-events.jsonl', stop = directory .. '/owner-stop.json'
  }
  local runtime = {api = {}, expectedPid = nil}
  local claimed, bound, giCalled, loadCalled, quitCalled = false, false, false, false, false
  local mission, renderFrames, eventCount, eventBytes = false, 0, 0, 0

  local function open(path, mode)
    assert(type(env.io) == 'table' and type(env.io.open) == 'function', 'io_unavailable')
    return env.io.open(path, mode)
  end

  local function read(path, allowMissing)
    local handle, _, code = open(path, 'rb')
    if not handle then
      if allowMissing and code == 2 then return nil end
      error('file_read_failed', 0)
    end
    local ok, result = pcall(function() return handle:read(MAX_JSON + 1) end)
    local closed, closeResult = pcall(function() return handle:close() end)
    assert(ok and closed and closeResult and type(result) == 'string' and #result <= MAX_JSON,
      'file_read_failed')
    return result
  end

  local function absent(path)
    local handle, _, code = open(path, 'rb')
    if handle then
      pcall(function() handle:close() end)
      return false
    end
    assert(code == 2, 'absence_not_proven')
    return true
  end

  local function decode(bytes)
    assert(type(env.jsonDecode) == 'function', 'json_decoder_unavailable')
    local ok, value = pcall(env.jsonDecode, bytes)
    assert(ok and type(value) == 'table', 'invalid_json')
    return value
  end

  local function startingArguments()
    assert(type(env.Engine) == 'table' and type(env.Engine.getStartingArgs) == 'function', 'starting_args_unavailable')
    local args = env.Engine.getStartingArgs()
    assert(type(args) == 'table', 'invalid_starting_args')
    local ordered = {}
    for index, value in pairs(args) do
      assert(integer(index, 0, 511) and type(value) == 'string' and #value <= 8192, 'invalid_starting_args')
      ordered[#ordered + 1] = index
    end
    assert(#ordered > 0, 'invalid_starting_args')
    table.sort(ordered)
    assert(ordered[1] == 0 or ordered[1] == 1, 'invalid_starting_args')
    local levels, tokens = 0, 0
    for ordinal, index in ipairs(ordered) do
      assert(index == ordered[1] + ordinal - 1, 'invalid_starting_args')
      local value = args[index]
      local lower = value:lower()
      if lower == '-level' then
        assert(value == '-level' and args[index + 1] == 'west_coast_usa', 'invalid_level_argument')
        levels = levels + 1
      elseif lower == '-beamrtobservationtoken' then
        assert(value == '-beamrtObservationToken' and args[index + 1] == token, 'invalid_token_argument')
        tokens = tokens + 1
      else
        assert(not lower:match('^%-level=') and not lower:match('^%-beamrtobservationtoken='), 'invalid_bound_argument')
      end
    end
    assert(levels == 1 and tokens == 1, 'missing_or_duplicate_bound_argument')
  end

  function runtime.validateContext()
    local ok, reason = pcall(function()
      startingArguments()
      local approval = decode(read(paths.approval, false))
      assert(exactKeys(approval, {token=true, scope=true, allow=true}) and approval.token == token
        and approval.scope == SCOPE and approval.allow == true, 'approval_refused')
      local context = decode(read(paths.process, false))
      assert(exactKeys(context, {token=true, expectedPid=true}) and context.token == token
        and integer(context.expectedPid, 1, 4294967295), 'process_context_refused')
      assert(runtime.expectedPid == nil or runtime.expectedPid == context.expectedPid, 'process_context_changed')
      assert(absent(paths.started), 'run_already_started')
      assert(absent(paths.ack), 'run_ack_already_present')
      assert(absent(paths.events), 'run_events_already_present')
      assert(absent(paths.stop), 'run_stop_already_present')
      runtime.expectedPid = context.expectedPid
    end)
    if not ok then return nil, tostring(reason) end
    return true
  end

  function runtime.api.now()
    assert(type(env.os) == 'table' and type(env.os.clockhp) == 'function', 'monotonic_clock_unavailable')
    return env.os.clockhp()
  end

  function runtime.api.claim(requestedToken)
    if claimed or requestedToken ~= token then return false end
    if not runtime.validateContext() then return false end
    -- Lua io.open/write/close has no portable create-new or fsync primitive. The
    -- owning host must serialize bootstrap calls; this persistent marker is a
    -- best-effort replay guard, not an atomic or crash-durable ownership claim.
    local marker = '{"token":"' .. token .. '","scope":"' .. SCOPE
      .. '","expectedPid":' .. tostring(runtime.expectedPid) .. '}\n'
    local handle = open(paths.started, 'wb')
    if not handle then return false end
    local wrote, result = pcall(function() return handle:write(marker) end)
    local closed, closeResult = pcall(function() return handle:close() end)
    if not wrote or not result or not closed or not closeResult then return false end
    if read(paths.started, false) ~= marker then return false end
    claimed = true
    return true
  end

  function runtime.api.sample()
    assert(claimed, 'run_not_claimed')
    assert(type(env.getMissionFilename) == 'function' and type(env.core_levels) == 'table'
      and type(env.core_levels.getLevelName) == 'function', 'level_api_unavailable')
    assert(type(env.core_modmanager) == 'table' and type(env.core_modmanager.isReady) == 'function', 'mod_api_unavailable')
    assert(type(env.core_gamestate) == 'table' and type(env.core_gamestate.loading) == 'function'
      and type(env.core_gamestate.getGameState) == 'function', 'game_state_api_unavailable')
    local filename = env.getMissionFilename()
    assert(type(filename) == 'string', 'invalid_mission_filename')
    local level = filename == '' and '' or env.core_levels.getLevelName(filename)
    assert(type(level) == 'string', 'invalid_level_name')
    local ready, loading, state = env.core_modmanager.isReady(), env.core_gamestate.loading(), env.core_gamestate.getGameState()
    assert(type(ready) == 'boolean' and type(loading) == 'boolean' and type(state) == 'table'
      and (state.state == nil or type(state.state) == 'string'), 'invalid_readiness_state')
    assert(integer(env.worldReadyState, -1, 2), 'invalid_world_ready_state')
    local giEnabled, giMode = false, ''
    local beamrt = env.beamrt_main
    if beamrt ~= nil then
      assert(type(beamrt) == 'table' and type(beamrt.getLightingAuditState) == 'function', 'gi_state_api_unavailable')
      local audit = beamrt.getLightingAuditState()
      assert(type(audit) == 'table' and type(audit.enabled) == 'boolean' and type(audit.mode) == 'string', 'invalid_gi_state')
      giEnabled, giMode = audit.enabled, audit.mode
    end
    return {level=level, missionStarted=mission, modReady=ready, loading=loading,
      freeroam=state.state == 'freeroam', worldReadyState=env.worldReadyState,
      renderFrames=renderFrames, giEnabled=giEnabled, giMode=giMode}
  end

  function runtime.api.startGI()
    if not claimed or giCalled then return false end
    giCalled = true
    if env.beamrt_main == nil then
      if loadCalled then return false end
      loadCalled = true
      assert(type(env.extensions) == 'table' and type(env.extensions.load) == 'function', 'extension_loader_unavailable')
      env.extensions.load('beamrt/main')
    end
    assert(type(env.beamrt_main) == 'table' and type(env.beamrt_main.start) == 'function', 'gi_start_api_unavailable')
    return env.beamrt_main.start() == true
  end

  function runtime.api.pollAck()
    assert(claimed, 'run_not_claimed')
    local bytes = read(paths.ack, true)
    if bytes == nil then return nil end
    local ack = decode(bytes)
    assert(exactKeys(ack, {token=true, kind=true, expectedPid=true, resourceABI=true, profile=true,
      mode=true, cbvProbeBytes=true, digest=true}) and ack.token == token
      and (ack.kind == 'receipt_validated' or ack.kind == 'host_refused')
      and ack.expectedPid == runtime.expectedPid and ack.resourceABI == 7 and ack.profile == 2
      and ack.mode == 1 and ack.cbvProbeBytes == 0 and hex(ack.digest, 64), 'ack_refused')
    return ack
  end

  function runtime.api.pollOwnerStop()
    assert(claimed, 'run_not_claimed')
    local bytes = read(paths.stop, true)
    if bytes == nil then return false end
    local request = decode(bytes)
    assert(exactKeys(request, {token=true, expectedPid=true, kind=true}) and request.token == token
      and integer(request.expectedPid, 1, 4294967295) and request.expectedPid == runtime.expectedPid
      and request.kind == 'normal_quit_requested', 'owner_stop_refused')
    return true -- A normal engine quit request only, never a forced-close action.
  end

  function runtime.api.emit(event, status)
    if not claimed or eventCount >= 64 or type(event) ~= 'string' or #event > 64
        or not event:match('^[a-z0-9_]+$') or type(status) ~= 'table' then return false end
    assert(type(env.jsonEncode) == 'function', 'json_encoder_unavailable')
    local safeStatus, fields = {}, 0
    for key, value in pairs(status) do
      fields = fields + 1
      if fields > 48 or type(key) ~= 'string' or #key > 64 then return false end
      if type(value) == 'string' then
        if #value > 256 then return false end
      elseif type(value) == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return false end
      elseif type(value) ~= 'boolean' then return false end
      safeStatus[key] = value
    end
    local bytes = env.jsonEncode({token=token, expectedPid=runtime.expectedPid, event=event, status=safeStatus})
    if type(bytes) ~= 'string' or #bytes > 8192 or eventBytes + #bytes + 1 > 131072 then return false end
    local handle = open(paths.events, 'ab')
    if not handle then return false end
    local wrote, result = pcall(function() return handle:write(bytes .. '\n') end)
    local closed, closeResult = pcall(function() return handle:close() end)
    if not wrote or not result or not closed or not closeResult then return false end
    eventCount, eventBytes = eventCount + 1, eventBytes + #bytes + 1
    return true
  end

  function runtime.api.requestQuit()
    if not claimed or quitCalled then return false end
    quitCalled = true
    assert(type(env.quit) == 'function', 'quit_api_unavailable')
    env.quit()
    return true -- request only; the external owner must prove OS process exit.
  end

  function runtime.bind(controller)
    assert(not bound and type(controller) == 'table', 'hooks_already_bound')
    for _, name in ipairs({'update', 'missionStarted', 'missionEnded', 'abort'}) do
      assert(type(controller[name]) == 'function', 'invalid_controller')
    end
    bound = true
    local function guarded(name, ...)
      local ok, result = pcall(controller[name], ...)
      if not ok then pcall(controller.abort, 'engine_hook_error'); return false end
      return result
    end
    return {
      onUpdate=function() return guarded('update') end,
      onPreRender=function()
        if renderFrames >= 9007199254740991 then return guarded('abort', 'render_counter_overflow') end
        renderFrames = renderFrames + 1
      end,
      onClientStartMission=function() mission = true; return guarded('missionStarted') end,
      onClientEndMission=function() mission = false; return guarded('missionEnded') end,
      onSerialize=function() guarded('abort', 'serialization_refused'); return nil end,
      onDeserialized=function() return guarded('abort', 'deserialization_refused') end
    }
  end

  return runtime
end

return M
