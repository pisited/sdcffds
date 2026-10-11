-- Read-only field/binding inspection. No objects, textures or settings changed.
local M = {}

local function fieldsFor(object)
  local errors = {}
  for _, method in ipairs({'getFieldsForEditor', 'getFields'}) do
    local ok, fields = pcall(function()
      if type(object[method]) ~= 'function' then return nil end
      return object[method](object)
    end)
    if ok and type(fields) == 'table' then return fields end
    if not ok then errors[#errors + 1] = method .. ': ' .. tostring(fields) end
  end
  return nil, table.concat(errors, '; ')
end

local function descriptor(fields, name)
  if type(fields) ~= 'table' then return nil end
  if type(fields[name]) == 'table' then return fields[name] end
  for _, field in pairs(fields) do
    if type(field) == 'table' and (field.name == name or field.fieldName == name) then return field end
  end
end

local function summary(field, metadataKnown)
  if not field then
    if metadataKnown then return {present = false, metadataAvailable = true} end
    return {metadataAvailable = false}
  end
  local result = {present = true}
  for key, value in pairs(field) do
    if type(key) == 'string' and (type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean') then
      result[key] = value
    end
  end
  local count = tonumber(field.elementCount or field.arraySize)
  if count and count >= 0 and count <= 64 and count == math.floor(count) then result.capacity = count end
  return result
end

local function readField(object, name, index)
  local ok, value = pcall(function() return object:getField(name, index or 0) end)
  if ok and value ~= nil then return tostring(value) end
end

local function inspect(name)
  local object = scenetree and scenetree.findObject(name)
  if not object then return {name = name, available = false} end
  local fields, err = fieldsFor(object)
  local result = {name = name, available = true, metadataError = err,
    texture = summary(descriptor(fields, 'texture'), fields ~= nil),
    textureCube = summary(descriptor(fields, 'textureCube'), fields ~= nil),
    shaderName = readField(object, 'shader', 0)}
  -- Read array indices only when the real native descriptor supplies bounds.
  result.boundCubes = {}
  if result.textureCube.capacity then
    for i = 0, result.textureCube.capacity - 1 do
      local target = readField(object, 'textureCube', i)
      if target and target ~= '' then result.boundCubes[#result.boundCubes + 1] = {index = i, target = target} end
    end
  end
  local shader = result.shaderName and scenetree.findObject(result.shaderName)
  if shader then
    result.pixelShaderFile = readField(shader, 'DXPixelShaderFile', 0)
    local shaderFields = fieldsFor(shader)
    result.samplerNamesDescriptor = summary(descriptor(shaderFields, 'samplerNames'), shaderFields ~= nil)
    result.samplerNames = {}
    if result.samplerNamesDescriptor.capacity then
      for i = 0, result.samplerNamesDescriptor.capacity - 1 do
        local value = readField(shader, 'samplerNames', i)
        if value and value ~= '' then result.samplerNames[#result.samplerNames + 1] = {index = i, name = value} end
      end
    end
  end
  return result
end

function M.getStatus()
  local objects = {}
  for _, name in ipairs({'BeamRT_ReflectionFx', 'BeamRT_ReflectionTemporalFx',
    'BeamRT_AuxiliaryPackFx', 'PostEffectSkyCameraVolumeFallback'}) do
    objects[#objects + 1] = inspect(name)
  end
  return {probeVersion = 1, renderingChanged = false, shaderResourcesMoved = false,
    cubeRegisterMapping = 'UNVERIFIED: a separate field does not prove a separate register bank.', objects = objects}
end

function M.printStatus()
  local result = M.getStatus()
  for _, object in ipairs(result.objects) do
    if type(log) == 'function' then
      local cubePresence = object.textureCube and object.textureCube.present
      log('I', 'BeamRT.CubeInputs', object.name .. ': available=' .. tostring(object.available)
        .. '; 2D=' .. tostring(object.texture and object.texture.capacity or 'unknown')
        .. '; cubeField=' .. (cubePresence == nil and 'unknown' or tostring(cubePresence))
        .. '; cubeCount=' .. tostring(object.textureCube and object.textureCube.capacity or 'unknown')
        .. '; shader=' .. tostring(object.shaderName))
    end
  end
  if type(dumps) == 'function' and type(log) == 'function' then log('I', 'BeamRT.CubeInputs', dumps(result)) end
  return result
end

function M.onExtensionLoaded()
  if type(setExtensionUnloadMode) == 'function' then setExtensionUnloadMode(M, 'manual') end
  M.printStatus()
end

return M
