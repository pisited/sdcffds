-- Read-only rigid player OBB motion. Engine velocity, when available, remains
-- responsible for other objects and deformation; this is not skinned motion.
local M = {}
local previous
local function vector(v)
  local result = {tonumber(v.x), tonumber(v.y), tonumber(v.z)}
  for i = 1, 3 do
    local n = result[i]
    if not n or n ~= n or math.abs(n) == math.huge then error('Invalid motion vector') end
  end
  return result
end
function M.clear() previous = nil end
function M.capture(dt)
  local ok, current = pcall(function()
    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return nil end
    local box = vehicle:getSpawnWorldOOBB()
    local result = {id = vehicle:getID(), center = vector(box:getCenter()),
      axes = {vector(box:getAxis(0)), vector(box:getAxis(1)), vector(box:getAxis(2))},
      half = vector(box:getHalfExtents())}
    for i = 1, 3 do
      if result.half[i] <= 0 or result.half[i] > 100 then error('Invalid motion bounds') end
      local axis = result.axes[i]
      local norm = axis[1]^2 + axis[2]^2 + axis[3]^2
      if math.abs(norm - 1) > 0.02 then error('Invalid motion basis') end
      for j = 1, i - 1 do
        local other = result.axes[j]
        if math.abs(axis[1]*other[1] + axis[2]*other[2] + axis[3]*other[3]) > 0.02 then
          error('Nonorthogonal motion basis')
        end
      end
    end
    return result
  end)
  if not ok or not current then M.clear(); return {valid = false} end
  local old = previous
  previous = current
  if not old or old.id ~= current.id or dt > 0.25 then return {valid = false} end
  local distance = 0
  for i = 1, 3 do distance = distance + (current.center[i] - old.center[i])^2 end
  if distance > 900 then return {valid = false} end
  return {valid = true, current = current, previous = old}
end
return M
