-- Opt-in tuning of the existing native SSSR classifier, not another renderer.
-- samplesPerQuad=4 requests one independent ray per eligible TRACE pixel.
-- It does not request four rays per pixel or change native SSR enablement.
local M = {}
local OBJECT_NAME, OBJECT_CLASS, FIELD = 'PostFxSSSRObject', 'PostFxSSSR', 'samplesPerQuad'
local requested, comparison, lease = false, 'enhanced', nil
local reason, lastError, restoration = 'Not enabled.', nil, 'No native fields changed.'

local function errorText(value)
  if type(value) ~= 'string' then return 'Native API failed (' .. type(value) .. ').' end
  return (value:gsub('^[^\n]-:%d+:%s*', '')):sub(1, 1024)
end

local function integer(value)
  return type(value) == 'number' and value == value and value > 0
    and value < 2147483648 and value == math.floor(value)
end

local function bindingTables(object)
  local mt = getmetatable(object)
  if mt ~= nil and type(mt) ~= 'table' then error('Native binding metadata is protected or unavailable.', 0) end
  local getters = mt and rawget(mt, 1)
  local setters = mt and rawget(mt, 2)
  if getters ~= nil and type(getters) ~= 'table' or setters ~= nil and type(setters) ~= 'table' then
    error('Native getter/setter metadata is unavailable.', 0)
  end
  return mt, type(getters) == 'table' and getters or nil,
    type(setters) == 'table' and setters or nil
end

local function accessFor(object)
  -- Installed lua/common/luaBinding.lua dispatches registered getters/setters
  -- BEFORE SimObject fields. setField can otherwise create a useless decoy.
  local mt, getters, setters = bindingTables(object)
  local getter = getters and rawget(getters, FIELD)
  local setter = setters and rawget(setters, FIELD)
  if getter ~= nil or setter ~= nil then
    if type(getter) ~= 'function' or type(setter) ~= 'function' then
      error('Native samplesPerQuad typed getter/setter pair is incomplete.', 0)
    end
    if rawget(mt, FIELD) ~= nil then error('Native samplesPerQuad typed property is shadowed.', 0) end
    return {kind = 'typed', metatable = mt, getter = getter, setter = setter}
  end
  local fields = object:getFields()
  if type(fields) ~= 'table' or rawget(fields, FIELD) == nil then
    error('Native samplesPerQuad has neither a complete typed binding nor an advertised static field.', 0)
  end
  getter, setter = object.getField, object.setField
  if type(getter) ~= 'function' or type(setter) ~= 'function' then
    error('Native samplesPerQuad static field methods are unavailable.', 0)
  end
  return {kind = 'static', metatable = mt, getter = getter, setter = setter}
end

local function sameAccess(a, b)
  return a and b and a.kind == b.kind and a.metatable == b.metatable
    and a.getter == b.getter and a.setter == b.setter
end

local function readValue(object, access)
  local raw
  if access.kind == 'typed' then raw = access.getter(object)
  else raw = access.getter(object, FIELD, 0) end
  if access.kind == 'typed' and type(raw) ~= 'number' then
    error('Native samplesPerQuad typed getter did not return a number.', 0)
  end
  if type(raw) ~= 'string' and type(raw) ~= 'number' then error('Native samplesPerQuad read failed.', 0) end
  return raw
end

local function writeValue(snapshot, value)
  -- Do not call a replacement setter, even on the same native object.
  local current = accessFor(snapshot.object)
  if not sameAccess(current, lease.access) then error('Native samplesPerQuad binding changed; write refused.', 0) end
  -- A metadata/getter call may have retired the object since observe(). Only
  -- use the freshly resolved owner, never follow a stale captured reference.
  if not scenetree or type(scenetree.findObject) ~= 'function' then error('Scene lookup unavailable before write.', 0) end
  local object = scenetree.findObject(OBJECT_NAME)
  if object == nil or object ~= snapshot.object or object ~= lease.object
    or object:getClassName() ~= lease.objectClass or object:getID() ~= lease.objectId then
    error('Native SSR object identity changed; write refused.', 0)
  end
  if current.kind == 'typed' then return current.setter(object, value) end
  return current.setter(object, FIELD, 0, tostring(value))
end

local function resolutionDivisor(object)
  local ok, divisor = pcall(function()
    local mt, getters = bindingTables(object)
    local getter = getters and rawget(getters, 'resolutionDivisor')
    if getter ~= nil then
      if type(getter) ~= 'function' or rawget(mt, 'resolutionDivisor') ~= nil then return nil end
      local value = getter(object)
      return type(value) == 'number' and value or nil
    end
    local fields = object:getFields()
    if type(fields) == 'table' and rawget(fields, 'resolutionDivisor') ~= nil then
      return tonumber(object:getField('resolutionDivisor', 0))
    end
  end)
  if ok and type(divisor) == 'number' and divisor == divisor and divisor > 0 and divisor < 16384 then return divisor end
end

local function observe()
  local found, object = pcall(function()
    if not scenetree or type(scenetree.findObject) ~= 'function' then error('Scene lookup unavailable.', 0) end
    return scenetree.findObject(OBJECT_NAME)
  end)
  if not found then return nil, 'Native SSR lookup failed.', 'unknown' end
  if object == nil then return nil, 'Native SSR object is absent.', 'missing' end
  local ok, snapshot = pcall(function()
    if object:getClassName() ~= OBJECT_CLASS then error('Native SSR object class changed.', 0) end
    local id = object:getID()
    if not integer(id) then error('Native SSR identity unavailable.', 0) end
    local enabled = object:isEnabled()
    if type(enabled) ~= 'boolean' then error('Native SSR enabled state is unknown.', 0) end
    local access = accessFor(object)
    local raw = readValue(object, access)
    local value = tonumber(raw)
    local sampleValid = value == 1 or value == 2 or value == 4
    local result = {object = object, objectId = id, objectClass = OBJECT_CLASS,
      nativeEnabled = enabled, raw = tostring(raw), samplesPerQuad = sampleValid and value or nil,
      sampleValid = sampleValid, access = access, resolutionDivisor = resolutionDivisor(object)}
    return result
  end)
  if not ok then return nil, errorText(snapshot), 'unknown' end
  return snapshot
end

local function sameOwner(snapshot)
  return lease and snapshot and snapshot.object == lease.object
    and snapshot.objectId == lease.objectId and snapshot.objectClass == lease.objectClass
end

local function sameBinding(snapshot)
  return lease and snapshot and sameAccess(snapshot.access, lease.access)
end

local function status(snapshot, observationReason)
  local expected = lease and (lease.owns and lease.appliedRaw or lease.baselineRaw)
  local dense = requested and comparison == 'enhanced' and sameOwner(snapshot) and sameBinding(snapshot)
    and snapshot.nativeEnabled and snapshot.samplesPerQuad == 4 and snapshot.raw == expected
    and not lease.restorePending
  return {requested = requested, comparisonMode = comparison, denseTracingActive = dense == true,
    restorePending = lease and lease.restorePending == true or false,
    ownsField = lease and (lease.owns or lease.uncertain) == true or false,
    objectName = OBJECT_NAME, objectId = snapshot and snapshot.objectId,
    objectClass = snapshot and snapshot.objectClass, nativeEnabled = snapshot and snapshot.nativeEnabled,
    available = snapshot and snapshot.sampleValid and snapshot.nativeEnabled or false,
    currentSamplesPerQuad = snapshot and snapshot.samplesPerQuad,
    baselineSamplesPerQuad = lease and lease.baseline,
    baselineSameAsEnhanced = lease and lease.baseline == 4 or false,
    accessKind = snapshot and snapshot.access.kind or 'unavailable',
    ownedAccessKind = lease and lease.access.kind,
    enhancedSamplesPerQuad = 4, resolutionDivisor = snapshot and snapshot.resolutionDivisor,
    reason = reason, lastError = lastError, restoration = restoration,
    observationReason = observationReason, nativeSettingsChanged = false,
    customSsrCombined = false, gameAppearanceVerified = false, performanceVerified = false,
    samplingMeaning = 'One independent ray per eligible native trace pixel, not four samples per pixel.'}
end

local function ownedValue(snapshot)
  if lease.owns and snapshot.raw == lease.appliedRaw then return true end
  -- A setter can change the field and then throw, or a readback can fail.
  -- Keep the ledger until an explicit retry can check the attempted value.
  return lease.uncertain and (snapshot.raw == lease.appliedRaw or snapshot.samplesPerQuad == 4)
end

local function release(action)
  restoration = action
  lease = nil
end

local function restoreField(keepLease)
  if not lease then return true, 'none', 'No owned native fields remain.' end
  if not lease.owns and not lease.uncertain and not lease.restorePending then
    restoration = 'BeamRT did not change the baseline; no restoration write needed.'
    if not keepLease then lease = nil end
    return true, 'baseline', restoration
  end
  local snapshot, why, kind = observe()
  if not snapshot then
    if kind == 'missing' then
      release('Original native object is absent; its lease was retired, not restored.')
      return false, 'retired', restoration
    end
    lease.restorePending = true
    restoration = 'Restoration unconfirmed; ownership retained for explicit disable retry.'
    return false, 'pending', why
  end
  if not sameOwner(snapshot) then
    release('Native object identity changed; replacement left untouched, original not restored.')
    return false, 'retired', restoration
  end
  if not sameBinding(snapshot) then
    lease.restorePending = true
    restoration = 'Native samplesPerQuad binding changed; ownership retained without calling the replacement setter.'
    return false, 'pending', restoration
  end
  if snapshot.samplesPerQuad == lease.baseline then
    lease.owns, lease.uncertain, lease.restorePending, lease.appliedRaw = false, false, false, nil
    lease.baselineRaw = snapshot.raw
    restoration = 'Native samplesPerQuad baseline verified.'
    if not keepLease then lease = nil end
    return true, 'baseline', restoration
  end
  if not ownedValue(snapshot) then
    release('Native samplesPerQuad changed externally; external value preserved, original not restored.')
    return false, 'conflict', restoration
  end
  local owner = lease
  local wrote, failure = pcall(writeValue, snapshot, owner.baseline)
  local after, afterWhy, afterKind = observe()
  if after and sameOwner(after) then
    if not sameBinding(after) then
      owner.uncertain, owner.restorePending = true, true
      restoration = 'Native binding changed during restoration; original ownership retained, replacement setter not called.'
      return false, 'pending', restoration
    end
    if after.samplesPerQuad == owner.baseline then
      owner.owns, owner.uncertain, owner.restorePending, owner.appliedRaw = false, false, false, nil
      owner.baselineRaw = after.raw
      restoration = 'Native samplesPerQuad baseline restored and verified.'
      if not keepLease then lease = nil end
      return true, 'restored', restoration
    end
    -- Track the actual result of our failed restoration, including a clamp.
    owner.owns, owner.appliedRaw, owner.uncertain = true, after.raw, false
  elseif afterKind == 'missing' or after and not sameOwner(after) then
    release('Native object retired during restoration; replacement left untouched, restoration unconfirmed.')
    return false, 'retired', restoration
  else
    owner.uncertain = true
  end
  owner.restorePending = true
  restoration = 'Restoration failed; ownership retained for explicit disable retry.'
  return false, 'pending', afterWhy or (not wrote and errorText(failure)) or 'Native baseline readback did not match.'
end

local function fail(why, rollback)
  requested = false
  lastError, reason = why, why
  if rollback then
    local restored, action, detail = restoreField(false)
    if not restored then reason = why .. ' ' .. (action == 'pending' and restoration or detail) end
  end
  return false, reason
end

local function verifySession(snapshot)
  if not sameOwner(snapshot) then
    release('Native object identity changed; replacement left untouched, original not restored.')
    return false, 'Native SSR object changed; enhancement stopped.'
  end
  if not sameBinding(snapshot) then
    lease.restorePending = true
    return false, 'Native samplesPerQuad binding changed; enhancement stopped with restoration pending.'
  end
  if not snapshot.nativeEnabled then return false, 'Native SSR was disabled; enhancement stopped.' end
  local expected = lease.owns and lease.appliedRaw or lease.baselineRaw
  if not snapshot.sampleValid or snapshot.raw ~= expected then
    release('Native samplesPerQuad changed externally; external value preserved, original not restored.')
    return false, 'Native samplesPerQuad changed externally; enhancement stopped without reclaiming it.'
  end
  return true
end

local function applyEnhanced(snapshot)
  if snapshot.samplesPerQuad == 4 then
    lease.restorePending = false
    return true
  end
  -- Record the baseline/attempt before entering any engine setter.
  lease.uncertain = true
  local wrote, failure = pcall(writeValue, snapshot, 4)
  local after, afterWhy, afterKind = observe()
  if after and sameOwner(after) then
    if not sameBinding(after) then
      lease.restorePending = true
      return fail('Native samplesPerQuad binding changed during write; original ownership retained.', false)
    end
    lease.owns = after.raw ~= lease.baselineRaw
    lease.appliedRaw = lease.owns and after.raw or nil
    lease.uncertain = false
    if not after.nativeEnabled then return fail('Native SSR was disabled during enhancement.', true) end
    if wrote and failure ~= false and after.samplesPerQuad == 4 then
      lease.restorePending = false
      return true
    end
    return fail(not wrote and ('Native samplesPerQuad write failed: ' .. errorText(failure))
      or 'Native samplesPerQuad=4 exact readback was refused.', true)
  end
  if afterKind == 'missing' or after and not sameOwner(after) then
    release('Native object changed during write; replacement left untouched, original restoration unconfirmed.')
    return fail('Native SSR object changed during enhancement; enhancement stopped.', false)
  end
  return fail('Native samplesPerQuad readback failed: ' .. tostring(afterWhy), true)
end

function M.enable()
  if lease and lease.restorePending then return false, 'Restoration is pending; call disable again before enabling.' end
  if requested then return M.update() end
  local snapshot, why = observe()
  if not snapshot then return fail(why, false) end
  if not snapshot.nativeEnabled then return fail('Enable native Screen Space Reflections in BeamNG first.', false) end
  if not snapshot.sampleValid then return fail('Native samplesPerQuad must be exactly 1, 2, or 4.', false) end
  lease = {object = snapshot.object, objectId = snapshot.objectId, objectClass = snapshot.objectClass,
    access = snapshot.access,
    baseline = snapshot.samplesPerQuad, baselineRaw = snapshot.raw,
    owns = false, uncertain = false, restorePending = false}
  requested, comparison = true, 'enhanced'
  local ok, failure = applyEnhanced(snapshot)
  if not ok then return false, failure end
  reason, lastError = 'Native dense tracing selected; appearance and GPU cost are unverified.', nil
  restoration = lease.baseline == 4 and 'Baseline already uses samplesPerQuad=4; no write was needed.'
    or 'Native baseline retained for conditional restoration.'
  return true, M.getStatus()
end

function M.disable(why)
  requested = false
  local ok, action, detail = restoreField(false)
  -- Retired objects/external edits are no longer ours. Do not block a fresh
  -- session on their replacements, but never label those outcomes restored.
  if action == 'retired' or action == 'conflict' then ok = true end
  reason = type(why) == 'string' and why or 'Native SSR enhancement disabled.'
  if not ok then reason, lastError = reason .. ' ' .. restoration, detail; return false, reason end
  lastError = nil
  return true, M.getStatus()
end

function M.update()
  -- The main extension may call this every render even while inactive.
  -- No scene/API queries or automatic restoration retries in that state.
  if not requested then return not (lease and lease.restorePending), status(nil, 'Inactive; not observed during update.') end
  local snapshot, why = observe()
  if not snapshot then return fail(why, true) end
  local valid, failure = verifySession(snapshot)
  if not valid then return fail(failure, lease ~= nil) end
  return true, status(snapshot)
end

function M.setComparisonMode(mode)
  if mode ~= 'native' and mode ~= 'enhanced' then return false, 'Comparison mode must be native or enhanced.' end
  if not requested or not lease then return false, 'Enable the native SSR enhancement before comparing.' end
  local snapshot, why = observe()
  if not snapshot then return fail(why, true) end
  local valid, failure = verifySession(snapshot)
  if not valid then return fail(failure, lease ~= nil) end
  if mode == comparison then return true, status(snapshot) end
  if mode == 'native' then
    local restored, _, detail = restoreField(true)
    if not restored then return fail('Native comparison could not restore the baseline: ' .. tostring(detail), false) end
  else
    local ok, failureText = applyEnhanced(snapshot)
    if not ok then return false, failureText end
  end
  comparison, lastError = mode, nil
  reason = mode == 'native' and 'Native comparison: original samplesPerQuad baseline selected.'
    or 'Enhanced comparison: native dense tracing selected; appearance and cost unverified.'
  return true, M.getStatus()
end

function M.getStatus()
  local snapshot, why = observe()
  return status(snapshot, why)
end

local function boundedValue(value, depth)
  local kind = type(value)
  if kind == 'string' then return value:sub(1, 1024) end
  if kind == 'boolean' or kind == 'nil' then return value end
  if kind == 'number' then
    if value == value and math.abs(value) < math.huge then return value end
    return '[non-finite number]'
  end
  if kind ~= 'table' or depth <= 0 then return '[' .. kind .. ']' end
  local result, count = {}, 0
  for key, item in pairs(value) do
    count = count + 1
    if count > 16 then result.truncated = true; break end
    if type(key) == 'string' then result[key:sub(1, 64)] = boundedValue(item, depth - 1)
    elseif integer(key) and key <= 256 then result[key] = boundedValue(item, depth - 1) end
  end
  return result
end

local function inspectCall(callback)
  local ok, value = pcall(callback)
  if not ok then return {ok = false, error = errorText(value)} end
  return {ok = true, valueType = type(value), value = boundedValue(value, 2)}, value
end

local function inspectMethod(object, name)
  return inspectCall(function()
    local method = object[name]
    if type(method) ~= 'function' then error('Native ' .. name .. ' method is unavailable.', 0) end
    return method(object)
  end)
end

-- Explicit read-only inventory, never called by the per-frame update path.
-- Binding functions/metatables/object references never escape this snapshot.
function M.inspect()
  local result = {objectName = OBJECT_NAME, readOnly = true, objectPresent = false,
    properties = {}, nativeStatus = {}, gameAppearanceVerified = false}
  local lookupOK, object = pcall(function()
    if not scenetree or type(scenetree.findObject) ~= 'function' then error('Scene lookup unavailable.', 0) end
    return scenetree.findObject(OBJECT_NAME)
  end)
  result.lookupOK = lookupOK
  if not lookupOK then result.reason = errorText(object); return result end
  if object == nil then result.reason = 'Native SSR object is absent.'; return result end
  result.objectPresent = true
  local identity, id = inspectMethod(object, 'getID')
  local classResult, class = inspectMethod(object, 'getClassName')
  local enabledResult, enabled = inspectMethod(object, 'isEnabled')
  result.identity, result.class, result.enabled = identity, classResult, enabledResult
  result.objectId = identity.ok and integer(id) and id or nil
  result.objectClass = classResult.ok and type(class) == 'string' and class:sub(1, 128) or nil
  if enabledResult.ok and type(enabled) == 'boolean' then result.nativeEnabled = enabled end
  local metadata, fields = inspectMethod(object, 'getFields')
  local dynamicResult, dynamic = inspectMethod(object, 'getDynamicFields')
  result.staticMetadataAvailable = metadata.ok and type(fields) == 'table'
  result.dynamicMetadataAvailable = dynamicResult.ok and type(dynamic) == 'table'
  local bindingOK, mt, getters, setters = pcall(bindingTables, object)
  result.bindingMetadataAvailable = bindingOK and type(mt) == 'table'
  if not bindingOK then result.bindingError = errorText(mt) end
  for _, name in ipairs({'samplesPerQuad', 'resolutionDivisor'}) do
    local getter, setter
    if bindingOK then
      if getters then getter = rawget(getters, name) end
      if setters then setter = rawget(setters, name) end
    end
    local property = {staticMetadataAvailable = result.staticMetadataAvailable,
      staticAdvertised = result.staticMetadataAvailable and rawget(fields, name) ~= nil or false,
      dynamicAdvertised = false, typedGetterPresent = type(getter) == 'function',
      typedSetterPresent = type(setter) == 'function', getterEntryType = type(getter),
      setterEntryType = type(setter), rawMemberShadow = bindingOK and mt and rawget(mt, name) ~= nil or false,
      rawMemberType = bindingOK and mt and type(rawget(mt, name)) or 'nil'}
    if result.dynamicMetadataAvailable then
      for index = 1, 128 do
        local dynamicName = rawget(dynamic, index)
        if dynamicName == nil then break end
        if dynamicName == name then property.dynamicAdvertised = true end
      end
      if rawget(dynamic, 129) ~= nil then result.dynamicMetadataTruncated = true end
    end
    if type(getter) == 'function' then property.typedRead = inspectCall(function() return getter(object) end)
    else property.typedRead = {ok = false, error = 'No registered typed getter.'} end
    property.fieldRead = inspectCall(function()
      local method = object.getField
      if type(method) ~= 'function' then error('Native getField method is unavailable.', 0) end
      return method(object, name, 0)
    end)
    result.properties[name] = property
  end
  local accessOK, access = pcall(accessFor, object)
  result.accessKind = accessOK and access.kind or 'unavailable'
  if not accessOK then result.accessError = errorText(access) end
  for _, method in ipairs({'getStatus', 'getDenoiserStatus', 'getSurfaceStatus'}) do
    result.nativeStatus[method] = inspectMethod(object, method)
  end
  result.reason = accessOK and 'Read-only native binding inventory; rendering and setter behavior are not verified.'
    or 'Native samplesPerQuad write access is unavailable: ' .. result.accessError
  return result
end

return M
