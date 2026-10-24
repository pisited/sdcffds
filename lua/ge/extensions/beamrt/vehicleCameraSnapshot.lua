-- Read-only main-camera snapshot, checked against BeamNG native unprojection.
-- Uses shipped core_camera and RenderView APIs, not Torque quaternion guesses.
local M={}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function vector(v)
  local a={tonumber(v.x or v[1]),tonumber(v.y or v[2]),tonumber(v.z or v[3])}
  for j=1,3 do assert(finite(a[j]),'Invalid camera vector')end;return a
end
local function unit(v)
  local n=math.sqrt(dot(v,v));assert(finite(n) and n>1e-6,'Invalid camera ray')
  return {v[1]/n,v[2]/n,v[3]/n}
end
local function length(v)return math.sqrt(dot(v,v))end
local function loaded(name)
  -- BeamNG extensions.__index LOADS a missing extension. An optional feature
  -- probe must not enable split screen/VR simply by checking for its API.
  local registry=rawget(_G,'extensions')
  return rawget(_G,name) or (type(registry)=='table' and rawget(registry,name))
end
local function read()
  assert(core_camera and RenderViewManagerInstance,'Main camera APIs unavailable')
  local xr=loaded('render_openxr')
  local split=loaded('render_splitScreen')
  if xr and xr.isSessionRunning then assert(not xr.isSessionRunning(),'VR capture is unsupported')end
  if split and split.getCurrentConfiguration then
    local enabled=split.getCurrentConfiguration()
    assert(not enabled,'Disable split-screen/multiseat before main-camera capture (including one-player mode)')
  end
  local view=assert(RenderViewManagerInstance:getView('main'),'Main RenderView unavailable')
  local f=assert(view.frustum,'Main frustum unavailable')
  local extent=assert(view.viewPort and view.viewPort.extent,'Main viewport extent unavailable')
  local out={position=vector(core_camera.getPosition()),right=vector(core_camera.getRight()),
    forward=vector(core_camera.getForward()),up=vector(core_camera.getUp()),
    left=tonumber(f:getNearLeft()),rightEdge=tonumber(f:getNearRight()),
    top=tonumber(f:getNearTop()),bottom=tonumber(f:getNearBottom()),
    near=tonumber(f:getNearDist()),far=tonumber(f:getFarDist()),
    viewportWidth=tonumber(extent.x),viewportHeight=tonumber(extent.y)}
  for _,key in ipairs({'left','rightEdge','top','bottom','near','far','viewportWidth','viewportHeight'})do
    assert(finite(out[key]),'Invalid camera '..key)
  end
  assert(out.near>0 and out.far>out.near+.2 and out.left<out.rightEdge and out.bottom<out.top,'Invalid perspective frustum')
  assert(out.viewportWidth>=64 and out.viewportHeight>=64,'Invalid camera viewport')
  local aspect=out.viewportWidth/out.viewportHeight
  assert(aspect>=4/3-.001 and aspect<=4,'Use a single landscape viewport (4:3 through 4:1)')
  for _,a in ipairs({out.right,out.forward,out.up})do assert(math.abs(dot(a,a)-1)<1e-4,'Camera basis is not unit')end
  assert(math.abs(dot(out.right,out.forward))<1e-4 and math.abs(dot(out.right,out.up))<1e-4
    and math.abs(dot(out.forward,out.up))<1e-4,'Camera basis is not orthogonal')
  local cross={out.right[2]*out.forward[3]-out.right[3]*out.forward[2],
    out.right[3]*out.forward[1]-out.right[1]*out.forward[3],out.right[1]*out.forward[2]-out.right[2]*out.forward[1]}
  assert(dot(cross,out.up)>.9999,'Unexpected camera basis handedness')
  out.sampleWidth=128;out.sampleHeight=math.floor(128/aspect+.5)
  assert(out.sampleHeight>=32 and out.sampleHeight<=96,'Camera pixel budget exceeded')
  return out,view
end
function M.ray(snapshot,u,v)
  assert(finite(u) and finite(v) and u>=0 and u<=1 and v>=0 and v<=1,'Invalid viewport sample')
  local x=snapshot.left+(snapshot.rightEdge-snapshot.left)*u
  local y=snapshot.top+(snapshot.bottom-snapshot.top)*v
  local offset={};for j=1,3 do offset[j]=snapshot.right[j]*x+snapshot.forward[j]*snapshot.near+snapshot.up[j]*y end
  local direction=unit(offset);local start={}
  for j=1,3 do start[j]=snapshot.position[j]+offset[j]end
  local forwardDot=dot(direction,snapshot.forward)
  assert(forwardDot>0,'Ray points behind camera')
  local far=math.min(1000,(snapshot.far-snapshot.near)/forwardDot)
  assert(far>.16,'Camera segment too short')
  return start,direction,far
end
function M.capture()
  local out,view=read()
  out.nativeRayChecks=0;out.maxNativeDirectionError=0
  for _,v in ipairs({.1,.5,.9})do for _,u in ipairs({.1,.5,.9})do
    local ok,pos,dir=view:getUnprojectedRayPosDir(u*out.viewportWidth,v*out.viewportHeight)
    assert(ok and pos and dir,'Native camera unprojection failed')
    pos=vector(pos);dir=unit(vector(dir))
    local _,expected=M.ray(out,u,v)
    local delta={};for j=1,3 do delta[j]=dir[j]-expected[j]end
    local error=length(delta);out.maxNativeDirectionError=math.max(error,out.maxNativeDirectionError)
    assert(error<.001,'Main frustum/core camera disagree with native unprojection; stop camera and retry')
    local fromCamera={};for j=1,3 do fromCamera[j]=pos[j]-out.position[j]end
    local along=dot(fromCamera,expected);local lateral={}
    for j=1,3 do lateral[j]=fromCamera[j]-along*expected[j]end
    assert(length(lateral)<.01 and along>=-.01,
      'Native primary origin does not match the main camera ray')
    out.nativeRayChecks=out.nativeRayChecks+1
  end end
  out.projectionValidated=true;out.view='main';out.perspective=true
  return out
end
function M.matches(snapshot)
  local ok,current=pcall(read)
  if not ok then return false,tostring(current)end
  for _,key in ipairs({'position','right','forward','up'})do for j=1,3 do
    if math.abs(snapshot[key][j]-current[key][j])>(key=='position' and .002 or .0001)then
      return false,'Camera moved/rotated; recapture the camera-aligned mask'
    end
  end end
  if snapshot.viewportWidth~=current.viewportWidth or snapshot.viewportHeight~=current.viewportHeight then
    return false,'Camera viewport changed; recapture'
  end
  for _,key in ipairs({'left','rightEdge','top','bottom','near','far'})do
    local tolerance=key=='far' and .01 or .00001
    if key=='left' or key=='rightEdge' then tolerance=math.max(tolerance,(snapshot.rightEdge-snapshot.left)*2/snapshot.viewportWidth)end
    if key=='top' or key=='bottom' then tolerance=math.max(tolerance,(snapshot.top-snapshot.bottom)*2/snapshot.viewportHeight)end
    if math.abs(snapshot[key]-current[key])>tolerance then return false,'Camera projection changed; recapture'end
  end
  return true
end
function M.project(snapshot,point)
  local rel={};for j=1,3 do rel[j]=point[j]-snapshot.position[j]end
  local z=dot(rel,snapshot.forward)
  if z<=0 then return nil,nil,false end
  local x=dot(rel,snapshot.right)*snapshot.near/z
  local y=dot(rel,snapshot.up)*snapshot.near/z
  local u=(x-snapshot.left)/(snapshot.rightEdge-snapshot.left)
  local v=(snapshot.top-y)/(snapshot.top-snapshot.bottom)
  return u,v,u>=0 and u<=1 and v>=0 and v<=1 and z>=snapshot.near and z<=snapshot.far
end
return M
