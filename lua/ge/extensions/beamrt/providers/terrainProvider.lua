local M = {name = "terrain"}

local records = {}
local generation = 0
local lastStats = {valid = false, terrains = 0, feedsRayTracer = false}

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  return pcall(fn, ...)
end

local function field(object, name)
  local ok, value = pcall(function() return object[name] end)
  if ok and value ~= nil and value ~= "" and type(value) ~= "function" then return value end
  ok, value = safeCall(object and object.getField, object, name, "")
  if ok and value ~= nil and value ~= "" then return value end
  ok, value = safeCall(object and object.getField, object, name, "0")
  return ok and value ~= "" and value or nil
end

local function resolveObject(token)
  if type(token) == "userdata" then return token end
  if type(token) == "table" and type(token.getClassName) == "function" then return token end
  local ok, object = safeCall(scenetree and scenetree.findObject, token)
  if ok and object then return object end
  local numericId = tonumber(token)
  if numericId and numericId ~= token then
    ok, object = safeCall(scenetree and scenetree.findObject, numericId)
    if ok then return object end
  end
  return nil
end

local function callValue(object, methodName)
  local ok, value = safeCall(object and object[methodName], object)
  return ok and value or nil
end

function M.rebuild()
  if not scenetree or type(scenetree.findClassObjects) ~= "function" then
    return false, "scenetree.findClassObjects is unavailable"
  end
  local ok, tokens = safeCall(scenetree.findClassObjects, "TerrainBlock")
  if not ok or type(tokens) ~= "table" then return false, "TerrainBlock enumeration failed" end

  local nextRecords = {}
  local unresolved = 0
  for _, token in ipairs(tokens) do
    local object = resolveObject(token)
    local classOk, className = safeCall(object and object.getClassName, object)
    if classOk and tostring(className) == "TerrainBlock" then
      local idOk, id = safeCall(object.getID, object)
      local nameOk, name = safeCall(object.getName, object)
      nextRecords[#nextRecords + 1] = {
        id = idOk and tonumber(id) or nil,
        name = nameOk and tostring(name) or tostring(token),
        object = object,
        transform = callValue(object, "getTransform"),
        scale = callValue(object, "getScale"),
        worldBox = callValue(object, "getWorldBox"),
        objectBox = callValue(object, "getObjBox"),
        squareSize = tonumber(field(object, "squareSize")) or 0,
        maxHeight = tonumber(field(object, "maxHeight")) or 0,
        baseTexSize = tonumber(field(object, "baseTexSize")) or 0,
        lightMapSize = tonumber(field(object, "lightMapSize")) or 0,
        terrainFile = field(object, "terrainFile"),
        materialTextureSet = field(object, "materialTextureSet"),
      }
    else
      unresolved = unresolved + 1
    end
  end
  records = nextRecords
  generation = generation + 1
  lastStats = {
    valid = true,
    generation = generation,
    terrains = #records,
    unresolved = unresolved,
    geometryReconstructable = #records > 0,
    materialLayersResolved = false,
    feedsRayTracer = false,
  }
  return true, lastStats
end

-- Exact Terrain height/normal signatures were not preserved. A verified
-- runtime adapter can be supplied without baking a guessed call into BeamRT.
function M.sample(recordIndex, queryAdapter, ...)
  if type(queryAdapter) ~= "function" then
    return nil, "terrain sample requires a verified query adapter"
  end
  local record = records[tonumber(recordIndex) or 1]
  if not record then return nil, "terrain record not found" end
  local ok, result, normal = pcall(queryAdapter, record.object, ...)
  if not ok then return nil, tostring(result) end
  return result, normal
end

function M.invalidate()
  records = {}
  lastStats = {valid = false, generation = generation, terrains = 0, feedsRayTracer = false}
end

function M.getRecords() return records end
function M.getStats() return lastStats end

return M
