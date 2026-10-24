-- BeamNG 0.40 reuses the prepass material-specular attachment for native SSR
-- receivers after lighting. Late BeamRT consumers cannot treat it as F0 while
-- that path is active. Observe only: never toggle native rendering/settings.
local M = {}
local last = {safe = false, nativeSSR = 'unknown', reason = 'Renderer compatibility has not been checked.'}

local function copy(state)
  return {safe = state.safe, nativeSSR = state.nativeSSR, reason = state.reason}
end

local function result(state, reason)
  return {safe = state == 'off', nativeSSR = state, reason = reason}
end

function M.check()
  local settingOK, configured = pcall(function()
    if settings == nil or type(settings.getValue) ~= 'function' then error('missing settings API') end
    return settings.getValue('PostFXSSREnabled')
  end)
  local lookupOK, object = pcall(function()
    if scenetree == nil or type(scenetree.findObject) ~= 'function' then error('missing scene lookup API') end
    return scenetree.findObject('PostFxSSSRObject')
  end)
  if not lookupOK then
    return result('unknown', 'Native SSR object lookup is unavailable; late material buffers are not trusted.')
  end

  local actual
  if object ~= nil then
    local enabledOK, enabled = pcall(function()
      if type(object.isEnabled) ~= 'function' then error('missing native SSR state API') end
      return object:isEnabled()
    end)
    if not enabledOK or type(enabled) ~= 'boolean' then
      return result('unknown', 'Native SSR enabled state is unavailable; late material buffers are not trusted.')
    end
    actual = enabled
    if actual then
      return result('on', 'Native SSR is enabled and reuses the late material-specular buffer; affected BeamRT rendering is paused.')
    end
  end

  if not settingOK or type(configured) ~= 'boolean' then
    return result('unknown', 'Native SSR setting is unavailable or non-boolean; late material buffers are not trusted.')
  end
  if configured then
    return result('unknown', 'Native SSR is requested but not confirmed disabled; affected BeamRT rendering is paused.')
  end
  if actual == false then
    return result('off', 'Native SSR object and setting both report disabled.')
  end
  return result('off', 'Native SSR setting is disabled and no native SSR object exists.')
end

function M.update()
  local state = M.check()
  local changed = state.safe ~= last.safe or state.nativeSSR ~= last.nativeSSR or state.reason ~= last.reason
  last = copy(state)
  return changed, copy(last)
end

function M.getStatus()
  return copy(last)
end

return M
