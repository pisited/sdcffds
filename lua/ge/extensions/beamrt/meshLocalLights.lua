-- One real underground mesh queried directly in native point/spot shading.
-- Default OFF; no light setters, final-image multiply, camera or time changes.
local M={}
local sceneModule=require('ge/extensions/beamrt/meshLocalScene')
local active=false
local scene,manifest,lastDefines,errorMessage
local originals={}
local owned={}
local serial=0
local frame=0
local shaderCache={}
local function find(name)return scenetree.findObject(name)end
local function field(object,name,index)return object:getField(name,index or 0)end
local function normalize(text)return text and text:gsub('\r\n','\n')end
local function fail(message)
  errorMessage=tostring(message);if log then log('E','BeamRT.MeshLocalLights',errorMessage)end
  return false,errorMessage
end
local function isOwned(name)for _,ownedName in ipairs(owned)do if name==ownedName then return true end end;return false end
local function compatible()
  local data=jsonReadFile('/shaders/beamrt/generated/nativeLocalHooks.json')
  if type(data)~='table'or data.schema~='beamrt.native.local.hooks.v1'or type(data.dependencies)~='table'or type(data.lights)~='table'then
    return nil,'prepared local-light shaders unavailable'
  end
  for path,source in pairs(data.dependencies)do
    if normalize(readFile('/'..path))~=source then return nil,'local-light dependency changed: '..path end
  end
  for _,kind in ipairs({'Point','Spot'})do
    local hook=data.lights[kind]
    if type(hook)~='table'or hook.nativePath~='shaders/common/lighting/advanced/'..(kind=='Point'and'pointLightP.hlsl'or'spotLightP.hlsl')
      or type(hook.shaderPath)~='string'or not hook.shaderPath:match('^shaders/beamrt/generated/beamrtLocal%a+_%x+%.hlsl$')
      or normalize(readFile('/'..hook.nativePath))~=hook.nativeSource
      or normalize(readFile('/'..hook.shaderPath))~=hook.generatedSource then return nil,'native/generated local-light shader changed'end
  end
  return data
end
local function privateShader(kind,native,defines)
  local key=kind..'|'..manifest.lights[kind].shaderPath..'|'..scene.gpuData.texture..'|'
    ..(field(native,'defines')or'')..'|'..field(native,'DXVertexShaderFile')..'|'..defines
  if shaderCache[key]then return shaderCache[key]end
  if #owned>=64 then error('bounded private shader revision budget reached')end
  serial=serial+1
  local name='BeamRT_LocalMesh'..kind..'Shader_'..serial
  if find(name)then error('local-light shader namespace already occupied')end
  local shader=createObject('ShaderData')
  shader:setField('DXVertexShaderFile',0,field(native,'DXVertexShaderFile'))
  shader:setField('DXPixelShaderFile',0,manifest.lights[kind].shaderPath)
  for _,key in ipairs({'pixVersion','useDevicePixVersion','DXGeometryShaderFile'})do
    local value=field(native,key);if value and value~=''then shader:setField(key,0,value)end
  end
  shader:setField('defines',0,(field(native,'defines')or'')..';'..defines)
  for index,name in pairs({[0]='prePassBuffer',[1]='prePassDepthBuffer',[2]='shadowMap',[3]='cookieMap',[5]='prePassBuffer1',[14]='meshDataTex'})do
    shader:setField('samplerNames',index,name)
  end
  shader:registerObject(name);owned[#owned+1]=name
  shaderCache[key]=name
  return name
end
local function install(defines)
  for _,kind in ipairs({'Point','Spot'})do
    local original=originals[kind]
    local material=find(original.name)
    if not material then error('native local-light material unavailable')end
    material:setField('sampler','meshDataTex',scene.gpuData.texture)
    material:setField('shader',0,privateShader(kind,original.shader,defines))
    material:reload()
  end
  lastDefines=defines
end
function M.disable()
  active=false
  local restored=true
  for _,record in pairs(originals)do
    local material=find(record.name)
    if material then
      local changed=false
      if isOwned(field(material,'shader'))then material:setField('shader',0,record.shaderName);changed=true end
      if scene and field(material,'sampler','meshDataTex')==scene.gpuData.texture then
        material:setField('sampler','meshDataTex',record.sampler);changed=true
      end
      if changed then restored=pcall(material.reload,material)and restored end
    end
  end
  originals={};lastDefines=nil
  return restored
end
function M.enable()
  if active then return true,M.getStatus()end
  -- This installation also provides clustered compute shading. Its texture/
  -- structured-buffer bindings are not the legacy CustomMaterial interface.
  -- Do not report a successful install on an unverified alternate route.
  if ClusterShading~=nil or ClusteredShading~=nil then
    return fail('clustered lighting backend exposed; legacy point/spot hook is staged, not activated until matching dispatch/bindings are integrated')
  end
  local data,why=sceneModule.prepare();if not data then return fail(why)end
  scene=data
  local defines,count=sceneModule.defines(scene);if count==0 then return fail('no supported opaque underground blockers; native lighting retained')end
  manifest,why=compatible();if not manifest then return fail(why)end
  local nextOriginals={}
  for _,kind in ipairs({'Point','Spot'})do
    local name='AL_'..kind..'LightMaterial';local material=find(name)
    local shaderName='AL_'..kind..'LightShader';local shader=find(shaderName)
    if not material or not shader or type(material.reload)~='function'or field(shader,'DXVertexShaderFile')==''then return fail('native '..kind..' lighting API unavailable')end
    if field(material,'shader')~=shaderName or field(shader,'DXPixelShaderFile')~=manifest.lights[kind].nativePath
      or(field(material,'sampler','meshDataTex')or'')~=''then return fail('another local-light shader/sampler is active; refusing replacement')end
    nextOriginals[kind]={name=name,shaderName=shaderName,shader=shader,sampler=field(material,'sampler','meshDataTex')or''}
  end
  originals=nextOriginals
  local ok,err=pcall(install,defines)
  if not ok then M.disable();return fail('local-light material binding failed: '..tostring(err))end
  active=true;errorMessage=nil;frame=0
  if log then log('I','BeamRT.MeshLocalLights','Native point/spot world-mesh blocker path enabled; appearance and GPU binding unverified')end
  return true,M.getStatus()
end
function M.onPreRender()
  if not active then return end
  if ClusterShading~=nil or ClusteredShading~=nil then
    M.disable();fail('clustered lighting backend exposed; legacy local-light hook stopped');return
  end
  frame=frame+1
  for _,record in pairs(originals)do
    local material=find(record.name)
    if not material or not isOwned(field(material,'shader'))or field(material,'sampler','meshDataTex')~=scene.gpuData.texture then
      M.disable();fail('native local-light ownership changed');return
    end
  end
  if frame%30~=0 then return end
  local data,why=sceneModule.getBinding(true)
  if not data then M.disable();fail(why);return end
  scene=data
  local defines,count=sceneModule.defines(data)
  if count==0 then M.disable();fail('opaque underground coverage unavailable');return end
  if defines~=lastDefines then
    local ok,err=pcall(install,defines)
    if not ok then M.disable();fail(err)end
  end
end
function M.getStatus()
  return {enabled=active,error=errorMessage,objectId=scene and scene.objectId,
    selectedShape=scene and scene.asset.shapePath,triangles=scene and scene.gpuData.triangleCount,
    nodes=scene and scene.gpuData.nodeCount,scope='one imported underground instance, legacy native deferred point and spot lights',
    clusteredBackendExposed=ClusterShading~=nil or ClusteredShading~=nil,clusteredDispatchIntegrated=false,
    installation='fresh ShaderData with direct BVH queries in native local-light shading',
    cameraDepthRelayUsed=false,controlledVehicleSelectionUsed=false,brightnessOrColorChanged=false,
    nativeShadowsPreserved=true,ambientLightingChanged=false,alphaTexturesSampled=false,
    completeScene=false,gpuExecutionVerified=false,appearanceVerified=false}
end
function M.getBackendInfo()
  -- Bounded read-only member metadata, no getter calls or values/pointers.
  local backend=ClusterShading
  local backendName='ClusterShading'
  if backend==nil then backend=ClusteredShading;backendName='ClusteredShading'end
  local result={schema='beamrt.cluster.backend-metadata.v2',exposed=backend~=nil,
    name=backend~=nil and backendName or nil,kind=type(backend),members={},truncated=false}
  local seen={}
  local function collect(value,prefix,depth)
    if type(value)~='table'or seen[value]then return end
    seen[value]=true
    for key,member in next,value do
      if #result.members>=128 then result.truncated=true;return end
      if type(key)=='string'then
        result.members[#result.members+1]={name=prefix..key,kind=type(member)}
        if type(member)=='table'then
          if depth<4 then collect(member,prefix..key..'.',depth+1)else result.truncated=true end
        end
      end
    end
    -- Installed lua/common/luaBinding.lua: 1=getters, 2=setters, 3=super.
    -- These numeric slots are absent from a string-key-only member inventory.
    -- Inspect raw registration tables only; never invoke a bound accessor.
    for index,label in ipairs({'getters.','setters.','super.'})do
      local child=rawget(value,index)
      if type(child)=='table'then
        if depth<4 then collect(child,prefix..label,depth+1)else result.truncated=true end
      end
    end
  end
  collect(backend,'',0)
  if backend~=nil then collect(getmetatable(backend),'meta.',0)end
  table.sort(result.members,function(a,b)return a.name<b.name end)
  return result
end
function M.onClientEndMission()M.disable();sceneModule.clear();scene=nil end
function M.onClientStartMission()M.disable();sceneModule.clear();scene=nil end
function M.onExtensionUnloaded()
  M.disable()
  for i=#owned,1,-1 do local object=find(owned[i]);if object then object:delete()end end
  owned={};shaderCache={};sceneModule.clear();scene=nil
end
function M.onExtensionLoaded()if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual')end end
return M
