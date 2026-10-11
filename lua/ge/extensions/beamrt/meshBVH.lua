-- One-instance GPU BVH geometry diagnostic. No production GI/native shadows.
local M={}
local placement=require('ge/extensions/beamrt/meshPlacement')
local prefix='BeamRT_MeshBVH'
local scene
local active=false
local binding=false
local split=true
local quality='playable'
local sunSign=-1 -- Consistent with the earlier WORLD-space caster probe only.
local testLight=false -- Explicit synthetic geometry calibration, not a game light.
local errorMessage
local owned={}
local function find(suffix) return scenetree.findObject(prefix..suffix) end
local function logError(text) errorMessage=text;if log then log('E','BeamRT.MeshBVH',text) end;return false,text end
local function register(object,suffix) object:registerObject(prefix..suffix);owned[#owned+1]=prefix..suffix;return object end
local function vecText(v) return string.format('%.9g %.9g %.9g',v[1],v[2],v[3]) end
local function cross(a,b) return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function inverse(b)
  local rows={cross(b.y,b.z),cross(b.z,b.x),cross(b.x,b.y)}
  local determinant=dot(b.x,rows[1]);if math.abs(determinant)<1e-10 then return nil end
  for _,row in ipairs(rows) do for i=1,3 do row[i]=row[i]/determinant end end
  return rows
end
local function alignment() return extensions.beamrt_meshAlignment end
local function apply()
  local trace=find('TraceFx')
  if not trace or not scene then return end
  local gpu=scene.gpuData
  trace:setShaderConst('$meshOrigin',vecText(scene.placement.basis.origin))
  for i,key in ipairs({'X','Y','Z'}) do trace:setShaderConst('$meshInv'..key,vecText(scene.inverse[i])) end
  trace:setShaderConst('$meshQuantMin',vecText(gpu.quantMin))
  trace:setShaderConst('$meshQuantExtent',vecText(gpu.quantExtent))
  trace:setShaderConst('$meshNodeCount',gpu.nodeCount)
  trace:setShaderConst('$meshTriangleCount',gpu.triangleCount)
  trace:setShaderConst('$meshTriangleOffset',gpu.triangleOffset)
  trace:setShaderConst('$meshAtlasSize',string.format('%d %d',gpu.width,gpu.height))
  trace:setShaderConst('$meshSunSign',sunSign)
  trace:setShaderConst('$meshBindingView',binding and 1 or 0)
  trace:setShaderConst('$meshMaxDistance',200)
  trace:setShaderConst('$meshTestLightEnabled',testLight and 1 or 0)
  local center={};for i=1,3 do center[i]=gpu.quantMin[i]+gpu.quantExtent[i]*.5 end
  local light=placement.apply(scene.placement.basis,center)
  light={light[1]+10,light[2]-10,light[3]+12}
  trace:setShaderConst('$meshTestLightPosition',vecText(light))
  local preview=find('PreviewFx')
  if preview then
    preview:setShaderConst('$meshPreviewView',binding and 1 or 0)
    preview:setShaderConst('$meshSplit',split and 1 or 0)
  end
end
local function objects()
  if find('TraceFx') then return end
  local state=createObject('GFXStateBlockData')
  state.zDefined=true;state.zEnable=false;state.zWriteEnable=false
  state.blendDefined=true;state.blendEnable=false;state.samplersDefined=true
  for i=0,2 do state:setField('samplerStates',i,'SamplerClampPoint') end
  register(state,'State')
  for _,s in ipairs({{'TraceShader','shaders/beamrt/beamrtMeshBVHTraceP_v001.hlsl',{'prepassTex','prepassDepthTex','meshDataTex'}},
                      {'PreviewShader','shaders/beamrt/beamrtMeshBVHPreviewP_v001.hlsl',{'backBufferTex','meshVisibilityTex'}}}) do
    local shader=createObject('ShaderData');shader.DXVertexShaderFile=s[2];shader.DXPixelShaderFile=s[2];shader.pixVersion=5
    for i,name in ipairs(s[3]) do shader:setField('samplerNames',i-1,name) end
    register(shader,s[1])
  end
  local trace=createObject('PostEffect');trace.isEnabled=false;trace.allowReflectPass=false
  trace.renderPriority=10008;trace:setField('renderTime',0,'PFXAfterDiffuse')
  trace:setField('shader',0,prefix..'TraceShader');trace:setField('stateBlock',0,prefix..'State')
  trace:setField('texture',0,'#prepass[RT0]');trace:setField('texture',1,'#prepass[Depth]')
  trace:setField('texture',2,scene.gpuData.texture)
  trace:setField('target',0,'#BeamRT_MeshBVHVisibility')
  trace:setField('targetFormat',0,'GFXFormatR16G16B16A16F')
  trace:setField('targetScale',0,quality=='playable' and '0.5 0.5' or '1 1')
  register(trace,'TraceFx')
  local preview=createObject('PostEffect');preview.isEnabled=false;preview.allowReflectPass=false
  preview.renderPriority=9978;preview:setField('renderTime',0,'PFXAfterDiffuse')
  preview:setField('shader',0,prefix..'PreviewShader');preview:setField('stateBlock',0,prefix..'State')
  preview:setField('texture',0,'$backBuffer');preview:setField('texture',1,'#BeamRT_MeshBVHVisibility')
  preview:setField('target',0,'$backBuffer');register(preview,'PreviewFx')
  for _,suffix in ipairs({'TraceFx','PreviewFx'}) do
    rawset(_G,prefix..suffix..'Callbacks',{onEnabled=function() return true end,setShaderConsts=apply})
  end
end
function M.enable()
  if not alignment() then extensions.load('beamrt_meshAlignment') end
  local status=alignment().getStatus()
  if not status.active then
    local ok,err=alignment().previewNearest();if not ok then return logError(tostring(err)) end
  end
  -- Support the alignment extension already running in-game, without unloading
  -- it or losing its camera-restore snapshot just to add a new getter.
  local candidate,err
  if type(alignment().getGPUSceneBinding)=='function' then
    candidate,err=alignment().getGPUSceneBinding()
  else
    local ok,data=pcall(jsonReadFile,'/art/beamrt/alignment/wcu_guardhouse.gpu.beamrt.json')
    status=alignment().getStatus()
    if ok and type(data)=='table' and data.schema=='beamrt.mesh.alignment.v1'
      and data.shapePath==status.shapePath and data.nodeSelection.selectedNode==status.selectedNode
      and #data.triangles==status.triangles then
      candidate={objectId=status.objectId,placement=status.placement,gpuData=data.gpuData}
    else err='GPU package unavailable or does not match the running alignment capture' end
  end
  if not candidate then return logError(tostring(err)) end
  if not candidate.gpuData or candidate.gpuData.schema~='beamrt.bvh.rgba8.v1'
    or type(candidate.gpuData.texture)~='string' or candidate.gpuData.texture:find('..',1,true)
    or not candidate.gpuData.texture:match('^/art/beamrt/alignment/[%w_/%-%.]+%.data%.png$') then
    return logError('invalid GPU data descriptor')
  end
  candidate.inverse=inverse(candidate.placement.basis)
  if not candidate.inverse then return logError('singular instance transform') end
  local gpu=candidate.gpuData
  for _,key in ipairs({'nodeOffset','nodeStride','nodeCount','triangleCount','triangleOffset','triangleStride','width','height'}) do
    local n=gpu[key]
    if type(n)~='number' or n~=n or n%1~=0 or n<1 or n>4000000 then return logError('invalid numeric descriptor: '..key) end
  end
  for _,key in ipairs({'quantMin','quantExtent'}) do if not placement.xyz(gpu[key]) then return logError('invalid quantization vector') end end
  for i=1,3 do if gpu.quantExtent[i]<=0 then return logError('invalid quantization extent') end end
  if gpu.nodeOffset~=2 or gpu.nodeStride~=6 or gpu.triangleStride~=7 or gpu.nodeCount<1
    or gpu.nodeCount>=2^24 or gpu.triangleOffset~=2+gpu.nodeCount*6 or gpu.width~=256
    or gpu.height<1 or gpu.triangleOffset+gpu.triangleCount*7>gpu.width*gpu.height then
    return logError('unsupported or inconsistent packed-data layout')
  end
  if not FS:fileExists(gpu.texture) then return logError('packed texture unavailable: '..gpu.texture) end
  scene=candidate;errorMessage=nil
  local ok,why=pcall(objects);if not ok then M.disable();return logError('GPU object creation failed: '..tostring(why)) end
  find('TraceFx'):setField('texture',2,gpu.texture)
  apply();find('TraceFx'):enable();find('PreviewFx'):enable();active=true
  return true,M.getStatus()
end
function M.disable()
  active=false
  for _,suffix in ipairs({'TraceFx','PreviewFx'}) do local fx=find(suffix);if fx then fx:disable() end end
  return true
end
function M.setView(value)
  if value=='off' then local fx=find('PreviewFx');if fx then fx:disable() end;return true end
  if value~='classification' and value~='binding' then return false end
  binding=value=='binding';apply();if active then find('PreviewFx'):enable() end;return true
end
function M.setSplit(value) if type(value)~='boolean' then return false end;split=value;apply();return true end
function M.setQuality(value)
  if value~='playable' and value~='cinematic' then return false end
  quality=value;local fx=find('TraceFx');if fx then fx:setField('targetScale',0,value=='playable' and '0.5 0.5' or '1 1') end
  return true
end
function M.setSunDirection(value)
  if value~='normal' and value~='reversed' then return false end
  sunSign=value=='normal' and 1 or -1;apply();return true
end
function M.setTestLightEnabled(value)
  if type(value)~='boolean' then return false end
  testLight=value;apply();return true
end
function M.getStatus()
  return {enabled=active,quality=quality,error=errorMessage,split=split,
    view=binding and 'binding' or 'classification',objectId=scene and scene.objectId,
    triangles=scene and scene.gpuData.triangleCount,nodes=scene and scene.gpuData.nodeCount,
    sunlightDirection=sunSign<0 and 'reversed' or 'normal',
    raySource=testLight and 'synthetic fixed point light (geometry calibration)' or 'engine sunlight',
    gpuExecutionVerified=false,opacityTexturesSampled=false,completeScene=false,
    productionLightingChanged=false,geometryOnly=true}
end
function M.onPreRender()
  if not active then return end
  local status=alignment() and alignment().getStatus()
  if not status or not status.active or status.objectId~=scene.objectId
    or not placement.same(scene.placement,status.placement) then
    M.disable();logError('aligned instance is stale/changed; capture and enable again')
  end
end
function M.onClientEndMission() M.disable();scene=nil end
function M.onClientStartMission() M.disable();scene=nil end
function M.onExtensionUnloaded()
  M.disable()
  for i=#owned,1,-1 do local object=scenetree.findObject(owned[i]);if object then object:delete() end end
  owned={};scene=nil
  for _,suffix in ipairs({'TraceFx','PreviewFx'}) do rawset(_G,prefix..suffix..'Callbacks',nil) end
end
function M.onExtensionLoaded() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end end
return M
