local M = {}

local providers = {
  decalRoads = require("ge/extensions/beamrt/providers/decalRoadProvider"),
  vehicles = require("ge/extensions/beamrt/providers/vehicleProvider"),
  forest = require("ge/extensions/beamrt/providers/forestProvider"),
  tsStatic = require("ge/extensions/beamrt/providers/tsStaticProvider"),
  terrain = require("ge/extensions/beamrt/providers/terrainProvider"),
  lights = require("ge/extensions/beamrt/providers/lightProvider"),
  materials = require("ge/extensions/beamrt/providers/materialProvider"),
}

local pendingLevelBuilds = {}
local lastError = nil
local providerErrors = {}

local function logMessage(level, message)
  if type(log) == "function" then log(level, "BeamRT.SceneDB", message) end
end

function M.getProvider(name)
  return providers[name]
end

function M.registerProvider(name, provider)
  if type(name) ~= "string" or type(provider) ~= "table" then return false end
  providers[name] = provider
  return true
end

function M.invalidate(reason)
  pendingLevelBuilds = {}
  providerErrors = {}
  lastError = nil
  for _, provider in pairs(providers) do
    if type(provider.invalidate) == "function" then
      local ok, err = pcall(provider.invalidate, reason)
      if not ok then logMessage("E", "provider invalidation failed: " .. tostring(err)) end
    end
  end
end

function M.scheduleLevelBuild(delayFrames)
  local firstFrame = math.max(1, math.floor(tonumber(delayFrames) or 120))
  -- Acquisition-only snapshots are staggered to avoid stacking map-scale work
  -- in one update. Vehicle and Forest data remain explicit: vehicle buffers are
  -- large/live-deforming, while Forest spatial-query arguments remain unverified.
  pendingLevelBuilds = {
    {frames = firstFrame, name = "decalRoads"},
    {frames = firstFrame + 15, name = "terrain"},
    {frames = firstFrame + 30, name = "lights"},
    {frames = firstFrame + 45, name = "tsStatic"},
  }
  return pendingLevelBuilds
end

function M.rebuild(providerName, options)
  local provider = providers[providerName]
  if not provider or type(provider.rebuild) ~= "function" then
    lastError = "provider '" .. tostring(providerName) .. "' cannot rebuild"
    providerErrors[providerName] = lastError
    return false, lastError
  end
  local ok, result, detail = pcall(provider.rebuild, options)
  if not ok then
    lastError = tostring(result)
    providerErrors[providerName] = lastError
    logMessage("E", providerName .. " rebuild crashed: " .. lastError)
    return false, lastError
  end
  if not result then
    lastError = tostring(detail)
    providerErrors[providerName] = lastError
    logMessage("E", providerName .. " rebuild failed: " .. lastError)
    return false, lastError
  end
  lastError = nil
  providerErrors[providerName] = nil
  local stats = detail or (provider.getStats and provider.getStats()) or {}
  logMessage("I", providerName .. " cache rebuilt")

  if providerName == "decalRoads" and providers.materials and type(providers.materials.ingestNames) == "function" then
    local materialNames = {}
    local seen = {}
    for _, record in ipairs(provider.getRecords and provider.getRecords() or {}) do
      local name = tostring(record.material or "")
      if name ~= "" and not seen[name] then seen[name] = true; materialNames[#materialNames + 1] = name end
    end
    local materialOk, materialStats = providers.materials.ingestNames(materialNames)
    stats.materials = materialStats
    if not materialOk then
      logMessage("W", "some DecalRoad materials could not be acquired")
    end
  end
  return true, stats
end

function M.update()
  if #pendingLevelBuilds == 0 then return false end
  local completedAny = false
  for index = #pendingLevelBuilds, 1, -1 do
    local request = pendingLevelBuilds[index]
    request.frames = request.frames - 1
    if request.frames <= 0 then
      table.remove(pendingLevelBuilds, index)
      local ok, stats = M.rebuild(request.name)
      completedAny = true
      if ok and request.name == "decalRoads" then
        logMessage("I", string.format(
          "DecalRoad cache ready: %d cached, %d bulk, %d fallback, %.3f s",
          tonumber(stats.cachedRoads) or 0,
          tonumber(stats.bulkRoads) or 0,
          tonumber(stats.fallbackRoads) or 0,
          tonumber(stats.buildSeconds) or 0
        ))
      end
    end
  end
  return completedAny
end

function M.getStats()
  local pending = {}
  for _, request in ipairs(pendingLevelBuilds) do
    pending[#pending + 1] = {name = request.name, frames = request.frames}
  end
  local result = {
    pendingLevelBuilds = pending,
    lastError = lastError,
    providerErrors = providerErrors,
    providers = {},
    acquisitionOnly = true,
    feedsRayTracer = false,
  }
  for name, provider in pairs(providers) do
    result.providers[name] = type(provider.getStats) == "function" and provider.getStats() or {}
  end
  return result
end

return M
