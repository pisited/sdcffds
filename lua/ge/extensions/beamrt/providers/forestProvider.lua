local M = {name = "forest"}

local assets = {}
local instances = {}

local function safeValue(object, key)
  local ok, value = pcall(function() return object[key] end)
  return ok and value or nil
end

local function safeMethod(object, name, ...)
  local method = safeValue(object, name)
  if type(method) ~= "function" then return nil end
  local ok, value = pcall(method, object, ...)
  return ok and value or nil
end

local function assetKey(item)
  local data = nil
  if item and type(item.getData) == "function" then
    local ok, result = pcall(item.getData, item)
    if ok then data = result end
  end
  data = data or safeValue(item, "data")
  local key = data and (safeValue(data, "shapeFile") or safeValue(data, "shapeName") or safeValue(data, "name"))
  return tostring(key or "unknown"), data
end

function M.ingest(items)
  assets = {}
  instances = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    local key, data = assetKey(item)
    if not assets[key] then assets[key] = {key = key, source = data, instanceCount = 0} end
    assets[key].instanceCount = assets[key].instanceCount + 1
    instances[#instances + 1] = {
      assetKey = key,
      item = item,
      position = safeValue(item, "position") or safeMethod(item, "getPosition"),
      transform = safeValue(item, "transform") or safeMethod(item, "getTransform"),
      scale = safeValue(item, "scale") or safeMethod(item, "getScale"),
      bounds = safeValue(item, "bounds") or safeValue(item, "box") or safeMethod(item, "getWorldBox"),
      uid = safeValue(item, "uid") or safeValue(item, "UID") or safeMethod(item, "getUID"),
      size = safeValue(item, "size"),
      radius = safeValue(item, "radius"),
      materials = safeValue(item, "materials"),
    }
  end
  return M.getStats()
end

function M.rebuild(options)
  options = options or {}
  if type(options.items) == "table" then return true, M.ingest(options.items) end
  if type(options.queryAdapter) == "function" then
    return M.rebuildNearby(options.position, options.radius, options.queryAdapter)
  end
  return false, "forest rebuild requires options.items or a verified options.queryAdapter"
end

function M.getDatabase()
  if not core_forest or type(core_forest.getForestObject) ~= "function" then
    return nil, "core_forest is unavailable"
  end
  local ok, forest = pcall(core_forest.getForestObject)
  if not ok or not forest or type(forest.getData) ~= "function" then return nil, "forest database is unavailable" end
  local dbOk, database = pcall(forest.getData, forest)
  if not dbOk or not database then return nil, "forest database is unavailable" end
  return database
end

-- The Circle method exists, but its precise runtime argument contract was not
-- preserved. Require a verified caller-supplied adapter instead of encoding a
-- guessed native call into the provider.
function M.rebuildNearby(position, radius, verifiedQuery)
  if type(verifiedQuery) ~= "function" then
    return false, "ForestData.Circle signature is unverified; pass a verified query adapter or call ingest(items)"
  end
  local database, databaseError = M.getDatabase()
  if not database then return false, databaseError end
  local queryOk, items = pcall(verifiedQuery, database, position, radius)
  if not queryOk or type(items) ~= "table" then return false, "ForestData.Circle query failed" end
  M.ingest(items)
  return true, M.getStats()
end

function M.invalidate() assets = {}; instances = {} end
function M.getAssets() return assets end
function M.getInstances() return instances end
function M.getStats()
  local assetCount = 0
  for _ in pairs(assets) do assetCount = assetCount + 1 end
  return {
    assets = assetCount,
    instances = #instances,
    automatic = false,
    spatialQueryRequiresVerifiedAdapter = true,
    feedsRayTracer = false,
  }
end

return M
