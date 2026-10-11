local M = {name = "vehicles"}

local cache = {}
local ffiOk, ffi = pcall(require, "ffi")

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  return pcall(fn, ...)
end

-- GPUMesh values are properties in BeamNG's shipped util/export.lua, while
-- some runtime probes exposed callable accessors. Handle both representations.
local function readMember(object, name)
  if not object then return nil end
  local ok, value = pcall(function() return object[name] end)
  if not ok then return nil end
  if type(value) == "function" then
    ok, value = pcall(value, object)
    if not ok then return nil end
  end
  return value
end

local function count(object, memberName)
  return math.max(0, math.floor(tonumber(readMember(object, memberName)) or 0))
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

local function ensurePrimitiveType()
  if not ffiOk then return false, "LuaJIT FFI is unavailable" end
  if pcall(ffi.typeof, "gpuPrimitive_t") then return true end
  local ok, err = pcall(ffi.cdef, [[
    typedef struct gpuPrimitive_t {
      uint32_t startIndex;
      uint32_t indexCount;
      uint32_t materialId;
    } gpuPrimitive_t;
  ]])
  return ok, ok and nil or tostring(err)
end

local function acquireBuffer(owner, getterName, elementCount, components, ctype)
  if elementCount <= 0 then return nil end
  if not ffiOk then return nil, "LuaJIT FFI is unavailable" end
  local getterOk, getter = pcall(function() return owner[getterName] end)
  if not getterOk or type(getter) ~= "function" then return nil, getterName .. " is unavailable" end
  local allocationOk, buffer = pcall(ffi.new, ctype .. "[?]", elementCount * components)
  if not allocationOk then return nil, getterName .. " allocation failed: " .. tostring(buffer) end
  local callOk, result = pcall(getter, owner, buffer)
  if not callOk or result == false then
    return nil, getterName .. " failed: " .. tostring(result)
  end
  return buffer
end

local function captureBuffers(owner)
  local counts = {
    vertices = count(owner, "verticesCount"),
    indices = count(owner, "indicesCount"),
    normals = count(owner, "normalsCount"),
    tangents = count(owner, "tangentsCount"),
    uv1 = count(owner, "uv1Count"),
    uv2 = count(owner, "uv2Count"),
    vertexColors = count(owner, "vertColorsCount"),
  }
  local buffers = {}
  local errors = {}
  local function acquire(targetName, getterName, elementCount, components, ctype)
    local buffer, err = acquireBuffer(owner, getterName, elementCount, components, ctype)
    buffers[targetName] = buffer
    if err then errors[#errors + 1] = err end
  end

  acquire("vertices", "verticesGet", counts.vertices, 3, "float")
  acquire("indices", "indicesGet", counts.indices, 1, "uint32_t")
  acquire("normals", "normalsGet", counts.normals, 3, "float")
  acquire("tangents", "tangentsGet", counts.tangents, 4, "float")
  acquire("uv1", "uv1Get", counts.uv1, 2, "float")
  acquire("uv2", "uv2Get", counts.uv2, 2, "float")

  -- BeamNG's shipped exporter treats colors as packed four-byte RGBA values
  -- and over-allocates uint32 storage, so mirror that proven destination size.
  acquire("vertexColors", "vertColorsGet", counts.vertexColors, 4, "uint32_t")
  return counts, buffers, errors
end

local function capturePrimitives(descriptor, materialNames)
  local primitiveCount = count(descriptor, "primitivesCount")
  if primitiveCount <= 0 then return {}, nil end
  local typeOk, typeError = ensurePrimitiveType()
  if not typeOk then return {}, typeError end
  local allocationOk, nativePrimitives = pcall(ffi.new, "gpuPrimitive_t[?]", primitiveCount)
  if not allocationOk then return {}, tostring(nativePrimitives) end
  local getterOk, getter = pcall(function() return descriptor.primitivesGet end)
  if not getterOk or type(getter) ~= "function" then return {}, "primitivesGet is unavailable" end
  local callOk, result = pcall(getter, descriptor, nativePrimitives)
  if not callOk or result == false then return {}, "primitivesGet failed" end

  local primitives = {}
  for index = 0, primitiveCount - 1 do
    local native = nativePrimitives[index]
    local materialIndex = tonumber(native.materialId) or 0
    primitives[#primitives + 1] = {
      firstIndex = tonumber(native.startIndex) or 0,
      indexCount = tonumber(native.indexCount) or 0,
      materialIndex = materialIndex,
      materialName = materialNames[materialIndex + 1],
    }
  end
  return primitives
end

local function captureSubmeshes(mesh, accessorName, countName, materialNames, includeOwnBuffers)
  local accessorOk, accessor = pcall(function() return mesh[accessorName] end)
  if not accessorOk or type(accessor) ~= "function" then return {}, {accessorName .. " is unavailable"} end
  local submeshCount = count(mesh, countName)
  local result = {}
  local errors = {}
  for nativeIndex = 0, submeshCount - 1 do
    local ok, descriptor = pcall(accessor, mesh, nativeIndex)
    if ok and descriptor then
      local primitives, primitiveError = capturePrimitives(descriptor, materialNames)
      local record = {
        nativeIndex = nativeIndex,
        meshName = tostring(readMember(descriptor, "meshName") or ""),
        primitives = primitives,
      }
      if includeOwnBuffers then
        record.counts, record.buffers, record.bufferErrors = captureBuffers(descriptor)
      end
      result[#result + 1] = record
      if primitiveError then errors[#errors + 1] = record.meshName .. ": " .. primitiveError end
      for _, err in ipairs(record.bufferErrors or {}) do errors[#errors + 1] = record.meshName .. ": " .. err end
    else
      errors[#errors + 1] = accessorName .. "(" .. tostring(nativeIndex) .. ") failed"
    end
  end
  return result, errors
end

function M.capture(vehicleId)
  vehicleId = tonumber(vehicleId)
  if not vehicleId or not GPUMesh or type(GPUMesh.bng_getGPUMesh) ~= "function" then
    return nil, "GPUMesh.bng_getGPUMesh is unavailable"
  end
  if not ffiOk then return nil, "LuaJIT FFI is unavailable" end

  local ok, mesh = safeCall(GPUMesh.bng_getGPUMesh, vehicleId)
  if not ok or not mesh then return nil, "vehicle GPUMesh is unavailable" end

  local ready = readMember(mesh, "dataIsReady")
  if ready == false or ready == 0 or ready == nil then
    return nil, "vehicle GPUMesh data is not ready"
  end

  local vehicle = resolveVehicle(vehicleId)
  local namesOk, materialNames = false, nil
  if vehicle then namesOk, materialNames = safeCall(vehicle.getMeshMaterialNames, vehicle) end
  materialNames = namesOk and type(materialNames) == "table" and materialNames or {}

  local counts, buffers, bufferErrors = captureBuffers(mesh)
  if not buffers.vertices or not buffers.indices then
    return nil, "vehicle GPUMesh core buffer acquisition failed: " .. table.concat(bufferErrors, "; ")
  end

  local flexmeshes, flexErrors = captureSubmeshes(mesh, "flexmeshes", "flexmeshesCount", materialNames, false)
  local propmeshes, propErrors = captureSubmeshes(mesh, "propmeshes", "propmeshesCount", materialNames, true)
  for _, err in ipairs(flexErrors) do bufferErrors[#bufferErrors + 1] = err end
  for _, err in ipairs(propErrors) do bufferErrors[#bufferErrors + 1] = err end

  local primitiveCount = 0
  for _, submesh in ipairs(flexmeshes) do primitiveCount = primitiveCount + #submesh.primitives end
  for _, submesh in ipairs(propmeshes) do primitiveCount = primitiveCount + #submesh.primitives end

  local record = {
    id = vehicleId,
    mesh = mesh,
    ready = true,
    counts = counts,
    buffers = buffers,
    vertices = counts.vertices,
    indices = counts.indices,
    normals = counts.normals,
    tangents = counts.tangents,
    uv1 = counts.uv1,
    uv2 = counts.uv2,
    vertexColors = counts.vertexColors,
    materialNames = materialNames,
    flexmeshes = flexmeshes,
    propmeshes = propmeshes,
    primitiveCount = primitiveCount,
    acquisitionWarnings = bufferErrors,
    vertexColorLayout = "packed RGBA8 destination compatible with shipped util/export.lua",
  }
  cache[vehicleId] = record
  return record
end

function M.rebuild(options)
  options = options or {}
  local vehicleId = options.vehicleId
  if vehicleId == nil and be and type(be.getPlayerVehicleID) == "function" then
    local ok, id = safeCall(be.getPlayerVehicleID, be, tonumber(options.playerIndex) or 0)
    if ok then vehicleId = id end
  end
  local record, err = M.capture(vehicleId)
  if not record then return false, err end
  return true, {
    valid = true,
    vehicleId = record.id,
    vehicles = 1,
    vertices = record.vertices,
    indices = record.indices,
    primitives = record.primitiveCount,
    acquisitionWarnings = #record.acquisitionWarnings,
    feedsRayTracer = false,
  }
end

function M.get(vehicleId) return cache[tonumber(vehicleId)] end

function M.invalidate(vehicleId)
  if vehicleId ~= nil then cache[tonumber(vehicleId)] = nil else cache = {} end
end

function M.getStats()
  local vehicles, vertices, indices, primitives, warnings = 0, 0, 0, 0, 0
  for _, record in pairs(cache) do
    vehicles = vehicles + 1
    vertices = vertices + (record.vertices or 0)
    indices = indices + (record.indices or 0)
    primitives = primitives + (record.primitiveCount or 0)
    warnings = warnings + #(record.acquisitionWarnings or {})
  end
  return {
    vehicles = vehicles,
    vertices = vertices,
    indices = indices,
    primitives = primitives,
    acquisitionWarnings = warnings,
    lazy = true,
    feedsRayTracer = false,
  }
end

return M
