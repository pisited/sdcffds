local M = {name = "lights"}

local records = {}
local byId = {}
local valid = false
local generation = 0
local lastStats = {valid = false}

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  return pcall(fn, ...)
end

local function field(object, name, defaultValue)
  if not object then return defaultValue end
  local ok, value = pcall(function() return object[name] end)
  if ok and value ~= nil and value ~= "" and type(value) ~= "function" then return value end
  ok, value = safeCall(object.getField, object, name, "")
  if ok and value ~= nil and value ~= "" then return value end
  ok, value = safeCall(object.getField, object, name, "0")
  if ok and value ~= nil and value ~= "" then return value end
  return defaultValue
end

local function resolveObject(token)
  if type(token) == "userdata" then return token end
  if type(token) == "table" and type(token.getClassName) == "function" then return token end
  local ok, object = safeCall(scenetree and scenetree.findObject, token)
  if ok and object then return object end
  local numericId = tonumber(token)
  if numericId and numericId ~= token then
    ok, object = safeCall(scenetree and scenetree.findObject, numericId)
    if ok and object then return object end
  end
  return nil
end

local function objectIdentity(object)
  local idOk, id = safeCall(object and object.getID, object)
  local nameOk, name = safeCall(object and object.getName, object)
  return idOk and tonumber(id) or nil, nameOk and tostring(name) or nil
end

local function objectClass(object)
  local ok, className = safeCall(object and object.getClassName, object)
  return ok and tostring(className) or nil
end

local function positionOf(object)
  local ok, position = safeCall(object and object.getPosition, object)
  if ok then return position end
  return field(object, "position", nil)
end

local function transformOf(object)
  local ok, transform = safeCall(object and object.getTransform, object)
  return ok and transform or nil
end

local function directionOf(transform)
  local ok, direction = safeCall(transform and transform.getColumn, transform, 1)
  return ok and direction or nil
end

local function normalizedRecord(object)
  local className = objectClass(object)
  if className ~= "PointLight" and className ~= "SpotLight" then return nil end
  local id, name = objectIdentity(object)
  local transform = transformOf(object)
  local record = {
    id = id,
    name = name,
    className = className,
    type = className == "SpotLight" and "spot" or "point",
    object = object,
    position = positionOf(object),
    transform = transform,
    direction = className == "SpotLight" and directionOf(transform) or nil,
    color = field(object, "color", nil),
    brightness = tonumber(field(object, "brightness", 0)) or 0,
    intensity = tonumber(field(object, "intensity", 0)) or 0,
    radius = className == "PointLight" and (tonumber(field(object, "radius", 0)) or 0) or nil,
    range = className == "SpotLight" and (tonumber(field(object, "range", 0)) or 0) or nil,
    innerAngle = className == "SpotLight" and (tonumber(field(object, "innerAngle", 0)) or 0) or nil,
    outerAngle = className == "SpotLight" and (tonumber(field(object, "outerAngle", 0)) or 0) or nil,
    castShadows = field(object, "castShadows", 0),
    shadowType = field(object, "shadowType", ""),
    enabled = field(object, "isEnabled", field(object, "enabled", 1)),
  }
  return record
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

local function collectTokens(options)
  options = options or {}
  local frustum = options.frustum
  if frustum == nil and not options.all then
    local err
    frustum, err = mainFrustum()
    if not frustum then return nil, err end
  end
  if frustum ~= nil then
    if type(findObjectListFrustum) ~= "function" then
      return nil, "findObjectListFrustum is unavailable"
    end
    local ok, tokens = safeCall(findObjectListFrustum, frustum, 64)
    if not ok or type(tokens) ~= "table" then return nil, "visible-light frustum query failed" end
    return tokens, "frustum64"
  end

  if not scenetree or type(scenetree.findClassObjects) ~= "function" then
    return nil, "scenetree.findClassObjects is unavailable"
  end
  local pointOk, pointTokens = safeCall(scenetree.findClassObjects, "PointLight")
  local spotOk, spotTokens = safeCall(scenetree.findClassObjects, "SpotLight")
  if not pointOk or not spotOk or type(pointTokens) ~= "table" or type(spotTokens) ~= "table" then
    return nil, "PointLight/SpotLight enumeration failed"
  end
  local tokens = {}
  for _, token in ipairs(pointTokens) do tokens[#tokens + 1] = token end
  for _, token in ipairs(spotTokens) do tokens[#tokens + 1] = token end
  return tokens, "sceneClasses"
end

local function resolveVehicle(vehicleId)
  if type(getObjectByID) == "function" then
    local ok, vehicle = safeCall(getObjectByID, vehicleId)
    if ok and vehicle then return vehicle end
  end
  if be and type(be.getObjectByID) == "function" then
    local ok, vehicle = safeCall(be.getObjectByID, be, vehicleId)
    if ok then return vehicle end
  end
  return nil
end

local function collectVehicleLights(options)
  if options.includeVehicleLights == false then return {}, nil end
  local vehicleId = tonumber(options.vehicleId)
  if not vehicleId and be and type(be.getPlayerVehicleID) == "function" then
    local idOk, id = safeCall(be.getPlayerVehicleID, be, tonumber(options.playerIndex) or 0)
    if idOk then vehicleId = tonumber(id) end
  end
  if not vehicleId then return {}, "player vehicle is unavailable" end
  if not core_vehicle_manager or type(core_vehicle_manager.getVehicleData) ~= "function" then
    return {}, "core_vehicle_manager.getVehicleData is unavailable"
  end
  local dataOk, vehicleData = safeCall(core_vehicle_manager.getVehicleData, vehicleId)
  local props = dataOk and vehicleData and vehicleData.vdata and vehicleData.vdata.props
  local vehicle = resolveVehicle(vehicleId)
  if type(props) ~= "table" or not vehicle then return {}, "vehicle light props are unavailable" end

  local positionOk, vehiclePosition = safeCall(vehicle.getPosition, vehicle)
  if not positionOk then vehiclePosition = nil end
  local lights = {}
  for _, prop in pairs(props) do
    if type(prop) == "table" and (prop.mesh == "SPOTLIGHT" or prop.mesh == "POINTLIGHT") then
      local propOk, propObject = safeCall(vehicle.getProp, vehicle, prop.pid)
      local transformOk, transform = safeCall(propObject and propObject.getLiveTransformWorld, propObject)
      local localPositionOk, localPosition = safeCall(transform and transform.getColumn, transform, 3)
      local directionOk, direction = safeCall(transform and transform.getColumn, transform, 1)
      local worldPosition = localPositionOk and localPosition or nil
      if worldPosition and vehiclePosition then
        local addOk, added = pcall(function() return worldPosition + vehiclePosition end)
        if addOk then worldPosition = added end
      end
      lights[#lights + 1] = {
        id = "vehicle:" .. tostring(vehicleId) .. ":prop:" .. tostring(prop.pid),
        vehicleId = vehicleId,
        propId = prop.pid,
        name = tostring(prop.func or prop.mesh or prop.pid),
        className = "VehiclePropLight",
        type = prop.mesh == "SPOTLIGHT" and "spot" or "point",
        source = "vehicleProp",
        prop = prop,
        object = propOk and propObject or nil,
        transform = transformOk and transform or nil,
        position = worldPosition,
        direction = directionOk and direction or nil,
        color = prop.lightColor,
        brightness = tonumber(prop.lightBrightness) or 0,
        intensityCd = tonumber(prop.lightIntensityCd) or tonumber(prop.cd) or 0,
        intensityLm = tonumber(prop.lightIntensityLm) or 0,
        range = tonumber(prop.lightRange) or 0,
        innerAngle = tonumber(prop.lightInnerAngle) or 0,
        outerAngle = tonumber(prop.lightOuterAngle) or 0,
        castShadows = prop.lightCastShadows,
        attenuation = prop.lightAttenuation,
        enabled = nil,
        enabledStateVerified = false,
      }
    end
  end
  return lights
end

function M.rebuild(options)
  options = options or {}
  local started = os.clock()
  local tokens, sourceOrError = collectTokens(options)
  if not tokens then
    valid = false
    lastStats = {valid = false, error = sourceOrError}
    return false, sourceOrError
  end

  local nextRecords = {}
  local nextById = {}
  local pointCount, spotCount, vehicleLightCount, unresolved = 0, 0, 0, 0
  local seen = {}
  for _, token in ipairs(tokens) do
    local object = resolveObject(token)
    local record = normalizedRecord(object)
    if record then
      local identity = record.id and ("id:" .. tostring(record.id))
        or record.name and ("name:" .. record.name)
        or tostring(object)
      if not seen[identity] then
        seen[identity] = true
        nextRecords[#nextRecords + 1] = record
        if record.id then nextById[record.id] = record end
        if record.type == "point" then pointCount = pointCount + 1 else spotCount = spotCount + 1 end
      end
    else
      unresolved = unresolved + 1
    end
  end


  local vehicleLights, vehicleLightWarning = collectVehicleLights(options)
  for _, record in ipairs(vehicleLights) do
    nextRecords[#nextRecords + 1] = record
    nextById[record.id] = record
    vehicleLightCount = vehicleLightCount + 1
    if record.type == "point" then pointCount = pointCount + 1 else spotCount = spotCount + 1 end
  end

  records = nextRecords
  byId = nextById
  generation = generation + 1
  valid = true
  lastStats = {
    valid = true,
    generation = generation,
    source = sourceOrError,
    candidates = #tokens,
    lights = #records,
    pointLights = pointCount,
    spotLights = spotCount,
    vehicleLights = vehicleLightCount,
    vehicleLightWarning = vehicleLightWarning,
    unresolvedOrRejected = unresolved,
    buildSeconds = os.clock() - started,
    vehicleLightsIncluded = vehicleLightCount > 0,
    vehicleEnabledStateVerified = false,
    feedsRayTracer = false,
  }
  return true, lastStats
end

function M.invalidate()
  records = {}
  byId = {}
  valid = false
  lastStats = {valid = false, generation = generation}
end

function M.isValid() return valid end
function M.getRecords() return records end
function M.getById(id) return id ~= nil and (byId[tonumber(id)] or byId[tostring(id)]) or nil end
function M.getStats() return lastStats end

return M
