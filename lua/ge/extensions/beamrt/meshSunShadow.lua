-- One real mesh, native direct-sun shading integration. Default OFF.
-- No final-image multiply, fake light, time/camera changes or installation edits.
local M={}
local prefix='BeamRT_MeshSun'
local target='#BeamRT_MeshSunVisibility'
local active=false
local owned={}
local scene,original,errorMessage,savedWire
local nativeShader,nativeMaterial,hookManifest
local shaderBindings={}
local sunSign=-1 -- Established world-space caster convention; not screen-space SSR.
local comparison='hybrid'
local function ownedMaterialShader(name)
  for _,ownedName in pairs(shaderBindings)do if name==ownedName then return true end end
  return false
end
local function selectedShader(data)
  return data.variants and data.variants[comparison] and data.variants[comparison].shaderPath or data.shaderPath
end
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
local function privateNativeShader(path)
  if shaderBindings[path]then return shaderBindings[path]end
  local suffix='NativeShader_'..assert(path:match('beamrtVectorLight_(%x+)%.hlsl$'))
  local name=prefix..suffix
  if find(name)then error('private sunlight shader name already owned elsewhere')end
  local shader=createObject('ShaderData')
  -- A fresh ShaderData creates an empty compiled-program cache. Changing the
  -- filenames on the already-cached native object and calling reload() can
  -- simply reload its old GFXShader program paths in Torque-derived engines.
  shader:setField('DXVertexShaderFile',0,field(nativeShader,'DXVertexShaderFile'))
  shader:setField('DXPixelShaderFile',0,path)
  for _,key in ipairs({'pixVersion','useDevicePixVersion','defines','OGLVertexShaderFile','OGLPixelShaderFile','DXGeometryShaderFile'})do
    local value=field(nativeShader,key)
    if value and value~=''then shader:setField(key,0,value)end
  end
  for i,sampler in ipairs({'prePassBuffer','prePassDepthBuffer','ShadowMap','ssaoMask','sssMask',
    'prePassBuffer1','prePassBuffer2','prePassBuffer3','diffIBL','specIBL',
    'prePassBuffer4','prePassBuffer5','cloudTransmittanceCookie','sunShadowMask','beamrtMeshSunVisibility'})do
    shader:setField('samplerNames',i-1,sampler)
    local params=field(nativeShader,'rtParams',i-1)
    if params and params~=''then shader:setField('rtParams',i-1,params)end
  end
  register(shader,suffix);shaderBindings[path]=name
  return name
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
  fx:setField('targetClearColor',0,'0 0 0 0');register(fx,'TraceFx')
  rawset(_G,prefix..'TraceFxCallbacks',{onEnabled=function()return true end,setShaderConsts=apply})
end
local function compatible()
  local ok,data=pcall(jsonReadFile,'/shaders/beamrt/generated/nativeSunHook.json')
  if not ok or type(data)~='table' or (data.schema~='beamrt.native.sun.hook.v1'and data.schema~='beamrt.native.sun.hook.v2')
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
  if comparison~='hybrid'and not(data.variants and data.variants[comparison])then
    return nil,'sun comparison variants not prepared for this installation'
  end
  for _,variant in pairs(data.variants or{})do
    if type(variant.shaderPath)~='string'or not variant.shaderPath:match('^shaders/beamrt/generated/beamrtVectorLight_%x+%.hlsl$')
      or normalize(readFile('/'..variant.shaderPath))~=variant.generatedSource then
      return nil,'prepared comparison shader changed or unavailable'
    end
  end
  return data
end
function M.disable()
  active=false
  local fx=find(prefix..'TraceFx');if fx then fx:disable()end
  local restored=true
  if original then
    local changed=false
    -- Never overwrite another mod's subsequent shader or sampler change.
    if nativeMaterial and ownedMaterialShader(field(nativeMaterial,'shader'))then
      nativeMaterial:setField('shader',0,original.materialShader)
      changed=true
    end
    if nativeMaterial and field(nativeMaterial,'sampler','beamrtMeshSunVisibility')==target then
      nativeMaterial:setField('sampler','beamrtMeshSunVisibility',original.sampler)
      changed=true
    end
    if changed then restored=pcall(nativeMaterial.reload,nativeMaterial)and restored end
    original=nil
  end
  local alignment=extensions.beamrt_meshAlignment
  if savedWire and alignment and alignment.getStatus().mode=='off'then alignment.setMode(savedWire)end
  savedWire=nil
  comparison='hybrid'
  return restored
end
function M.enable()
  if active then return true,M.getStatus()end
  if not renderer()then extensions.load('beamrt_meshBVH')end
  if not renderer()then return fail('mesh renderer unavailable')end
  if type(renderer().applySceneConsts)~='function'or type(renderer().getSceneBinding)~='function'then
    return fail('loaded meshBVH predates shared geometry; reload that extension once')
  end
  local ok,data=renderer().prepareScene();if not ok then return fail(data)end
  scene=data
  local opaque=0;for _,record in ipairs(scene.policy.records)do if shadowMode(record)==1 then opaque=opaque+1 end end
  if opaque==0 then return fail('no live opaque shadow-casting materials; native lighting retained')end
  local manifest,why=compatible();if not manifest then return fail(why)end
  nativeShader=find('AL_VectorLightShader');nativeMaterial=find('AL_VectorLightMaterial')
  if not nativeShader or not nativeMaterial or type(nativeMaterial.reload)~='function'
    or field(nativeShader,'DXVertexShaderFile')==''then return fail('native sunlight objects/material reload API unavailable')end
  if field(nativeShader,'DXPixelShaderFile')~=manifest.nativePath
    or field(nativeMaterial,'shader')~='AL_VectorLightShader'then
    return fail('another sunlight shader is active; refusing to replace it')
  end
  local sampler=field(nativeMaterial,'sampler','beamrtMeshSunVisibility')or''
  if sampler~=''then return fail('sunlight hook sampler already owned; refusing to replace it')end
  hookManifest=manifest
  original={materialShader=field(nativeMaterial,'shader'),sampler=sampler}
  local created,err=pcall(function()
    objects();find(prefix..'TraceFx'):setField('texture',2,scene.gpuData.texture)
    active=true;apply();find(prefix..'TraceFx'):enable()
    nativeMaterial:setField('sampler','beamrtMeshSunVisibility',target)
    nativeMaterial:setField('shader',0,privateNativeShader(selectedShader(hookManifest)))
    nativeMaterial:reload()
  end)
  if not created then M.disable();return fail('sunlight integration failed: '..tostring(err))end
  local alignment=extensions.beamrt_meshAlignment
  if alignment then savedWire=alignment.getStatus().mode;alignment.setMode('off')end
  if type(renderer().setView)=='function'then renderer().setView('off')end
  errorMessage=nil
  if log then log('I','BeamRT.MeshSunShadow','Native direct-sun hook enabled; full mesh, opaque-only, GPU/appearance unverified')end
  return true,M.getStatus()
end
function M.setSunDirection(value)
  if value~='normal'and value~='reversed'then return false end
  sunSign=value=='normal'and 1 or -1;apply();return true
end
function M.setComparisonMode(value)
  if value~='hybrid'and value~='beamrt-only'and value~='unshadowed'and value~='split'then return false,'unknown sun comparison mode'end
  if not active then comparison=value;return true end
  if value~='hybrid'and not(hookManifest.variants and hookManifest.variants[value])then return false,'comparison variants not prepared'end
  if not ownedMaterialShader(field(nativeMaterial,'shader'))then M.disable();return fail('sunlight shader ownership changed')end
  comparison=value
  local ok,err=pcall(function()
    nativeMaterial:setField('shader',0,privateNativeShader(selectedShader(hookManifest)));nativeMaterial:reload()
  end)
  if not ok then M.disable();return fail('comparison reload failed: '..tostring(err))end
  return true,M.getStatus()
end
function M.getStatus()
  return {enabled=active,error=errorMessage,objectId=scene and scene.objectId,
    triangles=scene and scene.gpuData.triangleCount,completeScene=false,
    target=target,receiverResolution='native full resolution',
    shaderInstallation='private ShaderData plus material rebinding',
    activeMaterialShader=nativeMaterial and field(nativeMaterial,'shader'),
    scope='additional opaque mesh visibility in native deferred direct sunlight',
    comparisonMode=comparison,nativeShadowsPreserved=not active or comparison=='hybrid',
    nativeGeometricSunShadowsBypassed=active and comparison~='hybrid',
    splitLeft=comparison=='split'and'native sunlight'or nil,
    splitRight=comparison=='split'and'BeamRT-only geometric sun shadows'or nil,
    localLightShadowsChanged=false,ambientLightingChanged=false,
    finalImageMultiplied=false,alphaTexturesSampled=false,
    gpuExecutionVerified=false,offscreenPersistenceVerified=false}
end
function M.onPreRender()
  if not active then return end
  if not renderer()then M.disable();fail('mesh renderer unloaded; native fallback');return end
  local data,why=renderer().getSceneBinding()
  if not data then M.disable();fail(why or'stale geometry');return end
  scene=data
  local opaque=0;for _,record in ipairs(data.policy.records)do if shadowMode(record)==1 then opaque=opaque+1 end end
  if opaque==0 or not ownedMaterialShader(field(nativeMaterial,'shader'))
    or field(nativeMaterial,'sampler','beamrtMeshSunVisibility')~=target then
    M.disable();fail('materials or native hook ownership changed; native fallback');return
  end
  apply()
end
function M.onClientEndMission()M.disable();scene=nil end
function M.onClientStartMission()M.disable();scene=nil end
function M.onExtensionUnloaded()
  M.disable();for i=#owned,1,-1 do local object=find(owned[i]);if object then object:delete()end end
  owned={};shaderBindings={};scene=nil;rawset(_G,prefix..'TraceFxCallbacks',nil)
end
function M.onExtensionLoaded()if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual')end end
return M
