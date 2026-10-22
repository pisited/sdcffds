-- Opt-in thin-medium spotlight scattering, not a native shadow-atlas consumer.
-- No settings/material/light writes, no external renderer or global fog edits.
local M={requested=false,reason='Local lamp haze is off.',strength=1,density=.025,emissiveGain=1,
  vehicleEnabled=true,vehicleBeamGain=.35,vehicleHaloGain=1}
package.loaded['ge/extensions/beamrt/volumeLights']=nil
local sources=require('ge/extensions/beamrt/volumeLights')
package.loaded['ge/extensions/beamrt/emissiveVolumes']=nil
local emitters=require('ge/extensions/beamrt/emissiveVolumes')
package.loaded['ge/extensions/beamrt/vehicleVolumes']=nil
local vehicles=require('ge/extensions/beamrt/vehicleVolumes')
local owned={}
local registered={}
local elapsed=1
local lightCount=0
local drawing=false
local cache={}
local sourceRevision=-1
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
  sources.disable()
  emitters.disable()
  vehicles.disable()
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
  cache={};lightCount=0;drawing=false;sourceRevision=-1
  M.reason=why or 'Local lamp haze is off.'
  if not clean then M.reason=M.reason..' Cleanup pending; retry disable.' end
  return clean,M.reason
end
function M.enable()
  if not M.disable() then return false,M.reason end
  local ok,why=pcall(function()
    local shader=own('ShaderData','BeamRT_LocalVolumeShader')
    shader.DXVertexShaderFile='shaders/beamrt/beamrtLocalVolumeP_v006.hlsl'
    shader.DXPixelShaderFile='shaders/beamrt/beamrtLocalVolumeP_v006.hlsl'
    for i,name in ipairs({'sceneTex','normalTex','depthTex'}) do shader:setField('samplerNames',i-1,name) end
    shader.pixVersion=5
    shader:registerObject('BeamRT_LocalVolumeShader');registered.BeamRT_LocalVolumeShader=true
    local state=own('GFXStateBlockData','BeamRT_LocalVolumeState')
    local parent=scenetree.findObject('PFX_DefaultStateBlock')
    assert(parent,'PostFX state unavailable');state:inheritParentFields(parent)
    state.samplersDefined=true
    state.blendDefined=true;state.blendEnable=false
    state:setField('blendSrc',0,'GFXBlendOne');state:setField('blendDest',0,'GFXBlendZero')
    state:setField('blendOp',0,'GFXBlendOpAdd')
    for i=0,2 do state:setField('samplerStates',i,'SamplerClampPoint') end
    state:registerObject('BeamRT_LocalVolumeState');registered.BeamRT_LocalVolumeState=true
    local pass=own('PostEffect','BeamRT_LocalVolumeFx')
    pass:setField('shader',0,'BeamRT_LocalVolumeShader');pass:setField('stateBlock',0,'BeamRT_LocalVolumeState')
    -- Beauty first: a native passthrough/fallback must not display raw normals.
    -- Replace with scene + scatter, not additive blending of a possible copy.
    pass:setField('texture',0,'$backBuffer');pass:setField('texture',1,'#prepass[RT0]')
    pass:setField('texture',2,'#prepass[Depth]')
    pass:setField('target',0,'$backBuffer');pass:setField('targetScale',0,'1 1')
    pass:setField('renderTime',0,'PFXBeforeBin');pass:setField('renderBin',0,'AfterPostFX')
    pass.renderPriority=22 -- after Coherent composition, outside both histories
    pass.allowReflectPass=false
    pass:registerObject('BeamRT_LocalVolumeFx');registered.BeamRT_LocalVolumeFx=true
    upload(pass,'$volumeCount',0);upload(pass,'$volumeStrength',M.strength);upload(pass,'$volumeDensity',M.density)
    upload(pass,'$volumeDistance',sources.maxDistance)
    upload(pass,'$vehicleCount',0)
    upload(pass,'$emitterCount',0);upload(pass,'$emissiveRange',emitters.range)
    upload(pass,'$emissiveGain',M.emissiveGain*.001) -- experimental nits -> working radiance scale, not calibrated
    pass:disable() -- no full-screen copy until a supported lamp is available
  end)
  if not ok then M.disable('Local haze startup failed: '..tostring(why));return false,M.reason end
  sources.enable();M.requested=true;elapsed=1
  if M.vehicleEnabled then vehicles.enable() end
  M.reason='Local spotlight haze requested; unshadowed approximation, GPU appearance unverified.'
  return true
end
function M.setParameter(key,value)
  if key=='vehicleBeamReach' or key=='vehicleHaloReach' then
    elapsed=1;return vehicles.setParameter(key=='vehicleBeamReach' and 'beamReach' or 'haloReach',value)
  end
  if key~='strength' and key~='density' and key~='emissiveGain' and key~='vehicleBeamGain' and key~='vehicleHaloGain' then return false end
  if type(value)~='number' or value~=value or value<0 or value>(key=='density' and .1 or 4) then return false end
  M[key]=value;elapsed=1;return true
end
function M.setEmissiveEnabled(value)
  if type(value)~='boolean' then return false,'Expected boolean.' end
  if value and not M.requested then return false,'Enable local lamp haze first.' end
  elapsed=1
  if value then return emitters.enable() end
  return emitters.disable()
end
function M.setVehicleEnabled(value)
  if type(value)~='boolean' then return false,'Expected boolean.' end
  if value and not M.requested then return false,'Enable local haze first.' end
  M.vehicleEnabled=value;elapsed=1
  if value then return vehicles.enable() end
  return vehicles.disable()
end
function M.update(dt)
  if not M.requested then return end
  local ok,why=pcall(function()
    local pass=owned.BeamRT_LocalVolumeFx
    assert(pass and scenetree.findObject('BeamRT_LocalVolumeFx')==pass,'Volume pass lost')
    assert(not drawing or pass:isEnabled(),'Volume pass disabled externally')
    assert(pass:getField('renderTime',0)=='PFXBeforeBin' and pass:getField('renderBin',0)=='AfterPostFX'
      and tonumber(pass.renderPriority)==22 and pass:getField('target',0)=='$backBuffer'
      and pass:getField('texture',0)=='$backBuffer' and pass:getField('texture',1)=='#prepass[RT0]'
      and pass:getField('texture',2)=='#prepass[Depth]',
      'Volume pass bindings modified')
    assert(scenetree.findObject('BeamRT_LocalVolumeShader')==owned.BeamRT_LocalVolumeShader,'Volume shader lost')
    assert(scenetree.findObject('BeamRT_LocalVolumeState')==owned.BeamRT_LocalVolumeState,'Volume state lost')
    local step=tonumber(dt) or 0
    if step~=step then step=0 end
    elapsed=elapsed+math.max(0,math.min(step,1))
    sources.update(step)
    vehicles.update(step)
    local lights=sources.getVolumetricLights()
    emitters.update(step,lights)
    local discovery=sources.getStatus()
    if elapsed<.25 and discovery.revision==sourceRevision and not vehicles.getStatus().requested then return end
    sourceRevision=discovery.revision
    elapsed=0
    lightCount=math.min(sources.maxLights,#lights)
    upload(pass,'$volumeStrength',M.strength);upload(pass,'$volumeDensity',M.density)
    for i=1,lightCount do
      local l=lights[i]
      upload(pass,'$volumePosition'..(i-1),vector(l.position,l.range))
      upload(pass,'$volumeDirection'..(i-1),vector(l.direction,l.outer))
      upload(pass,'$volumeColor'..(i-1),vector(l.color,l.brightness))
      upload(pass,'$volumeInner'..(i-1),l.inner)
    end
    upload(pass,'$volumeCount',lightCount)
    local carLights=vehicles.getLights()
    for i=1,math.min(vehicles.maxLights,#carLights) do
      local l=carLights[i];local suffix=i-1
      upload(pass,'$vehiclePosition'..suffix,vector(l.position,l.range))
      upload(pass,'$vehicleDirection'..suffix,vector(l.direction,l.outer))
      upload(pass,'$vehicleColor'..suffix,vector(l.color,l.brightness*(l.halo and M.vehicleHaloGain or M.vehicleBeamGain)))
      upload(pass,'$vehicleInner'..suffix,l.inner)
    end
    upload(pass,'$vehicleCount',#carLights)
    local areaLights=emitters.getEmitters()
    upload(pass,'$emissiveGain',M.emissiveGain*.001)
    for i=1,math.min(emitters.maxEmitters,#areaLights) do
      local l=areaLights[i];local index=i-1
      upload(pass,'$emitterBounds'..index,vector(l.position,l.radius))
      upload(pass,'$emitterColor'..index,vector(l.color,0))
      for j=1,4 do
        local s=l.samples[j];local suffix=index..'_'..(j-1)
        upload(pass,'$emitterPoint'..suffix,vector(s.position,0))
        upload(pass,'$emitterNormal'..suffix,vector(s.normal,s.area))
      end
    end
    upload(pass,'$emitterCount',#areaLights)
    local vehicleDraw=false
    for _,l in ipairs(carLights) do if (l.halo and M.vehicleHaloGain or M.vehicleBeamGain)>0 then vehicleDraw=true;break end end
    local shouldDraw=(lightCount>0 or vehicleDraw or (#areaLights>0 and M.emissiveGain>0)) and M.strength>0 and M.density>0
    if shouldDraw~=drawing then
      if shouldDraw then pass:enable() else pass:disable() end
      drawing=shouldDraw
    end
    M.reason=lightCount>0 and 'Wide spotlight haze: independent read-only detection; unshadowed approximation, GPU appearance unverified.'
      or (#carLights>0 and 'Vehicle light haze active; unshadowed approximation, GPU appearance unverified.'
      or (#areaLights>0 and 'Prepared LED haze active; unshadowed approximation, GPU appearance unverified.'
      or 'No supported active haze sources in range yet.'))
  end)
  if not ok then M.disable('Local haze stopped: '..tostring(why)) end
end
function M.getStatus()
  return {requested=M.requested,active=drawing,reason=M.reason,strength=M.strength,density=M.density,lightCount=lightCount,
    pendingCleanup=not M.requested and next(owned)~=nil,gpuExecutionVerified=false,nativeShadowVisibility=false,
    discovery=sources.getStatus(),emissive=emitters.getStatus(),emissiveGain=M.emissiveGain,
    vehicle=vehicles.getStatus(),vehicleEnabled=M.vehicleEnabled,
    vehicleBeamGain=M.vehicleBeamGain,vehicleHaloGain=M.vehicleHaloGain}
end
return M
