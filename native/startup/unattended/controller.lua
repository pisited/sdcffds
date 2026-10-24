-- Inert, CPU-only state machine. Importing this module performs no game or I/O work.
-- All engine actions are explicit injected calls after one successful arm/claim.
local M = {}

local function finite(value)
  return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function integer(value, minimum, maximum)
  return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function hexadecimal(value, length)
  return type(value) == 'string' and #value == length and value:match('^[0-9a-f]+$') ~= nil
end

local function copy(value)
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end

function M.new(config, api)
  assert(type(config) == 'table' and type(api) == 'table', 'explicit configuration/API required')
  assert(hexadecimal(config.token, 32), '32 lowercase hex token required')
  assert(integer(config.expectedPid, 1, 4294967295), 'explicit owned expectedPid required')
  assert(config.expectedLevel == 'west_coast_usa', 'only the reviewed West Coast USA level is supported')
  for _, name in ipairs({'now', 'claim', 'sample', 'startGI', 'pollAck', 'emit', 'requestQuit'}) do
    assert(type(api[name]) == 'function', 'missing API: ' .. name)
  end
  assert(api.pollOwnerStop == nil or type(api.pollOwnerStop) == 'function', 'invalid owner-stop API')
  local limits = {
    loadTimeout = {1, 300}, captureTimeout = {1, 120}, overallTimeout = {1, 480},
    stableSeconds = {0.1, 5}, stableFrames = {2, 60}, quitGrace = {1, 30}
  }
  local settings = {token = config.token, expectedPid = config.expectedPid, expectedLevel = config.expectedLevel}
  for name, range in pairs(limits) do
    local value = config[name]
    assert(finite(value) and value >= range[1] and value <= range[2], 'invalid bounded setting: ' .. name)
    if name == 'stableFrames' then assert(value % 1 == 0, 'integral stableFrames required') end
    settings[name] = value
  end
  local state = {
    phase = 'unarmed', reason = '', armed = false, giStartCalls = 0, giConfirmed = false,
    receiptValidated = false, receiptPid = 0, receiptDigest = '', quitRequested = false,
    quitCalls = 0, quitCallReturned = false, quitCallError = false,
    processExitVerified = false, auditFailed = false, missionCount = 0,
    reentrancyObserved = false, lastTime = 0
  }
  local controller = {}
  local busy, pendingFailure = false, nil
  local beganAt, giAt, quitAt, stableAt, stableRender, lastRender

  local function emit(event)
    local ok, result = pcall(api.emit, event, copy(state))
    if not ok or result == false then
      state.auditFailed = true
      pendingFailure = pendingFailure or 'event_write_failed'
      return false
    end
    return true
  end

  local function stop(reason)
    if not state.armed or state.quitRequested then return false end
    state.phase, state.reason = 'quit_requested', reason
    state.quitRequested, state.quitCalls, quitAt = true, 1, state.lastTime
    emit('quit_requested')
    local ok, result = pcall(api.requestQuit)
    state.quitCallReturned = ok and result ~= false
    state.quitCallError = not ok or result == false
    -- A returned quit call, including nil, is only a request; never an OS exit receipt.
    emit(state.quitCallReturned and 'quit_call_returned' or 'quit_call_failed')
    return false
  end

  local function clock()
    local ok, value = pcall(api.now)
    if not ok or not finite(value) or value < 0 then return nil, 'invalid_clock' end
    if state.armed and value < state.lastTime then return nil, 'clock_regressed' end
    state.lastTime = value
    return value
  end

  local function guarded(action)
    if busy then
      state.reentrancyObserved = true
      pendingFailure = pendingFailure or 'reentrant_callback'
      return false
    end
    busy = true
    local ok, result = pcall(action)
    if not ok then
      if state.armed then stop('controller_error') else state.phase, state.reason = 'rejected', 'controller_error' end
    end
    if pendingFailure and state.armed and not state.quitRequested then stop(pendingFailure); result = false end
    pendingFailure = nil
    busy = false
    return ok and result or false
  end

  function controller.arm(token)
    return guarded(function()
      if state.phase ~= 'unarmed' then
        if state.armed then stop('rearm_refused') end
        return false
      end
      if token ~= settings.token then state.phase, state.reason = 'rejected', 'arm_token_mismatch'; return false end
      local now, reason = clock()
      if not now then state.phase, state.reason = 'rejected', reason; return false end
      if pendingFailure then state.phase, state.reason = 'rejected', pendingFailure; return false end
      local ok, granted = pcall(api.claim, token)
      if not ok or granted ~= true then state.phase, state.reason = 'rejected', 'claim_refused'; return false end
      state.armed, state.phase, beganAt = true, 'waiting_ready', now
      emit('armed')
      return true
    end)
  end

  function controller.missionStarted()
    return guarded(function()
      if not state.armed or state.quitRequested then return false end
      state.missionCount = state.missionCount + 1
      if state.missionCount ~= 1 then return stop('multiple_missions') end
      emit('mission_started')
      return true
    end)
  end

  function controller.missionEnded()
    return guarded(function() return stop('mission_ended') end)
  end

  function controller.abort(reason)
    return guarded(function()
      local safe = type(reason) == 'string' and #reason <= 64 and reason:match('^[a-z0-9_]+$')
      return stop(safe and reason or 'external_abort')
    end)
  end

  local function acknowledgement(value)
    if type(value) ~= 'table' or value.token ~= settings.token
        or (value.kind ~= 'receipt_validated' and value.kind ~= 'host_refused')
        or not integer(value.expectedPid, 1, 4294967295) or value.expectedPid ~= settings.expectedPid or value.resourceABI ~= 7
        or value.profile ~= 2 or value.mode ~= 1 or value.cbvProbeBytes ~= 0
        or not hexadecimal(value.digest, 64) then return false end
    local allowed = {token=true, kind=true, expectedPid=true, resourceABI=true, profile=true,
      mode=true, cbvProbeBytes=true, digest=true}
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
  end

  function controller.update()
    return guarded(function()
      if not state.armed or state.phase == 'quit_unconfirmed' then return false end
      local now, reason = clock()
      if not now then
        if state.quitRequested then state.phase = 'quit_unconfirmed'; emit('quit_unconfirmed'); return false end
        return stop(reason)
      end
      if pendingFailure then return stop(pendingFailure) end
      if state.quitRequested then
        if now - quitAt >= settings.quitGrace then state.phase = 'quit_unconfirmed'; emit('quit_unconfirmed') end
        return false
      end
      -- Runs inside the same reentrancy guard, before readiness/GI actions. The
      -- adapter polls only this claimed run's token/PID-bound normal-stop file.
      -- A request is never OS exit evidence and does not itself authorize force.
      if api.pollOwnerStop then
        local polled, requested = pcall(api.pollOwnerStop)
        if pendingFailure then return stop(pendingFailure) end
        if not polled or type(requested) ~= 'boolean' then return stop('owner_stop_invalid') end
        if requested then return stop('owner_shutdown_requested') end
      end
      if now - beganAt >= settings.overallTimeout then return stop('overall_timeout') end
      if not giAt and now - beganAt >= settings.loadTimeout then return stop('load_timeout') end
      if giAt and now - giAt >= settings.captureTimeout then return stop('capture_timeout') end
      local ok, sample = pcall(api.sample)
      if not ok then return stop('sample_error') end
      if pendingFailure then return stop(pendingFailure) end
      if type(sample) ~= 'table' or type(sample.level) ~= 'string' or #sample.level > 128
          or type(sample.missionStarted) ~= 'boolean' or type(sample.modReady) ~= 'boolean'
          or type(sample.loading) ~= 'boolean' or type(sample.freeroam) ~= 'boolean'
          or not integer(sample.worldReadyState, -1, 2)
          or not integer(sample.renderFrames, 0, 9007199254740991)
          or type(sample.giEnabled) ~= 'boolean' or type(sample.giMode) ~= 'string' or #sample.giMode > 64 then
        return stop('invalid_sample')
      end
      if sample.level ~= '' and sample.level ~= settings.expectedLevel then return stop('unexpected_level') end
      if lastRender and sample.renderFrames < lastRender then return stop('render_counter_regressed') end
      lastRender = sample.renderFrames
      local ready = sample.level == settings.expectedLevel and sample.missionStarted and state.missionCount == 1
          and sample.modReady and not sample.loading and sample.freeroam and sample.worldReadyState == 2
      if not giAt then
        if not ready then stableAt, stableRender = nil, nil; return true end
        if not stableAt then stableAt, stableRender = now, sample.renderFrames end
        if now - stableAt < settings.stableSeconds or sample.renderFrames - stableRender < settings.stableFrames then return true end
        state.phase, giAt = 'starting_gi', now
        if not emit('gi_start_requested') then return stop('event_write_failed') end
        if pendingFailure then return stop(pendingFailure) end
        state.giStartCalls = 1
        local started, result = pcall(api.startGI)
        if pendingFailure then return stop(pendingFailure) end
        if not started or result ~= true then return stop('gi_start_failed') end
        return true
      end
      if not ready then return stop('readiness_lost') end
      if not state.giConfirmed then
        if not sample.giEnabled or sample.giMode ~= 'lighting' then
          if now - giAt >= math.min(10, settings.captureTimeout) then return stop('gi_not_enabled') end
          return true
        end
        state.giConfirmed, state.phase = true, 'waiting_receipt'
        if not emit('gi_state_confirmed') then return stop('event_write_failed') end
        if pendingFailure then return stop(pendingFailure) end
      elseif not sample.giEnabled or sample.giMode ~= 'lighting' then return stop('gi_state_changed') end
      local read, ack = pcall(api.pollAck)
      if not read then return stop('ack_read_error') end
      if pendingFailure then return stop(pendingFailure) end
      if ack == nil then return true end
      if not acknowledgement(ack) then return stop('invalid_ack') end
      state.receiptValidated = ack.kind == 'receipt_validated'
      state.receiptPid, state.receiptDigest = ack.expectedPid, ack.digest
      -- Even a validated numeric receipt is not a resource lease or lighting result.
      return stop(ack.kind)
    end)
  end

  function controller.status() return copy(state) end
  return controller
end

return M
