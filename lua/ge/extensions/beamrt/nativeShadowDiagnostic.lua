-- Opt-in native 1.5 visibility relay. Native RGB/BRDF/shadow math stays intact.
-- RT1 alpha is diagnostic-only; no camera-depth occluder tracing or GI coupling.
local M={}
local provider=require('ge/extensions/beamrt/providers/lightProvider')
local inputs=require('ge/extensions/beamrt/lightVisibilityDiagnostic')
local prefix='BeamRT_NativeShadow'
local target='#BeamRT_NativeShadowEpoch'
local snapshot='#BeamRT_NativeShadowSnapshot'
local owned,registered={},{}
local callbacks,processCalls={},{}
local lease,selection,manifest,kind
local active,epoch=false,31
local reason='Native shadow diagnostic is off.'
local function find(name)return scenetree.findObject(name)end
local function field(o,key,index)return o:getField(key,index or 0)or''end
local function normalize(s)return type(s)=='string'and s:gsub('\r\n','\n')or s end
local function manager()
  if type(getActiveLightManager)~='function'then return nil end
  local ok,value=pcall(getActiveLightManager);return ok and tostring(value)or nil
end
local function compatible()
  local data=jsonReadFile('/shaders/beamrt/generated/nativeVisibility.json')
  assert(type(data)=='table'and data.schema=='beamrt.native.visibility.v1'and type(data.dependencies)=='table'
    and type(data.lights)=='table','Prepared native visibility contract missing')
  for path,source in pairs(data.dependencies)do
    assert(type(path)=='string'and not path:find('..',1,true)and normalize(readFile('/'..path))==source,
      'Native visibility dependency changed: '..tostring(path))
  end
  for _,k in ipairs({'Point','Spot'})do
    local h=data.lights[k]
    assert(type(h)=='table'and h.nativePath=='shaders/common/lighting/advanced/'..k:lower()..'LightP.hlsl'
      and type(h.shaderPath)=='string'and h.shaderPath:match('^shaders/beamrt/generated/beamrtNativeVisibility%a+_%x+%.hlsl$')
      and normalize(readFile('/'..h.nativePath))==h.nativeSource
      and normalize(readFile('/'..h.shaderPath))==h.generatedSource,'Native visibility shader changed')
  end
  return data
end
local function same(a,b)
  if a.id~=b.id or a.type~=b.type or math.abs(a.range-b.range)>.00001 then return false end
  for _,key in ipairs({'position','direction'})do
    for i=1,3 do if math.abs(a[key][i]-b[key][i])>.000001 then return false end end
  end
  return math.abs(a.outer-b.outer)<.000001
end
local function collision(a,b)
  if a.type~=b.type or math.abs(a.range-b.range)>.004 then return false end
  for i=1,3 do if math.abs(a.position[i]-b.position[i])>.004 then return false end end
  if a.type=='spot'then
    for i=1,3 do if math.abs(a.direction[i]-b.direction[i])>.0002 then return false end end
    if math.abs(a.outer-b.outer)>.0002 then return false end
  end
  return true
end
local function preflight(token)
  assert(manager()=='Advanced Lighting 1.5','Native diagnostic requires confirmed Advanced Lighting 1.5')
  assert(ClusteredShading==nil,'Exposed clustered dispatch is not integrated; native lighting retained')
  assert(token~=nil,'Choose a scene light name or ID')
  local object=find(tonumber(token)or token)
  local row,why=inputs.sample(object);assert(row,why)
  assert(row.enabledKnown and row.enabled,'Selected scene light is not enabled; test at night')
  local records,queryWhy=provider.queryScene();assert(records,queryWhy)
  local count=0
  for _,r in ipairs(records)do
    local other=inputs.sample(r.object)
    if other and collision(row,other)then count=count+1;assert(r.object==object,'Coincident light parameters: native draw identity is ambiguous')end
  end
  assert(count==1,'Selected light is not uniquely resolved in native scene enumeration')
  local k=row.type=='spot'and'Spot'or'Point'
  local data=compatible();local material=find('AL_'..k..'LightMaterial');local shader=find('AL_'..k..'LightShader')
  assert(material and shader and type(material.reload)=='function','Native local-light material API unavailable')
  assert(field(material,'shader')=='AL_'..k..'LightShader'
    and field(shader,'DXPixelShaderFile')==data.lights[k].nativePath,'Another native local-light shader is active')
  assert(field(material,'target')=='lightinfo'and field(material,'sampler','shadowMap')=='$dynamiclight',
    'Native per-draw shadow/lightinfo binding differs from inspected contract')
  assert(field(material,'sampler','beamrtNativeFrame')=='','Native diagnostic sampler already occupied')
  return {row=row,object=object,kind=k,data=data,material=material,shader=shader}
end
function M.inspect(token)
  local ok,value=pcall(preflight,token)
  return {canStart=ok,reason=ok and 'CPU contract compatible; actual native dispatch/RT1 alpha still unverified.'or tostring(value),
    manager=manager(),clusteredBackendExposed=ClusteredShading~=nil,shadowVizAPI=type(setShadowVizLight),
    light=ok and value.row or nil,shadowTextureAlias=ok and field(value.material,'sampler','shadowMap')or nil,
    matrixSource='native per-draw LightDataAdv.worldToLightProj, not Lua-reconstructed',
    gpuExecutionVerified=false}
end
local function own(class,suffix)
  local name=prefix..suffix;assert(not find(name),'Native diagnostic namespace occupied: '..name)
  local o=createObject(class);assert(o,'Native diagnostic allocation failed');owned[name]=o
  return o,name
end
local function register(o,name)o:registerObject(name);registered[name]=true end
local function watchProcess(name)
  local key=name..'Callbacks';assert(rawget(_G,key)==nil,'Native callback namespace occupied: '..key)
  local cb={preProcess=function()
    processCalls[name]=(processCalls[name]or 0)+1
    -- A lazy request at the late display must not authorize an early capture.
    -- Only the explicit bin-timed parent can authorize its child this epoch.
    for _,pass in ipairs({'Frame','Capture'})do
      if name==prefix..pass..'ScheduleFx'and active then
        owned[prefix..pass..'Fx']:setShaderConst('$nativeScheduledEpoch',epoch)
      end
    end
  end}
  callbacks[key]=cb;rawset(_G,key,cb)
end
function M.disable(message)
  active=false
  -- Neutralize packets and display BEFORE restoration; retain leases on failure.
  for _,suffix in ipairs({'FrameFx','CaptureFx','ViewFx'})do
    local o=owned[prefix..suffix]
    if o and find(prefix..suffix)==o then pcall(o.setShaderConst,o,'$nativeShadowEpoch',0)end
  end
  if lease then
    local ok,err=pcall(function()
      local l=lease
      if find(l.name)==l.material then
        local changed=false
        if field(l.material,'sampler','beamrtNativeFrame')==target then
          l.material:setField('sampler','beamrtNativeFrame',l.sampler);changed=true
          assert(field(l.material,'sampler','beamrtNativeFrame')==l.sampler,'Native sampler restore rejected')
        end
        if field(l.material,'shader')==prefix..'NativeShader'then
          l.material:setField('shader',0,l.shader);changed=true
          assert(field(l.material,'shader')==l.shader,'Native shader restore rejected')
        end
        if changed or l.retry then l.retry=true;l.material:reload();l.retry=false end
      end
    end)
    if not ok then reason='Native visibility restore pending; retry off. '..tostring(err);return false,reason end
    lease=nil
  end
  for _,suffix in ipairs({'ViewFx','CaptureFx','FrameFx','CaptureScheduleFx','FrameScheduleFx',
    'ViewShader','CaptureShader','FrameShader','State','NativeShader'})do
    local name=prefix..suffix;local o=owned[name]
    if o then
      local ok=pcall(function()
        if not registered[name]or find(name)==o then
          if suffix:sub(-2)=='Fx'then o:disable()end
          o:delete()
        end
      end)
      if not ok then reason='Native diagnostic cleanup pending; retry off.';return false,reason end
      owned[name]=nil;registered[name]=nil
    end
  end
  for key,cb in pairs(callbacks)do if rawget(_G,key)==cb then rawset(_G,key,nil)end;callbacks[key]=nil end
  selection=nil;manifest=nil;reason=message or'Native shadow diagnostic is off; native shaders restored.'
  return true,reason
end
local function publish()
  owned[prefix..'FrameFx']:setShaderConst('$nativeShadowEpoch',epoch)
  owned[prefix..'CaptureFx']:setShaderConst('$nativeShadowEpoch',epoch)
  owned[prefix..'ViewFx']:setShaderConst('$nativeShadowEpoch',epoch)
  owned[prefix..'FrameFx']:setShaderConst('$nativeScheduledEpoch',0)
  owned[prefix..'CaptureFx']:setShaderConst('$nativeScheduledEpoch',0)
end
local function advanceEpoch()
  epoch=epoch+1;if epoch==480 then epoch=481 end;if epoch==992 then epoch=1056 end
  assert(epoch<=2015,'Frame-tag budget complete; native shaders restored. Reload BeamRT for another bounded test.')
end
function M.enable(token)
  local ok,ready=pcall(preflight,token);if not ok then return false,tostring(ready)end
  if not M.disable()then return false,reason end
  local result,why=pcall(function()
    advanceEpoch();selection=ready;kind=ready.kind;manifest=ready.data
    local o,name=own('ShaderData','NativeShader')
    o:setField('DXVertexShaderFile',0,field(ready.shader,'DXVertexShaderFile'))
    o:setField('DXPixelShaderFile',0,manifest.lights[kind].shaderPath)
    for _,key in ipairs({'pixVersion','useDevicePixVersion','DXGeometryShaderFile'})do
      local v=field(ready.shader,key);if v~=''then o:setField(key,0,v)end
    end
    for i=0,13 do
      local v=field(ready.shader,'samplerNames',i);if v~=''then o:setField('samplerNames',i,v)end
      v=field(ready.shader,'rtParams',i);if v~=''then o:setField('rtParams',i,v)end
    end
    o:setField('samplerNames',14,'beamrtNativeFrame')
    local function v3(a)return string.format('float3(%.12g,%.12g,%.12g)',a[1],a[2],a[3])end
    local r=ready.row
    o:setField('defines',0,field(ready.shader,'defines')..';BEAMRT_NATIVE_POSITION='..v3(r.position)
      ..';BEAMRT_NATIVE_DIRECTION='..v3(r.direction)..';BEAMRT_NATIVE_RANGE='..string.format('%.12g',r.range)
      ..';BEAMRT_NATIVE_OUTER='..string.format('%.12g',r.outer))
    register(o,name)
    o,name=own('GFXStateBlockData','State');local parent=find('PFX_DefaultStateBlock');assert(parent,'PostFX state unavailable')
    o:inheritParentFields(parent);o.zDefined=true;o.zEnable=false;o.zWriteEnable=false;o.blendDefined=true;o.blendEnable=false
    o.samplersDefined=true;for i=0,2 do o:setField('samplerStates',i,'SamplerClampPoint')end;register(o,name)
    processCalls={}
    for _,pass in ipairs({'Frame','Capture','View'})do
      o,name=own('ShaderData',pass..'Shader')
      o.DXVertexShaderFile='shaders/beamrt/beamrtNativeShadow'..pass..(pass=='View'and'P_v003.hlsl'or pass=='Frame'and'P_v002.hlsl'or'P_v001.hlsl');o.DXPixelShaderFile=o.DXVertexShaderFile;o.pixVersion=5
      o:setField('samplerNames',0,pass=='Capture'and'receiverTex'or'sceneTex')
      if pass=='Capture'then o:setField('samplerNames',1,'nativeSpecTex');o:setField('samplerNames',2,'nativeFrameTex')end
      if pass=='View'then o:setField('samplerNames',1,'nativeSnapshotTex')end
      register(o,name)
      o,name=own('PostEffect',pass..'Fx');o.allowReflectPass=false
      o:setField('shader',0,prefix..pass..'Shader');o:setField('stateBlock',0,prefix..'State')
      o:setField('texture',0,pass=='View'and'$backBuffer'or'#prepass[RT0]')
      if pass=='Frame'then
        o:setField('target',0,target);o:setField('targetSize',0,'1 1');o:setField('targetFormat',0,'GFXFormatR32G32B32A32F')
        o:setField('targetClear',0,'PFXTargetClear_OnDraw');o:setField('targetClearColor',0,'0 0 0 0')
      elseif pass=='Capture'then
        o:setField('texture',1,'#lightinfo[RT1]');o:setField('texture',2,target)
        o:setField('target',0,snapshot);o:setField('targetScale',0,'1 1')
        o:setField('targetFormat',0,'GFXFormatR32G32B32A32F')
        o:setField('targetClear',0,'PFXTargetClear_OnDraw');o:setField('targetClearColor',0,'0 0 0 0')
      else
        o:setField('renderTime',0,'PFXBeforeBin')
        o:setField('renderBin',0,'AfterPostFX');o.renderPriority=1
        o:setField('texture',1,snapshot);o:setField('target',0,'$backBuffer')
        o:setField('targetScale',0,'1 1')
      end
      if pass~='View'then o:setField('renderTime',0,'PFXTexGenOnDemand')end
      register(o,name);o:disable()
      watchProcess(name)
    end
    -- Normal PostFX targets are frame-local. On-demand children own allocations;
    -- explicit parents execute them in chain order EVERY frame (not lazy-once).
    for _,pass in ipairs({'Frame','Capture'})do
      o,name=own('PostEffect',pass..'ScheduleFx');o.allowReflectPass=false;o.skipDraw=true
      o:setField('shader',0,prefix..'FrameShader');o:setField('stateBlock',0,prefix..'State')
      o:setField('texture',0,'#prepass[RT0]');o:setField('target',0,'$outTex')
      o:setField('renderTime',0,pass=='Frame'and'PFXBeforeBin'or'PFXAfterBin')
      o:setField('renderBin',0,'AL_LightBin');o.renderPriority=10010
      register(o,name);o:disable();o:add(owned[prefix..pass..'Fx'])
      watchProcess(name)
    end
    lease={name='AL_'..kind..'LightMaterial',material=ready.material,shader=field(ready.material,'shader'),
      sampler=field(ready.material,'sampler','beamrtNativeFrame')}
    publish()
    for _,suffix in ipairs({'FrameFx','CaptureFx','FrameScheduleFx','CaptureScheduleFx','ViewFx'})do owned[prefix..suffix]:enable()end
    ready.material:setField('sampler','beamrtNativeFrame',target)
    ready.material:setField('shader',0,prefix..'NativeShader');ready.material:reload()
    assert(field(ready.material,'shader')==prefix..'NativeShader'
      and field(ready.material,'sampler','beamrtNativeFrame')==target,'Native diagnostic binding rejected')
    active=true
  end)
  if not result then M.disable('Native diagnostic start failed: '..tostring(why));return false,reason end
  reason='Native visibility instrumentation installed; GPU execution/RT1 alpha relay unverified. Bounded frame-tag test.'
  return true,reason
end
function M.update()
  if not active then return end
  local ok,why=pcall(function()
    assert(manager()=='Advanced Lighting 1.5'and ClusteredShading==nil,'Native lighting backend changed')
    assert(find(selection.row.id)==selection.object,'Selected native light removed/replaced')
    local row,err=inputs.sample(selection.object);assert(row,err)
    assert(row.enabledKnown and row.enabled and same(row,selection.row),'Light disabled or moved; restart diagnostic')
    assert(find(lease.name)==lease.material and field(lease.material,'shader')==prefix..'NativeShader'
      and field(lease.material,'sampler','beamrtNativeFrame')==target,'Native diagnostic lease changed')
    for name,o in pairs(owned)do assert(find(name)==o,'Native diagnostic object replaced')end
    for key,cb in pairs(callbacks)do assert(rawget(_G,key)==cb,'Native diagnostic callback replaced')end
    for _,pass in ipairs({'Frame','Capture','View'})do
      local fx=owned[prefix..pass..'Fx']
      assert(fx:isEnabled()and field(fx,'texture',0)==(pass=='View'and'$backBuffer'or'#prepass[RT0]')
        and field(fx,'stateBlock')==prefix..'State'and field(fx,'shader')==prefix..pass..'Shader'
        and field(fx,'renderTime')==(pass=='View'and'PFXBeforeBin'or'PFXTexGenOnDemand'),
        'Native diagnostic pass modified')
      if pass=='Frame'then
        assert(field(fx,'target')==target and field(fx,'targetSize')=='1 1'
          and field(fx,'targetFormat')=='GFXFormatR32G32B32A32F','Native frame producer modified')
      elseif pass=='Capture'then
        assert(field(fx,'texture',1)=='#lightinfo[RT1]'and field(fx,'texture',2)==target
          and field(fx,'target')==snapshot and field(fx,'targetFormat')=='GFXFormatR32G32B32A32F'
          and field(fx,'targetScale')=='1 1','Early native snapshot modified')
      else
        assert(field(fx,'renderBin')=='AfterPostFX'and tonumber(fx.renderPriority)==1
          and field(fx,'texture',1)==snapshot and field(fx,'texture',2)==''
          and field(fx,'target')=='$backBuffer','Native visibility display modified')
      end
    end
    for _,pass in ipairs({'Frame','Capture'})do
      local fx=owned[prefix..pass..'ScheduleFx']
      assert(fx:isEnabled()and fx.skipDraw==true and field(fx,'renderBin')=='AL_LightBin'
        and field(fx,'renderTime')==(pass=='Frame'and'PFXBeforeBin'or'PFXAfterBin')
        and tonumber(fx.renderPriority)==10010 and field(fx,'target')=='$outTex'
        and field(fx,'shader')==prefix..'FrameShader'and field(fx,'stateBlock')==prefix..'State'
        and field(fx,'texture',0)=='#prepass[RT0]','Native diagnostic scheduler modified')
      assert(fx:getCount()==1 and fx:getObject(0)==owned[prefix..pass..'Fx'],'Native diagnostic child detached/replaced')
    end
    advanceEpoch()
    publish()
  end)
  if not ok then M.disable('Native visibility stopped: '..tostring(why))end
end
function M.getStatus()
  local passes={}
  for _,suffix in ipairs({'FrameScheduleFx','FrameFx','CaptureScheduleFx','CaptureFx','ViewFx'})do
    local name=prefix..suffix;local o=owned[name]
    if o and find(name)==o then
      local ok,size=pcall(function()return o:getRenderTargetSize()end)
      passes[suffix]={processCalls=processCalls[name]or 0,renderTime=field(o,'renderTime'),
        bin=field(o,'renderBin'),target=field(o,'target'),
        targetWidth=ok and size and tonumber(size.x)or nil,targetHeight=ok and size and tonumber(size.y)or nil}
    end
  end
  return {enabled=active,reason=reason,pendingRestore=lease~=nil and not active,pendingCleanup=next(owned)~=nil and not active,
    epoch=epoch,light=selection and selection.row or nil,manager=manager(),gpuExecutionVerified=false,
    nativeVisibilitySource='native per-draw light matrix/shadow map and existing filter; not camera-depth ray marching',
    transport='early native lightinfo RT1 alpha snapshot; persistent owned child targets; 16-level visibility; unique frame tag',
    passes=passes,processCountsAreCPUOnly=true,
    failureBars={'frame texture is not 1x1','frame metadata is nonfinite','frame signature missing/invalid',
      'frame epoch stale/mismatched','lightinfo/prepass texture dimensions incompatible',
      'native alpha is nonfinite','matching native draw reports unavailable shadow map',
      'snapshot texture unavailable','snapshot signature invalid','snapshot epoch stale','snapshot status invalid',
      'reserved valid-packet status','early capture was not scheduled this epoch'},
    nativeDispatchObserved=false,beautyRGBChanged=false,nativeAttenuationChanged=false,feedsGI=false}
end
return M
