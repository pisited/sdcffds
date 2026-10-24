-- Incremental, full primitive-reference CPU controls. No BVH/GPU/rendering.
local M={testsPerUpdate=8192}
local intersect=require('ge/extensions/beamrt/geometryTriangleIntersection').segment
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function vector(v)
  local a={v[1],v[2],v[3]};for i=1,3 do assert(finite(a[i]),'Invalid ray coordinate') end;return a
end
local function segment(name,start,finish,expected,exclude)
  local a,b=vector(start),vector(finish);local d={};local length=0
  for i=1,3 do d[i]=b[i]-a[i];length=length+d[i]^2 end;length=math.sqrt(length)
  assert(length>.16 and length<=1000,'Invalid diagnostic segment length')
  for i=1,3 do d[i]=d[i]/length end
  return {name=name,origin=a,target=b,direction=d,length=length,expectedVehicleId=expected,
    excludedVehicleId=exclude,nearest=nil,tests=0}
end
local function support(pose,direction)
  local radius=0
  for i=1,3 do
    local dot=0;for j=1,3 do dot=dot+direction[j]*pose.axes[i][j] end
    radius=radius+math.abs(dot)*pose.half[i]
  end
  return radius
end
function M.prepare(record,preview,id)
  assert(preview and preview.sampledOnly and not preview.alignmentVerified,'Candidate preview transforms required')
  local scene={id=id,ranges={},triangles=0,origin=vector(preview.origin)}
  local props={};for _,p in ipairs(preview.props) do props[p.nativeIndex]=p.columns end
  local function ranges(meshes,kind)
    for _,mesh in ipairs(meshes) do
      local basis=kind=='prop' and assert(props[mesh.nativeIndex],'Full prop transform missing') or nil
      for pi,p in ipairs(mesh.primitives) do
        if p.indexCount>0 then
          scene.ranges[#scene.ranges+1]={kind=kind,buffers=mesh.buffers or record.buffers,basis=basis,
            first=p.firstIndex,count=p.indexCount,meshName=mesh.meshName,nativeIndex=mesh.nativeIndex,
            primitive=pi,materialName=p.materialName}
          scene.triangles=scene.triangles+p.indexCount/3
        end
      end
    end
  end
  ranges(record.flexmeshes,'flex');ranges(record.propmeshes,'prop')
  assert(scene.triangles>0 and scene.triangles<=500000,'Full vehicle triangle-reference budget exceeded')
  return scene
end
function M.create(scenes,poses)
  assert(#scenes==2 and #poses==2 and scenes[1].id~=scenes[2].id,'Two distinct captured vehicles required')
  local a,b=poses[1].center,poses[2].center;local d={};local length=0
  for i=1,3 do d[i]=b[i]-a[i];length=length+d[i]^2 end;length=math.sqrt(length)
  assert(length>.16 and length<500,'Vehicle separation out of range')
  for i=1,3 do d[i]=d[i]/length end
  local ra,rb=support(poses[1],d),support(poses[2],d)
  assert(length>ra+rb+.7,'Park the cars farther apart for outside-body ray origins')
  local startA,endB,startB,endA={},{},{},{}
  for i=1,3 do
    startA[i]=a[i]+d[i]*(ra+.35);endB[i]=b[i]+d[i]*(rb+.35)
    startB[i]=b[i]-d[i]*(rb+.35);endA[i]=a[i]-d[i]*(ra+.35)
  end
  local high=-math.huge
  for _,pose in ipairs(poses) do high=math.max(high,pose.center[3]+pose.half[1]+pose.half[2]+pose.half[3]+10) end
  local rays={segment('A to B',startA,endB,scenes[2].id),segment('B to A',startB,endA,scenes[1].id),
    segment('above both cars',{a[1],a[2],high},{a[1],a[2],high+10}),
    segment('A to B with B excluded',startA,endB,nil,scenes[2].id)}
  local total=0
  for _,ray in ipairs(rays) do for _,scene in ipairs(scenes) do
    if scene.id~=ray.excludedVehicleId then total=total+scene.triangles end
  end end
  return {scenes=scenes,rays=rays,rayIndex=1,sceneIndex=1,rangeIndex=1,offset=0,tests=0,total=total,
    elapsed=0,phase='running',results={},scratch={a={},b={},c={}}}
end
local function vertex(out,buffers,index,basis,origin)
  local vi=tonumber(buffers.indices[index]);local p=vi*3
  local x=tonumber(buffers.vertices[p]);local y=-tonumber(buffers.vertices[p+2]);local z=tonumber(buffers.vertices[p+1])
  if basis then
    for i=1,3 do out[i]=basis[1][i]*x+basis[2][i]*y+basis[3][i]*z+basis[4][i]+origin[i] end
  else out[1]=x+origin[1];out[2]=y+origin[2];out[3]=z+origin[3] end
end
-- Shared CPU point conversion for the BVH diagnostic; no native method calls.
M.vertexWorld=vertex
local function finishRay(job,ray)
  local hit=ray.nearest
  local result={name=ray.name,origin=ray.origin,target=ray.target,excludedVehicleId=ray.excludedVehicleId,
    expectedVehicleId=ray.expectedVehicleId,geometricHit=hit~=nil,hit=hit,trianglesTested=ray.tests,
    controlPassed=ray.expectedVehicleId and hit~=nil and hit.vehicleId==ray.expectedVehicleId
      or ray.expectedVehicleId==nil and hit==nil,alphaDecision='unknown; geometry only'}
  job.results[#job.results+1]=result
  job.rayIndex=job.rayIndex+1;job.sceneIndex=1;job.rangeIndex=1;job.offset=0
end
function M.advance(job,dt,limit)
  if job.phase~='running' then return end
  assert(finite(dt) and dt>=0,'Invalid ray-test frame delta')
  job.elapsed=job.elapsed+dt;assert(job.elapsed<60,'CPU ray test timed out')
  limit=limit or M.testsPerUpdate
  assert(finite(limit) and limit>=1 and limit%1==0 and limit<=M.testsPerUpdate,'Invalid CPU triangle step budget')
  local tested=0
  while tested<limit and job.rayIndex<=#job.rays do
    local ray=job.rays[job.rayIndex];local scene=job.scenes[job.sceneIndex]
    if not scene then finishRay(job,ray)
    elseif scene.id==ray.excludedVehicleId or not scene.ranges[job.rangeIndex] then
      job.sceneIndex=job.sceneIndex+1;job.rangeIndex=1;job.offset=0
    else
      local range=scene.ranges[job.rangeIndex]
      local first=range.first+job.offset;local tri=job.scratch
      vertex(tri.a,range.buffers,first,range.basis,scene.origin)
      vertex(tri.b,range.buffers,first+1,range.basis,scene.origin)
      vertex(tri.c,range.buffers,first+2,range.basis,scene.origin)
      local distance,u,v=intersect(ray.origin,ray.direction,ray.length,tri)
      if distance and (not ray.nearest or distance<ray.nearest.distance) then
        local point={};for i=1,3 do point[i]=ray.origin[i]+ray.direction[i]*distance end
        ray.nearest={vehicleId=scene.id,kind=range.kind,meshName=range.meshName,nativeIndex=range.nativeIndex,
          primitive=range.primitive,triangleInPrimitive=job.offset/3,materialName=range.materialName,
          distance=distance,point=point,barycentric={1-u-v,u,v},alphaMode='unknown'}
      end
      tested=tested+1;job.tests=job.tests+1;ray.tests=ray.tests+1;job.offset=job.offset+3
      if job.offset>=range.count then job.rangeIndex=job.rangeIndex+1;job.offset=0 end
    end
  end
  if job.rayIndex>#job.rays then
    assert(job.tests==job.total,'CPU test did not visit every primitive reference')
    job.phase='complete';job.scenes=nil;job.scratch=nil -- retire all retained native CPU buffers
  end
end
function M.status(job)
  if not job then return {phase='idle',cpuReferenceOnly=true,offscreenReflectionTestPassed=false} end
  local passed=job.phase=='complete'
  for _,r in ipairs(job.results) do if not r.controlPassed then passed=false end end
  return {phase=job.phase,trianglesTested=job.tests,totalTriangleTests=job.total,results=job.results,
    geometricControlsPassed=passed,cpuReferenceOnly=true,fullPrimitiveReferences=true,screenInputsUsed=false,
    alphaTexturesSampled=false,opaqueVisibilityVerified=false,sceneComplete=false,gpuExecutionVerified=false,
    offscreenReflectionTestPassed=false,materialShadingVerified=false}
end
return M
