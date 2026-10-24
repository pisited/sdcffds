-- Timed drawing of an already-completed CPU control. This extension never
-- requests meshes, starts rays, changes materials or reloads its owning probe.
local M={}
local owner,snapshot
local remaining,selection=0,'hits'
local reason='Not shown'
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function point(p)
  assert(type(p)=='table','Missing debug point')
  local out={p[1],p[2],p[3]}
  for i=1,3 do assert(finite(out[i]),'Nonfinite debug point')end
  return out
end
local function distance(a,b)
  local d=0;for i=1,3 do d=d+(a[i]-b[i])^2 end;return math.sqrt(d)
end
local function currentPair()
  return extensions and extensions.beamrt_vehiclePairProbe
end
local function state(pair)
  assert(simTimeAuthority and simTimeAuthority.getPause(),'Physics resumed; hit overlay stopped')
  assert(pair,'Load/run the two-car CPU test first')
  local getter=pair.getHitPreviewState or pair.getStatus
  assert(type(getter)=='function','Pair status API unavailable')
  local value=getter()
  assert(value.phase=='inspected','Pair snapshot is not current: '..tostring(value.reason))
  assert(not value.cleanupUnverified and not value.journalFailed,'Pair cleanup/journal unverified')
  assert(type(value.run)=='string' and value.run~='','Pair run identity unavailable')
  assert(value.vehicleHitTest and value.vehicleHitTest.phase=='complete','Wait for the CPU ray test to complete')
  assert(#value.vehicleHitTest.results==4,'Expected exactly four CPU controls')
  return value
end
local function build(value)
  local result={run=value.run,rays={}}
  for i,r in ipairs(value.vehicleHitTest.results)do
    local row={name=tostring(r.name),origin=point(r.origin),target=point(r.target),
      controlPassed=r.controlPassed==true,hit=r.geometricHit==true}
    local length=distance(row.origin,row.target)
    assert(finite(length) and length>.16 and length<=1000,'Invalid debug ray length')
    if row.hit then
      assert(r.hit,'Hit data missing')
      row.point=point(r.hit.point);row.vehicleId=r.hit.vehicleId
      row.meshName=tostring(r.hit.meshName);row.materialName=tostring(r.hit.materialName)
      row.distance=r.hit.distance
      assert(finite(row.distance) and row.distance>0 and row.distance<length,'Invalid hit distance')
      local projected={}
      for j=1,3 do projected[j]=row.origin[j]+(row.target[j]-row.origin[j])*row.distance/length end
      assert(distance(projected,row.point)<.001,'Hit point is not on its CPU ray')
    end
    result.rays[i]=row
  end
  return result
end
function M.hide(message)
  owner=nil;snapshot=nil;remaining=0;reason=message or 'Hidden'
  return true
end
function M.show(seconds,which)
  local pair=currentPair()
  local ok,value=pcall(function()
    seconds=seconds or 90;which=which or 'hits'
    assert(finite(seconds) and seconds>=1 and seconds<=120,'Overlay duration must be 1..120 seconds')
    assert(which=='hits' or which=='all' or (finite(which) and which%1==0 and which>=1 and which<=4),
      'Selection must be hits, all, or control number 1..4')
    assert(debugDrawer and type(debugDrawer.drawLine)=='function' and type(debugDrawer.drawSphere)=='function'
      and vec3 and ColorF,'Native debug drawing API unavailable')
    return build(state(pair))
  end)
  if not ok then return false,tostring(value)end
  owner=pair;snapshot=value;remaining=seconds;selection=which
  reason='CPU hit overlay only: cyan A-to-B, magenta B-to-A, yellow hit markers; not reflections'
  return true,reason
end
local function vector(p)return vec3(p[1],p[2],p[3])end
local palette={{.1,.9,1},{1,.2,.8},{.25,1,.35},{1,.65,.1}}
local function draw(row,index)
  local rgb=palette[index]
  if not row.controlPassed then rgb={1,.15,.1}end
  local color=ColorF(rgb[1],rgb[2],rgb[3],1)
  local dim=ColorF(rgb[1],rgb[2],rgb[3],.25)
  -- The fourth argument disables depth testing, as in BeamNG's installed
  -- vehicle-editor light debugger. These through-body markers are NOT evidence
  -- of opaque visibility. The endpoints are never offset to make them prettier.
  debugDrawer:drawLine(vector(row.origin),vector(row.target),dim,true)
  debugDrawer:drawSphere(vector(row.origin),.035,color,true)
  if row.hit then
    debugDrawer:drawLine(vector(row.origin),vector(row.point),color,true)
    local yellow=ColorF(1,1,.05,1)
    debugDrawer:drawSphere(vector(row.point),.08,yellow,true)
    for axis=1,3 do
      local a,b=point(row.point),point(row.point);a[axis]=a[axis]-.15;b[axis]=b[axis]+.15
      debugDrawer:drawLine(vector(a),vector(b),yellow,true)
    end
  else
    debugDrawer:drawLine(vector(row.origin),vector(row.target),color,true)
  end
end
function M.onPreRender()
  if remaining<=0 or not snapshot then return end
  local ok,err=pcall(function()
    assert(currentPair()==owner,'Pair controller reloaded/replaced; show a fresh result')
    local live=state(owner) -- all cars/props validated before ANY drawing
    assert(live.run==snapshot.run,'Pair run changed; show the new result explicitly')
    for i,row in ipairs(snapshot.rays)do
      if selection=='all' or (selection=='hits' and i<=2) or selection==i then draw(row,i)end
    end
  end)
  if not ok then M.hide('Hit overlay stopped: '..tostring(err))end
end
function M.onUpdate(dtReal)
  if remaining<=0 then return end
  if not finite(dtReal) or dtReal<0 then M.hide('Invalid overlay frame delta');return end
  remaining=math.max(0,remaining-dtReal)
  if remaining==0 then M.hide('Hit overlay expired')end
end
function M.getStatus()
  return {diagnosticRevision=1,enabled=remaining>0,secondsRemaining=remaining,selection=selection,
    reason=reason,run=snapshot and snapshot.run,rayCount=snapshot and #snapshot.rays or 0,
    throughBodyDebug=true,meshReadbacksRequested=0,startsCPUJobs=false,
    reflectionsEnabled=false,alignmentVerified=false,opaqueVisibilityVerified=false,
    legend={aToB='cyan',bToA='magenta',hit='yellow sphere and cross',missAbove='green',excludedB='orange',failedControl='red'}}
end
function M.onVehicleResetted()M.hide('Vehicle reset')end
function M.onVehicleDestroyed()M.hide('Vehicle removed')end
function M.onClientStartMission()M.hide('Mission changed')end
function M.onClientEndMission()M.hide('Mission ended')end
function M.onExtensionUnloaded()M.hide('Hit preview unloaded')end
return M
