-- Off-screen VIEW PROBE ONLY. No automatic SSR fallback/composite. BeamNG's
-- shipped render/viewDemo and render/renderViews establish the ordinary camera
-- fields used here, but do not establish reflection-plane clipping support.
local M={}
local mathPolicy=require('ge/extensions/beamrt/reflectionCaptureMath')
local view,viewName,frame,preview
local destroyPending=false
local requested=false
local mode,height,frames='mirror',nil,0
local reason='Probe disabled. Plane-side clipping and capture depth are not verified.'
local NAME='BeamRT_PlanarCaptureProbe'
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function manager()return RenderViewManagerInstance end
-- Native getView() may wrap the same RenderView in a different Lua userdata.
-- Use our reserved name AND assigned color target, not wrapper equality alone.
local function isOwned(current)
  return current and (current==view or current.namedTexTargetColor==viewName)
end
local function clearView()
  view=nil;viewName=nil;destroyPending=false
end
local function reserveName(m)
  -- Never adopt an old fixed-name probe after its creating module lost it.
  if m:getView(NAME)then error('Legacy probe view remains; restart BeamNG once to clear the old capture')end
  for i=1,64 do
    local candidate=NAME..'_'..i
    if not m:getView(candidate)then return candidate end
  end
  error('No unused probe view name available; not taking ownership')
end
local function findMain()
  local m=manager()
  if not m or type(m.getView)~='function'then error('RenderView lookup is unavailable')end
  local main=m:getView('main');if not main then error('Main RenderView is unavailable')end
  return main
end
local function camera(main)
  local matrix=type(getCameraTransform)=='function'and getCameraTransform()or main.cameraMatrix
  if not matrix then error('Main camera pose unavailable')end
  local fov=tonumber(main.fov)
  if core_camera and type(core_camera.getFovDeg)=='function'then fov=core_camera.getFovDeg()end
  return {eye=matrix:getColumn(3),right=matrix:getColumn(0),forward=matrix:getColumn(1),up=matrix:getColumn(2),fov=fov}
end
local function discoverPlane()
  local found
  if not scenetree or type(scenetree.findClassObjects)~='function'then error('Water-plane lookup unavailable; pass height explicitly')end
  for _,name in pairs(scenetree.findClassObjects('WaterPlane')or{})do
    local object=scenetree.findObject(name)
    if object then
      local z=tonumber(object:getPosition().z)
      if not finite(z)then error('Invalid WaterPlane height')end
      if found and math.abs(found-z)>.01 then error('Multiple water heights; pass one plane height explicitly')end
      found=z
    end
  end
  if found==nil then error('No WaterPlane found; pass a plane height explicitly')end
  return found
end
local function configure(main)
  local transformed,err=mathPolicy.frame(camera(main),height,mode)
  if not transformed then error(err)end
  local width=512
  local rx,ry=tonumber(main.resolution.x),tonumber(main.resolution.y)
  if not finite(rx)or not finite(ry)or rx<1 or ry<1 then error('Main view resolution unavailable')end
  local h=math.max(16,math.min(1024,math.floor(width*ry/rx+.5)))
  local matrix=MatrixF(true)
  for i,key in ipairs({'right','forward','up','eye'})do
    local a=transformed[key];matrix:setColumn(i-1,vec3(a[1],a[2],a[3]))
  end
  view.cameraMatrix=matrix
  view.resolution=Point2I(width,h)
  view.viewPort=RectI(0,0,width,h)
  view.frustum=Frustum.construct(false,math.rad(transformed.fov),width/h,.1,2000)
  view.fov=transformed.fov
  frame=transformed
end
function M.getStatus()
  return {requested=requested,mode=mode,height=height,framesScheduled=frames,reason=reason,
    viewName=viewName,target=viewName and '#'..viewName or nil,cleanupPending=destroyPending,
    outputVerified=false,depthVerified=false,planeClipVerified=false,
    compositeAllowed=false,gameSettingsChanged=false}
end
function M.inspect()
  local report={fields={},objectTypeConstants={},planeClipVerified=false,depthVerified=false,
    note='Read-only binding inventory. A readable field is not proof that a capture or clip operation works.'}
  local ok,main=pcall(findMain)
  report.mainViewAvailable=ok and main~=nil
  if ok and main then
    for _,name in ipairs({'namedTexTargetColor','namedTexTargetDepth','cameraMatrix','frustum',
      'reflectionPlane','clipPlane','renderWater','isReflection'})do
      local read,value=pcall(function()return main[name]end)
      report.fields[name]={readOK=read,nonNil=read and value~=nil,valueType=read and type(value)or 'unavailable'}
    end
  end
  for name,value in pairs(_G)do
    if type(name)=='string'and name:sub(1,4)=='SOTM'and type(value)=='number'then
      report.objectTypeConstants[#report.objectTypeConstants+1]=name
    end
  end
  table.sort(report.objectTypeConstants)
  return report
end
function M.stop(why)
  requested=false;preview=nil;frame=nil
  local ok,err=pcall(function()
    if view then
      local m=manager()
      if not m or type(m.getView)~='function'or type(m.destroyView)~='function'then error('View cleanup unavailable')end
      if isOwned(m:getView(viewName))then
        if not destroyPending then
          view.active=false
          -- Shipped renderViews.lua destroys its stored handle directly.
          m:destroyView(view)
          destroyPending=true
        end
        -- Deletion may be deferred. Retain the lease but never dereference or
        -- destroy the accepted handle twice; block a new renderer until gone.
        if isOwned(m:getView(viewName))then error('Capture view deletion pending; retry Stop camera probe after a frame')end
      end
    end
    clearView()
  end)
  reason=why or 'Capture probe stopped.'
  if not ok then reason=reason..' Cleanup incomplete: '..tostring(err);return false,reason end
  return true
end
function M.start(planeHeight,captureMode)
  if captureMode~='mirror'and captureMode~='rear'then return false,'Choose mirror or rear capture.'end
  if planeHeight~=nil and not finite(planeHeight)then return false,'Plane height must be finite.'end
  local stopped,err=M.stop('Preparing isolated capture probe')
  if not stopped then return false,err end
  local ok,failure=pcall(function()
    local main=findMain();local m=manager()
    if type(m.getOrCreateView)~='function'or type(m.destroyView)~='function'then error('View creation/cleanup API unavailable')end
    mode=captureMode;height=mode=='mirror'and(planeHeight or discoverPlane())or nil
    -- Validate pose and constructors before allocating a native view.
    local planned,why=mathPolicy.frame(camera(main),height,mode)
    if not planned then error(why)end
    if MatrixF==nil or vec3==nil or Point2I==nil or RectI==nil
      or not Frustum or Frustum.construct==nil then error('Camera construction API unavailable')end
    viewName=reserveName(m)
    view=m:getOrCreateView(viewName)
    if not view then error('Could not create the capture view')end
    view.active=false;view.luaOwned=true;view.renderCubemap=false
    view.renderEditorIcons=false;view.usePostEffects=false
    view.namedTexTargetColor=viewName
    configure(main)
    view.active=true
  end)
  if not ok then M.stop('Capture probe failed: '..tostring(failure));return false,reason end
  requested=true;frames=0
  reason='512px capture probe scheduled; preview only. No plane clipping, depth proof or reflection compositing.'
  return true
end
function M.update()
  if not requested then return end
  local ok,err=pcall(function()
    if not view or not isOwned(manager():getView(viewName))then error('Owned capture view lost')end
    configure(findMain());view.active=true;frames=frames+1
  end)
  if not ok then M.stop('Capture stopped: '..tostring(err))end
end
function M.drawPreview(im)
  if not requested then return end
  local ok,err=pcall(function()
    preview=preview or require('ui/imguiUtils').texObj('#'..viewName)
    if not preview or not preview.tex then error('Named color texture unavailable')end
    local scale=math.min(1,288/view.resolution.y)
    im.Image(preview.tex:getID(),im.ImVec2(512*scale,view.resolution.y*scale))
  end)
  if not ok then im.TextWrapped('Preview unavailable: '..tostring(err))end
end
M.release=M.stop
return M
