local M = {name = "vehicles", diagnosticStageVersion = 1}

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
  local n=tonumber(readMember(object,memberName))
  local limit=memberName=='indicesCount' and 1500000
    or (memberName=='primitivesCount' and 2048)
    or ((memberName=='flexmeshesCount' or memberName=='propmeshesCount') and 256) or 500000
  assert(n and n==n and n>=0 and n%1==0 and n<=limit,'Invalid/over-budget '..memberName)
  return n
end
local function reserve(budget,bytes)
  assert(budget.bytes+bytes<=32*1024*1024,'Vehicle CPU buffer budget exceeded; no truncation')
  budget.bytes=budget.bytes+bytes
end

-- Opt-in, synchronous breadcrumbs. Observer errors abort the copy rather than
-- silently entering the next native call without a persisted boundary marker.
-- No handles, pointers or mesh contents are passed to the observer.
local function observed(budget,scope,operation,fn,...)
  local observer=budget.observer
  if observer then observer({scope=scope,operation=operation,boundary='before'}) end
  local a,b,c=fn(...)
  if observer then observer({scope=scope,operation=operation,boundary='after'}) end
  return a,b,c
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
  if pcall(ffi.typeof, "gpuPrimitive_t") then
    local ok=ffi.sizeof('gpuPrimitive_t')==12 and ffi.offsetof('gpuPrimitive_t','startIndex')==0
      and ffi.offsetof('gpuPrimitive_t','indexCount')==4 and ffi.offsetof('gpuPrimitive_t','materialId')==8
    return ok,not ok and 'gpuPrimitive_t ABI differs from installed cdefGpuMesh.lua' or nil
  end
  local ok, err = pcall(ffi.cdef, [[
    typedef struct gpuPrimitive_t {
      uint32_t startIndex;
      uint32_t indexCount;
      uint32_t materialId;
    } gpuPrimitive_t;
  ]])
  return ok, ok and nil or tostring(err)
end

local function acquireBuffer(owner, getterName, elementCount, components, ctype,budget,scope)
  if elementCount <= 0 then return nil end
  if not ffiOk then return nil, "LuaJIT FFI is unavailable" end
  local getterOk, getter = pcall(function() return owner[getterName] end)
  if not getterOk or type(getter) ~= "function" then return nil, getterName .. " is unavailable" end
  local allocationOk, buffer = pcall(ffi.new, ctype .. "[?]", elementCount * components)
  if not allocationOk then return nil, getterName .. " allocation failed: " .. tostring(buffer) end
  local callOk, result = observed(budget,scope,getterName,pcall,getter,owner,buffer)
  if not callOk or (result~=true and result~=1) then
    return nil, getterName .. " failed: " .. tostring(result)
  end
  return buffer
end

local function captureBuffers(owner,profile,budget,scope)
  local counts = {
    vertices = observed(budget,scope,'verticesCount',count,owner,'verticesCount'),
    indices = observed(budget,scope,'indicesCount',count,owner,'indicesCount'),
    normals = 0, tangents = 0, uv1 = 0, uv2 = 0, vertexColors = 0,
  }
  if profile=='glass' then
    counts.uv1=observed(budget,scope,'uv1Count',count,owner,'uv1Count')
    assert(counts.uv1==counts.vertices,'Requested UV0/vertex count mismatch')
  end
  assert(counts.indices%3==0,'Native index buffer is not a triangle list')
  reserve(budget,counts.vertices*12+counts.indices*4+counts.uv1*8)
  local buffers = {}
  local errors = {}
  local function acquire(targetName, getterName, elementCount, components, ctype)
    local buffer, err = acquireBuffer(owner, getterName, elementCount, components, ctype,budget,scope)
    buffers[targetName] = buffer
    if err then error(err) end -- selected profile streams are mandatory
  end

  acquire("vertices", "verticesGet", counts.vertices, 3, "float")
  acquire("indices", "indicesGet", counts.indices, 1, "uint32_t")
  if profile=='glass' then acquire('uv1','uv1Get',counts.uv1,2,'float') end
  -- Deliberately do not LOOK UP optional color/normal/tangent/UV1 counts or
  -- getters. A positive count and pcall did not prevent the native color crash.
  return counts, buffers, errors
end

local function capturePrimitives(descriptor, materialNames, indexCount, budget,scope)
  local primitiveCount = observed(budget,scope,'primitivesCount',count,descriptor,'primitivesCount')
  if primitiveCount <= 0 then return {}, nil end
  assert(budget.primitives+primitiveCount<=2048,'Vehicle primitive budget exceeded; no truncation')
  budget.primitives=budget.primitives+primitiveCount;reserve(budget,primitiveCount*12)
  local typeOk, typeError = ensurePrimitiveType()
  if not typeOk then return {}, typeError end
  local allocationOk, nativePrimitives = pcall(ffi.new, "gpuPrimitive_t[?]", primitiveCount)
  if not allocationOk then return {}, tostring(nativePrimitives) end
  local getterOk, getter = pcall(function() return descriptor.primitivesGet end)
  if not getterOk or type(getter) ~= "function" then return {}, "primitivesGet is unavailable" end
  local callOk, result = observed(budget,scope,'primitivesGet',pcall,getter,descriptor,nativePrimitives)
  if not callOk or (result~=true and result~=1) then return {}, "primitivesGet failed" end

  local primitives = {}
  for index = 0, primitiveCount - 1 do
    local native = nativePrimitives[index]
    local first,length=tonumber(native.startIndex),tonumber(native.indexCount)
    assert(first%3==0 and length%3==0 and first+length<=indexCount,'Invalid native primitive triangle range')
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

local function captureSubmeshes(mesh, accessorName, countName, materialNames, includeOwnBuffers,profile,budget,sharedCounts)
  local submeshCount = observed(budget,'root',countName,count,mesh,countName)
  if submeshCount==0 then return {},{} end
  local accessorOk, accessor = pcall(function() return mesh[accessorName] end)
  if not accessorOk or type(accessor) ~= "function" then return {}, {accessorName .. " is unavailable"} end
  local result = {}
  local errors = {}
  for nativeIndex = 0, submeshCount - 1 do
    local scope=accessorName..'['..nativeIndex..']'
    local ok, descriptor = observed(budget,scope,'descriptor',pcall,accessor,mesh,nativeIndex)
    if ok and descriptor then
      local record = {
        nativeIndex = nativeIndex,
        meshName = tostring(observed(budget,scope,'meshName',readMember,descriptor,'meshName') or ""),
      }
      scope=scope..':'..record.meshName
      if includeOwnBuffers then
        -- Current glass consumer uses UV0 only from shared flexmesh geometry;
        -- it rejects exterior-window props rather than shading them by guess.
        record.counts, record.buffers, record.bufferErrors = captureBuffers(descriptor,'geometry',budget,scope)
        record.captureProfile='geometry'
      end
      local primitives,primitiveError=capturePrimitives(descriptor,materialNames,
        (record.counts or sharedCounts).indices,budget,scope)
      record.primitives=primitives
      result[#result + 1] = record
      if primitiveError then errors[#errors + 1] = record.meshName .. ": " .. primitiveError end
      for _, err in ipairs(record.bufferErrors or {}) do errors[#errors + 1] = record.meshName .. ": " .. err end
    else
      errors[#errors + 1] = accessorName .. "(" .. tostring(nativeIndex) .. ") failed"
    end
  end
  return result, errors
end

-- Explicit caller-owned ready readback only. This module never requests,
-- frees, or retains a native handle; returned records contain CPU buffers only.
local function capture(vehicleId, readyMesh,profile,observer)
  vehicleId = tonumber(vehicleId)
  if not vehicleId or vehicleId~=vehicleId or vehicleId<=0 or vehicleId%1~=0 or vehicleId>2147483647 then return nil,'Invalid vehicle ID' end
  if not ffiOk then return nil, "LuaJIT FFI is unavailable" end

  if cache[vehicleId] then return nil,'Vehicle snapshot already cached; explicit invalidation required' end
  local mesh = readyMesh

  local budget={bytes=0,primitives=0,observer=observer}
  local ready = observed(budget,'root','dataIsReady',readMember,mesh,'dataIsReady')
  if ready ~= true and ready ~= 1 then
    return nil, "vehicle GPUMesh data is not ready"
  end

  local vehicle = observed(budget,'vehicle','resolve',resolveVehicle,vehicleId)
  if not vehicle then return nil,'Vehicle identity unavailable' end
  local namesOk, materialNames = false, nil
  if vehicle then namesOk, materialNames = observed(budget,'vehicle','getMeshMaterialNames',safeCall,vehicle.getMeshMaterialNames,vehicle) end
  if not namesOk or type(materialNames)~='table' then return nil,'Vehicle material names unavailable' end
  local detachedNames={};for i,name in ipairs(materialNames)do
    assert(type(name)=='string','Invalid material name');detachedNames[i]=name
  end;materialNames=detachedNames

  local counts, buffers, bufferErrors = captureBuffers(mesh,profile,budget,'root')
  if not buffers.vertices or not buffers.indices or (profile=='glass' and not buffers.uv1) then
    return nil, "vehicle GPUMesh core buffer acquisition failed: " .. table.concat(bufferErrors, "; ")
  end

  local flexmeshes, flexErrors = captureSubmeshes(mesh, "flexmeshes", "flexmeshesCount", materialNames, false,profile,budget,counts)
  local propmeshes, propErrors = captureSubmeshes(mesh, "propmeshes", "propmeshesCount", materialNames, true,profile,budget,nil)
  for _, err in ipairs(flexErrors) do bufferErrors[#bufferErrors + 1] = err end
  for _, err in ipairs(propErrors) do bufferErrors[#bufferErrors + 1] = err end
  if #bufferErrors>0 then return nil,'Required profile acquisition failed: '..table.concat(bufferErrors,'; ') end

  local primitiveCount = 0
  for _, submesh in ipairs(flexmeshes) do primitiveCount = primitiveCount + #submesh.primitives end
  for _, submesh in ipairs(propmeshes) do primitiveCount = primitiveCount + #submesh.primitives end

  local record = {
    id = vehicleId,
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
    captureProfile=profile,cpuAllocationBytes=budget.bytes,nativeHandleRetained=false,
    readbackOwnership='caller-owned; borrowed during this call only',nativeIdentityVerified=false,
    vertexColorsCaptured=false,optionalBufferPolicy='No normals, tangents, secondary UVs or vertex colors; shared flex UV0 only for glass',
  }
  cache[vehicleId] = record
  return record
end

function M.capture(vehicleId,readyMesh,profile,observer)
  profile=profile or 'geometry'
  if profile~='geometry' and profile~='glass' then return nil,'Unsupported profile; optional color acquisition is disabled' end
  if observer~=nil and type(observer)~='function' then return nil,'Diagnostic observer must be a function' end
  if not readyMesh then return nil,'Explicit caller-owned ready GPUMesh required; implicit native readbacks are disabled' end
  if not ffiOk then return nil,'LuaJIT FFI is unavailable' end
  local checked,ok,abiError=pcall(ensurePrimitiveType)
  if not checked then return nil,'Primitive ABI validation failed: '..tostring(ok) end
  if not ok then return nil,abiError end
  local success,result,err=pcall(capture,vehicleId,readyMesh,profile,observer)
  if not success then return nil,tostring(result) end
  return result,err
end

function M.rebuild(options)
  options = options or {}
  local vehicleId = options.vehicleId
  if vehicleId == nil and be and type(be.getPlayerVehicleID) == "function" then
    local ok, id = safeCall(be.getPlayerVehicleID, be, tonumber(options.playerIndex) or 0)
    if ok then vehicleId = id end
  end
  local record, err = M.capture(vehicleId,options.readyMesh,options.profile)
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
    nativeHandleRetained=false,captureProfile=record.captureProfile,
  }
end

function M.get(vehicleId) return cache[tonumber(vehicleId)] end

function M.invalidate(vehicleId)
  -- SceneDatabase broadcasts a descriptive reason (for example,
  -- "extension unloaded") to every provider. That is a full cache
  -- invalidation, not a specific numeric vehicle ID.
  local id = tonumber(vehicleId)
  if id ~= nil then
    cache[id] = nil
  else
    cache = {}
  end
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
    nativeHandlesOwned=0,vertexColorsCaptured=false,
  }
end

return M
