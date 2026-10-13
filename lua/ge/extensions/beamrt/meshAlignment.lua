-- Isolated actual-mesh alignment preview. Never enables GI or shadow effects.
local M={}
local placement=require('ge/extensions/beamrt/meshPlacement')
local current
local defaultPath='/art/beamrt/alignment/wcu_guardhouse.beamrt.json'
local mode='wire'
local maxEdges=2400
local frame=0
local savedCamera
local function fail(message) if log then log('E','BeamRT.Alignment',message) end;return false,message end
local function packageAt(path)
  if type(path)~='string' or path:find('..',1,true) or not path:match('^/art/beamrt/alignment/[%w_/%-%.]+%.json$') then
    return nil,'package must be /art/beamrt/alignment/<name>.json without traversal'
  end
  local ok,data=pcall(jsonReadFile,path)
  if not ok or type(data)~='table' or data.schema~='beamrt.mesh.alignment.v1' then return nil,'alignment package unavailable or wrong schema' end
  if data.space~='engine-model metres, Z-up' or not data.nodeSelection or not data.nodeSelection.sceneNodeTransformsBaked then
    return nil,'package does not contain node-baked engine-model geometry'
  end
  if type(data.triangles)~='table' or #data.triangles<1 or #data.triangles>200000 then return nil,'invalid triangle count' end
  for _,face in ipairs(data.triangles) do
    if type(face.v)~='table' or #face.v~=3 then return nil,'invalid face' end
    for _,p in ipairs(face.v) do if not placement.xyz(p) then return nil,'nonfinite triangle position' end end
  end
  return data
end
local function field(obj,name)
  local ok,v=pcall(function() return obj[name] or obj:getField(name,0) end)
  return ok and tostring(v or '') or ''
end
local function canonical(path) return tostring(path):gsub('\\','/'):gsub('^/',''):lower() end
local function install(data,obj,path,distance)
  local transform,err=placement.capture(obj)
  if not transform then return fail(err) end
  if canonical(transform.shapePath)~=canonical(data.shapePath) then return fail('selected object uses a different shape asset') end
  local run={package=data,path=path,placement=transform,objectId=transform.objectId,objectName=transform.objectName,
             distance=distance,worldTriangles={},edges={},enabled=true,alignmentVerified=false}
  local seen={}
  local materials={};local count=0
  for _,face in ipairs(data.triangles) do
    local name=face.materialNameCandidate or '<unresolved>'
    if not materials[name] then count=count+1;materials[name]=count end
    local v={}
    for i=1,3 do v[i]=placement.apply(transform.basis,face.v[i]) end
    run.worldTriangles[#run.worldTriangles+1]={a=v[1],b=v[2],c=v[3],uv=face.uv,
      materialName=name,alphaMode='unknown',geometryId=face.geometryId,nodePath=face.nodePath}
    for i=1,3 do
      local j=i%3+1
      local a=string.format('%.6f %.6f %.6f',face.v[i][1],face.v[i][2],face.v[i][3])
      local b=string.format('%.6f %.6f %.6f',face.v[j][1],face.v[j][2],face.v[j][3])
      local key=a<b and (a..'|'..b) or (b..'|'..a)
      if not seen[key] then
        seen[key]=true
        run.edges[#run.edges+1]={vec3(v[i][1],v[i][2],v[i][3]),vec3(v[j][1],v[j][2],v[j][3]),materials[name]}
      end
    end
  end
  current=run
  if log then log('I','BeamRT.Alignment',string.format('Actual mesh ready: id=%s, faces=%d, edges=%d, distance=%.1fm. Wire preview only; alignment NOT yet visually verified.',
    tostring(run.objectId),#run.worldTriangles,#run.edges,distance or 0)) end
  return true,M.getStatus()
end
function M.previewObject(objectName,path)
  path=path or defaultPath
  local data,err=packageAt(path);if not data then return fail(err) end
  local obj=scenetree.findObject(objectName)
  if not obj then return fail('scene object not found') end
  return install(data,obj,path)
end
function M.previewNearest(path)
  path=path or defaultPath
  local data,err=packageAt(path);if not data then return fail(err) end
  local eye=placement.xyz(core_camera.getPosition());if not eye then return fail('camera position unavailable') end
  local selected,best
  local tokens=scenetree.findClassObjects('TSStatic')
  for _,token in ipairs(tokens or {}) do
    local obj=scenetree.findObject(token)
    if obj and canonical(field(obj,'shapeName'))==canonical(data.shapePath) then
      local ok,p=pcall(function() return placement.xyz(obj:getPosition()) end)
      if ok and p then
        local d=0;for i=1,3 do d=d+(p[i]-eye[i])^2 end
        if not best or d<best then selected,best=obj,d end
      end
    end
  end
  if not selected then return fail('no instance of the prepared asset exists in this map') end
  return install(data,selected,path,math.sqrt(best))
end
function M.setMode(value)
  if value~='wire' and value~='materials' and value~='off' then return false end
  mode=value;return true
end
function M.setMaxEdges(value)
  if type(value)~='number' or value~=value or value%1~=0 or value<1 or value>6000 then return false end
  maxEdges=value;return true
end
function M.clear() current=nil;return true end
-- Explicit opt-in convenience: focus the FREE camera, never move the vehicle.
-- This is not called by previewNearest/load/unload or other diagnostics.
function M.focusPreview()
  if not current or not current.enabled then return fail('capture a non-stale instance first') end
  if not core_camera or type(core_camera.globalCameraFunction)~='function' or type(quatFromDir)~='function' then
    return fail('native free-camera APIs unavailable')
  end
  local ok,err=pcall(function()
    local lo={math.huge,math.huge,math.huge};local hi={-math.huge,-math.huge,-math.huge}
    for _,face in ipairs(current.worldTriangles) do
      for _,p in ipairs({face.a,face.b,face.c}) do
        for i=1,3 do lo[i]=math.min(lo[i],p[i]);hi[i]=math.max(hi[i],p[i]) end
      end
    end
    local center=vec3((lo[1]+hi[1])*.5,(lo[2]+hi[2])*.5,(lo[3]+hi[3])*.5)
    local distance=math.max(8,math.max(hi[1]-lo[1],hi[2]-lo[2],hi[3]-lo[3])*2)
    local eye=vec3(center.x+distance,center.y-distance,center.z+distance*.5)
    local direction=vec3(center.x-eye.x,center.y-eye.y,center.z-eye.z)
    if not savedCamera then
      local p=placement.xyz(core_camera.getPosition());local q=core_camera.getQuat()
      savedCamera={mode=core_camera.getActiveCamName(0),position=p,
                   rotation={q.x,q.y,q.z,q.w}}
    end
    core_camera.setByName(0,'free')
    core_camera.globalCameraFunction('free','setPosition',eye)
    core_camera.globalCameraFunction('free','setRotation',quatFromDir(direction))
  end)
  if not ok then return fail('free-camera focus failed: '..tostring(err)) end
  return true
end
function M.restoreCamera()
  if not savedCamera then return false end
  local old=savedCamera
  local ok,err=pcall(function()
    if old.mode=='free' then
      core_camera.setByName(0,'free')
      core_camera.globalCameraFunction('free','setPosition',vec3(old.position[1],old.position[2],old.position[3]))
      core_camera.globalCameraFunction('free','setRotation',quat(old.rotation[1],old.rotation[2],old.rotation[3],old.rotation[4]))
    else
      core_camera.setByName(0,old.mode)
    end
  end)
  if not ok then return fail('camera restore failed: '..tostring(err)) end
  savedCamera=nil;return true
end
function M.confirmAlignment(value)
  if not current or type(value)~='boolean' then return false end
  current.alignmentVerified=value -- Explicit human evidence, never automatic.
  return true
end
function M.getStatus()
  if not current then return {active=false,productionRenderingChanged=false} end
  return {active=current.enabled,mode=mode,objectId=current.objectId,objectName=current.objectName,
    shapePath=current.package.shapePath,selectedNode=current.package.nodeSelection.selectedNode,
    triangles=#current.worldTriangles,edges=#current.edges,drawnEdgeBudget=math.min(maxEdges,#current.edges),
    wireframeIsPartial=#current.edges>maxEdges,distanceAtCapture=current.distance,
    placement=current.placement,alignmentVerified=current.alignmentVerified,
    materials=current.package.materials,staleReason=current.staleReason,
    gpuUploaded=false,productionRenderingChanged=false,shadowPersistenceVerified=false}
end
function M.getGPUSceneBinding(path)
  if not current or not current.enabled then return nil,'capture an aligned instance first' end
  local data,err=packageAt(path or '/art/beamrt/alignment/wcu_guardhouse.gpu.beamrt.json')
  if not data then return nil,err end
  if data.sourceSha256~=current.package.sourceSha256 or data.nodeSelection.selectedNode~=current.package.nodeSelection.selectedNode then
    return nil,'GPU package does not match captured visual geometry'
  end
  local gpu=data.gpuData
  if not gpu or gpu.schema~='beamrt.bvh.rgba8.v1' or gpu.triangleCount~=#current.worldTriangles
    or type(gpu.texture)~='string' or gpu.texture:find('..',1,true)
    or not gpu.texture:match('^/art/beamrt/alignment/[%w_/%-%.]+%.data%.png$') then
    return nil,'invalid or missing GPU data package'
  end
  return {objectId=current.objectId,placement=current.placement,gpuData=gpu,
          alignmentVerified=current.alignmentVerified,shapePath=data.shapePath}
end
function M.exportWorldMesh(path)
  if not current or not current.enabled then return fail('capture a non-stale instance first') end
  if type(path)~='string' or not path:match('^/settings/beamrt[%w_%-]+%.json$') then return fail('use /settings/beamrt<name>.json') end
  local payload={schema='beamrt.mesh.world-alignment.v1',triangles=current.worldTriangles,
    placement=current.placement,materials=current.package.materials,
    assetSha256=current.package.sourceSha256,alignmentVerified=current.alignmentVerified,
    gpuUploaded=false,opaqueFacesVerified=false,shadowPersistenceVerified=false}
  local ok,result=pcall(jsonWriteFile,path,payload,true)
  if not ok or result==false then return fail('world mesh export failed') end
  return true,{path=path,triangles=#current.worldTriangles,alignmentVerified=current.alignmentVerified}
end
function M.onPreRender()
  if not current or not current.enabled then return end
  frame=frame+1
  if frame%30==0 then
    local obj=scenetree.findObject(current.objectId)
    local updated=obj and placement.capture(obj)
    if not updated or not placement.same(current.placement,updated) then
      current.enabled=false;current.alignmentVerified=false;current.staleReason='object disappeared or moved/scaled; recapture required'
      if log then log('W','BeamRT.Alignment',current.staleReason) end
      return
    end
  end
  if mode=='off' or not debugDrawer then return end
  local palette={ColorF(1,.55,.05,1),ColorF(.1,.8,1,1),ColorF(.7,1,.2,1),ColorF(1,.2,.6,1)}
  for i=1,math.min(maxEdges,#current.edges) do
    local edge=current.edges[i]
    debugDrawer:drawLine(edge[1],edge[2],palette[mode=='materials' and ((edge[3]-1)%4+1) or 1])
  end
end
function M.onClientStartMission() M.clear();savedCamera=nil end
function M.onClientEndMission() M.clear();savedCamera=nil end
function M.onExtensionLoaded() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end end
function M.onExtensionUnloaded() M.clear() end
return M
