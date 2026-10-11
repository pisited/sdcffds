-- One real mesh, native direct-sun shading integration. Default OFF.
-- No final-image multiply, fake light, time/camera changes or installation edits.
local M={}
local prefix='BeamRT_MeshSun'
local target='#BeamRT_MeshSunVisibility'
local active=false
local owned={}
local scene,original,errorMessage,savedWire
local nativeShader,nativeMaterial,hookManifest
local sunSign=-1 -- Established world-space caster convention; not screen-space SSR.
local function find(name)return scenetree.findObject(name)end
local function field(object,name,index)return object:getField(name,index or 0)end
local function normalize(text)return text and text:gsub('\r\n','\n')end
local function renderer()return extensions.beamrt_meshBVH end
local function shadowMode(record)
  if not record then return 0 end
  local mode=record.mode or 0
  -- The already-loaded material policy may predate shadowMode. Query the
  -- current native no-shadow declaration without forcing a geometry reload.
  local object=find(record.name)
  if mode==1 and object then
    local ok,value=pcall(field,object,'castShadows')
    if ok and (value=='0'or value=='false')then return 0 end
  end
  return mode
end
local function fail(reason)
  errorMessage=tostring(reason)
  if log then log('E','BeamRT.MeshSunShadow',errorMessage)end
  return false,errorMessage
end
local function register(object,suffix)
  local name=prefix..suffix;object:registerObject(name);owned[#owned+1]=name;return object
end
local function apply()
  local fx=find(prefix..'TraceFx');if not fx or not scene then return end
  renderer().applySceneConsts(fx,scene,active)
  fx:setShaderConst('$meshSunSign',sunSign)
  -- Material opacity and native no-shadow declarations have different purposes.
  for bank=0,3 do
    local modes={}
    for i=1,4 do
      local index=bank*4+i;local record=scene.policy.records[index]
      modes[i]=tostring(shadowMode(record))
    end
    fx:setShaderConst('$meshMaterialModes'..bank,table.concat(modes,' '))
  end
end
local function objects()
  if find(prefix..'TraceFx')then return end
  local state=createObject('GFXStateBlockData')
  state.zDefined=true;state.zEnable=false;state.zWriteEnable=false
  state.blendDefined=true;state.blendEnable=false;state.samplersDefined=true
  for i=0,2 do state:setField('samplerStates',i,'SamplerClampPoint')end
  register(state,'State')
  local shader=createObject('ShaderData')
  shader.DXVertexShaderFile='shaders/beamrt/beamrtMeshSunVisibilityP_v001.hlsl'
  shader.DXPixelShaderFile=shader.DXVertexShaderFile;shader.pixVersion=5
  for i,name in ipairs({'prepassTex','prepassDepthTex','meshDataTex'})do shader:setField('samplerNames',i-1,name)end
  register(shader,'Shader')
  local fx=createObject('PostEffect');fx.isEnabled=false;fx.allowReflectPass=false
  -- Prepass receivers exist here; the mask is ready BEFORE native sunlight.
  fx:setField('renderTime',0,'PFXBeforeBin');fx:setField('renderBin',0,'AL_LightBin')
  fx.renderPriority=10008
  fx:setField('shader',0,prefix..'Shader');fx:setField('stateBlock',0,prefix..'State')
  fx:setField('texture',0,'#prepass[RT0]');fx:setField('texture',1,'#prepass[Depth]')
  fx:setField('texture',2,scene.gpuData.texture)
  fx:setField('target',0,target);fx:setField('targetFormat',0,'GFXFormatR32G32B32A32F')
  fx:setField('targetScale',0,'1 1');fx:setField('targetClear',0,'PFXTargetClear_OnDraw')
  fx:setField('targetClearColor',0,'0 0 0 1');register(fx,'TraceFx')
  rawset(_G,prefix..'TraceFxCallbacks',{onEnabled=function()return true end,setShaderConsts=apply})
end
local function compatible()
  local ok,data=pcall(jsonReadFile,'/shaders/beamrt/generated/nativeSunHook.json')
  if not ok or type(data)~='table' or data.schema~='beamrt.native.sun.hook.v1'
    or data.nativePath~='shaders/common/lighting/advanced/vectorLightP.hlsl'
    or type(data.shaderPath)~='string' or not data.shaderPath:match('^shaders/beamrt/generated/beamrtVectorLight_%x+%.hlsl$')
    or type(data.dependencies)~='table' then return nil,'prepared native sunlight hook missing or invalid' end
  if normalize(readFile('/'..data.nativePath))~=data.nativeSource
    or normalize(readFile('/'..data.shaderPath))~=data.generatedSource then
    return nil,'native/generated sunlight shader changed; prepare against this installation again'
  end
  for path,source in pairs(data.dependencies)do
    if normalize(readFile('/'..path))~=source then return nil,'native sunlight dependency changed: '..path end
  end
  return data
end
function M.disable()
  active=false
  local fx=find(prefix..'TraceFx');if fx then fx:disable()end
  local restored=true
  if original then
    -- Never overwrite another mod's subsequent shader or sampler change.
    if nativeShader and field(nativeShader,'DXPixelShaderFile')==hookManifest.shaderPath then
      nativeShader:setField('DXPixelShaderFile',0,original.shader)
      restored=pcall(nativeShader.reload,nativeShader)and restored
    end
    if nativeMaterial and field(nativeMaterial,'sampler','beamrtMeshSunVisibility')==target then
      nativeMaterial:setField('sampler','beamrtMeshSunVisibility',original.sampler)
      restored=pcall(nativeMaterial.reload,nativeMaterial)and restored
    end
    original=nil
  end
  local alignment=extensions.beamrt_meshAlignment
  if savedWire and alignment and alignment.getStatus().mode=='off'then alignment.setMode(savedWire)end
  savedWire=nil
  return restored
end
function M.enable()
  if active then return true,M.getStatus()end
  if not renderer()then extensions.load('beamrt_meshBVH')end
  if not renderer()then return fail('mesh renderer unavailable')end
  local ok,data=renderer().prepareScene();if not ok then return fail(data)end
  scene=data
  local opaque=0;for _,record in ipairs(scene.policy.records)do if shadowMode(record)==1 then opaque=opaque+1 end end
  if opaque==0 then return fail('no live opaque shadow-casting materials; native lighting retained')end
  local manifest,why=compatible();if not manifest then return fail(why)end
  nativeShader=find('AL_VectorLightShader');nativeMaterial=find('AL_VectorLightMaterial')
  if not nativeShader or not nativeMaterial or type(nativeShader.reload)~='function'
    or type(nativeMaterial.reload)~='function'then return fail('native sunlight objects/reload API unavailable')end
  if field(nativeShader,'DXPixelShaderFile')~=manifest.nativePath
    or field(nativeMaterial,'shader')~='AL_VectorLightShader'then
    return fail('another sunlight shader is active; refusing to replace it')
  end
  local sampler=field(nativeMaterial,'sampler','beamrtMeshSunVisibility')or''
  if sampler~=''then return fail('sunlight hook sampler already owned; refusing to replace it')end
  hookManifest=manifest
  original={shader=field(nativeShader,'DXPixelShaderFile'),sampler=sampler}
  local created,err=pcall(function()
    objects();find(prefix..'TraceFx'):setField('texture',2,scene.gpuData.texture)
    active=true;apply();find(prefix..'TraceFx'):enable()
    nativeMaterial:setField('sampler','beamrtMeshSunVisibility',target)
    nativeShader:setField('DXPixelShaderFile',0,hookManifest.shaderPath)
    nativeShader:reload();nativeMaterial:reload()
  end)
  if not created then M.disable();return fail('sunlight integration failed: '..tostring(err))end
  local alignment=extensions.beamrt_meshAlignment
  if alignment then savedWire=alignment.getStatus().mode;alignment.setMode('off')end
  errorMessage=nil
  if log then log('I','BeamRT.MeshSunShadow','Native direct-sun hook enabled; full mesh, opaque-only, GPU/appearance unverified')end
  return true,M.getStatus()
end
function M.setSunDirection(value)
  if value~='normal'and value~='reversed'then return false end
  sunSign=value=='normal'and 1 or -1;apply();return true
end
function M.getStatus()
  return {enabled=active,error=errorMessage,objectId=scene and scene.objectId,
    triangles=scene and scene.gpuData.triangleCount,completeScene=false,
    target=target,receiverResolution='native full resolution',
    scope='additional opaque mesh visibility in native deferred direct sunlight',
    nativeShadowsPreserved=true,finalImageMultiplied=false,alphaTexturesSampled=false,
    gpuExecutionVerified=false,offscreenPersistenceVerified=false}
end
function M.onPreRender()
  if not active then return end
  if not renderer()then M.disable();fail('mesh renderer unloaded; native fallback');return end
  local data,why=renderer().getSceneBinding()
  if not data then M.disable();fail(why or'stale geometry');return end
  scene=data
  local opaque=0;for _,record in ipairs(data.policy.records)do if shadowMode(record)==1 then opaque=opaque+1 end end
  if opaque==0 or field(nativeShader,'DXPixelShaderFile')~=hookManifest.shaderPath
    or field(nativeMaterial,'sampler','beamrtMeshSunVisibility')~=target then
    M.disable();fail('materials or native hook ownership changed; native fallback');return
  end
  apply()
end
function M.onClientEndMission()M.disable();scene=nil end
function M.onClientStartMission()M.disable();scene=nil end
function M.onExtensionUnloaded()
  M.disable();for i=#owned,1,-1 do local object=find(owned[i]);if object then object:delete()end end
  owned={};scene=nil;rawset(_G,prefix..'TraceFxCallbacks',nil)
end
function M.onExtensionLoaded()if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual')end end
return M
