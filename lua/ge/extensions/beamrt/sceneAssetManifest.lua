-- BeamRT static scene asset manifest v001.
-- Acquisition-only: stable primitive data for offline .dae processing.
-- It never claims a TSStatic world box is a visual mesh or GPU triangle data.
local M = {}
local function scalar(x)
  local n=tonumber(x)
  if not n or n~=n or n==math.huge or n==-math.huge then return nil end
  return n
end
local function point(v)
  if v==nil then return nil end
  local ok,x,y,z=pcall(function() return v.x or v[1],v.y or v[2],v.z or v[3] end)
  if not ok then return nil end
  x,y,z=scalar(x),scalar(y),scalar(z)
  if x and y and z then return {x,y,z} end
end
local function member(obj,field)
  if not obj then return nil end
  local ok,v=pcall(function() return obj[field] end)
  if ok and v~=nil and v~="" and type(v)~="function" then return v end
  ok,v=pcall(function() return obj:getField(field,0) end)
  if ok and v~=nil and v~="" then return v end
  return nil
end
local function method(obj,field)
  if not obj then return nil end
  local ok,v=pcall(function() return obj[field](obj) end)
  if ok then return v end
end
local function identity(obj,name)
  local v=method(obj,name)
  if v~=nil and tostring(v)~="" then return tostring(v) end
end
local function roundedVectorOrString(obj,methodName)
  local v=method(obj,methodName)
  if v==nil then return nil,nil end
  return point(v), tostring(v)
end
local function assetExt(path)
  return tostring(path):lower():match("%.([a-z0-9]+)$") or "unknown"
end
local function safeText(value)
  local kind=type(value)
  if kind=="string" or kind=="number" or kind=="boolean" then
    return tostring(value)
  end
  -- Never serialize game-object userdata or a nested property table.
  return nil
end
local function parseInstance(obj,token)
  local class=identity(obj,"getClassName")
  if class~="TSStatic" then return nil end
  local key=tostring(member(obj,"shapeName") or member(obj,"shapeFile") or "")
  if key=="" then return nil end
  local position, positionRaw=roundedVectorOrString(obj,"getPosition")
  local scale,scaleRaw=roundedVectorOrString(obj,"getScale")
  local _,transformRaw=roundedVectorOrString(obj,"getTransform")
  local _,worldBoundsRaw=roundedVectorOrString(obj,"getWorldBox")
  local placement,placementError=require("ge/extensions/beamrt/meshPlacement").capture(obj)
  return {
    name=identity(obj,"getName") or tostring(token),
    id=scalar(method(obj,"getID")),
    assetKey=key,
    position=position,positionRaw=positionRaw,
    scale=scale,scaleRaw=scaleRaw,
    transformRaw=transformRaw,
    worldBoundsRaw=worldBoundsRaw,
    materialHint=safeText(member(obj,"material")),
    materialsHint=safeText(member(obj,"materials")),
    positionField=safeText(member(obj,"position")),
    nativePlacement=placement,placementError=placementError,
    -- materialHint is metadata only; TSStatic may have per-submesh
    -- materials that require Collada instance bind_material resolution.
    -- MATRIX CONVENTION IS NOT VERIFIED. Never use transformRaw to place
    -- triangles until BeamNG matrix row/column and pivot are confirmed.
    transformVerified=false,meshTrianglesAvailable=false,
    worldSpaceTrianglesAvailable=false
  }
end
local function append(result, record)
  result.instances[#result.instances+1]=record
  local key=record.assetKey
  if not result.assets[key] then
    result.assets[key]={shapePath=key,extension=assetExt(key),
      instanceCount=0,verifiedMeshAvailable=false}
  end
  result.assets[key].instanceCount=result.assets[key].instanceCount+1
end
function M.capture(options)
  options=type(options)=="table" and options or {}
  local cap=math.floor(tonumber(options.limit) or 512)
  cap=math.max(1,math.min(20000,cap))
  local tokens=options.tokens
  local cached=options.cached
  if tokens==nil and cached~=true then
    if not scenetree or type(scenetree.findClassObjects)~="function" then
      return nil,"scenetree.findClassObjects is unavailable"
    end
    local ok,found=pcall(scenetree.findClassObjects,"TSStatic")
    if not ok or type(found)~="table" then
      return nil,"TSStatic enumeration failed"
    end
    tokens=found
  elseif tokens==nil then
    local provider=require("ge/extensions/beamrt/providers/tsStaticProvider")
    tokens={}
    for _,rec in ipairs(provider.getInstances() or {}) do
      tokens[#tokens+1]=rec.object or rec.name or rec.id
    end
  end
  if type(tokens)~="table" then return nil,"tokens must be a list" end
  local result={
    schema="beamrt.static.manifest.v1",
    purpose="offline shape discovery and extraction (not runtime ray data)",
    assets={},instances={},
    scope=cached and "cached" or "enumerated",
    inputCount=#tokens,truncated=#tokens>cap,
    maxCount=cap,space="BeamNG world metres",
    transformsVerified=false,realMeshTrianglesImported=false,
    alphaMaterialsVerified=false,shaderStorageReady=false
  }
  local failed=0
  for i=1,math.min(cap,#tokens) do
    local token=tokens[i]
    local obj=token
    if type(token)~="userdata" and type(token)~="table" then
      local ok,v=pcall(function() return scenetree.findObject(token) end)
      obj=ok and v or nil
    end
    local ok,record=pcall(parseInstance,obj,token)
    if ok and record then append(result,record) else failed=failed+1 end
  end
  local assetCount=0
  local types={}
  for _,asset in pairs(result.assets) do
    assetCount=assetCount+1
    types[asset.extension]=(types[asset.extension] or 0)+1
  end
  result.stats={assets=assetCount,instances=#result.instances,
    unresolved=failed,extensions=types}
  return result
end
function M.write(path,options)
  if type(path)~="string" or not path:match("^/settings/beamrt[%w_%-]+%.json$") then
    return false,"use /settings/beamrt<name>.json as the export path"
  end
  local manifest,err=M.capture(options)
  if not manifest then return false,err end
  if type(jsonWriteFile)~="function" then
    return false,"jsonWriteFile is unavailable"
  end
  local ok,result=pcall(jsonWriteFile,path,manifest,true)
  if not ok or result==false then
    return false,"JSON writing failed: "..tostring(result)
  end
  return true,{path=path,stats=manifest.stats,
    inputCount=manifest.inputCount,truncated=manifest.truncated,
    warnings={"Scene transforms are not yet validated for baking.",
      "This manifest exports shape references, not triangles."}}
end
return M
