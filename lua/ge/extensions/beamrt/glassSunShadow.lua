-- Paused-player exterior glass, opacity-map extinction in native deferred sun.
-- Owns a private shader/material binding, never edits window/native source files.
local M={}
local geometry=require('ge/extensions/beamrt/glassGeometry')
local prefix='BeamRT_GlassSun'
local target='#BeamRT_GlassSunVisibility'
local owned={}
local requested,active=false,false
local pending,data,original,nativeMaterial,nativeShader,manifest,shaderName
local producer,callbacks
local serial=0
local reason='Glass sunlight transmission is off.'
local strength,sunSign=1,-1
local function find(name)return scenetree.findObject(name)end
local function field(o,key,index)return o:getField(key,index or 0)end
local function normalize(s)return type(s)=='string'and s:gsub('\r\n','\n')or s end
local function logStatus()if log then log('I','BeamRT.GlassSun',reason)end end
local function register(o,suffix)
  local name=prefix..suffix;assert(not find(name),'Glass object name already occupied')
  o:registerObject(name);owned[#owned+1]={name=name,object=o};return o
end
local function freePending()
  if pending and pending.mesh then pcall(function()pending.mesh:free()end)end
  pending=nil
end
local function compatible()
  local m=jsonReadFile('/shaders/beamrt/generated/glassSunHook.json')
  assert(type(m)=='table'and m.schema=='beamrt.glass.sun.v1','Prepared glass sunlight hook missing')
  assert(m.nativePath=='shaders/common/lighting/advanced/vectorLightP.hlsl'
    and type(m.shaderPath)=='string'and m.shaderPath:match('^shaders/beamrt/generated/beamrtGlassVector_%x+%.hlsl$')
    and type(m.dependencies)=='table','Invalid glass shader manifest')
  assert(normalize(readFile('/'..m.nativePath))==m.nativeSource
    and normalize(readFile('/'..m.shaderPath))==m.generatedSource,'Native/glass shader changed; prepare again')
  for path,source in pairs(m.dependencies)do
    assert(type(path)=='string'and not path:find('..',1,true)
      and normalize(readFile('/'..path))==source,'Glass/native shader dependency changed')
  end
  return m
end
function M.disable(message)
  requested=false;active=false;freePending()
  local fx=find(prefix..'TraceFx')==producer and producer or nil
  -- If native restoration fails, keep a neutral producer rather than leaving
  -- a frozen attenuating mask bound to the still-owned sunlight shader.
  if fx then pcall(fx.setShaderConst,fx,'$glassStrength',0)end
  if original then
    local lease=original
    local ok=pcall(function()
      if find('AL_VectorLightMaterial')==nativeMaterial then
        local changed=false
        if field(nativeMaterial,'sampler','beamrtGlassSunVisibility')==target then
          nativeMaterial:setField('sampler','beamrtGlassSunVisibility',lease.sampler);changed=true
          assert(field(nativeMaterial,'sampler','beamrtGlassSunVisibility')==lease.sampler,'Sunlight sampler restoration rejected')
        end
        if field(nativeMaterial,'shader')==shaderName then
          nativeMaterial:setField('shader',0,lease.shader);changed=true
          assert(field(nativeMaterial,'shader')==lease.shader,'Sunlight shader restoration rejected')
        end
        -- Retry a failed reload even when fields were already restored.
        if changed or lease.retry then
          lease.retry=true;nativeMaterial:reload();lease.retry=false
        end
      end
    end)
    if not ok then reason='Glass sunlight restore failed; retry Disable. Ownership retained.';logStatus();return false,reason end
    original=nil
  end
  if fx then pcall(fx.disable,fx)end
  data=nil
  local remaining={}
  for i=#owned,1,-1 do
    local entry=owned[i];local o=find(entry.name)
    if o==entry.object and not pcall(o.delete,o)then remaining[#remaining+1]=entry end
  end
  owned=remaining
  if #owned>0 then reason='Glass effect cleanup failed; retry Disable.';return false,reason end
  shaderName=nil
  producer=nil
  if rawget(_G,prefix..'TraceFxCallbacks')==callbacks then rawset(_G,prefix..'TraceFxCallbacks',nil)end
  callbacks=nil
  reason=message or 'Native sunlight restored; glass transmission off.';logStatus();return true,reason
end
local function apply()
  if not active or not data then return end
  local fx=find(prefix..'TraceFx');if not fx or fx~=producer then return end
  fx:setShaderConst('$glassStrength',strength);fx:setShaderConst('$glassSunSign',sunSign)
end
local function install(snapshot)
  assert(original==nil,'Restore the old glass sunlight lease first')
  assert(find('AL_VectorLightMaterial')==nativeMaterial and field(nativeMaterial,'shader')=='AL_VectorLightShader',
    'Another sunlight shader is active; no replacement attempted')
  assert((field(nativeMaterial,'sampler','beamrtGlassSunVisibility')or'')=='','Glass sunlight sampler already occupied')
  assert(geometry.valid(snapshot),'Snapshot changed; keep physics paused and recapture')
  serial=serial+1;assert(serial<=8,'Eight snapshot budget reached; reload BeamRT to recapture')
  local tag=serial
  local texels=geometry.texels(snapshot,tag)
  local height=math.ceil(#texels/geometry.width)
  local cacheDir='settings/beamrt/glass_snapshots'
  FS:directoryCreate(cacheDir)
  assert(FS:directoryExists(cacheDir),'Could not create glass cache directory')
  local nonce=(tostring({})..tostring(os.clock())):gsub('[^%w]','')
  local path=cacheDir..'/snapshot_'..nonce..'.data.png'
  local bitmap=GBitmap();bitmap:allocateBitmap(geometry.width,height,false,'GFXFormatR16')
  for y=0,height-1 do for x=0,geometry.width-1 do
    local value=texels[y*geometry.width+x+1]or 0;bitmap:setTexel(x,y,value,value,value,65535)
  end end
  assert(bitmap:saveFile(path),'Could not publish R16 glass geometry cache')
  local state=createObject('GFXStateBlockData');state.zDefined=true;state.zEnable=false;state.zWriteEnable=false
  state.blendDefined=true;state.blendEnable=false;state.samplersDefined=true
  for i=0,5 do state:setField('samplerStates',i,i<3 and 'SamplerClampPoint'or'SamplerWrapLinear')end
  register(state,'State')
  local shader=createObject('ShaderData')
  shader.DXVertexShaderFile='shaders/beamrt/beamrtGlassSunP_v001.hlsl'
  shader.DXPixelShaderFile=shader.DXVertexShaderFile;shader.pixVersion=5
  for i,name in ipairs({'prepassTex','prepassDepthTex','glassGeometryTex','glassOpacity0','glassOpacity1','glassOpacity2'})do
    shader:setField('samplerNames',i-1,name)
  end
  register(shader,'Shader')
  local fx=createObject('PostEffect');fx.isEnabled=false;fx.allowReflectPass=false
  fx:setField('renderTime',0,'PFXBeforeBin');fx:setField('renderBin',0,'AL_LightBin');fx.renderPriority=10008
  fx:setField('shader',0,prefix..'Shader');fx:setField('stateBlock',0,prefix..'State')
  fx:setField('texture',0,'#prepass[RT0]');fx:setField('texture',1,'#prepass[Depth]');fx:setField('texture',2,'/'..path)
  for i=0,2 do fx:setField('texture',3+i,(snapshot.materials[i+1]or snapshot.materials[1]).path)end
  fx:setField('target',0,target);fx:setField('targetFormat',0,'GFXFormatR32G32B32A32F')
  fx:setField('targetScale',0,'1 1');fx:setField('targetClear',0,'PFXTargetClear_OnDraw');fx:setField('targetClearColor',0,'0 0 0 0')
  register(fx,'TraceFx')
  producer=fx
  local function vec(v)return table.concat(v,' ')end
  fx:setShaderConst('$glassMin',vec(snapshot.lo));fx:setShaderConst('$glassExtent',vec(snapshot.extent))
  fx:setShaderConst('$glassUVMin',vec(snapshot.uvLo));fx:setShaderConst('$glassUVExtent',vec(snapshot.uvExtent))
  fx:setShaderConst('$glassAtlasSize',geometry.width..' '..height);fx:setShaderConst('$glassTag',tag)
  fx:setShaderConst('$glassTriangles',#snapshot.triangles);fx:setShaderConst('$glassNodes',#snapshot.nodes)
  fx:setShaderConst('$glassMaterials',#snapshot.materials)
  local factors={0,0,0};for i,m in ipairs(snapshot.materials)do factors[i]=m.factor end
  fx:setShaderConst('$glassOpacityFactor',vec(factors))
  local native=createObject('ShaderData')
  native:setField('DXVertexShaderFile',0,field(nativeShader,'DXVertexShaderFile'))
  native:setField('DXPixelShaderFile',0,manifest.shaderPath)
  for _,key in ipairs({'pixVersion','useDevicePixVersion','defines','DXGeometryShaderFile'})do
    local value=field(nativeShader,key);if value and value~=''then native:setField(key,0,value)end
  end
  for i,name in ipairs({'prePassBuffer','prePassDepthBuffer','ShadowMap','ssaoMask','sssMask',
    'prePassBuffer1','prePassBuffer2','prePassBuffer3','diffIBL','specIBL',
    'prePassBuffer4','prePassBuffer5','cloudTransmittanceCookie','sunShadowMask','beamrtGlassSunVisibility'})do
    native:setField('samplerNames',i-1,name)
    local params=field(nativeShader,'rtParams',i-1);if params and params~=''then native:setField('rtParams',i-1,params)end
  end
  shaderName=prefix..'NativeShader';register(native,'NativeShader')
  original={shader=field(nativeMaterial,'shader'),sampler=field(nativeMaterial,'sampler','beamrtGlassSunVisibility')or''}
  data=snapshot;active=true;apply()
  callbacks={onEnabled=function()return true end,setShaderConsts=apply}
  assert(rawget(_G,prefix..'TraceFxCallbacks')==nil,'Glass shader callback already occupied')
  rawset(_G,prefix..'TraceFxCallbacks',callbacks)
  fx:enable();nativeMaterial:setField('sampler','beamrtGlassSunVisibility',target)
  nativeMaterial:setField('shader',0,shaderName);nativeMaterial:reload()
  assert(field(nativeMaterial,'shader')==shaderName and field(nativeMaterial,'sampler','beamrtGlassSunVisibility')==target,
    'Native glass sunlight binding rejected')
  reason='Glass sunlight transmission scheduled: '..#snapshot.triangles..' exterior triangles, '..#snapshot.materials
    ..' opacity maps; '..snapshot.coordinateMode..'. Neutral shadow only; GPU appearance unverified.';logStatus()
end
function M.enable()
  if requested then return true,reason end
  if original or #owned>0 then return false,'Retry Disable before enabling glass sunlight again.' end
  local ok,why=pcall(function()
    assert(simTimeAuthority and simTimeAuthority.getPause(),'Pause physics with J before capturing window geometry')
    manifest=compatible();nativeShader=find('AL_VectorLightShader');nativeMaterial=find('AL_VectorLightMaterial')
    assert(nativeShader and nativeMaterial and type(nativeMaterial.reload)=='function','Native sunlight reload API unavailable')
    assert(field(nativeShader,'DXPixelShaderFile')==manifest.nativePath and field(nativeMaterial,'shader')=='AL_VectorLightShader',
      'Another native sunlight hook is active; disable it first')
    assert((field(nativeMaterial,'sampler','beamrtGlassSunVisibility')or'')=='','Glass sampler already occupied')
    local vehicle=be:getPlayerVehicle(0);local targetOK,targetWhy=M.checkTarget();assert(targetOK,targetWhy)
    assert(GPUMesh and type(GPUMesh.bng_getGPUMesh)=='function','Native vehicle GPUMesh unavailable')
    pending={vehicle=vehicle,pose=geometry.pose(vehicle),elapsed=0}
    pending.mesh=GPUMesh.bng_getGPUMesh(vehicle:getID());assert(pending.mesh,'Native GPU readback request failed')
  end)
  if not ok then M.disable('Glass sunlight start failed: '..tostring(why));return false,reason end
  requested=true;reason='Waiting for native window mesh readback; keep physics paused.';logStatus();return true,reason
end
function M.update(dt)
  if not requested then return end
  local ok,why=pcall(function()
    if pending then
      assert(simTimeAuthority.getPause()and be:getPlayerVehicle(0)==pending.vehicle
        and geometry.samePose(pending.pose,geometry.pose(pending.vehicle)),'Vehicle/physics changed during capture')
      pending.elapsed=pending.elapsed+(tonumber(dt)or 1/60);assert(pending.elapsed<5,'GPU window mesh readback timed out')
      local ready=pending.mesh.dataIsReady;if type(ready)=='function'then ready=ready(pending.mesh)end
      if ready~=true and ready~=1 then return end
      local snapshot,err=geometry.capture(pending.vehicle,pending.mesh);assert(snapshot,err)
      freePending();install(snapshot)
    elseif active then
      assert(data and geometry.valid(data),'Physics resumed or vehicle/material changed; recapture paused windows')
      assert(find(prefix..'TraceFx')==producer,'Glass visibility producer replaced or removed')
      assert(find('AL_VectorLightMaterial')==nativeMaterial and field(nativeMaterial,'shader')==shaderName
        and field(nativeMaterial,'sampler','beamrtGlassSunVisibility')==target,'Glass sunlight shader ownership changed')
    end
  end)
  if not ok then M.disable('Glass sunlight stopped: '..tostring(why))end
end
function M.setStrength(value)
  if type(value)~='number'or value~=value or value<0 or value>1 then return false,'Expected strength 0..1'end
  strength=value;apply();return true
end
function M.inspectMaterials()return geometry.inspect(be:getPlayerVehicle(0))end
function M.checkTarget()return geometry.checkTarget(be:getPlayerVehicle(0))end
function M.setSunDirection(value)
  if value~='normal'and value~='reversed'then return false end
  sunSign=value=='normal'and 1 or -1;apply();return true
end
function M.getStatus()
  local materials={};if data then for i,m in ipairs(data.materials)do materials[i]=m.name end end
  return {requested=requested,enabled=active,pending=pending~=nil,pendingRestore=(original~=nil or #owned>0)and not active,
    reason=reason,triangles=data and #data.triangles or 0,nodes=data and #data.nodes or 0,materials=materials,
    strength=strength,sunDirection=sunSign==-1 and 'reversed'or'normal',nativeBodyShadowsPreserved=true,
    materialInspection=geometry.getInspection and geometry.getInspection()or nil,
    finalImageMultiplied=false,materialOpacityChanged=false,scope='paused player vehicle; deferred sunlight only',
    rgbTransmission=false,windowReflectionsAdded=false,gpuExecutionVerified=false}
end
return M
