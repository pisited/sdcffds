-- Diagnostic ONLY: one selected native scene light, no illumination writes.
-- Does not claim access to dispatch-owned clustered shadow resources.
local M={}
local provider=require('ge/extensions/beamrt/providers/lightProvider')
local modes={influence=1,direction=2,visibility=3,native=4}
local prefix='BeamRT_LightVisibility'
local owned,registered={},{}
local selected,selectedId,mode,active,latest=nil,nil,'visibility',false,nil
local reason='Light visibility diagnostic is off.'
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<math.huge end
local function vector(v)
  if type(v)=='string'then
    local a={};for n in v:gmatch('[-+%d.eE]+')do a[#a+1]=tonumber(n)end
    if #a<3 then return nil end
    for i=1,3 do if not finite(a[i])then return nil end end
    return {a[1],a[2],a[3]}
  end
  if not v then return nil end
  local ok,a=pcall(function()return {tonumber(v.x or v.r or v[1]),tonumber(v.y or v.g or v[2]),tonumber(v.z or v.b or v[3])}end)
  if not ok then return nil end
  for i=1,3 do if not finite(a[i])then return nil end end
  return a
end
local function state(v)
  if v==true or v==1 or v=='1'or v=='true'then return true end
  if v==false or v==0 or v=='0'or v=='false'then return false end
  return nil
end
local function declared(object,key)
  local ok,v=pcall(function()return object:getField(key,0)end)
  if ok and v~=nil and v~=''then return v end
  ok,v=pcall(function()return object[key]end)
  if ok and type(v)~='function'and v~=nil and v~=''then return v end
  return nil
end
function M.sample(object)
  local ok,r=pcall(provider.readObject,object)
  if not ok or not r then return nil,'Selected object is not a readable PointLight/SpotLight.' end
  if not finite(r.id)or r.id<=0 or r.id%1~=0 then return nil,'Native light identity unavailable.'end
  local p,c=vector(r.position),vector(r.color)
  r.brightness=tonumber(declared(object,'brightness'))
  local range=r.type=='spot'and r.range or r.radius
  if not p or not c or not finite(range)or range<=0 or not finite(r.brightness)or r.brightness<0 then
    return nil,'Invalid light position/color/range/brightness; no guessed defaults.'
  end
  for i=1,3 do if c[i]<0 then return nil,'Invalid negative light color.'end end
  local enabled=state(declared(object,'isEnabled'))
  if enabled==nil then enabled=state(declared(object,'enabled'))end
  if enabled==nil and type(object.isEnabled)=='function'then
    local read,value=pcall(object.isEnabled,object);if read then enabled=state(value)end
  end
  local direction,outer,inner={0,0,1},-1,1
  if r.type=='spot'then
    direction=vector(r.direction)
    local a,b=r.innerAngle,r.outerAngle
    if not direction or not finite(a)or not finite(b)or a<0 or b<=0 or a>b or b>=180 then
      return nil,'Invalid spotlight axis/cone; no guessed direction.'
    end
    local length=math.sqrt(direction[1]^2+direction[2]^2+direction[3]^2)
    if length<1e-6 then return nil,'Zero spotlight axis.'end
    for i=1,3 do direction[i]=direction[i]/length end
    outer=math.cos(math.rad(b*.5));inner=math.cos(math.rad(a*.5))
  end
  return {id=r.id,name=r.name,type=r.type,position=p,color=c,range=range,
    direction=direction,outer=outer,inner=inner,brightness=r.brightness,
    enabled=enabled,enabledKnown=enabled~=nil,castShadows=state(r.castShadows),
    shadowType=r.shadowType,intensity=declared(object,'intensity'),
    attenuation=declared(object,'attenuationRatio'),cookie=declared(object,'cookie'),
    nativeVisibility={available=false,source='unavailable',reason='No verified per-light shadow atlas/view binding in this PostFX.'},
    photometry='Relative declared brightness only; engine intensity conversion/exposure/cookies not reproduced.'}
end
function M.list()
  -- Explicit one-shot enumeration, never done each frame or by status getters.
  local records,why=provider.queryScene()
  if not records then return nil,why end
  local eye=core_camera and vector(core_camera.getPosition())or nil
  local rows={}
  for _,r in ipairs(records)do
    local row,err=M.sample(r.object)
    if row then
      row.distance=eye and math.sqrt((row.position[1]-eye[1])^2+(row.position[2]-eye[2])^2+(row.position[3]-eye[3])^2)or nil
      rows[#rows+1]=row
    else rows[#rows+1]={id=r.id,name=r.name,rejected=err}end
  end
  table.sort(rows,function(a,b)
    local x,y=a.distance or math.huge,b.distance or math.huge
    return x==y and tostring(a.id)<tostring(b.id)or x<y
  end)
  local result={total=#rows,lights={},scope='native scene PointLight/SpotLight only; sun/vehicle/emissive not integrated'}
  for i=1,math.min(#rows,16)do result.lights[i]=rows[i]end
  return result
end
local function own(class,suffix)
  local name=prefix..suffix;assert(not scenetree.findObject(name),'Diagnostic namespace occupied: '..name)
  local o=createObject(class);assert(o,'Diagnostic object allocation failed');owned[name]=o
  return o,name
end
function M.disable(message)
  active=false
  local pass=owned[prefix..'Fx']
  if pass and scenetree.findObject(prefix..'Fx')==pass then
    -- A failed native disable/delete must not leave stale evidence displayed.
    pcall(pass.setShaderConst,pass,'$diagnosticMode',0)
  end
  for _,suffix in ipairs({'Fx','Shader','State'})do
    local name=prefix..suffix;local o=owned[name]
    if o then
      local ok=pcall(function()
        if not registered[name]or scenetree.findObject(name)==o then
          if suffix=='Fx'then o:disable()end
          o:delete()
        end
      end)
      if not ok then reason='Diagnostic cleanup pending; retry off.';return false,reason end
      owned[name]=nil;registered[name]=nil
    end
  end
  selected=nil;selectedId=nil;latest=nil
  reason=message or 'Light visibility diagnostic is off.';return true,reason
end
local function upload(pass,row)
  local function vec(a,w)return string.format('%.9g %.9g %.9g %.9g',a[1],a[2],a[3],w)end
  pass:setShaderConst('$diagnosticMode',modes[mode])
  pass:setShaderConst('$diagnosticPosition',vec(row.position,row.range))
  pass:setShaderConst('$diagnosticDirection',vec(row.direction,row.outer))
  pass:setShaderConst('$diagnosticColor',vec(row.color,row.brightness))
  pass:setShaderConst('$diagnosticInner',row.inner)
  pass:setShaderConst('$diagnosticSpot',row.type=='spot'and 1 or 0)
  pass:setShaderConst('$diagnosticEnabled',row.enabledKnown and(row.enabled and 1 or 0)or -1)
end
function M.enable(id,view)
  if view~=nil and not modes[view]then return false,'Use influence, direction, visibility or native.'end
  if not id then return false,'Select an explicit native light object ID from listLightVisibilityCandidates().'end
  local object=scenetree.findObject(tonumber(id)or id)
  local row,why=M.sample(object);if not row then return false,why end
  if not M.disable()then return false,reason end
  mode=view or 'visibility'
  local ok,err=pcall(function()
    local o,name=own('ShaderData','Shader')
    o.DXVertexShaderFile='shaders/beamrt/beamrtLightVisibilityP_v003.hlsl'
    o.DXPixelShaderFile=o.DXVertexShaderFile;o.pixVersion=5
    for i,s in ipairs({'sceneTex','normalTex','depthTex'})do o:setField('samplerNames',i-1,s)end
    o:registerObject(name);registered[name]=true
    o,name=own('GFXStateBlockData','State')
    local parent=scenetree.findObject('PFX_DefaultStateBlock');assert(parent,'Default PostFX state missing')
    o:inheritParentFields(parent);o.zDefined=true;o.zEnable=false;o.zWriteEnable=false
    o.blendDefined=true;o.blendEnable=false;o.samplersDefined=true
    for i=0,2 do o:setField('samplerStates',i,'SamplerClampPoint')end
    o:registerObject(name);registered[name]=true
    o,name=own('PostEffect','Fx');o.allowReflectPass=false
    o:setField('shader',0,prefix..'Shader');o:setField('stateBlock',0,prefix..'State')
    o:setField('texture',0,'$backBuffer');o:setField('texture',1,'#prepass[RT0]');o:setField('texture',2,'#prepass[Depth]')
    o:setField('target',0,'$backBuffer');o:setField('targetScale',0,'1 1')
    -- Last debug display, after both renderers' histories and local haze.
    o:setField('renderTime',0,'PFXBeforeBin');o:setField('renderBin',0,'AfterPostFX');o.renderPriority=1
    o:registerObject(name);registered[name]=true
    o:disable();selected=object;selectedId=row.id;latest=row;upload(o,row);o:enable();active=true
  end)
  if not ok then M.disable('Diagnostic start failed: '..tostring(err));return false,reason end
  reason='Diagnostic scheduled for light '..tostring(row.id)..' ('..tostring(row.name)..'); GPU output unverified.'
  return true,reason
end
function M.setMode(view)
  if not modes[view]then return false,'Use influence, direction, visibility or native.'end
  mode=view;if active then upload(owned[prefix..'Fx'],latest)end
  return true
end
function M.update()
  if not active then return end
  local ok,why=pcall(function()
    assert(scenetree.findObject(selectedId)==selected,'Selected light removed or replaced')
    for name,o in pairs(owned)do assert(scenetree.findObject(name)==o,'Diagnostic object replaced')end
    local fx=owned[prefix..'Fx']
    assert(fx:isEnabled()and fx:getField('shader',0)==prefix..'Shader'
      and fx:getField('stateBlock',0)==prefix..'State'
      and fx:getField('renderTime',0)=='PFXBeforeBin'and fx:getField('renderBin',0)=='AfterPostFX'
      and tonumber(fx.renderPriority)==1 and fx:getField('target',0)=='$backBuffer'
      and fx:getField('texture',0)=='$backBuffer'and fx:getField('texture',1)=='#prepass[RT0]'
      and fx:getField('texture',2)=='#prepass[Depth]','Diagnostic pass bindings changed')
    local row,err=M.sample(selected);assert(row,err);latest=row;upload(fx,row)
  end)
  if not ok then M.disable('Diagnostic stopped: '..tostring(why))end
end
function M.getStatus()
  return {enabled=active,mode=mode,light=latest,reason=reason,pendingCleanup=next(owned)~=nil and not active,
    nativeVisibilityAvailable=false,screenVisibility='approximate hit or unknown, never proven clear',
    receiverBias='depth-neighbour geometric frame, 5-25 mm offset, 3-15 mm receiver-plane rejection',
    rayPolicy='32 coarse samples, at most two 6-step crossing refinements; 2 cm depth residual; misses remain unknown',
    geometryVisibilityAvailable=false,feedsGI=false,appliesShadowAttenuation=false,
    clusteredBackendExposed=ClusterShading~=nil or ClusteredShading~=nil,gpuExecutionVerified=false}
end
return M
