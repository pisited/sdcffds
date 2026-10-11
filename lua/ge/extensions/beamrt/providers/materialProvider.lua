local M = {name = "materials"}

local records = {}
local byName = {}
local generation = 0
local lastStats = {valid = true, materials = 0, acquisitionOnly = true, feedsRayTracer = false}

local MATERIAL_FIELDS = {
  "baseColorMap", "diffuseMap", "normalMap", "roughnessMap", "metallicMap",
  "ambientOcclusionMap", "opacityMap", "baseColorFactor", "roughnessFactor",
  "metallicFactor", "translucent", "translucentBlendOp", "alphaRef",
  "doubleSided", "emissive", "emissiveMap", "emissiveFactor",
  "emissiveIntensityNits",
}

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  return pcall(fn, ...)
end

local function resolveMaterial(materialOrName)
  if type(materialOrName) == "userdata" then return materialOrName end
  if type(materialOrName) == "table" and type(materialOrName.getClassName) == "function" then return materialOrName end
  local ok, object = safeCall(scenetree and scenetree.findObject, materialOrName)
  return ok and object or nil
end

local function readField(material, name)
  local ok, value = pcall(function() return material[name] end)
  if ok and value ~= nil and value ~= "" and type(value) ~= "function" then return value end
  ok, value = safeCall(material and material.getField, material, name, "0")
  if ok and value ~= nil and value ~= "" then return value end
  ok, value = safeCall(material and material.getField, material, name, "")
  if ok and value ~= nil and value ~= "" then return value end
  return nil
end

function M.capture(materialOrName)
  local material = resolveMaterial(materialOrName)
  if not material then return nil, "material object could not be resolved" end
  local classOk, className = safeCall(material.getClassName, material)
  if not classOk or tostring(className) ~= "Material" then return nil, "resolved object is not a Material" end
  local nameOk, materialName = safeCall(material.getName, material)
  materialName = nameOk and tostring(materialName) or tostring(materialOrName)
  if materialName == "" then return nil, "material has no stable name" end

  local values = {}
  for _, fieldName in ipairs(MATERIAL_FIELDS) do values[fieldName] = readField(material, fieldName) end
  local idOk, id = safeCall(material.getID, material)
  local record = {
    id = idOk and tonumber(id) or nil,
    name = materialName,
    object = material,
    fields = values,
  }
  byName[materialName] = record
  local replaced = false
  for index, existing in ipairs(records) do
    if existing.name == materialName then records[index] = record; replaced = true; break end
  end
  if not replaced then records[#records + 1] = record end
  return record
end

function M.ingestNames(names)
  local captured, failures = 0, {}
  local seen = {}
  for _, name in ipairs(type(names) == "table" and names or {}) do
    name = tostring(name or "")
    if name ~= "" and not seen[name] then
      seen[name] = true
      local record, err = M.capture(name)
      if record then captured = captured + 1 else failures[#failures + 1] = {name = name, error = err} end
    end
  end
  generation = generation + 1
  lastStats = {
    valid = #failures == 0,
    generation = generation,
    requested = (function() local count = 0; for _ in pairs(seen) do count = count + 1 end; return count end)(),
    captured = captured,
    materials = #records,
    failures = failures,
    acquisitionOnly = true,
    feedsRayTracer = false,
  }
  return #failures == 0, lastStats
end

function M.rebuild(options)
  options = options or {}
  local names = options.names or options.materialNames
  if type(names) ~= "table" then return false, "material rebuild requires options.names" end
  records = {}
  byName = {}
  return M.ingestNames(names)
end

function M.invalidate()
  records = {}
  byName = {}
  lastStats = {valid = true, generation = generation, materials = 0, acquisitionOnly = true, feedsRayTracer = false}
end

function M.get(name) return name ~= nil and byName[tostring(name)] or nil end
function M.getRecords() return records end
function M.getStats() return lastStats end

return M
