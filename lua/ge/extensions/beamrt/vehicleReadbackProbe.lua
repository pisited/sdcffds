-- Opt-in single-car native acquisition experiment, not a reflection test.
-- No auto-start, camera/physics/vehicle edits, drawing or renderer integration.
local M={}
local provider=require('ge/extensions/beamrt/providers/vehicleProvider')
local geometry=require('ge/extensions/beamrt/glassGeometry') -- pose/target checks only
local JOURNAL='/settings/beamrtVehicleReadbackStages.jsonl'
local phase,reason='idle','Not started'
local row,report,lastStage
local elapsed,sequence,runNumber=0,0,0
local runId=''
local cleanupUnverified,journalFailed=false,false

local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function member(o,key)local v=o[key];if type(v)=='function'then return v(o)end;return v end
local function mark(stage)
  sequence=sequence+1
  lastStage={scope=tostring(stage.scope):sub(1,192),operation=tostring(stage.operation):sub(1,80),
    boundary=stage.boundary,sequence=sequence}
  local entry={schema='beamrt.vehicle-readback-stage.v1',run=runId,vehicleId=row and row.id,
    scope=lastStage.scope,operation=lastStage.operation,boundary=lastStage.boundary,sequence=sequence}
  local ok,err=pcall(function()
    -- Append, flush and close each small record before the next native call.
    -- This is not a disk durability / power-loss guarantee.
    local f,why=io.open(JOURNAL,'a');assert(f,why or 'Cannot open stage journal')
    local wrote,writeError=pcall(function()assert(f:write(jsonEncode(entry)..'\n'));assert(f:flush())end)
    local closed,closeError=f:close()
    assert(wrote,writeError);assert(closed,closeError or 'Stage journal close failed')
  end)
  if not ok then journalFailed=true;error('Stage journal failed: '..tostring(err))end
end
local function ownerMark(operation,boundary)mark({scope='owner',operation=operation,boundary=boundary})end
local function release()
  if not row then return end
  if row.record and provider.get(row.id)==row.record then provider.invalidate(row.id)end
  row.record=nil
  if row.mesh and not row.freeAttempted then
    row.freeAttempted=true -- an uncertain native free must NEVER be retried
    local marked,why=pcall(ownerMark,'free','before')
    if not marked then reason=reason..'; '..tostring(why)end
    local ok,result=pcall(function()return row.mesh:free()end)
    if not ok or result==false then
      cleanupUnverified=true;reason=reason..'; native free outcome unverified; restart BeamNG before retry'
      return
    end
    row.mesh=nil
    pcall(ownerMark,'free','after')
  end
end
function M.stop(message)
  phase='stopped';reason=message or 'Stopped'
  release();row=nil;report=nil
  return not cleanupUnverified and not journalFailed,reason
end
local function names(vehicle)
  local source=vehicle:getMeshMaterialNames();assert(type(source)=='table','Material names unavailable')
  local result={};for i,name in ipairs(source)do assert(type(name)=='string','Invalid material identity');result[i]=name end
  return result
end
local function valid()
  assert(simTimeAuthority and simTimeAuthority.getPause(),'Physics resumed; acquisition stopped')
  assert(be:getObjectByID(row.id)==row.vehicle,'Vehicle removed/replaced')
  assert(geometry.samePose(row.pose,geometry.pose(row.vehicle)),'Vehicle pose changed')
  local now=names(row.vehicle);assert(#now==#row.names,'Material identities changed')
  for i,name in ipairs(now)do assert(name==row.names[i],'Material identities changed')end
end
function M.start(vehicleId)
  if phase=='pending' then return false,'A single-car readback is already pending'end
  if cleanupUnverified or journalFailed then return false,'Cleanup/journal unverified; restart BeamNG before retry'end
  local ok,err=pcall(function()
    assert(provider.diagnosticStageVersion==1,'Stale provider loaded; restart BeamNG to load the instrumented provider')
    if vehicleId==nil then vehicleId=be:getPlayerVehicleID(0)end
    assert(finite(vehicleId) and vehicleId>0 and vehicleId%1==0 and vehicleId<=2147483647,'Invalid vehicle ID')
    assert(simTimeAuthority and simTimeAuthority.getPause(),'Park the car and pause physics with J first')
    local vehicle=assert(be:getObjectByID(vehicleId),'Vehicle unavailable')
    assert(vehicle:getClassName()=='BeamNGVehicle','Target is not a BeamNG vehicle')
    local target,why=geometry.checkTarget(vehicle);assert(target,why)
    assert(not provider.get(vehicleId),'A snapshot already exists; stop its owning diagnostic first')
    assert(GPUMesh and type(GPUMesh.bng_getGPUMesh)=='function','Native GPUMesh API unavailable')
    row={id=vehicleId,vehicle=vehicle,pose=geometry.pose(vehicle),names=names(vehicle)}
    report=nil;elapsed=0;sequence=0;runNumber=runNumber+1
    runId=os.date('!%Y%m%dT%H%M%SZ')..'-'..runNumber
    phase='pending';reason='Waiting for one native mesh readback; keep physics paused'
    ownerMark('request','before')
    row.mesh=assert(GPUMesh.bng_getGPUMesh(vehicleId),'Native readback request returned no handle')
    ownerMark('request','after')
  end)
  if not ok then
    -- Bad preflight must not discard an existing completed result.
    if row then M.stop(tostring(err))else reason=tostring(err)end
    return false,tostring(err)
  end
  return true,reason
end
local function inspect(record)
  local result={id=record.id,captureProfile=record.captureProfile,cpuBufferBytes=record.cpuAllocationBytes,
    flexMeshes=#record.flexmeshes,propMeshes=#record.propmeshes,flexTriangles=0,propTriangles=0,
    verticesChecked=0,indicesChecked=0,vertexColorsCaptured=false,coordinateFrameVerified=false}
  local function buffers(counts,data)
    for i=0,counts.vertices*3-1 do assert(finite(tonumber(data.vertices[i])),'Nonfinite native position')end
    for i=0,counts.indices-1 do
      local index=tonumber(data.indices[i]);assert(index>=0 and index<counts.vertices,'Native vertex index out of bounds')
    end
    result.verticesChecked=result.verticesChecked+counts.vertices
    result.indicesChecked=result.indicesChecked+counts.indices
  end
  buffers(record.counts,record.buffers)
  for _,mesh in ipairs(record.flexmeshes)do
    for _,primitive in ipairs(mesh.primitives)do result.flexTriangles=result.flexTriangles+primitive.indexCount/3 end
  end
  for _,mesh in ipairs(record.propmeshes)do
    buffers(mesh.counts,mesh.buffers)
    for _,primitive in ipairs(mesh.primitives)do result.propTriangles=result.propTriangles+primitive.indexCount/3 end
  end
  return result
end
function M.update(dtReal)
  if phase~='pending' then return end
  local ok,err=pcall(function()
    assert(finite(dtReal) and dtReal>=0,'Invalid real frame delta')
    elapsed=elapsed+dtReal;valid()
    assert(elapsed<10,'Native readback readiness timed out')
    ownerMark('dataIsReady','before')
    local ready=member(row.mesh,'dataIsReady')
    ownerMark('dataIsReady','after')
    if ready~=true and ready~=1 then return end
    ownerMark('captureGeometry','before')
    local record,why=provider.capture(row.id,row.mesh,'geometry',mark)
    assert(record,why);row.record=record
    ownerMark('captureGeometry','after')
    valid()
    ownerMark('validateCPU','before');local result=inspect(record);ownerMark('validateCPU','after')
    reason='Geometry-only single-car copy and CPU range checks completed; not a ray/reflection test'
    release()
    assert(not cleanupUnverified and not journalFailed,'Native cleanup or stage journal failed')
    ownerMark('complete','after')
    report=result;row=nil;phase='complete'
  end)
  if not ok then M.stop(tostring(err))end
end
function M.getStatus()
  local result={phase=phase,reason=reason,journal=JOURNAL,run=runId,sequence=sequence,
    cleanupUnverified=cleanupUnverified,journalFailed=journalFailed,feedsRayTracer=false,
    reflectionsEnabled=false,offscreenTestPassed=false,profile='geometry',diagnosticRevision=1}
  if lastStage then result.lastStage={};for key,value in pairs(lastStage)do result.lastStage[key]=value end end
  if report then result.summary={};for key,value in pairs(report)do result.summary[key]=value end end
  return result
end
M.onUpdate=M.update
function M.onVehicleResetted(id)if row and row.id==id then M.stop('Selected vehicle reset')end end
M.onVehicleDestroyed=M.onVehicleResetted
function M.onClientStartMission()if row then M.stop('Mission changed')end end
function M.onClientEndMission()if row then M.stop('Mission ended')end end
function M.onExtensionUnloaded()if row then M.stop('Single-car probe unloaded')end end
return M
