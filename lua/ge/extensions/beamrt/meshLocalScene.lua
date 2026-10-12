-- One prepared underground TSStatic instance, selected by actual world bounds.
-- Read-only scene capture; no wire preview or camera/vehicle movement.
local M={}
local placement=require('ge/extensions/beamrt/meshPlacement')
local policy=require('ge/extensions/beamrt/meshMaterialPolicy')
local scene
local function canonical(path)return tostring(path):gsub('\\','/'):gsub('^/',''):lower()end
local function cross(a,b)return{a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function inverse(b)
  local rows={cross(b.y,b.z),cross(b.z,b.x),cross(b.x,b.y)}
  local det=dot(b.x,rows[1]);if math.abs(det)<1e-10 then return nil end
  for _,row in ipairs(rows)do for i=1,3 do row[i]=row[i]/det end end
  return rows
end
local function validate(asset)
  if type(asset)~='table'or asset.space~='engine-model metres, Z-up'or asset.sceneNodeTransformsBaked~=true
    or type(asset.shapePath)~='string'or asset.shapePath:find('..',1,true)then return false end
  local gpu=asset.gpuData
  if type(gpu)~='table'or gpu.schema~='beamrt.bvh.rgba8.v1'or type(gpu.texture)~='string'
    or gpu.texture:find('..',1,true)or not gpu.texture:match('^/art/beamrt/alignment/[%w_/%-%.]+%.data%.png$')then return false end
  for _,key in ipairs({'width','height','nodeCount','triangleCount','triangleOffset','nodeOffset','nodeStride','triangleStride'})do
    local value=gpu[key];if type(value)~='number'or value~=value or value%1~=0 or value<1 or value>4000000 then return false end
  end
  if gpu.width~=256 or gpu.nodeOffset~=2 or gpu.nodeStride~=6 or gpu.triangleStride~=7
    or gpu.triangleOffset~=2+gpu.nodeCount*6 or gpu.triangleOffset+gpu.triangleCount*7>gpu.width*gpu.height then return false end
  if not placement.xyz(gpu.quantMin)or not placement.xyz(gpu.quantExtent)or type(gpu.materialNames)~='table'
    or #gpu.materialNames<1 or #gpu.materialNames>16 then return false end
  for _,name in ipairs(gpu.materialNames)do if type(name)~='string'or name==''or #name>256 then return false end end
  for i=1,3 do if gpu.quantExtent[i]<=0 then return false end end
  return true
end
local function distanceSquared(eye,basis,gpu)
  local lo={math.huge,math.huge,math.huge};local hi={-math.huge,-math.huge,-math.huge}
  for corner=0,7 do
    local p={};for i=1,3 do p[i]=gpu.quantMin[i]+(math.floor(corner/2^(i-1))%2)*gpu.quantExtent[i]end
    p=placement.apply(basis,p)
    for i=1,3 do lo[i]=math.min(lo[i],p[i]);hi[i]=math.max(hi[i],p[i])end
  end
  local distance=0;local volume=1
  for i=1,3 do distance=distance+math.max(lo[i]-eye[i],eye[i]-hi[i],0)^2;volume=volume*(hi[i]-lo[i])end
  return distance,volume
end
function M.prepare()
  local registry=jsonReadFile('/art/beamrt/alignment/wcu_underground_registry.json')
  if type(registry)~='table'or registry.schema~='beamrt.underground.registry.v1'or type(registry.assets)~='table'
    or #registry.assets<1 or #registry.assets>32 then return nil,'prepared underground registry unavailable'end
  local assets={}
  for _,asset in ipairs(registry.assets)do
    if not validate(asset)then return nil,'invalid underground descriptor'end
    assets[canonical(asset.shapePath)]=asset
  end
  local eye=placement.xyz(core_camera.getPosition());if not eye then return nil,'camera position unavailable'end
  local best,nearest,smallest
  for _,token in ipairs(scenetree.findClassObjects('TSStatic')or{})do
    local object=scenetree.findObject(token)
    local ok,shape=pcall(function()return object.shapeName or object:getField('shapeName',0)end)
    local asset=ok and assets[canonical(shape)]
    if asset then
      local captured=placement.capture(object)
      if captured then
        local distance,volume=distanceSquared(eye,captured.basis,asset.gpuData)
        if distance<=30^2 and(not nearest or distance<nearest or distance==nearest and volume<smallest)then
          best={placement=captured,objectId=captured.objectId,asset=asset,gpuData=asset.gpuData}
          nearest=distance;smallest=volume
        end
      end
    end
  end
  if not best then return nil,'no prepared underground instance within 30 m of camera'end
  if not FS:fileExists(best.gpuData.texture)then return nil,'underground packed texture unavailable'end
  best.inverse=inverse(best.placement.basis);if not best.inverse then return nil,'singular underground instance'end
  best.policy=policy.capture(best.gpuData.materialNames)
  if not best.policy then return nil,'underground material policy unavailable'end
  best.distanceToBounds=math.sqrt(nearest);scene=best
  if log then
    log('I','BeamRT.LocalMesh',string.format('Selected %s, id=%s, triangles=%d, distanceToBounds=%.2fm, opaque=%d/mask=%d/blend=%d/unknown=%d; GPU/visual match unverified',
      best.asset.shapePath,tostring(best.objectId),best.gpuData.triangleCount,best.distanceToBounds,
      best.policy.opaque,best.policy.masked,best.policy.blended,best.policy.unknown))
  end
  return scene
end
function M.getBinding(refresh)
  if not scene then return nil,'underground scene not prepared'end
  local object=scenetree.findObject(scene.objectId)
  if not object then return nil,'underground instance removed'end
  local current=placement.capture(object)
  if not current or not placement.same(current,scene.placement)then return nil,'underground placement changed'end
  if refresh then
    local updated,why=policy.capture(scene.gpuData.materialNames);if not updated then return nil,why end
    scene.policy=updated
  end
  return scene
end
function M.defines(data)
  local values={}
  local function vector(name,v)
    local parts={};for i=1,#v do parts[i]=string.format('%.17g',v[i])end
    values[#values+1]=name..'=float'..#v..'('..table.concat(parts,',')..')'
  end
  vector('meshOrigin',data.placement.basis.origin)
  for i,name in ipairs({'meshInvX','meshInvY','meshInvZ'})do vector(name,data.inverse[i])end
  vector('meshQuantMin',data.gpuData.quantMin);vector('meshQuantExtent',data.gpuData.quantExtent)
  vector('meshAtlasSize',{data.gpuData.width,data.gpuData.height})
  for name,key in pairs({meshNodeCount='nodeCount',meshTriangleCount='triangleCount',meshTriangleOffset='triangleOffset'})do
    values[#values+1]=name..'='..data.gpuData[key]
  end
  values[#values+1]='meshVisibilityEnabled=1';values[#values+1]='meshMaterialPolicyEnabled=1'
  local blockers=0
  for bank=0,3 do
    local modes={};for i=1,4 do
      local record=data.policy.records[bank*4+i]
      local mode=record and(record.shadowMode or record.mode)or 0
      modes[i]=mode;if mode==1 then blockers=blockers+1 end
    end
    vector('meshMaterialModes'..bank,modes)
  end
  table.sort(values)
  return table.concat(values,';'),blockers
end
-- GI consumes the same actual instance without installing the blocked legacy
-- local-light hook. Opacity policy matches existing GI, not a transparency guess.
function M.applySceneConsts(effect,data,enabled)
  local function vector(name,v)effect:setShaderConst('$'..name,string.format('%.9g %.9g %.9g',v[1],v[2],v[3]))end
  vector('meshOrigin',data.placement.basis.origin)
  for i,name in ipairs({'meshInvX','meshInvY','meshInvZ'})do vector(name,data.inverse[i])end
  vector('meshQuantMin',data.gpuData.quantMin);vector('meshQuantExtent',data.gpuData.quantExtent)
  effect:setShaderConst('$meshAtlasSize',string.format('%d %d',data.gpuData.width,data.gpuData.height))
  for name,key in pairs({meshNodeCount='nodeCount',meshTriangleCount='triangleCount',meshTriangleOffset='triangleOffset'})do
    effect:setShaderConst('$'..name,data.gpuData[key])
  end
  effect:setShaderConst('$meshVisibilityEnabled',enabled and 1 or 0);effect:setShaderConst('$meshMaterialPolicyEnabled',1)
  for bank=0,3 do local values={};for i=1,4 do values[i]=tostring(data.policy.modes[bank*4+i] or 0)end
    effect:setShaderConst('$meshMaterialModes'..bank,table.concat(values,' '))end
end
function M.clear()scene=nil end
return M
