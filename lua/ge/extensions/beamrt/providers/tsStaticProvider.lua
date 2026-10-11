local M = {name = "tsStatic"}

local assets = {}
local instances = {}

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
  return ok and value or nil
end

local function findObject(token)
  if type(token) == "userdata" then return token end
  if type(token) == "table" and (type(token.getField) == "function" or type(token.getID) == "function") then return token end
  local ok, object = safeCall(scenetree and scenetree.findObject, token)
  if ok and object then return object end
  local numericId = tonumber(token)
  if numericId and numericId ~= token then
    ok, object = safeCall(scenetree and scenetree.findObject, numericId)
    if ok and object then return object end
  end
  return nil
end

local function isTSStatic(object)
  local ok, className = safeCall(object and object.getClassName, object)
  return ok and tostring(className) == "TSStatic"
end

local function methodValue(object, name)
  local ok, value = safeCall(object and object[name], object)
  return ok and value or nil
end

function M.ingest(objectTokens)
  assets = {}
  instances = {}
  for _, token in ipairs(type(objectTokens) == "table" and objectTokens or {}) do
    local object = findObject(token)
    if object and isTSStatic(object) then
      local shape = field(object, "shapeName") or field(object, "shapeFile") or "unknown"
      local key = tostring(shape)
      if not assets[key] then assets[key] = {key = key, dae = shape, instanceCount = 0} end
      assets[key].instanceCount = assets[key].instanceCount + 1
      local idOk, id = safeCall(object.getID, object)
      local nameOk, name = safeCall(object.getName, object)
      instances[#instances + 1] = {
        assetKey = key,
        object = object,
        id = idOk and tonumber(id) or nil,
        name = nameOk and tostring(name) or tostring(token),
        transform = methodValue(object, "getTransform"),
        scale = methodValue(object, "getScale"),
        worldBox = methodValue(object, "getWorldBox"),
        objectBox = methodValue(object, "getObjBox"),
        material = field(object, "material"),
        materials = field(object, "materials"),
      }
    end
  end
  return M.getStats()
end

local function mainFrustum()
  if not RenderViewManagerInstance or type(RenderViewManagerInstance.getView) ~= "function" then
    return nil, "RenderViewManagerInstance:getView is unavailable"
  end
  local ok, view = safeCall(RenderViewManagerInstance.getView, RenderViewManagerInstance, "main")
  if not ok or not view then return nil, "main RenderView is unavailable" end
  local frustumOk, frustum = pcall(function() return view.frustum end)
  if not frustumOk or frustum == nil then return nil, "main RenderView frustum is unavailable" end
  return frustum
end

function M.rebuild(options)
  options = options or {}
  if type(options.objectTokens) == "table" then return true, M.ingest(options.objectTokens) end
  local frustum = options.frustum
  if frustum == nil then
    local err
    frustum, err = mainFrustum()
    if not frustum then return false, err end
  end
  return M.rebuildVisible(frustum)
end

function M.rebuildVisible(frustum)
  if frustum == nil then return false, "a verified RenderView frustum is required" end
  if type(findObjectListFrustum) ~= "function" then return false, "findObjectListFrustum is unavailable" end
  local ok, tokens = pcall(findObjectListFrustum, frustum, 256)
  if not ok or type(tokens) ~= "table" then return false, "TSStatic frustum query failed" end
  M.ingest(tokens)
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
    frustumMask = 256,
    geometryParsed = false,
    feedsRayTracer = false,
  }
end

return M
