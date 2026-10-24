-- Frozen main-camera perspective rays. BOTH cars participate in primary and
-- full secondary visibility. No buildings/terrain/alpha or material shading.
local M={}
local camera=require('ge/extensions/beamrt/vehicleCameraSnapshot')
local bvh=require('ge/extensions/beamrt/vehicleGeometryBVH')
local bounce=require('ge/extensions/beamrt/vehicleReflectionMask')
local offscreen=require('ge/extensions/beamrt/vehicleOffscreenGeometry')
function M.render(db,ids,snapshot,work,job,gpuEndpoint)
  assert(snapshot.projectionValidated and snapshot.nativeRayChecks==9,'Native camera projection was not validated')
  local width,height=snapshot.sampleWidth,snapshot.sampleHeight
  local surface=job.profile=='camera-material'
  local gpuImage=job.profile=='camera-gpu-image' and require('ge/extensions/beamrt/vehicleGpuImage')
  local materials=surface and require('ge/extensions/beamrt/vehicleMaterialSnapshot')
  assert(width==128 and height>=32 and height<=96 and job.width==width*((surface or gpuImage) and 2 or 1) and job.height==height*2,'Camera sample budget mismatch')
  if gpuImage then job.gpuImageExpected=gpuImage.expected(width*height)end
  local stats={primarySamples=0,secondaryRays=0,sourceExcludedRays=0,otherHitsA=0,otherHitsB=0,
    selfHits=0,reflectedMisses=0,excludedSelfHits=0,excludedMisses=0,changedPixels=0,
    reflectedReferenceSamples=0,bounceReferenceTriangleTests=0,reflectedReferenceMatched=false,
    sourceExcludedControlPassed=false,oneBounceGeometricControlsPassed=false,bothDirectionsRequired=false,
    cameraPrimarySamplesChecked=0,cameraPrimaryReferenceTests=0,cameraPrimaryMatched=false,
    cameraBounceGeometricControlsPassed=false,reflectedHitPointsOutsideFrustum=0,
    wholeSourceOutsideFrustumVerified=false,offscreenGeometryControlsPassed=false,
    offscreenSourceHitsA=0,offscreenSourceHitsB=0,offscreenGeometryTestRevision=1,
    offscreenSourceBounds=offscreen.capture(db,ids,snapshot)}
  job.bounce=stats
  if surface then
    assert(job.materialSnapshot,'Detached material snapshot required')
    stats.reflectedFactorPixels=0;stats.excludedFactorPixels=0
    stats.reflectedUnknownMaterialPixels=0;stats.excludedUnknownMaterialPixels=0
    stats.materialControlIdenticalSelfPixels=0
  end
  local diagonal=0;for j=1,3 do diagonal=diagonal+(db.bounds[j+2]-db.bounds[j-1])^2 end
  local far=math.sqrt(diagonal)+2;assert(far>.16 and far<=1000,'Reflected segment out of supported range')
  stats.bounceMaxDistance=far
  local primaries,samples={},{}
  local generic,positive={0,0},{0,0}
  for y=0,height-1 do for x=0,width-1 do
    local start,direction,primaryFar=camera.ray(snapshot,(x+.5)/width,(y+.5)/height)
    local hit=bvh.trace(db,start,direction,primaryFar,nil,work,job.trace)
    local fullPixel,excludedPixel={12,16,23},{12,16,23}
    local fullSurface,excludedSurface={12,16,23},{12,16,23}
    local secondaryFull,secondaryExcluded
    stats.primarySamples=stats.primarySamples+1
    if hit then
      local car=hit.carIndex;local receiverId,sourceId=ids[car],ids[3-car]
      assert(hit.vehicleId==receiverId,'Unexpected camera primary owner')
      job.hits[car]=job.hits[car]+1
      if hit.frontFacing then job.frontFacePixels=job.frontFacePixels+1 else job.backFacePixels=job.backFacePixels+1 end
      local cast=bounce.cast(db,hit,start,direction,far,sourceId,work,job.trace)
      secondaryFull,secondaryExcluded=cast.full,cast.excluded
      if surface then
        local fullKind,excludedKind
        fullSurface,fullKind=materials.pixel(job.materialSnapshot,cast.full)
        excludedSurface,excludedKind=materials.pixel(job.materialSnapshot,cast.excluded)
        if fullKind=='factor' then stats.reflectedFactorPixels=stats.reflectedFactorPixels+1
        elseif fullKind=='unknown' then stats.reflectedUnknownMaterialPixels=stats.reflectedUnknownMaterialPixels+1 end
        if excludedKind=='factor' then stats.excludedFactorPixels=stats.excludedFactorPixels+1
        elseif excludedKind=='unknown' then stats.excludedUnknownMaterialPixels=stats.excludedUnknownMaterialPixels+1 end
        if cast.full and cast.full.vehicleId==receiverId then
          assert(cast.excluded and cast.full.reference==cast.excluded.reference,'Material control changed a retained self hit')
          for j=1,3 do assert(fullSurface[j]==excludedSurface[j],'Material control changed self-hit appearance')end
          stats.materialControlIdenticalSelfPixels=stats.materialControlIdenticalSelfPixels+1
        end
        fullSurface.reflectedMaterialName=cast.full and cast.full.materialName
        excludedSurface.reflectedMaterialName=cast.excluded and cast.excluded.materialName
      end
      local kind,excludedKind
      fullPixel,kind=bounce.classify(cast.full,receiverId,sourceId)
      excludedPixel,excludedKind=bounce.classify(cast.excluded,receiverId,sourceId)
      fullPixel.vehicleId=receiverId;excludedPixel.vehicleId=receiverId
      fullPixel.reflectedVehicleId=cast.full and cast.full.vehicleId
      excludedPixel.reflectedVehicleId=cast.excluded and cast.excluded.vehicleId
      stats.secondaryRays=stats.secondaryRays+1;stats.sourceExcludedRays=stats.sourceExcludedRays+1
      if kind=='other' then
        local key=car==1 and 'otherHitsA' or 'otherHitsB';stats[key]=stats[key]+1
        assert(excludedKind~='other','Source exclusion failed')
        stats.changedPixels=stats.changedPixels+1
        local p={};for j=1,3 do p[j]=cast.origin[j]+cast.direction[j]*cast.full.distance end
        local _,_,inside=camera.project(snapshot,p)
        if not inside then stats.reflectedHitPointsOutsideFrustum=stats.reflectedHitPointsOutsideFrustum+1 end
        if stats.offscreenSourceBounds[3-car].outside then
          assert(not inside,'Certified offscreen geometry produced an inside-frustum hit point')
          local offscreenKey=car==1 and 'offscreenSourceHitsA' or 'offscreenSourceHitsB'
          stats[offscreenKey]=stats[offscreenKey]+1
        end
      elseif kind=='self'then stats.selfHits=stats.selfHits+1 else stats.reflectedMisses=stats.reflectedMisses+1 end
      if excludedKind=='self'then stats.excludedSelfHits=stats.excludedSelfHits+1 else stats.excludedMisses=stats.excludedMisses+1 end
      if generic[car]<2 then
        generic[car]=generic[car]+1;samples[#samples+1]=cast
        primaries[#primaries+1]={origin=start,direction=direction,far=primaryFar,expected=hit}
      elseif kind=='other' and positive[car]<2 then positive[car]=positive[car]+1;samples[#samples+1]=cast end
    end
    job.pixels[y*job.width+x+1]=fullPixel
    job.pixels[(y+height)*job.width+x+1]=excludedPixel
    if surface then
      job.pixels[y*job.width+x+width+1]=fullSurface
      job.pixels[(y+height)*job.width+x+width+1]=excludedSurface
    end
    if gpuImage then gpuImage.record(job.gpuImageExpected,y*width+x,hit,secondaryFull,secondaryExcluded,ids)end
    job.pixelsRendered=job.pixelsRendered+(surface and 4 or 2);work()
  end end
  job.phase='checking-camera-primaries'
  local primaryReference={triangleTests=0}
  local function primaryWork()stats.cameraPrimaryReferenceTests=primaryReference.triangleTests;work()end
  for _,ray in ipairs(primaries)do
    bounce.compareReference(ray.expected,bvh.traceReference(db,ray.origin,ray.direction,ray.far,nil,primaryWork,primaryReference))
    stats.cameraPrimarySamplesChecked=stats.cameraPrimarySamplesChecked+1
  end
  stats.cameraPrimaryMatched=#primaries>0
  job.phase='checking-bounces'
  local reference={triangleTests=0}
  local function referenceWork()stats.bounceReferenceTriangleTests=reference.triangleTests;work()end
  for _,cast in ipairs(samples)do
    bounce.compareReference(cast.full,bvh.traceReference(db,cast.origin,cast.direction,cast.far,nil,referenceWork,reference))
    bounce.compareReference(cast.excluded,bvh.traceReference(db,cast.origin,cast.direction,cast.far,cast.sourceId,referenceWork,reference))
    stats.reflectedReferenceSamples=stats.reflectedReferenceSamples+1
  end
  stats.reflectedReferenceMatched=#samples>0
  local total=stats.otherHitsA+stats.otherHitsB
  stats.sourceExcludedControlPassed=total>0 and stats.changedPixels==total
  stats.cameraBounceGeometricControlsPassed=stats.sourceExcludedControlPassed and stats.reflectedReferenceMatched and stats.cameraPrimaryMatched
  stats.oneBounceGeometricControlsPassed=stats.cameraBounceGeometricControlsPassed
  for car=1,2 do
    assert(not stats.offscreenSourceBounds[car].outside or job.hits[car]==0,
      'Certified offscreen geometry unexpectedly received camera primary hits')
  end
  stats.wholeSourceOutsideFrustumVerified=stats.offscreenSourceHitsA+stats.offscreenSourceHitsB>0
  stats.offscreenGeometryControlsPassed=stats.wholeSourceOutsideFrustumVerified
    and stats.cameraBounceGeometricControlsPassed and job.acceleratorMatchesReference
  if job.profile=='camera-gpu' then
    require('ge/extensions/beamrt/vehicleGpuProbe').run(db,ids,snapshot,samples,job.controls,work,job,gpuEndpoint)
  end
  if gpuImage then gpuImage.run(db,ids,snapshot,work,job,gpuEndpoint)end
end
return M
