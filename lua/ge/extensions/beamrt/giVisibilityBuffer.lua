-- Engine-managed GPU visibility handoff. No DLL, compute hook or final-image filter.
-- Default unused; main explicitly selects this backend. Inline v083 remains fallback.
local M={shaderName='BeamRT_GIVisibilityConsumerShader',target='#BeamRT_GIVisibilityBuffer'}
local prefix='BeamRT_GIVisibility'
local owned={}
local callbacksInstalled=false
local state={active=false,prepared=false,frame=0,geometry=0,surfel=0,geometryKey='',surfelKey='',reason='disabled'}
local config
local function find(suffix)return scenetree.findObject(prefix..suffix)end
local function token(n)return n%16777215+1 end
local function owns(name)for _,value in ipairs(owned)do if value==name then return true end end;return false end
local function register(object,name)
  if scenetree.findObject(name)then object:delete();error('visibility namespace occupied: '..name)end
  object:registerObject(name);owned[#owned+1]=name
end
local function shader(name,path,samplers)
  local object=scenetree.findObject(name)
  if object then error('visibility shader namespace occupied: '..name)end
  object=createObject('ShaderData');object.DXVertexShaderFile=path;object.DXPixelShaderFile=path;object.pixVersion=5
  for i,name in ipairs(samplers)do object:setField('samplerNames',i-1,name)end
  register(object,name)
end
local function keyText()return string.format('%d %d %d 1',state.frame,state.geometry,state.surfel)end
local function apply()
  if not config or not state.active then return end
  local receiver,producer=find('ReceiverFx'),find('ProducerFx')
  if not receiver or not producer then return end
  receiver:setShaderConst('$rayNormalBias',config.bias)
  producer:setShaderConst('$visibilitySize',string.format('%d %d',config.width,config.height))
  producer:setShaderConst('$nativeGIVisibilityKey',keyText())
  producer:setShaderConst('$surfelCount',#config.surfels)
  config.applySceneConsts(producer,config.scene,true)
  for i=0,31 do
    producer:setShaderConst('$surfelPositionRadius'..i,config.positions[i+1] or '0 0 0 0')
  end
  if config.trace:getField('shader',0)==M.shaderName then
    config.trace:setShaderConst('$nativeGIVisibilitySize',string.format('%d %d',config.width,config.height))
    config.trace:setShaderConst('$nativeGIVisibilityKey',keyText())
    config.trace:setShaderConst('$nativeGIVisibilityEnabled',state.prepared and 1 or 0)
  end
end
local function create()
  if find('ReceiverFx') and find('ProducerFx')then
    if #owned==0 then error('unowned visibility graph exists; reload BeamRT normally')end
    return
  end
  if #owned>0 then M.release()end -- repair a partially created private graph only
  local block=createObject('GFXStateBlockData');block.zDefined=true;block.zEnable=false;block.zWriteEnable=false
  block.blendDefined=true;block.blendEnable=false;block.samplersDefined=true
  for i=0,1 do block:setField('samplerStates',i,'SamplerClampPoint')end
  register(block,prefix..'State')
  shader(prefix..'ReceiverShader','shaders/beamrt/beamrtGIReceiverExportP_v002.hlsl',{'prepassTex','prepassDepthTex'})
  shader(prefix..'ProducerShader','shaders/beamrt/beamrtGIVisibilityBufferP_v001.hlsl',{'receiverOriginTex','meshDataTex'})
  shader(M.shaderName,'shaders/beamrt/beamrtGITraceP_v084.hlsl',
    {'prepassTex','prepassDepthTex','backBufferTex','lightInfoTex','auxiliaryTex','nativeGIVisibilityTex'})
  for _,pass in ipairs({{'Receiver',10003.8,'#BeamRT_GIReceiverOrigins'}, {'Producer',10003.6,M.target}})do
    local fx=createObject('PostEffect');fx.isEnabled=false;fx.allowReflectPass=false;fx.renderPriority=pass[2]
    fx:setField('renderTime',0,'PFXAfterDiffuse');fx:setField('shader',0,prefix..pass[1]..'Shader')
    fx:setField('stateBlock',0,prefix..'State');fx:setField('target',0,pass[3])
    fx:setField('targetFormat',0,'GFXFormatR32G32B32A32F');fx:setField('targetSize',0,'1 1')
    fx:setField('targetClear',0,'PFXTargetClear_OnDraw');fx:setField('targetClearColor',0,pass[1]=='Producer' and '-1 -1 -1 -1' or '0 0 0 0')
    register(fx,prefix..pass[1]..'Fx')
  end
  find('ReceiverFx'):setField('texture',0,'#prepass[RT0]');find('ReceiverFx'):setField('texture',1,'#prepass[Depth]')
  find('ProducerFx'):setField('texture',0,'#BeamRT_GIReceiverOrigins')
  rawset(_G,prefix..'ReceiverFxCallbacks',{onEnabled=function()return true end,
    preProcess=function()
      if not state.active or not config then return end
      -- Prepare GI sampling/surfels BEFORE exporting origins; consumer skips a
      -- second preparation. Normal (inline/off) frame preparation is unchanged.
      local ok,why=pcall(config.prepareFrame)
      if not ok then M.disable('GI frame preparation failed: '..tostring(why));return end
      if not state.active or not config then return end
      state.frame=token(state.frame);state.prepared=true;state.reason='receiver/visibility passes scheduled; GPU appearance unverified';apply()
    end,setShaderConsts=apply})
  rawset(_G,prefix..'ProducerFxCallbacks',{onEnabled=function()return true end,setShaderConsts=apply})
  callbacksInstalled=true
end
function M.configure(args)
  if type(args)~='table' or not args.trace or not args.scene or type(args.applySceneConsts)~='function'
    or type(args.prepareFrame)~='function' or type(args.surfels)~='table' then M.disable('missing visibility inputs');return false,state.reason end
  if args.viewAvailable~=true then M.disable('main RenderView unavailable');return false,state.reason end
  local w,h=tonumber(args.width),tonumber(args.height)
  if not w or not h or w~=w or h~=h or w<1 or h<1 or w>2048 or h>=2048 or w%1~=0 or h%1~=0 then
    M.disable('unsupported visibility dimensions');return false,state.reason
  end
  if #args.surfels<1 or #args.surfels>32 then M.disable('world samples not populated');return false,state.reason end
  if w*h*#args.surfels>1048576 then M.disable('buffer budget exceeded; use inline or an explicit reduced GI scale');return false,state.reason end
  if type(args.bias)~='number' or args.bias~=args.bias or math.abs(args.bias)==math.huge or args.bias<0 then M.disable('invalid receiver bias');return false,state.reason end
  local positions={}
  for _,surfel in ipairs(args.surfels)do
    if not surfel.position or not surfel.radius then M.disable('invalid world sample');return false,state.reason end
    local values={surfel.position.x,surfel.position.y,surfel.position.z,surfel.radius}
    for i=1,4 do local v=values[i];if type(v)~='number' or v~=v or math.abs(v)==math.huge then M.disable('nonfinite world sample');return false,state.reason end end
    if #values~=4 or values[4]<=0 then M.disable('invalid world sample radius');return false,state.reason end
    positions[#positions+1]=string.format('%.9g %.9g %.9g %.9g',values[1],values[2],values[3],values[4])
  end
  local geometryKey=tostring(args.scene.objectId)..':'..args.scene.policy.key..':'..args.scene.gpuData.texture
  local surfelKey=table.concat(positions,'|')
  local changed=not state.active or geometryKey~=state.geometryKey or surfelKey~=state.surfelKey
    or not config or w~=config.width or h~=config.height or args.bias~=config.bias or args.trace~=config.trace
  local ok,why=pcall(create)
  if not ok then M.release();state.reason='visibility graph unavailable: '..tostring(why);return false,state.reason end
  if geometryKey~=state.geometryKey then state.geometry=token(state.geometry);state.geometryKey=geometryKey end
  if surfelKey~=state.surfelKey then state.surfel=token(state.surfel);state.surfelKey=surfelKey end
  config={trace=args.trace,scene=args.scene,applySceneConsts=args.applySceneConsts,prepareFrame=args.prepareFrame,
    width=w,height=h,bias=args.bias,surfels=args.surfels,positions=positions};state.active=true
  if changed then state.prepared=false;state.frame=token(state.frame)end -- mismatch old GPU output
  find('ReceiverFx'):setField('targetSize',0,string.format('%d %d',w,h))
  find('ProducerFx'):setField('targetSize',0,string.format('%d %d',w,h+1))
  find('ProducerFx'):setField('texture',1,args.scene.gpuData.texture)
  find('ReceiverFx'):enable();find('ProducerFx'):enable();apply()
  return true
end
function M.consumePreparedFrame()
  if not state.active then return false end
  if not state.prepared then state.frame=token(state.frame);apply();return false end
  -- Keep prepared through setShaderConsts. Next receiver draw refreshes token;
  -- a repeated consumer without its matching producer must not reuse a frame.
  if state.consumed==state.frame then state.prepared=false;state.frame=token(state.frame);apply();return false end
  state.consumed=state.frame;return true
end
function M.invalidateFrame()
  state.prepared=false;state.frame=token(state.frame);apply()
end
function M.applyConsumer()apply()end
function M.disable(reason)
  state.active=false;state.prepared=false;state.reason=reason or 'disabled'
  if config and config.trace and config.trace:getField('shader',0)==M.shaderName then config.trace:setShaderConst('$nativeGIVisibilityEnabled',0)end
  for _,name in ipairs({'ReceiverFx','ProducerFx'})do local fx=find(name);if fx and owns(prefix..name)then fx:disable()end end
end
function M.release()
  M.disable()
  for i=#owned,1,-1 do local object=scenetree.findObject(owned[i]);if object then object:delete()end end
  owned={};config=nil
  if callbacksInstalled then
    rawset(_G,prefix..'ReceiverFxCallbacks',nil);rawset(_G,prefix..'ProducerFxCallbacks',nil)
    callbacksInstalled=false
  end
end
function M.getStatus()
  return {active=state.active,reason=state.reason,framePrepared=state.prepared,frameKey=state.frame,
    width=config and config.width,height=config and config.height,surfelCount=config and #config.surfels or 0,
    backend='BeamNG PostFX pixel producer; shared native GPU format/traversal',nativeWorkerAttached=false,
    gpuExecutionVerified=false,appearanceVerified=false,scope='selected imported mesh, world-surfel bounce segments'}
end
return M
