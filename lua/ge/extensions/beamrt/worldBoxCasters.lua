-- BeamRT world-space TSStatic bounding-box occluder prototypes.
-- No camera-depth dependency. This is deliberately not a full mesh tracer.
-- Data collection only runs on explicit commands, never every game frame.
local M = {}
local slots = {}
local LIMIT = 4

local function number(v)
  local n = tonumber(v)
  if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
  return n
end

local function vectorComponents(v)
  if not v then return nil end
  local ok, x, y, z = pcall(function()
    return v.x or v[1], v.y or v[2], v.z or v[3]
  end)
  if not ok then return nil end
  x, y, z = number(x), number(y), number(z)
  if x and y and z then return {x, y, z} end
end

local function parseBounds(worldBox)
  if not worldBox then return nil, "world box is unavailable" end
  local ok, minV, maxV = pcall(function()
    return worldBox.minExtents or worldBox.min or worldBox.minPoint,
           worldBox.maxExtents or worldBox.max or worldBox.maxPoint
  end)
  if ok then
    local lo, hi = vectorComponents(minV), vectorComponents(maxV)
    if lo and hi then return lo, hi end
  end
  -- Some BeamNG builds expose a six-number Box3F string instead of members.
  -- Accept only an unambiguous six-number representation.
  local result = tostring(worldBox)
  local values = {}
  for token in result:gmatch("[-+]?%d+%.?%d*[eE]?[-+]?%d*") do
    local n = number(token)
    if n then values[#values + 1] = n end
  end
  if #values == 6 then
    return {values[1], values[2], values[3]},
           {values[4], values[5], values[6]}
  end
  return nil, "getWorldBox did not expose six numeric extents; use setOffscreenBox with manual bounds"
end

local function validBounds(lo, hi)
  if not lo or not hi then return false end
  for i = 1, 3 do
    if not number(lo[i]) or not number(hi[i]) or
        hi[i] <= lo[i] or hi[i] - lo[i] > 250 then return false end
  end
  return true
end

local function copy(bounds)
  return {lo = {bounds.lo[1], bounds.lo[2], bounds.lo[3]},
          hi = {bounds.hi[1], bounds.hi[2], bounds.hi[3]},
          name = bounds.name, source = bounds.source}
end

function M.set(index, minX, minY, minZ, maxX, maxY, maxZ, name)
  index = number(index)
  if not index or index % 1 ~= 0 or index < 1 or index > LIMIT then
    return false, "slot index must be 1 to 4"
  end
  local lo = {number(minX), number(minY), number(minZ)}
  local hi = {number(maxX), number(maxY), number(maxZ)}
  if not validBounds(lo, hi) then return false, "box extents must be finite, increasing, and within 250 metres per axis" end
  if index > #slots + 1 then return false, "fill existing slots in order" end
  slots[index] = {lo = lo, hi = hi, name = tostring(name or "manual"), source = "world-space AABB"}
  return true
end

function M.clear()
  slots = {}
  return true
end

function M.getSlots()
  local result = {}
  for i = 1, #slots do result[i] = copy(slots[i]) end
  return result
end

function M.captureObject(objectName, replace)
  if type(objectName) ~= "string" or objectName == "" then
    return false, "supply a TSStatic scene object name"
  end
  if not scenetree or type(scenetree.findObject) ~= "function" then
    return false, "scenetree is unavailable"
  end
  local found, obj = pcall(scenetree.findObject, objectName)
  if not found or not obj then return false, "object not found: " .. objectName end
  local clsOk, cls = pcall(obj.getClassName, obj)
  if not clsOk or cls ~= "TSStatic" then
    return false, "only TSStatic objects are currently supported; got " .. tostring(cls)
  end
  if type(obj.getWorldBox) ~= "function" then
    return false, "TSStatic has no getWorldBox method"
  end
  local boxOk, box = pcall(obj.getWorldBox, obj)
  if not boxOk then return false, "getWorldBox call failed: " .. tostring(box) end
  local lo, hi = parseBounds(box)
  if not lo then return false, hi end
  local index = replace and 1 or (#slots + 1)
  if replace then M.clear() end
  return M.set(index, lo[1], lo[2], lo[3],
               hi[1], hi[2], hi[3], objectName)
end

local function nearbyCenter()
  local ok, vehicle = pcall(function()
    return be and be:getPlayerVehicle(0) or nil
  end)
  if ok and vehicle then
    local posOk, position = pcall(vehicle.getPosition, vehicle)
    if posOk then return vectorComponents(position) end
  end
  return nil
end

function M.captureNearby(radius)
  local r = number(radius) or 60
  if r < 1 or r > 250 then return false, "radius must be between 1 and 250 metres" end
  local center = nearbyCenter()
  if not center then return false, "player vehicle position unavailable; use captureOffscreenObject(name)" end
  if not scenetree or type(scenetree.findClassObjects) ~= "function" then
    return false, "scene class enumeration unavailable"
  end
  local ok, tokens = pcall(scenetree.findClassObjects, "TSStatic")
  if not ok or type(tokens) ~= "table" then
    return false, "TSStatic class enumeration failed"
  end
  local candidates = {}
  for _, token in ipairs(tokens) do
    local found, object = pcall(scenetree.findObject, token)
    if found and object and type(object.getWorldBox) == "function" then
      local boundsOk, bounds = pcall(object.getWorldBox, object)
      if boundsOk then
        local lo, hi = parseBounds(bounds)
        if validBounds(lo, hi) then
          local dx = (lo[1]+hi[1])*0.5 - center[1]
          local dy = (lo[2]+hi[2])*0.5 - center[2]
          local dz = (lo[3]+hi[3])*0.5 - center[3]
          local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
          local height = hi[3]-lo[3]
          -- Deliberately skip ground-sized, ultra-thin and huge boxes.
          if distance < r and height >= 1.5 and height <= 65 and
             hi[1]-lo[1] <= 80 and hi[2]-lo[2] <= 80 then
            candidates[#candidates+1] = {lo=lo,hi=hi,name=tostring(token),distance=distance}
          end
        end
      end
    end
  end
  table.sort(candidates, function(a,b) return a.distance < b.distance end)
  M.clear()
  for i=1,math.min(#candidates,LIMIT) do
    local b=candidates[i]
    M.set(i,b.lo[1],b.lo[2],b.lo[3],b.hi[1],b.hi[2],b.hi[3],b.name)
  end
  if #slots==0 then return false, "no parsable nearby TSStatic world bounds; use manual boxes" end
  return true, M.getSlots()
end

function M.getStatus()
  local names = {}
  for i,b in ipairs(slots) do names[i] = b.name end
  return {count=#slots, limit=LIMIT, objects=names, approximate=true,
    updatedAutomatically=false, screenIndependent=true}
end

return M
