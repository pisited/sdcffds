-- Paused acquisition/CPU geometry controls. No GPU shading or scene writes.
local M = {}
-- Revision 8: user-approved geometry-only retry after one live single-car
-- copy/validation/free succeeded. This is NOT a proven native crash repair.
-- Revision 9 adds a separately budgeted CPU BVH/image mode after native release.
-- Revision 10 keeps that baseline and adds isolated signed-normal close-ups.
-- Revision 11 adds an ideal-mirror one-bounce geometric mask with exclusions.
-- Revision 12 adds a native-unprojection-validated frozen main-camera mask.
-- Revision 13 adds reflected layer-zero material factors under diagnostic light.
-- Revision 14 certifies whole captured sources outside the frozen view frustum.
-- Revision 15 compares bounded rays against a separate, owned GPU helper.
-- Revision 16 generates a full primary/reflected hit image on an owned GPU BVH.
local ACQUISITION_BLOCKED = false
local ACQUISITION_REASON = 'Vehicle GPUMesh acquisition is quarantined'
-- These helpers own no global jobs/resources. Refresh their API on an extension
-- reload; the previous controller's unload hook cancels its data before reload.
package.loaded['ge/extensions/beamrt/vehicleAlignmentPreview']=nil
package.loaded['ge/extensions/beamrt/vehicleRayProbe']=nil
local provider = require('ge/extensions/beamrt/providers/vehicleProvider')
local geometry = require('ge/extensions/beamrt/glassGeometry') -- pose/checkTarget only
local propPlacement = require('ge/extensions/beamrt/vehiclePropPlacement')
local alignment = require('ge/extensions/beamrt/vehicleAlignmentPreview')
local rayProbe = require('ge/extensions/beamrt/vehicleRayProbe')
local rows, reports = {}, {}
local phase, reason, elapsed = 'idle', 'Not started', 0
local cleanupUnverified = false
local journalFailed = false
local JOURNAL='/settings/beamrtVehiclePairStages.jsonl'
local runId,sequence,lastStage,runNumber='',0,nil,0
local previewRemaining = 0
local captureMode,rayJob,imageModule,imageJob
local imagePath,imageUIReason
local imageFailure,imageFailureRemaining,lastGpuFailure,lastGpuImageFailure=nil,0,nil,nil
local imageRemaining=0
local imageUIRequested=false
local cameraModule,cameraSnapshot,gpuEndpoint
local function imageMode(mode)return mode=='image' or mode=='normal-image' or mode=='reflection-mask' or mode=='camera-reflection-mask' or mode=='camera-material' or mode=='camera-gpu' or mode=='camera-gpu-image'end
local function cameraMode(mode)return mode=='camera-reflection-mask' or mode=='camera-material' or mode=='camera-gpu' or mode=='camera-gpu-image'end
local LIMIT_BYTES, LIMIT_VERTICES, LIMIT_INDICES = 32*1024*1024, 500000, 1500000

local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function integer(n,limit)
  return finite(n) and n>=0 and n%1==0 and n<=limit
end
local function member(o,k)
  local v=o[k];if type(v)=='function' then return v(o) end;return v
end
local function mark(row,stage)
  sequence=sequence+1
  lastStage={scope=tostring(stage.scope):sub(1,192),operation=tostring(stage.operation):sub(1,80),
    boundary=stage.boundary,sequence=sequence,vehicleId=row and row.id,role=row and row.role}
  local entry={schema='beamrt.vehicle-pair-stage.v1',run=runId}
  for k,v in pairs(lastStage)do entry[k]=v end
  local ok,err=pcall(function()
    local f,why=io.open(JOURNAL,'a');assert(f,why or 'Cannot open pair stage journal')
    local wrote,writeError=pcall(function()assert(f:write(jsonEncode(entry)..'\n'));assert(f:flush())end)
    local closed,closeError=f:close()
    assert(wrote,writeError);assert(closed,closeError or 'Pair stage journal close failed')
  end)
  if not ok then journalFailed=true;error('Pair stage journal failed: '..tostring(err))end
end
local function stage(row,operation,boundary,scope)
  mark(row,{scope=scope or 'owner',operation=operation,boundary=boundary})
end
local function observed(row,scope,operation,fn,...)
  stage(row,operation,'before',scope)
  local a,b,c=fn(...)
  stage(row,operation,'after',scope)
  return a,b,c
end
local function request(row)
  stage(row,'request','before')
  -- Store ownership before writing the after marker, which can itself fail.
  row.mesh=assert(GPUMesh.bng_getGPUMesh(row.id),'Native vehicle readback request failed')
  stage(row,'request','after')
end
local function resolve(id)
  return be and be:getObjectByID(id)
end
local function names(v)
  local value=v:getMeshMaterialNames()
  assert(type(value)=='table','Vehicle material names unavailable')
  local result={}
  for i,name in ipairs(value) do
    assert(type(name)=='string','Invalid vehicle material name');result[i]=name
  end
  return result
end
local function sameNames(a,b)
  if #a~=#b then return false end
  for i,name in ipairs(a) do if name~=b[i] then return false end end
  return true
end
local function validRows()
  assert(simTimeAuthority and simTimeAuthority.getPause(),'Physics resumed; recapture both parked cars')
  if cameraSnapshot then local ok,why=cameraModule.matches(cameraSnapshot);assert(ok,why)end
  for _,row in ipairs(rows) do
    assert(resolve(row.id)==row.vehicle,'Vehicle removed/replaced; recapture pair')
    assert(geometry.samePose(row.pose,geometry.pose(row.vehicle)),'Vehicle pose changed; recapture pair')
    assert(sameNames(row.names,names(row.vehicle)),'Vehicle material names changed; recapture pair')
    if row.preview then alignment.validate(row.preview,row.vehicle) end
  end
end
local function release(row)
  if row.record and provider.get(row.id)==row.record then provider.invalidate(row.id) end
  row.record=nil
  if row.mesh and not row.freeAttempted then
    row.freeAttempted=true
    pcall(stage,row,'free','before') -- journal failure must not skip owned cleanup
    local ok,result=pcall(function() return row.mesh:free() end)
    if not ok or result==false then
      -- Do not retry a native free with an uncertain outcome or silently lose
      -- ownership. Block a new acquisition for the lifetime of this module.
      cleanupUnverified=true
    else row.mesh=nil;pcall(stage,row,'free','after') end
  end
end
function M.stop(message)
  previewRemaining=0
  imageRemaining=0;imageUIRequested=false;imagePath=nil;imageUIReason=nil
  if imageJob and imageModule then imageModule.cancel(imageJob)end
  imageJob=nil
  imageFailure=nil;imageFailureRemaining=0;lastGpuFailure=nil;lastGpuImageFailure=nil
  cameraSnapshot=nil;gpuEndpoint=nil
  rayJob=nil;captureMode=nil
  for _,row in ipairs(rows) do row.preview=nil;row.traceScene=nil;release(row) end
  reports={};phase='stopped';reason=message or 'Stopped'
  if cleanupUnverified then reason=reason..'; native mesh cleanup unverified; no new capture' end
  if journalFailed then reason=reason..'; stage journal failed; no new capture' end
  return not cleanupUnverified and not journalFailed,reason
end

-- Check counts before provider.capture allocates any FFI buffers. The native
-- GPUMesh request itself is engine-owned and cannot be budgeted from Lua here.
local function budget(mesh,row)
  local bytes,primitives=0,0
  local function buffers(owner,scope)
    for _,field in ipairs({{'verticesCount',3},{'indicesCount',1}}) do
      local n=tonumber(observed(row,scope,field[1],member,owner,field[1]))
      local limit=field[1]=='indicesCount' and LIMIT_INDICES or LIMIT_VERTICES
      assert(integer(n,limit),'Invalid/over-budget '..field[1])
      bytes=bytes+n*field[2]*4
      assert(bytes<=LIMIT_BYTES,'Vehicle CPU buffer budget exceeded; no truncation')
    end
  end
  buffers(mesh,'budget.root')
  for _,kind in ipairs({'flexmeshes','propmeshes'}) do
    local count=tonumber(observed(row,'budget.root',kind..'Count',member,mesh,kind..'Count'))
    assert(integer(count,256),'Invalid/over-budget '..kind..'Count')
    for i=0,count-1 do
      local scope='budget.'..kind..'['..i..']'
      local desc=assert(observed(row,scope,'descriptor',function()return mesh[kind](mesh,i)end),'Native submesh unavailable')
      local n=tonumber(observed(row,scope,'primitivesCount',member,desc,'primitivesCount'))
      assert(integer(n,2048),'Invalid native primitive count')
      primitives=primitives+n;assert(primitives<=2048,'Vehicle primitive budget exceeded')
      if kind=='propmeshes' then buffers(desc,scope) end
    end
  end
  return bytes
end
local function outsideDistance(v,pose)
  local outside=0
  for i=1,3 do
    local distance=0
    for j=1,3 do distance=distance+(v[j]-pose.center[j])*pose.axes[i][j] end
    outside=math.max(outside,math.abs(distance)-pose.half[i])
  end
  return outside
end
local function inspect(record,row,bytes)
  local report={id=row.id,role=row.role,model=row.model,pose=row.pose,
    cpuBufferBytes=bytes,materials={},warnings={},flexTriangles=0,propTriangles=0,
    unresolvedPrimitives=0,propMeshes=#record.propmeshes,
    coordinateFrameVerified=false,propTransformsVerified=false,
    materialShadingVerified=false,completeVehicleGeometryVerified=false}
  for i,name in ipairs(record.materialNames) do report.materials[i]=name end
  for i,value in ipairs(record.acquisitionWarnings or {}) do report.warnings[i]=tostring(value) end
  local function inspectBuffers(counts,buffers,pose)
    assert(counts.vertices>0 and buffers.vertices and buffers.indices,'Missing core mesh buffers')
    assert(counts.indices%3==0,'Native index buffer is not a triangle list')
    local lo,hi={math.huge,math.huge,math.huge},{-math.huge,-math.huge,-math.huge}
    local worldCandidate,relativeCandidate,exporterCandidate=true,true,true
    local exporterMaxOutside=0
    for i=0,counts.vertices-1 do
      local p,translated={},{}
      for j=1,3 do
        local v=tonumber(buffers.vertices[i*3+j-1]);assert(finite(v),'Nonfinite native vertex')
        p[j]=v;lo[j]=math.min(lo[j],v);hi[j]=math.max(hi[j],v)
        if pose then translated[j]=v+pose.position[j] end
      end
      if pose then
        worldCandidate=worldCandidate and outsideDistance(p,pose)<=.3
        relativeCandidate=relativeCandidate and outsideDistance(translated,pose)<=.3
        -- The shipped glTF exporter writes GPUMesh positions unchanged, but
        -- maps prop translation from engine axes as (x,z,-y). Test its inverse
        -- plus vehicle origin; do NOT infer this is a verified flexmesh frame.
        -- No extra vehicle rotation: this candidate assumes already rotated
        -- world-relative geometry, not model-local coordinates.
        local exporterWorld={p[1]+pose.position[1],-p[3]+pose.position[2],p[2]+pose.position[3]}
        exporterMaxOutside=math.max(exporterMaxOutside,outsideDistance(exporterWorld,pose))
        exporterCandidate=exporterCandidate and exporterMaxOutside<=.3
      end
    end
    for i=0,counts.indices-1 do
      assert(integer(tonumber(buffers.indices[i]),counts.vertices-1),'Native triangle index out of range')
    end
    return {min=lo,max=hi},worldCandidate,relativeCandidate,exporterCandidate,exporterMaxOutside
  end
  report.rawFlexBounds,report.worldBoundsCandidate,report.originRelativeBoundsCandidate,
    report.exporterAxesOriginRelativeBoundsCandidate,report.exporterAxesMaxOutsideMetres=
    inspectBuffers(record.counts,record.buffers,row.pose)
  local function primitives(meshes,counts,key)
    for _,mesh in ipairs(meshes) do
      local c=mesh.counts or counts
      if mesh.counts then inspectBuffers(c,mesh.buffers) end
      for _,p in ipairs(mesh.primitives) do
        assert(integer(p.firstIndex,c.indices) and integer(p.indexCount,c.indices)
          and p.firstIndex%3==0 and p.indexCount%3==0
          and p.firstIndex+p.indexCount<=c.indices,'Invalid primitive triangle range')
        report[key]=report[key]+p.indexCount/3
        if type(p.materialName)~='string' or p.materialName=='' then
          report.unresolvedPrimitives=report.unresolvedPrimitives+1
        end
      end
    end
  end
  primitives(record.flexmeshes,record.counts,'flexTriangles')
  primitives(record.propmeshes,nil,'propTriangles')
  report.propPlacement=propPlacement.inspect(record,row.mesh,row.vehicle,row.pose.position)
  assert(report.flexTriangles+report.propTriangles>0,'No vehicle primitive triangles captured')
  -- Bounds candidates are evidence only, not a guessed world transform. They
  -- may both pass near world origin; props require separate transforms.
  return report
end

function M.start(receiverId,sourceId,mode)
  if ACQUISITION_BLOCKED then return false,ACQUISITION_REASON end
  if cleanupUnverified then return false,'Native mesh cleanup unverified; no new capture' end
  if journalFailed then return false,'Pair stage journal failed; restart BeamNG before retry' end
  if phase=='pending' or phase=='inspected' then return false,'Stop the previous pair probe first' end
  rows={};reports={};elapsed=0
  local ok,err=pcall(function()
    assert(provider.diagnosticStageVersion==1,'Stale provider loaded; restart BeamNG before pair retry')
    assert(mode==nil or mode=='hit-test' or imageMode(mode),'Unknown vehicle capture mode')
    if imageMode(mode) then
      package.loaded['ge/extensions/beamrt/vehicleGeometryBVH']=nil
      package.loaded['ge/extensions/beamrt/vehicleRayImage']=nil
      package.loaded['ge/extensions/beamrt/vehicleReflectionMask']=nil
      if cameraMode(mode) then
        package.loaded['ge/extensions/beamrt/vehicleCameraSnapshot']=nil
        package.loaded['ge/extensions/beamrt/vehicleCameraReflectionMask']=nil
        package.loaded['ge/extensions/beamrt/vehicleMaterialSnapshot']=nil
        package.loaded['ge/extensions/beamrt/vehicleOffscreenGeometry']=nil
        package.loaded['ge/extensions/beamrt/vehicleGpuProbe']=nil
        package.loaded['ge/extensions/beamrt/vehicleGpuImage']=nil
        cameraModule=require('ge/extensions/beamrt/vehicleCameraSnapshot')
      end
      imageModule=require('ge/extensions/beamrt/vehicleRayImage')
      imageUIRequested=true
    end
    captureMode=mode;rayJob=nil
    assert(integer(receiverId,2147483647) and integer(sourceId,2147483647)
      and receiverId>0 and sourceId>0 and receiverId~=sourceId,'Specify two distinct numeric vehicle IDs')
    assert(simTimeAuthority and simTimeAuthority.getPause(),'Park both cars and pause physics with J first')
    assert(GPUMesh and type(GPUMesh.bng_getGPUMesh)=='function','Native vehicle GPUMesh unavailable')
    for i,id in ipairs({receiverId,sourceId}) do
      local vehicle=assert(resolve(id),'Vehicle ID not found')
      local targetOK,targetWhy=geometry.checkTarget(vehicle);assert(targetOK,targetWhy)
      if type(vehicle.getClassName)=='function' then
        assert(vehicle:getClassName()=='BeamNGVehicle','Selected object is not a BeamNG vehicle')
      end
      assert(provider.get(id)==nil,'Vehicle already has a cached GPUMesh; do not overwrite another capture')
      rows[i]={id=id,vehicle=vehicle,role=i==1 and 'receiver A' or 'source B',
        model=tostring(vehicle:getJBeamFilename()),pose=geometry.pose(vehicle),names=names(vehicle)}
    end
    -- Both identities are validated, but only one readback may be outstanding.
    -- A is copied/released before B is requested, like the shipped exporter.
    runNumber=runNumber+1;sequence=0;lastStage=nil
    runId=os.date('!%Y%m%dT%H%M%SZ')..'-'..tostring(os.clock())..'-'..runNumber
    if mode=='camera-gpu' or mode=='camera-gpu-image' then
      stage(nil,'preflightGpuHelper','before')
      gpuEndpoint=require('ge/extensions/beamrt/'..(mode=='camera-gpu-image' and 'vehicleGpuImage' or 'vehicleGpuProbe')).preflight()
      stage(nil,'preflightGpuHelper','after')
    end
    if cameraMode(mode) then
      stage(nil,'captureMainCamera','before')
      cameraSnapshot=cameraModule.capture()
      stage(nil,'captureMainCamera','after')
    end
    request(rows[1])
    validRows()
  end)
  if not ok then M.stop('Pair preflight failed: '..tostring(err));return false,reason end
  phase='pending';reason='Waiting for two native mesh readbacks; keep physics paused'
  return true,reason
end
function M.update(dt)
  if phase~='pending' and phase~='inspected' then return end
  local ok,err=pcall(function()
    validRows()
    if phase=='inspected' then
      if imageJob and imageJob.phase~='complete' then
        imageModule.advance(imageJob,dt)
        if imageJob.phase=='complete' then
          validRows()
          if imageJob.gpuProbe and imageJob.gpuProbe.hardwareExecutionVerified then
            stage(nil,'isolatedGpuReadbackComplete','after')
            stage(nil,imageJob.gpuProbe.passed and 'isolatedGpuComparisonMatched' or 'isolatedGpuComparisonMismatch','after')
          end
          if imageJob.gpuImage and imageJob.gpuImage.hardwareExecutionVerified then
            stage(nil,'isolatedGpuImageReadbackComplete','after')
            stage(nil,imageJob.gpuImage.passed and 'isolatedGpuImageMatched' or 'isolatedGpuImageMismatch','after')
          end
          stage(nil,'saveCPUImage','before')
          local prefix=imageJob.profile=='camera-gpu-image' and 'camera-gpu-image-' or (imageJob.profile=='camera-gpu' and 'camera-gpu-'
            or (imageJob.profile=='camera-material' and 'camera-material-'
            or (imageJob.profile=='camera-bounce' and 'camera-bounce-'
            or (imageJob.profile=='normals' and 'normals-' or (imageJob.profile=='bounce' and 'bounce-' or '')))))
          local path='/settings/beamrtVehicleRayImage-'..prefix
            ..runId:gsub('[^%w%._%-]','_')..'.bmp'
          local data=imageModule.bitmap(imageJob)
          local f,why=io.open(path,'wb');assert(f,why or 'Cannot open diagnostic bitmap')
          local wrote,writeError=pcall(function()assert(f:write(data));assert(f:flush())end)
          local closed,closeError=f:close();assert(wrote,writeError);assert(closed,closeError)
          imagePath=path;imageRemaining=120
          stage(nil,'saveCPUImage','after');stage(nil,'cpuImageComplete','after')
        end
      elseif rayJob and rayJob.phase=='running' then
        rayProbe.advance(rayJob,dt)
        if rayJob.phase=='complete' then stage(nil,'cpuControlsComplete','after') end
      end
      return
    end
    assert(finite(dt) and dt>=0,'Invalid real frame delta')
    elapsed=elapsed+dt;assert(elapsed<10,'Two-vehicle mesh readback timed out')
    for i,row in ipairs(rows) do
      if not reports[i] then
        if not row.mesh then
          assert(provider.get(row.id)==nil,'Another capture acquired this vehicle; no new readback requested')
          request(row)
        end
        local ready=observed(row,'owner','dataIsReady',member,row.mesh,'dataIsReady')
        if ready==true or ready==1 then
          local bytes=budget(row.mesh,row)
          assert(provider.get(row.id)==nil,'Another capture acquired this vehicle; pair probe will not overwrite it')
          stage(row,'captureGeometry','before')
          local record,why=provider.capture(row.id,row.mesh,'geometry',function(event)mark(row,event)end);assert(record,why)
          row.record=record
          stage(row,'captureGeometry','after')
          assert(sameNames(row.names,record.materialNames),'Captured material identity changed')
          stage(row,'inspectAndPropPlacement','before')
          reports[i]=inspect(record,row,bytes)
          stage(row,'inspectAndPropPlacement','after')
          stage(row,'prepareTransforms','before')
          local previewOK,preview=pcall(alignment.build,record,reports[i].propPlacement,
            row.vehicle,row.pose.position,reports[i].exporterAxesOriginRelativeBoundsCandidate)
          if previewOK then
            row.preview=preview;reports[i].previewTriangles=#preview.triangles
          else reports[i].previewReason=tostring(preview) end
          if captureMode=='hit-test' or imageMode(captureMode) then
            assert(row.preview,reports[i].previewReason)
            row.traceScene=rayProbe.prepare(record,row.preview,row.id)
          end
          stage(row,'prepareTransforms','after')
          release(row)
          assert(not cleanupUnverified and not journalFailed,'Native cleanup or stage journal unverified')
        else return end -- never request the next car while this one is pending
      end
    end
    validRows()
    if reports[1] and reports[2] then
      phase='inspected';reason='Both mesh snapshots inspected; NOT a reflection or world-transform proof'
      if imageMode(captureMode) then
        stage(nil,'createCPUImage','before')
        local profile=captureMode=='camera-gpu-image' and 'camera-gpu-image' or (captureMode=='camera-gpu' and 'camera-gpu' or (captureMode=='camera-material' and 'camera-material'
          or (captureMode=='camera-reflection-mask' and 'camera-bounce'
          or (captureMode=='reflection-mask' and 'bounce' or (captureMode=='normal-image' and 'normals' or 'identity')))))
        imageJob=imageModule.create({rows[1].traceScene,rows[2].traceScene},{rows[1].pose,rows[2].pose},
          profile,cameraSnapshot,gpuEndpoint)
        rayJob=imageJob.controls
        rows[1].traceScene=nil;rows[2].traceScene=nil
        stage(nil,'createCPUImage','after')
      elseif captureMode=='hit-test' then
        stage(nil,'createCPUControls','before')
        rayJob=rayProbe.create({rows[1].traceScene,rows[2].traceScene},{rows[1].pose,rows[2].pose})
        rows[1].traceScene=nil;rows[2].traceScene=nil -- sole buffer owner is now the bounded job
        stage(nil,'createCPUControls','after')
      end
    end
  end)
  if not ok then
    local failedMode=captureMode
    local gpu=imageJob and imageModule and imageModule.status(imageJob).gpuProbe
    local gpuImage=imageJob and imageModule and imageModule.status(imageJob).gpuImage
    M.stop('Pair preflight stopped: '..tostring(err))
    if imageMode(failedMode) then
      imageFailure={phase='cancelled',profile=failedMode,failureReason=reason}
      imageFailureRemaining=120
      if gpu then gpu.phase='cancelled';gpu.passed=false;gpu.error=reason;lastGpuFailure=gpu end
      if gpuImage then gpuImage.phase='cancelled';gpuImage.passed=false;gpuImage.error=reason;lastGpuImageFailure=gpuImage end
    end
  end
end
function M.getStatus()
  -- Never report a successful old snapshot as current after a pose/physics edit.
  if phase=='pending' or phase=='inspected' then
    local ok,err=pcall(validRows);if not ok then M.stop(tostring(err)) end
  end
  -- Return a detached report; callers cannot mutate internal validity evidence.
  local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
  end
  local previewReady=phase=='inspected'
  for _,row in ipairs(rows) do if not row.preview then previewReady=false end end
  local hitStatus=rayProbe.status(rayJob)
  if captureMode=='hit-test' and phase=='pending' then hitStatus.phase='acquiring'
  elseif phase=='stopped' then hitStatus.phase='cancelled';hitStatus.reason=reason end
  return {schema='beamrt.vehicle.pair.preflight.v1',diagnosticRevision=16,phase=phase,reason=reason,
    acquisitionBlocked=ACQUISITION_BLOCKED,acquisitionBlockReason=ACQUISITION_BLOCKED and ACQUISITION_REASON or nil,
    inspected=phase=='inspected',vehicles=copy(reports),cleanupUnverified=cleanupUnverified,
    journal=JOURNAL,journalFailed=journalFailed,run=runId,sequence=sequence,lastStage=copy(lastStage),
    feedsRayTracer=false,reflectionsEnabled=false,offscreenTestPassed=false,
    geometryFreshnessVerified=false,materialShadingVerified=false,
    alignmentPreview={ready=previewReady,enabled=previewRemaining>0,secondsRemaining=previewRemaining,
      sampledOnly=true,alignmentVerified=false},
    vehicleHitTest=copy(hitStatus),
    vehicleRayImage=imageModule and imageModule.status(imageJob)or {phase='idle'},
    scope='paused snapshots / optional CPU geometry controls; no GPU lighting proof'}
end
function M.getSummary()
  local status=M.getStatus()
  local summary={diagnosticRevision=status.diagnosticRevision,phase=status.phase,reason=status.reason,
    acquisitionBlocked=status.acquisitionBlocked,acquisitionBlockReason=status.acquisitionBlockReason,
    cleanupUnverified=status.cleanupUnverified,feedsRayTracer=false,offscreenTestPassed=false,
    journal=status.journal,journalFailed=status.journalFailed,lastStage=status.lastStage,
    alignmentPreview=status.alignmentPreview,vehicles={}}
  summary.vehicleHitTest={phase=status.vehicleHitTest.phase,trianglesTested=status.vehicleHitTest.trianglesTested,
    totalTriangleTests=status.vehicleHitTest.totalTriangleTests,geometricControlsPassed=status.vehicleHitTest.geometricControlsPassed}
  for i,v in ipairs(status.vehicles) do
    summary.vehicles[i]={id=v.id,flexTriangles=v.flexTriangles,propTriangles=v.propTriangles,
      propMeshes=v.propMeshes,warnings=#v.warnings,unresolvedPrimitives=v.unresolvedPrimitives,
      world=v.worldBoundsCandidate,originRelative=v.originRelativeBoundsCandidate,
      exporterAxesOriginRelative=v.exporterAxesOriginRelativeBoundsCandidate,
      exporterAxesMaxOutsideMetres=v.exporterAxesMaxOutsideMetres,
      propPlacement=propPlacement.summary(v.propPlacement),
      previewTriangles=v.previewTriangles,previewReason=v.previewReason,
      coordinateFrameVerified=false,propTransformsVerified=false}
  end
  return summary
end
local function startMode(mode,receiverId,sourceId)
  if ACQUISITION_BLOCKED then return false,ACQUISITION_REASON end
  if receiverId==nil and sourceId==nil then
    local selectedOK,a,b=pcall(function()
      local vehicles=M.listVehicles()
      assert(#vehicles==2,'Automatic pair selection needs exactly two cars; listVehicles() and supply both IDs explicitly')
      local current=be:getPlayerVehicleID(0)
      assert(current==vehicles[1].id or current==vehicles[2].id,'Enter one of the two cars first')
      return current,vehicles[1].id==current and vehicles[2].id or vehicles[1].id
    end)
    if not selectedOK then return false,tostring(a) end
    receiverId,sourceId=a,b
  end
  M.stop('Starting a fresh full-mesh CPU geometry control')
  return M.start(receiverId,sourceId,mode)
end
function M.startHitTest(receiverId,sourceId)return startMode('hit-test',receiverId,sourceId)end
function M.startImageTest(receiverId,sourceId)return startMode('image',receiverId,sourceId)end
function M.startNormalImageTest(receiverId,sourceId)return startMode('normal-image',receiverId,sourceId)end
function M.startReflectionMaskTest(receiverId,sourceId)return startMode('reflection-mask',receiverId,sourceId)end
function M.startCameraReflectionMaskTest(receiverId,sourceId)return startMode('camera-reflection-mask',receiverId,sourceId)end
function M.startMaterialReflectionTest(receiverId,sourceId)return startMode('camera-material',receiverId,sourceId)end
function M.startGpuReflectionProbe(receiverId,sourceId)return startMode('camera-gpu',receiverId,sourceId)end
function M.startGpuImageTest(receiverId,sourceId)return startMode('camera-gpu-image',receiverId,sourceId)end
function M.getImageStatus()
  local full=M.getStatus() -- applies the same live pose/prop/identity guards
  local out=full.vehicleRayImage
  if imageMode(captureMode) and phase=='pending' then out.phase='acquiring' end
  if phase=='stopped' then out.phase='cancelled';out.reason=reason end
  out.file=imagePath;out.uiSecondsRemaining=imageRemaining;out.uiReason=imageUIReason
  out.uiRequested=imageUIRequested
  out.journal=JOURNAL;out.cleanupUnverified=cleanupUnverified;out.journalFailed=journalFailed
  return out
end
function M.showImage(seconds)
  local status=M.getImageStatus()
  if status.phase~='complete' then return false,'Wait for the CPU image to complete: '..tostring(status.phase)end
  seconds=seconds or 120
  if not finite(seconds) or seconds<1 or seconds>120 then return false,'Image duration must be 1..120 seconds'end
  imageRemaining=seconds;imageUIRequested=true
  return true,'CPU geometry snapshot ('..tostring(status.profile)..'); not material-shaded reflections'
end
function M.getMaterialStatus()
  local image=M.getImageStatus() -- apply camera/vehicle guards first
  if image.profile~='camera-material' or image.phase~='complete' then
    return {phase=image.phase,reason='Complete a current material reflection test first',records={}}
  end
  return imageModule.materialStatus(imageJob)
end
function M.getOffscreenStatus()
  local s=M.getImageStatus()
  return {phase=s.phase,diagnosticRevision=16,profile=s.profile,
    offscreenGeometryControlsPassed=s.offscreenGeometryControlsPassed or false,
    wholeSourceOutsideFrustumVerified=s.wholeSourceOutsideFrustumVerified or false,
    offscreenSourceHitsA=s.offscreenSourceHitsA or 0,offscreenSourceHitsB=s.offscreenSourceHitsB or 0,
    sourceBounds=s.offscreenSourceBounds,primaryHitsA=s.hitsA,primaryHitsB=s.hitsB,
    cameraPrimaryMatched=s.cameraPrimaryMatched,reflectedReferenceMatched=s.reflectedReferenceMatched,
    sourceExcludedControlPassed=s.sourceExcludedControlPassed,
    offscreenReflectionTestPassed=false,materialShadingVerified=false,gpuExecutionVerified=false,
    scope='paused captured two-car geometry only; no shaded reflection acceptance'}
end
function M.getGpuStatus()
  local s=M.getImageStatus()
  local function copy(value)
    if type(value)~='table'then return value end
    local out={};for k,v in pairs(value)do out[k]=copy(v)end;return out
  end
  return {phase=s.phase,diagnosticRevision=16,profile=s.profile,gpu=copy(s.gpuProbe or lastGpuFailure or {phase='not started'}),
    cameraPrimaryMatched=s.cameraPrimaryMatched,reflectedReferenceMatched=s.reflectedReferenceMatched,
    offscreenGeometryControlsPassed=s.offscreenGeometryControlsPassed or false,
    sourceExcludedControlPassed=s.sourceExcludedControlPassed,cleanupUnverified=s.cleanupUnverified,
    reason=s.reason,file=s.file,gameIntegrationVerified=false,
    scope='isolated hardware ray comparison; CPU mask displayed; no live GPU reflection effect'}
end
function M.getGpuImageStatus()
  local s=M.getImageStatus()
  local function copy(v)if type(v)~='table'then return v end;local out={};for k,a in pairs(v)do out[k]=copy(a)end;return out end
  return {phase=s.phase,diagnosticRevision=16,profile=s.profile,gpu=copy(s.gpuImage or lastGpuImageFailure or {phase='not started'}),
    reason=s.reason,file=s.file,cleanupUnverified=s.cleanupUnverified,gameIntegrationVerified=false,
    scope='GPU-generated two-car hit image alongside CPU reference; material shading and native-frame composition pending'}
end
function M.hideImage()imageRemaining=0;imageUIRequested=false;imageFailure=nil;imageFailureRemaining=0;return true end
function M.getHitTestStatus()
  local full=M.getStatus()
  local status=full.vehicleHitTest -- already a detached copy
  status.reason=status.reason or full.reason
  status.diagnosticRevision=full.diagnosticRevision;status.cleanupUnverified=full.cleanupUnverified
  status.journal=full.journal;status.journalFailed=full.journalFailed
  for _,result in ipairs(status.results or {}) do
    result.origin=nil;result.target=nil
    if result.hit then
      result.hit.nativeIndex=nil;result.hit.primitive=nil;result.hit.triangleInPrimitive=nil
      result.hit.point=nil;result.hit.barycentric=nil
    end
  end
  return status
end
-- Small detached endpoint/hit report for a debug overlay. The same paused
-- identity/pose/prop guards still run; no material lists or CPU mesh arrays are
-- copied. Older live revision-8 instances can use getStatus() as a fallback.
function M.getHitPreviewState()
  if phase=='pending' or phase=='inspected' then
    local ok,err=pcall(validRows);if not ok then M.stop(tostring(err)) end
  end
  local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value)do out[k]=copy(v)end;return out
  end
  return {phase=phase,reason=reason,run=runId,diagnosticRevision=16,
    cleanupUnverified=cleanupUnverified,journalFailed=journalFailed,
    vehicleHitTest=copy(rayProbe.status(rayJob))}
end
function M.listVehicles()
  local result={}
  if not be then return result end
  for i=0,be:getObjectCount()-1 do
    local v=be:getObject(i)
    if v and v:getClassName()=='BeamNGVehicle' and geometry.checkTarget(v) then
      result[#result+1]={id=v:getID(),model=tostring(v:getJBeamFilename())}
    end
  end
  return result
end
function M.showAlignment(seconds)
  local ok,err=pcall(function()
    assert(phase=='inspected','Capture an inspected pair first')
    assert(debugDrawer and vec3 and ColorF,'Debug line drawing API unavailable')
    seconds=seconds or 90
    assert(finite(seconds) and seconds>=1 and seconds<=120,'Preview duration must be 1..120 seconds')
    validRows()
    for i,row in ipairs(rows) do
      assert(row.preview,'Alignment preview unavailable for '..row.id..': '..tostring(reports[i].previewReason))
    end
  end)
  if not ok then return false,tostring(err) end
  previewRemaining=seconds
  return true,'Sampled wireframe only: A cyan/yellow, B pink/orange. NOT reflections or alignment certification.'
end
function M.hideAlignment() previewRemaining=0;return true end
function M.onPreRender()
  if previewRemaining<=0 then return end
  local ok,err=pcall(function()
    validRows() -- validate ALL cars/props before issuing any drawing
    for i,row in ipairs(rows) do alignment.draw(row.preview,i) end
  end)
  if not ok then M.stop('Alignment preview stopped: '..tostring(err)) end
end
function M.onUpdate(dtReal)
  M.update(dtReal)
  if imageFailure and imageFailureRemaining>0 then
    if not finite(dtReal) or dtReal<0 then imageFailureRemaining=0;return end
    imageFailureRemaining=math.max(0,imageFailureRemaining-dtReal)
    local ok,err=pcall(imageModule.draw,imageFailure)
    if not ok then imageUIReason=tostring(err);imageFailureRemaining=0 end
    return
  end
  if previewRemaining>0 then
    if not finite(dtReal) or dtReal<0 then M.stop('Invalid alignment preview frame delta');return end
    previewRemaining=math.max(0,previewRemaining-dtReal)
  end
  if imageUIRequested and imageMode(captureMode) then
    if imageJob and imageJob.phase=='complete' then
      if not finite(dtReal) or dtReal<0 then imageRemaining=0;imageUIRequested=false;return end
      imageRemaining=math.max(0,imageRemaining-dtReal)
      if imageRemaining==0 then imageUIRequested=false;return end
    end
    local ok,err=pcall(imageModule.draw,imageJob)
    if not ok then imageUIReason=tostring(err);imageRemaining=0;imageUIRequested=false end
  end
end
function M.onVehicleResetted(id)
  for _,row in ipairs(rows) do if row.id==id then M.stop('Selected vehicle reset');return end end
end
function M.onVehicleDestroyed(id) M.onVehicleResetted(id) end
function M.onClientStartMission() M.stop('Mission changed') end
function M.onClientEndMission() M.stop('Mission ended') end
function M.onExtensionUnloaded() M.stop('Pair probe unloaded') end
return M
