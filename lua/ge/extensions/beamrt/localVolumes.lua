-- Opt-in thin-medium spotlight scattering, not a native shadow-atlas consumer.
-- No settings/material/light writes, no external renderer or global fog edits.
local M={requested=false,reason='Local lamp haze is off.',strength=1,density=.025}
local owned={}
local registered={}
local elapsed=1
local lightCount=0
local drawing=false
local cache={}
local function own(class,name)
  assert(not scenetree.findObject(name),'Volume object name already owned: '..name)
  local object=createObject(class)
  owned[name]=object
  return object
end
local function upload(pass,key,value)
  if cache[key]~=value then pass:setShaderConst(key,value);cache[key]=value end
end
local function vector(values,w)
  return string.format('%.8g %.8g %.8g %.8g',values[1],values[2],values[3],w)
end
function M.disable(why)
  M.requested=false
  local clean=true
  -- Pass must stop before any of its shader/state dependencies are deleted.
  for _,name in ipairs({'BeamRT_LocalVolumeFx','BeamRT_LocalVolumeShader','BeamRT_LocalVolumeState'}) do
    local object=owned[name]
    if object then
      local ok=pcall(function()
        if scenetree.findObject(name)==object or not registered[name] then
          if name=='BeamRT_LocalVolumeFx' then object:disable() end
          object:delete()
        end
      end)
      if ok then owned[name]=nil;registered[name]=nil else clean=false;break end
    end
  end
  cache={};lightCount=0;drawing=false
  M.reason=why or 'Local lamp haze is off.'
  if not clean then M.reason=M.reason..' Cleanup pending; retry disable.' end
  return clean,M.reason
end
function M.enable()
  if not M.disable() then return false,M.reason end
  local ok,why=pcall(function()
    local shader=own('ShaderData','BeamRT_LocalVolumeShader')
    shader.DXVertexShaderFile='shaders/beamrt/beamrtLocalVolumeP_v001.hlsl'
    shader.DXPixelShaderFile='shaders/beamrt/beamrtLocalVolumeP_v001.hlsl'
    for i,name in ipairs({'$normalTex','$depthTex'}) do shader:setField('samplerNames',i-1,name) end
    shader.pixVersion=5
    shader:registerObject('BeamRT_LocalVolumeShader');registered.BeamRT_LocalVolumeShader=true
    local state=own('GFXStateBlockData','BeamRT_LocalVolumeState')
    local parent=scenetree.findObject('PFX_DefaultStateBlock')
    assert(parent,'PostFX state unavailable');state:inheritParentFields(parent)
    state.samplersDefined=true
    state.blendDefined=true;state.blendEnable=true
    state:setField('blendSrc',0,'GFXBlendOne');state:setField('blendDest',0,'GFXBlendOne')
    state:setField('samplerStates',0,'SamplerClampPoint');state:setField('samplerStates',1,'SamplerClampPoint')
    state:registerObject('BeamRT_LocalVolumeState');registered.BeamRT_LocalVolumeState=true
    local pass=own('PostEffect','BeamRT_LocalVolumeFx')
    pass:setField('shader',0,'BeamRT_LocalVolumeShader');pass:setField('stateBlock',0,'BeamRT_LocalVolumeState')
    pass:setField('texture',0,'#prepass[RT0]');pass:setField('texture',1,'#prepass[Depth]')
    pass:setField('target',0,'');pass:setField('targetScale',0,'1 1')
    pass:setField('renderTime',0,'PFXBeforeBin');pass:setField('renderBin',0,'AfterPostFX')
    pass.renderPriority=22 -- after Coherent composition, outside both histories
    pass.allowReflectPass=false
    pass:registerObject('BeamRT_LocalVolumeFx');registered.BeamRT_LocalVolumeFx=true
    upload(pass,'$volumeCount',0);upload(pass,'$volumeStrength',M.strength);upload(pass,'$volumeDensity',M.density)
    pass:disable() -- no full-screen copy until a supported lamp is available
  end)
  if not ok then M.disable('Local haze startup failed: '..tostring(why));return false,M.reason end
  M.requested=true;elapsed=1
  M.reason='Local spotlight haze requested; unshadowed approximation, GPU appearance unverified.'
  return true
end
function M.setParameter(key,value)
  if key~='strength' and key~='density' then return false end
  if type(value)~='number' or value~=value or value<0 or value>(key=='density' and .1 or 4) then return false end
  M[key]=value;elapsed=1;return true
end
function M.update(dt,lamps)
  if not M.requested then return end
  local ok,why=pcall(function()
    local pass=owned.BeamRT_LocalVolumeFx
    assert(pass and scenetree.findObject('BeamRT_LocalVolumeFx')==pass,'Volume pass lost')
    assert(not drawing or pass:isEnabled(),'Volume pass disabled externally')
    assert(pass:getField('renderTime',0)=='PFXBeforeBin' and pass:getField('renderBin',0)=='AfterPostFX'
      and tonumber(pass.renderPriority)==22 and pass:getField('target',0)==''
      and pass:getField('texture',0)=='#prepass[RT0]' and pass:getField('texture',1)=='#prepass[Depth]',
      'Volume pass bindings modified')
    assert(scenetree.findObject('BeamRT_LocalVolumeShader')==owned.BeamRT_LocalVolumeShader,'Volume shader lost')
    assert(scenetree.findObject('BeamRT_LocalVolumeState')==owned.BeamRT_LocalVolumeState,'Volume state lost')
    local step=tonumber(dt) or 0
    if step~=step then step=0 end
    elapsed=elapsed+math.max(0,math.min(step,1))
    if elapsed<.25 then return end
    elapsed=0
    local lights=lamps and lamps.getVolumetricLights and lamps.getVolumetricLights() or {}
    lightCount=math.min(4,#lights)
    upload(pass,'$volumeStrength',M.strength);upload(pass,'$volumeDensity',M.density)
    for i=1,lightCount do
      local l=lights[i]
      upload(pass,'$volumePosition'..(i-1),vector(l.position,l.range))
      upload(pass,'$volumeDirection'..(i-1),vector(l.direction,l.outer))
      upload(pass,'$volumeColor'..(i-1),vector(l.color,l.brightness))
      upload(pass,'$volumeInner'..(i-1),l.inner)
    end
    upload(pass,'$volumeCount',lightCount)
    local shouldDraw=lightCount>0 and M.strength>0 and M.density>0
    if shouldDraw~=drawing then
      if shouldDraw then pass:enable() else pass:disable() end
      drawing=shouldDraw
    end
    M.reason=lightCount>0 and 'Local spotlight haze: depth-limited, unshadowed approximation; GPU appearance unverified.'
      or 'No supported nearby spotlights. Enable automatic lamp shadows and nearby priority; point/emissive/vehicle lights are not covered.'
  end)
  if not ok then M.disable('Local haze stopped: '..tostring(why)) end
end
function M.getStatus()
  return {requested=M.requested,active=drawing,reason=M.reason,strength=M.strength,density=M.density,lightCount=lightCount,
    pendingCleanup=not M.requested and next(owned)~=nil,gpuExecutionVerified=false,nativeShadowVisibility=false}
end
return M
