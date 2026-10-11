-- Read-only inspector loaded as extensions.load('beamrt_nativeCubemapProbe').
-- Source resolution is not proof that a compiled GPU permutation executed it.
local M = {}
local virtualPath = '/shaders/common/material/shadergen/permutations.h.hlsl'
local manifestPath = '/shaders/beamrt/nativeCubemapProbeManifest.json'

local function fsCall(method, path)
  if not FS then return nil, 'filesystem interface unavailable' end
  local ok, result = pcall(function() return FS[method](FS, path) end)
  if not ok then return nil, tostring(result) end
  if result == nil or result == '' then return nil, 'no result' end
  return tostring(result)
end

local function normalized(path)
  return type(path) == 'string' and path:gsub('\\', '/'):lower() or nil
end

function M.getStatus()
  local path, pathError = fsCall('getFileRealPath', virtualPath)
  local hash, hashError = fsCall('hashFileSHA1', virtualPath)
  local manifest
  if type(jsonReadFile) == 'function' then
    local ok, value = pcall(jsonReadFile, manifestPath)
    if ok and type(value) == 'table' and value.experimentId == 'beamrt-native-scene-cubemap-probe-v1' then
      manifest = value
    end
  end
  local matchPath = manifest and path and normalized(path) == normalized(manifest.target) or false
  local matchHash = manifest and hash and type(manifest.overrideSha1) == 'string'
    and hash:lower() == manifest.overrideSha1:lower() or false
  return {virtualPath = virtualPath, resolvedRealPath = path, resolutionError = pathError,
    resolvedSha1 = hash, hashError = hashError, manifestAvailable = manifest ~= nil,
    overrideWinsVfs = matchPath, expectedSourceHashMatches = matchHash,
    sourceOverrideVerified = matchPath and matchHash,
    mode = manifest and manifest.mode or 'unknown',
    gpuExecution = 'UNVERIFIED: observe magenta on eligible native reflections, then confirm restored appearance.',
    eligibility = 'Modern scene-cubemap branch only; excludes custom cubemap sources, custom buffers and focused metadata.',
    beamrtStateChanged = false,
    refresh = 'Full BeamNG restart after enabling/disabling; Lua reload is not a verified shader refresh.'}
end

function M.printStatus()
  local status = M.getStatus()
  if type(dumps) == 'function' then print(dumps(status)) end
  if type(log) == 'function' then
    log('I', 'BeamRT.NativeCubemapProbe', 'VFS source verified=' .. tostring(status.sourceOverrideVerified)
      .. '; real path=' .. tostring(status.resolvedRealPath) .. '; SHA1=' .. tostring(status.resolvedSha1)
      .. '; GPU execution remains unverified')
  end
  return status
end

function M.onExtensionLoaded()
  if type(setExtensionUnloadMode) == 'function' then setExtensionUnloadMode(M, 'manual') end
  M.printStatus()
end

return M
