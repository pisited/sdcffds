-- One-shot CPU sequence observation. No renderer objects or settings changed.
local M = {}
local observation
local lastReport

local function sample()
  local main = extensions and extensions.beamrt_main or beamrt_main
  if not main or type(main.getReflectionSamplingState) ~= 'function' then return nil end
  local ok, result = pcall(function()
    return {sampling = main.getReflectionSamplingState(),
      reconstruction = main.getReflectionReconstructionState(),
      hitAware = main.getReflectionHitState()}
  end)
  if ok and type(result) == 'table' and type(result.sampling) == 'table' then return result end
end

local function emit(message)
  if type(log) == 'function' then log('I', 'BeamRT.ReflectionSequence', message) end
end

function M.start()
  local initial = sample()
  if not initial then emit('Cannot observe: BeamRT sampling status unavailable.'); return false end
  observation = {elapsed = 0, observations = 0, advances = 0, unchanged = 0,
    resets = 0, frozenObservations = 0, start = initial, previous = initial,
    renderingChanged = false, gpuExecutionVerified = false}
  emit('Read-only sequence observation started for 3 seconds; leave camera still. No settings changed.')
  return true
end

function M.getReport() return lastReport end

function M.onPreRender(dtReal)
  if not observation then return end
  local current = sample()
  if not current then
    emit('Observation stopped: BeamRT status became unavailable.')
    observation = nil
    return
  end
  local state = observation
  state.observations = state.observations + 1
  local previousIndex = tonumber(state.previous.sampling.sampleIndex)
  local currentIndex = tonumber(current.sampling.sampleIndex)
  if previousIndex and currentIndex then
    if currentIndex == previousIndex then state.unchanged = state.unchanged + 1
    elseif currentIndex < previousIndex and not (previousIndex > 16777000 and currentIndex < 256) then
      state.resets = state.resets + 1
    else state.advances = state.advances + 1 end
  end
  if current.sampling.frozen then state.frozenObservations = state.frozenObservations + 1 end
  state.previous = current
  local delta = tonumber(dtReal)
  if not delta or delta ~= delta or delta <= 0 or delta == math.huge then delta = 1 / 60 end
  state.elapsed = state.elapsed + math.min(delta, 0.25)
  if state.elapsed < 3 then return end
  state.finish = current
  state.previous = nil
  lastReport, observation = state, nil
  local conclusion = 'CPU sequence advances; this does not verify GPU sampling or successful history reuse.'
  if state.finish.sampling.name ~= 'ggx' then conclusion = 'Not a GGX observation.'
  elseif state.frozenObservations > 0 then conclusion = 'Diagnostics/audit froze sampling during observation.'
  elseif state.advances == 0 then conclusion = 'CPU sample index did not advance; investigate pass execution/callback scheduling.'
  elseif state.resets > 0 then conclusion = 'CPU sequence reset during observation; investigate camera/history resets.' end
  state.conclusion = conclusion
  emit(string.format('Observed %d frames: advances=%d unchanged=%d resets=%d frozen=%d; start=%s finish=%s. %s',
    state.observations, state.advances, state.unchanged, state.resets, state.frozenObservations,
    tostring(state.start.sampling.sampleIndex), tostring(state.finish.sampling.sampleIndex), conclusion))
  if type(dumps) == 'function' then emit(dumps(state)) end
end

function M.onExtensionLoaded()
  if type(setExtensionUnloadMode) == 'function' then setExtensionUnloadMode(M, 'manual') end
  M.start()
end

function M.onExtensionUnloaded() observation = nil end
return M
