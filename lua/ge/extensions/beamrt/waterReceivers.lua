-- Explicit-refresh water GEOMETRY preview only. No rendered-water ownership,
-- wave normals, reflection replacement, native changes or per-frame scene scan.
local M={}
local LIMIT=128
local state
local function finite(v)return type(v)=='number' and v==v and math.abs(v)<1e10 end
local function xyz(v)
  if not v then return nil end
  local ok,x,y,z=pcall(function()return v.x or v[1],v.y or v[2],v.z or v[3]end)
  if not ok or not finite(x)or not finite(y)or not finite(z)then return nil end
  return{x,y,z}
end
local function copy(v)
  if type(v)~='table'then return v end
  local result={};for k,item in pairs(v)do result[k]=copy(item)end;return result
end
function M.clear(reason)
  state={available=false,reason=reason or'not refreshed',maxDistance=250,
    planeCount=0,blockCount=0,rejected=0,ownershipVerified=false,
    waveNormalsVerified=false,normalLightingAffected=false,prototype=true}
end
M.clear()
local function unit(v)
  v=xyz(v);if not v then return nil end
  local length=math.sqrt(v[1]^2+v[2]^2+v[3]^2)
  if length<0.000001 then return nil end
  return{v[1]/length,v[2]/length,v[3]/length}
end
local function capture(object,class)
  local ok,value=pcall(function()
    if object:getClassName()~=class then error('class changed')end
    local hidden=object.hidden
    if hidden==true or hidden=='true'or hidden=='1'then error('hidden water')end
    if type(object.isHidden)=='function'and object:isHidden()then error('hidden water')end
    local position=xyz(object:getPosition());if not position then error('position unavailable')end
    local matrix=object:getTransform()
    local x,y,z=unit(matrix:getColumn(0)),unit(matrix:getColumn(1)),unit(matrix:getColumn(2))
    if not x or not y or not z or math.abs(z[1])>0.0001 or math.abs(z[2])>0.0001
      or z[3]<0.9999 or math.abs(x[3])>0.0001 or math.abs(y[3])>0.0001 then error('non-horizontal water')end
    local dot=x[1]*y[1]+x[2]*y[2]+x[3]*y[3]
    if math.abs(dot)>0.0001 then error('non-orthogonal transform')end
    local record={id=object:getID(),name=object:getName(),height=position[3],class=class}
    if class=='WaterBlock'then
      if math.min(math.abs(x[1]),math.abs(x[2]))>0.0001
        or math.min(math.abs(y[1]),math.abs(y[2]))>0.0001 then error('rotated WaterBlock unsupported')end
      local box=object:getWorldBox();local lo,hi=xyz(box.minExtents),xyz(box.maxExtents)
      if not lo or not hi or hi[1]-lo[1]<=0.04 or hi[2]-lo[2]<=0.04 or hi[3]<lo[3]
        or position[3]<lo[3]-0.1 or position[3]>hi[3]+0.1 then error('invalid water bounds')end
      record.min={lo[1],lo[2]};record.max={hi[1],hi[2]}
    end
    return record
  end)
  return ok and value or nil
end
function M.refresh(options)
  options=options or{}
  if type(options)~='table'then M.clear('invalid refresh options');return false,state.reason end
  local distance=options.maxDistance or 250
  if not finite(distance)or distance<1 or distance>1000 then M.clear('maxDistance must be finite from 1 through 1000');return false,state.reason end
  local ok,eye=pcall(function()return xyz(core_camera.getPosition())end)
  if not ok or not eye then M.clear('camera position unavailable');return false,state.reason end
  if not scenetree or type(scenetree.findClassObjects)~='function'or type(scenetree.findObject)~='function'then
    M.clear('scene queries unavailable');return false,state.reason
  end
  local nextState={available=false,reason='no supported nearby water',maxDistance=distance,
    planeCount=0,blockCount=0,rejected=0,ownershipVerified=false,
    waveNormalsVerified=false,normalLightingAffected=false,prototype=true}
  for _,class in ipairs({'WaterPlane','WaterBlock'})do
    local queried,tokens=pcall(scenetree.findClassObjects,class)
    if not queried or type(tokens)~='table'or#tokens>LIMIT then M.clear('water class query failed or exceeded bounded limit');return false,state.reason end
    local ordered={};for _,token in ipairs(tokens)do ordered[#ordered+1]=token end
    table.sort(ordered,function(a,b)return tostring(a)<tostring(b)end)
    local best,bestDistance
    for _,token in ipairs(ordered)do
      local found,object=pcall(scenetree.findObject,token)
      local record=found and object and capture(object,class)
      if record then
        local dx,dy=0,0
        if record.min then
          dx=math.max(record.min[1]-eye[1],eye[1]-record.max[1],0)
          dy=math.max(record.min[2]-eye[2],eye[2]-record.max[2],0)
        end
        local d=dx*dx+dy*dy+(eye[3]-record.height)^2
        if d<=distance*distance and(not bestDistance or d<bestDistance)then best,bestDistance=record,d end
      else nextState.rejected=nextState.rejected+1 end
    end
    if class=='WaterPlane'then nextState.plane=best;nextState.planeCount=best and 1 or 0
    else nextState.block=best;nextState.blockCount=best and 1 or 0 end
  end
  nextState.available=nextState.planeCount+nextState.blockCount>0
  if nextState.available then nextState.reason='flat geometry candidates only; actual water pixel ownership and waves unverified'end
  state=nextState
  return state.available,state.reason
end
function M.getStatus()return copy(state)end
function M.getShaderConstants()
  local p,b=state.plane,state.block
  return{waterReceiverPlane=string.format('%.9g %d 0 0',p and p.height or 0,p and 1 or 0),
    waterReceiverBlockMin=b and string.format('%.9g %.9g %.9g 1',b.min[1],b.min[2],b.height)or'0 0 0 0',
    waterReceiverBlockMax=b and string.format('%.9g %.9g 0 0',b.max[1],b.max[2])or'0 0 0 0',
    waterReceiverMaxDistance=state.maxDistance}
end
return M
