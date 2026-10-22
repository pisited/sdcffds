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
  local tagOk,tag=pcall(function()return object.___type end)
  if tagOk and type(tag)=='string'and tag~=''then return tag:match('^class<([^>]+)>$')or tag end
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

local function collectOneVehicleLights(vehicleId)
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
        -- Constructor defaults in jbeam/sections/meshs.lua, not live emission.
        brightness = tonumber(prop.lightBrightness) or 1,
        intensityCd = tonumber(prop.lightIntensityCd) or tonumber(prop.cd) or 0,
        intensityLm = tonumber(prop.lightIntensityLm) or 0,
        range = tonumber(prop.lightRange) or 10,
        innerAngle = tonumber(prop.lightInnerAngle) or 40,
        outerAngle = tonumber(prop.lightOuterAngle) or 45,
        castShadows = prop.lightCastShadows or false,
        shadowPolicySource = prop.lightCastShadows==nil and 'native constructor default: no shadows' or 'JBeam declaration',
        attenuation = prop.lightAttenuation,
        enabled = nil,
        enabledStateVerified = false,
      }
    end
  end
  return lights
end

local function xyz(value)
  if not value then return nil end
  local ok,x,y,z=pcall(function()return tonumber(value.x or value[1]),tonumber(value.y or value[2]),tonumber(value.z or value[3])end)
  if not ok or not x or not y or not z or x~=x or y~=y or z~=z
    or math.abs(x)==math.huge or math.abs(y)==math.huge or math.abs(z)==math.huge then return nil end
  return {x,y,z}
end

local function collectVehicleLights(options)
  if options.includeVehicleLights==false then return {},nil,{mode='disabled',vehicles=0}end
  local explicit=tonumber(options.vehicleId)
  -- An explicit vehicle remains a scoped query for existing callers. Otherwise
  -- enumerate nearby real vehicles, NOT only the currently controlled avatar.
  local ids,selection={},{mode='nearby',vehicles=0,selectionIndependentOfControlledVehicle=true}
  if explicit then ids={explicit};selection.mode='explicit';selection.selectionIndependentOfControlledVehicle=false
  else
    local radius=tonumber(options.vehicleLightRadius)or 80
    local cap=tonumber(options.maxVehicleLightVehicles)or 8
    if radius~=radius or radius<1 or radius>500 or cap~=cap or cap%1~=0 or cap<1 or cap>16 then
      return {},'invalid nearby vehicle-light radius/cap',{mode='invalid',vehicles=0}
    end
    local eyeOk,eye=safeCall(core_camera and core_camera.getPosition)
    eye=eyeOk and xyz(eye)or nil
    local allOk,vehicles=safeCall(getAllVehicles)
    if eye and allOk and type(vehicles)=='table'then
      local candidates,seen={},{}
      for _,vehicle in pairs(vehicles)do
        local idOk,id=safeCall(vehicle and vehicle.getID,vehicle)
        local posOk,pos=safeCall(vehicle and vehicle.getPosition,vehicle)
        id=idOk and tonumber(id)or nil;pos=posOk and xyz(pos)or nil
        if id and pos and not seen[id]then
          seen[id]=true;local distance=0
          for i=1,3 do distance=distance+(pos[i]-eye[i])^2 end
          if distance<=radius*radius then candidates[#candidates+1]={id=id,distance=distance}end
        end
      end
      table.sort(candidates,function(a,b)return a.distance==b.distance and a.id<b.id or a.distance<b.distance end)
      for i=1,math.min(cap,#candidates)do ids[#ids+1]=candidates[i].id end
      selection.radius=radius;selection.cap=cap;selection.candidates=#candidates
      selection.capped=#candidates>cap
    else
      -- Compatibility fallback is explicitly reported, not called mode-stable.
      local idOk,id=safeCall(be and be.getPlayerVehicleID,be,tonumber(options.playerIndex)or 0)
      if idOk and tonumber(id)then ids={tonumber(id)}end
      selection.mode='player fallback';selection.selectionIndependentOfControlledVehicle=false
      selection.warning='nearby vehicle enumeration/camera position unavailable'
    end
  end
  local records,warnings={},{}
  for _,id in ipairs(ids)do
    local lights,why=collectOneVehicleLights(id)
    for _,record in ipairs(lights)do records[#records+1]=record end
    if why then warnings[#warnings+1]='vehicle '..tostring(id)..': '..why end
  end
  selection.vehicles=#ids
  return records,#warnings>0 and table.concat(warnings,'; ')or selection.warning,selection
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


  local vehicleLights, vehicleLightWarning, vehicleSelection = collectVehicleLights(options)
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
    vehicleSelection = vehicleSelection,
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
-- Fresh, read-only single-object sampling. No rebuild or shared cache changes.
function M.readObject(object) return normalizedRecord(object) end
function M.queryScene()
  local tokens,why=collectTokens({all=true})
  if not tokens then return nil,why end
  local result,seen={},{}
  for _,token in ipairs(tokens)do
    local object=resolveObject(token)
    if object and not seen[object]then
      seen[object]=true;local record=normalizedRecord(object)
      if record then result[#result+1]=record end
    end
  end
  return result
end

return M
