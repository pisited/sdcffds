-- One ideal-mirror geometric bounce. Four panels, not material shading or a
-- gameplay-camera/off-screen reflection acceptance test. No native mesh calls.
local M={width=192,height=128,panelWidth=96,panelHeight=64}
local bvh=require('ge/extensions/beamrt/vehicleGeometryBVH')
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function cross(a,b)return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
local function unit(v)
  local length=math.sqrt(dot(v,v));assert(finite(length) and length>1e-6,'Degenerate reflection frame')
  return {v[1]/length,v[2]/length,v[3]/length}
end
function M.reflect(direction,normal)
  assert(math.abs(dot(direction,direction)-1)<1e-6 and math.abs(dot(normal,normal)-1)<1e-6,'Unit reflection inputs required')
  local d=dot(direction,normal)
  return unit({direction[1]-2*d*normal[1],direction[2]-2*d*normal[2],direction[3]-2*d*normal[3]})
end
function M.cast(db,hit,primaryOrigin,primaryDirection,far,sourceId,work,stats)
  local reflected=M.reflect(primaryDirection,hit.normal)
  local point,start={},{}
  for j=1,3 do
    point[j]=primaryOrigin[j]+primaryDirection[j]*hit.distance
    start[j]=point[j]+reflected[j]*.01
  end
  -- Keep the receiver in BOTH secondary scenes: an actual self-hit must be
  -- reported, not silently removed to manufacture an inter-car hit.
  local full=bvh.trace(db,start,reflected,far,nil,work,stats)
  local excluded=bvh.trace(db,start,reflected,far,sourceId,work,stats)
  assert(not excluded or excluded.vehicleId~=sourceId,'Source-excluded control returned the excluded source')
  return {origin=start,direction=reflected,far=far,full=full,excluded=excluded,sourceId=sourceId}
end
local function frame(db,poses,car)
  local a,b=poses[1].center,poses[2].center
  local towardB=unit({b[1]-a[1],b[2]-a[2],0})
  local direction=car==1 and {-towardB[1],-towardB[2],0} or towardB
  local right=unit(cross(direction,{0,0,1}));local up=cross(right,direction)
  local bounds=db.carBounds[car]
  local lo,hi={math.huge,math.huge,math.huge},{-math.huge,-math.huge,-math.huge}
  for mask=0,7 do
    local p={};for j=1,3 do p[j]=math.floor(mask/2^(j-1))%2==0 and bounds.lo[j] or bounds.hi[j]end
    local projected={dot(p,right),dot(p,up),dot(p,direction)}
    for j=1,3 do lo[j]=math.min(lo[j],projected[j]);hi[j]=math.max(hi[j],projected[j])end
  end
  local height=math.max((hi[2]-lo[2])*1.08,(hi[1]-lo[1])*1.08*M.panelHeight/M.panelWidth,.1)
  local width=height*M.panelWidth/M.panelHeight
  return {direction=direction,right=right,up=up,near=lo[3]-.35,far=hi[3]-lo[3]+.7,
    x=(lo[1]+hi[1])*.5,y=(lo[2]+hi[2])*.5,width=width,height=height}
end
local function origin(f,x,y)
  local a=f.x+((x+.5)/M.panelWidth-.5)*f.width
  local b=f.y+(.5-(y+.5)/M.panelHeight)*f.height
  local result={};for j=1,3 do result[j]=f.right[j]*a+f.up[j]*b+f.direction[j]*f.near end
  return result
end
local function color(hit,receiverId,sourceId)
  if not hit then return {58,68,82},'miss'end
  if hit.vehicleId==sourceId then return {45,240,100},'other'end
  assert(hit.vehicleId==receiverId,'Unexpected secondary vehicle')
  return {255,145,35},'self'
end
local function same(actual,expected)
  assert((actual~=nil)==(expected~=nil),'Reflected BVH/reference hit-miss mismatch')
  if actual then
    assert(actual.vehicleId==expected.vehicleId and actual.reference==expected.reference
      and math.abs(actual.distance-expected.distance)<1e-5,'Reflected BVH/reference nearest primitive mismatch')
  end
end
M.classify=color
M.compareReference=same
function M.render(db,poses,ids,work,job)
  local stats={primarySamples=0,secondaryRays=0,sourceExcludedRays=0,otherHitsA=0,otherHitsB=0,
    selfHits=0,reflectedMisses=0,excludedSelfHits=0,excludedMisses=0,changedPixels=0,
    reflectedReferenceSamples=0,bounceReferenceTriangleTests=0,reflectedReferenceMatched=false,
    sourceExcludedControlPassed=false,oneBounceGeometricControlsPassed=false}
  job.bounce=stats
  local diagonal=0;for j=1,3 do diagonal=diagonal+(db.bounds[j+2]-db.bounds[j-1])^2 end
  local far=math.sqrt(diagonal)+2
  assert(finite(far) and far>.16 and far<=1000,'Reflected segment out of supported range')
  stats.bounceMaxDistance=far
  local samples={};local generic={0,0};local positive={0,0}
  local frames={frame(db,poses,1),frame(db,poses,2)};job.frames=frames
  for car=1,2 do
    local f=frames[car];local receiverId,sourceId=ids[car],ids[3-car]
    for y=0,M.panelHeight-1 do for x=0,M.panelWidth-1 do
      local start=origin(f,x,y)
      -- Receiver-isolated primary view is a deliberate diagnostic setup. It
      -- does NOT assert that a real gameplay camera sees this receiver.
      local hit=bvh.trace(db,start,f.direction,f.far,sourceId,work,job.trace)
      local fullPixel,excludedPixel={12,16,23},{12,16,23}
      stats.primarySamples=stats.primarySamples+1
      if hit then
        assert(hit.vehicleId==receiverId,'Primary ray did not hit its isolated receiver')
        job.hits[car]=job.hits[car]+1
        if hit.frontFacing then job.frontFacePixels=job.frontFacePixels+1 else job.backFacePixels=job.backFacePixels+1 end
        local cast=M.cast(db,hit,start,f.direction,far,sourceId,work,job.trace)
        local kind,excludedKind
        fullPixel,kind=color(cast.full,receiverId,sourceId)
        excludedPixel,excludedKind=color(cast.excluded,receiverId,sourceId)
        fullPixel.vehicleId=receiverId;excludedPixel.vehicleId=receiverId
        fullPixel.reflectedVehicleId=cast.full and cast.full.vehicleId
        excludedPixel.reflectedVehicleId=cast.excluded and cast.excluded.vehicleId
        stats.secondaryRays=stats.secondaryRays+1;stats.sourceExcludedRays=stats.sourceExcludedRays+1
        if kind=='other' then
          local key=car==1 and 'otherHitsA' or 'otherHitsB';stats[key]=stats[key]+1
          assert(excludedKind~='other','Source exclusion failed to remove a reflected source hit')
          stats.changedPixels=stats.changedPixels+1
        elseif kind=='self'then stats.selfHits=stats.selfHits+1 else stats.reflectedMisses=stats.reflectedMisses+1 end
        if excludedKind=='self'then stats.excludedSelfHits=stats.excludedSelfHits+1 else stats.excludedMisses=stats.excludedMisses+1 end
        -- Bounded full-scan checks: up to two generic and two positive bounces
        -- per receiver, including source-excluded versions. At most 8 packets.
        if generic[car]<2 then generic[car]=generic[car]+1;samples[#samples+1]=cast
        elseif kind=='other' and positive[car]<2 then positive[car]=positive[car]+1;samples[#samples+1]=cast end
      end
      local column=(car-1)*M.panelWidth+x
      job.pixels[y*M.width+column+1]=fullPixel
      job.pixels[(y+M.panelHeight)*M.width+column+1]=excludedPixel
      job.pixelsRendered=job.pixelsRendered+2
      work()
    end end
  end
  job.phase='checking-bounces'
  local reference={triangleTests=0}
  local function referenceWork()
    stats.bounceReferenceTriangleTests=reference.triangleTests;work()
  end
  for _,cast in ipairs(samples)do
    same(cast.full,bvh.traceReference(db,cast.origin,cast.direction,cast.far,nil,referenceWork,reference))
    same(cast.excluded,bvh.traceReference(db,cast.origin,cast.direction,cast.far,cast.sourceId,referenceWork,reference))
    stats.reflectedReferenceSamples=stats.reflectedReferenceSamples+1
    stats.bounceReferenceTriangleTests=reference.triangleTests
  end
  stats.reflectedReferenceMatched=#samples>0
  local other=stats.otherHitsA+stats.otherHitsB
  stats.sourceExcludedControlPassed=other>0 and stats.changedPixels==other
  stats.oneBounceGeometricControlsPassed=stats.otherHitsA>0 and stats.otherHitsB>0
    and stats.sourceExcludedControlPassed and stats.reflectedReferenceMatched
end
return M
