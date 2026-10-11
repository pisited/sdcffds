local M = {name = "decalRoads"}

local records = {}
local byId = {}
local byName = {}
local valid = false
local generation = 0
local lastStats = {}
local lastError = nil

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  return pcall(fn, ...)
end

local function objectField(object, fieldName, defaultValue)
  if not object then return defaultValue end
  local ok, value = pcall(function() return object[fieldName] end)
  if ok and value ~= nil and type(value) ~= "function" and value ~= "" then return value end
  if type(object.getField) == "function" then
    ok, value = pcall(object.getField, object, fieldName, "")
    if ok and value ~= nil and value ~= "" then return value end
    ok, value = pcall(object.getField, object, fieldName, "0")
    if ok and value ~= nil and value ~= "" then return value end
  end
  return defaultValue
end

local function objectId(object)
  if not object then return nil end
  local ok, value = safeCall(object.getID, object)
  return ok and tonumber(value) or nil
end

local function objectName(object)
  if not object then return nil end
  local ok, value = safeCall(object.getName, object)
  if ok and value and value ~= "" then return tostring(value) end
  value = objectField(object, "name", nil)
  return value and tostring(value) or nil
end

local function findObject(token)
  if not scenetree then return nil end
  if type(scenetree.findObject) == "function" then
    local ok, object = safeCall(scenetree.findObject, token)
    if ok and object then return object end
    local numericId = tonumber(token)
    if numericId and numericId ~= token then
      ok, object = safeCall(scenetree.findObject, numericId)
      if ok and object then return object end
    end
  end
  return nil
end

local function valueOr(record, object, fieldName, defaultValue)
  local value = record and record[fieldName]
  if value ~= nil and value ~= "" then return value end
  return objectField(object, fieldName, defaultValue)
end

local function normalizedRecord(raw, key, object, source)
  raw = type(raw) == "table" and raw or {}
  local id = tonumber(raw.id or raw.objectId or raw.roadId) or objectId(object)
  local name = raw.name or raw.internalName or objectName(object)
  local vertices = type(raw.vertices) == "table" and raw.vertices or {}
  return {
    id = id,
    name = name,
    material = valueOr(raw, object, "material", ""),
    vertices = vertices,
    edgeCount = math.floor(#vertices / 9),
    drivability = tonumber(valueOr(raw, object, "drivability", 0)) or 0,
    lanesLeft = tonumber(valueOr(raw, object, "lanesLeft", 0)) or 0,
    lanesRight = tonumber(valueOr(raw, object, "lanesRight", 0)) or 0,
    oneWay = valueOr(raw, object, "oneWay", 0),
    inverted = valueOr(raw, object, "inverted", 0),
    textureLength = tonumber(valueOr(raw, object, "textureLength", 0)) or 0,
    renderPriority = tonumber(valueOr(raw, object, "renderPriority", 0)) or 0,
    overObjects = valueOr(raw, object, "overObjects", 0),
    detail = tonumber(valueOr(raw, object, "detail", 0)) or 0,
    breakAngle = tonumber(valueOr(raw, object, "breakAngle", 0)) or 0,
    zBias = tonumber(valueOr(raw, object, "zBias", 0)) or 0,
    startEndFade = valueOr(raw, object, "startEndFade", 0),
    improvedSpline = valueOr(raw, object, "improvedSpline", 0),
    useSubdivisions = valueOr(raw, object, "useSubdivisions", 0),
    canSave = valueOr(raw, object, "canSave", nil),
    hidden = valueOr(raw, object, "hidden", nil),
    source = source,
    bulkKey = key,
  }
end

-- Bulk DecalRoad records contain edge data and navigation fields but omit
-- several material-layer properties. Once the matching SceneTree object is
-- known, always source those properties from the object rather than retaining
-- normalized zero placeholders.
local function backfillObjectMetadata(record, object)
  if not record or not object then return false end
  local numericFields = {
    "textureLength", "renderPriority", "detail", "breakAngle", "zBias",
  }
  local scalarFields = {
    "overObjects", "startEndFade", "improvedSpline", "useSubdivisions",
    "canSave", "hidden",
  }
  local updated = false
  for _, name in ipairs(numericFields) do
    local value = objectField(object, name, nil)
    if value ~= nil then
      record[name] = tonumber(value) or record[name]
      updated = true
    end
  end
  for _, name in ipairs(scalarFields) do
    local value = objectField(object, name, nil)
    if value ~= nil then
      record[name] = value
      updated = true
    end
  end
  local objectMaterial = objectField(object, "material", nil)
  if (record.material == nil or record.material == "") and objectMaterial then
    record.material = objectMaterial
    updated = true
  end
  record.sceneMetadataBackfilled = updated
  return updated
end

local function registerAlias(tableRef, key, record, collisionStats)
  if key == nil or key == "" then return end
  local normalized = tostring(key)
  local previous = tableRef[normalized]
  if previous and previous ~= record then
    collisionStats.aliasCollisions = collisionStats.aliasCollisions + 1
    return
  end
  tableRef[normalized] = record
end

local function registerAliases(record, raw, key, keyIsArrayIndex, collisionStats)
  registerAlias(byId, record.id, record, collisionStats)
  registerAlias(byName, record.name, record, collisionStats)
  -- A numeric 1..#bulk key is ordinarily just a Lua array index, not a
  -- SceneObject ID. Treating it as an ID can create false-positive matches.
  if not keyIsArrayIndex then
    if tonumber(key) then registerAlias(byId, key, record, collisionStats) end
    if type(key) == "string" then registerAlias(byName, key, record, collisionStats) end
  end
  if type(raw) == "table" then
    registerAlias(byId, raw.id, record, collisionStats)
    registerAlias(byId, raw.objectId, record, collisionStats)
    registerAlias(byId, raw.roadId, record, collisionStats)
    registerAlias(byName, raw.name, record, collisionStats)
    registerAlias(byName, raw.internalName, record, collisionStats)
  end
end

local function matchRecord(token, object)
  local id = objectId(object)
  local name = objectName(object)
  return byId[tostring(id)] or byName[tostring(name)] or byId[tostring(token)] or byName[tostring(token)]
end

function M.invalidate()
  records = {}
  byId = {}
  byName = {}
  valid = false
  lastError = nil
  lastStats = {valid = false, generation = generation}
end

function M.rebuild(options)
  options = options or {}
  local started = os.clock()
  local bulkOk, bulk = safeCall(Sim and Sim.getDecalRoadData)
  if not bulkOk or type(bulk) ~= "table" then
    lastError = "Sim.getDecalRoadData() failed or returned no table"
    lastStats = {valid = false, error = lastError}
    return false, lastStats.error
  end

  records = {}
  byId = {}
  byName = {}
  local collisionStats = {aliasCollisions = 0}
  local bulkCount = 0
  local floatCount = 0
  local arrayLength = #bulk
  for key, raw in pairs(bulk) do
    if type(raw) == "table" and type(raw.vertices) == "table" then
      local record = normalizedRecord(raw, key, nil, "bulk")
      records[#records + 1] = record
      local keyIsArrayIndex = type(key) == "number"
        and key >= 1 and key <= arrayLength and key == math.floor(key)
      registerAliases(record, raw, key, keyIsArrayIndex, collisionStats)
      bulkCount = bulkCount + 1
      floatCount = floatCount + #record.vertices
    end
  end

  local sceneTokens = {}
  local sceneQueryOk = false
  if scenetree and type(scenetree.findClassObjects) == "function" then
    local sceneOk, result = safeCall(scenetree.findClassObjects, "DecalRoad")
    if sceneOk and type(result) == "table" then
      sceneTokens = result
      sceneQueryOk = true
    end
  end
  if not sceneQueryOk then
    lastError = "scenetree.findClassObjects('DecalRoad') failed or returned no table"
    valid = false
    lastStats = {valid = false, error = lastError, bulkRoads = bulkCount}
    return false, lastError
  end

  local missing = {}
  local matched = 0
  local metadataBackfilled = 0
  for _, token in ipairs(sceneTokens) do
    local object = findObject(token)
    local record = matchRecord(token, object)
    if record then
      matched = matched + 1
      local id = objectId(object)
      local name = objectName(object)
      if record.id == nil then record.id = id end
      if record.name == nil then record.name = name end
      if backfillObjectMetadata(record, object) then metadataBackfilled = metadataBackfilled + 1 end
      registerAlias(byId, id, record, collisionStats)
      registerAlias(byName, name, record, collisionStats)
    else
      missing[#missing + 1] = {token = token, object = object, id = objectId(object)}
    end
  end

  -- A bad identity match must never degrade into ~12k slow native calls. The
  -- verified West Coast omission set is 12 roads; 256 is a generous guardrail.
  local fallbackLimit = math.max(0, math.floor(tonumber(options.maxFallbackRoads) or 256))
  local fallbackCount = 0
  local fallbackFailures = 0
  local fallbackSkipped = 0
  if #missing <= fallbackLimit then
    for _, missingRoad in ipairs(missing) do
      local ok, vertices = false, nil
      if missingRoad.object and missingRoad.id then
        ok, vertices = safeCall(Sim and Sim.getVerticesOfDecalRoad, missingRoad.id)
      end
      if ok and type(vertices) == "table" then
        local raw = {id = missingRoad.id, vertices = vertices}
        local record = normalizedRecord(raw, missingRoad.token, missingRoad.object, "fallback")
        records[#records + 1] = record
        registerAliases(record, raw, missingRoad.token, false, collisionStats)
        fallbackCount = fallbackCount + 1
        floatCount = floatCount + #vertices
      else
        fallbackFailures = fallbackFailures + 1
      end
    end
  else
    fallbackSkipped = #missing
  end

  generation = generation + 1
  local coveredSceneRoads = matched + fallbackCount
  local coverageComplete = coveredSceneRoads == #sceneTokens
    and fallbackFailures == 0 and fallbackSkipped == 0
  valid = coverageComplete
  lastError = coverageComplete and nil or string.format(
    "DecalRoad cache incomplete: covered %d of %d SceneTree roads (%d failures, %d skipped)",
    coveredSceneRoads, #sceneTokens, fallbackFailures, fallbackSkipped
  )
  lastStats = {
    valid = valid,
    error = lastError,
    generation = generation,
    sceneRoads = #sceneTokens,
    bulkRoads = bulkCount,
    bulkMatched = matched,
    missingFromBulk = #missing,
    fallbackRoads = fallbackCount,
    fallbackFailures = fallbackFailures,
    fallbackSkipped = fallbackSkipped,
    coveredSceneRoads = coveredSceneRoads,
    coverageComplete = coverageComplete,
    aliasCollisions = collisionStats.aliasCollisions,
    metadataBackfilled = metadataBackfilled,
    cachedRoads = #records,
    edgeFloats = floatCount,
    edgeCount = math.floor(floatCount / 9),
    buildSeconds = os.clock() - started,
    acquisitionOnly = true,
    feedsRayTracer = false,
  }
  if not coverageComplete then return false, lastError end
  return true, lastStats
end

function M.isValid() return valid end
function M.getRecords() return records end
function M.getById(id) return id ~= nil and byId[tostring(id)] or nil end
function M.getByName(name) return name ~= nil and byName[tostring(name)] or nil end
function M.getStats() return lastStats end

return M
