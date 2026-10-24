-- Frozen primary/reflected ray generation and BVH traversal happen on the GPU.
-- CPU expected records remain local and are NEVER included in the wire payload.
local M={endpoint='/settings/beamrtGpuImageEndpoint.json'}
local ffi=require('ffi')
local probe=require('ge/extensions/beamrt/vehicleGpuProbe')
if not pcall(ffi.typeof,'beamrt_gpu_image_pixel_v1')then ffi.cdef[[
 typedef struct {uint32_t left,right,first,count;} beamrt_gpu_topology_v1;
 typedef struct {uint32_t owner,reference;float distance;uint32_t state;} beamrt_gpu_image_hit_v1;
 typedef struct {beamrt_gpu_image_hit_v1 primary,full,excluded;} beamrt_gpu_image_pixel_v1;
 typedef struct {uint32_t owner,reference;double distance;} beamrt_cpu_image_hit_v1;
 typedef struct {beamrt_cpu_image_hit_v1 primary,full,excluded;} beamrt_cpu_image_pixel_v1;
]]end
assert(ffi.sizeof('beamrt_gpu_topology_v1')==16 and ffi.sizeof('beamrt_gpu_image_pixel_v1')==48
 and ffi.sizeof('beamrt_cpu_image_pixel_v1')==48,'GPU image ABI mismatch')
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function owner(ids,id)
 if id==nil then return 0 elseif id==ids[1]then return 1 elseif id==ids[2]then return 2 end
 error('Unknown image vehicle identity')
end
function M.preflight()return probe.preflight(M.endpoint,'beamrt.gpu-image.v2',1810)end
function M.expected(count)
 assert(count>0 and count<=12288 and count%1==0,'CPU image reference budget')
 return ffi.new('beamrt_cpu_image_pixel_v1[?]',count)
end
function M.record(expected,index,primary,full,excluded,ids)
 for _,entry in ipairs({{'primary',primary},{'full',full},{'excluded',excluded}})do
  local h=entry[2];local out=expected[index][entry[1]]
  out.owner=h and owner(ids,h.vehicleId) or 0;out.reference=h and h.reference or 4294967295
  out.distance=h and h.distance or 0
 end
end
function M.pack(db,ids,snapshot,work,stats,far)
 assert(db.nodeCount>0 and db.nodeCount<=2*db.count-1,'GPU image node budget exceeded')
 assert(snapshot.sampleWidth==128 and snapshot.sampleHeight>=32 and snapshot.sampleHeight<=96,'GPU image sample budget')
 local triangles=probe.packTriangles(db,ids,snapshot,work,stats)
 local topology=ffi.new('beamrt_gpu_topology_v1[?]',db.nodeCount)
 for i=0,db.nodeCount-1 do
  local n=topology[i];local base=i*4
  n.left=db.topology[base];n.right=db.topology[base+1];n.first=db.topology[base+2];n.count=db.topology[base+3]
  stats.nodesPacked=i+1;work()
 end
 local order=ffi.new('uint32_t[?]',db.count)
 for i=0,db.count-1 do order[i]=db.order[i];work()end
 local camera=ffi.new('float[16]')
 for j=1,3 do camera[j-1]=snapshot.right[j];camera[j+3]=snapshot.forward[j];camera[j+7]=snapshot.up[j]end
 camera[3]=snapshot.near;camera[7]=snapshot.far;camera[11]=far
 camera[12]=snapshot.left;camera[13]=snapshot.rightEdge;camera[14]=snapshot.top;camera[15]=snapshot.bottom
 return {triangles=triangles,topology=topology,order=order,camera=camera,triangleCount=db.count,nodeCount=db.nodeCount,
  width=snapshot.sampleWidth,height=snapshot.sampleHeight}
end
function M.header(p,endpoint)
 local le=probe.encodeU32
 return 'BRGIMG1\0'..le(2)..le(p.triangleCount)..le(p.nodeCount)..le(p.width)..le(p.height)
  ..le(p.triangleCount*52+p.nodeCount*16+64)..endpoint.token
end
local function valid(h,count)
 local state=tonumber(h.state);local who=tonumber(h.owner);local ref=tonumber(h.reference);local d=tonumber(h.distance)
 if state==0 then return who==4294967295 and ref==4294967295 and d==0,0 end
 if state==1 and (who==1 or who==2) and ref<count and finite(d) and d>.08 and d<=1000 then return true,who end
 return false,-1
end
local function pixel(primary,secondary,count)
 local ok,p=valid(primary,count);local validSecondary,who=valid(secondary,count)
 if not ok or not validSecondary then return {175,85,220}end
 if p==0 then return {12,16,23}end
 if who==0 then return {58,68,82}end
 if who==p then return {255,145,35}end
 return {45,240,100}
end
function M.publish(p,endpoint,data,expected,job,stats,work)
 local u=probe.decodeU32
 assert(job.width==p.width*2 and job.height==p.height*2,'GPU/CPU panel layout mismatch')
 assert(#data==64+p.width*p.height*48 and data:sub(1,8)=='BRGIMO1\0' and u(data,9)==2
  and u(data,13)==0 and u(data,17)==p.width and u(data,21)==p.height and u(data,25)==1
  and u(data,29)==48 and data:sub(33,64)==endpoint.token,'GPU image reply identity/size/hardware mismatch')
 local actual=ffi.new('beamrt_gpu_image_pixel_v1[?]',p.width*p.height)
 ffi.copy(actual,data:sub(65),p.width*p.height*48)
 stats.hardwareExecutionVerified=true;stats.pixels=p.width*p.height;stats.pixelsMatched=0
 stats.ownerDisagreements=0;stats.primitiveDisagreements=0;stats.distanceDisagreements=0;stats.invalidPixels=0;stats.incompletePixels=0
 stats.fullOtherHits=0;stats.fullSelfHits=0;stats.excludedOtherHits=0;stats.excludedSelfHits=0;stats.selfHitChanges=0
 stats.offscreenHits=0;stats.mismatches={};stats.phase='comparing';job.phase='gpu-image-comparing'
 job.gpuImageWitnesses={}
 for index=0,p.width*p.height-1 do
  local a,e=actual[index],expected[index]
  local own,ref,dist,allValid=true,true,true,true
  for _,key in ipairs({'primary','full','excluded'})do
   local good,who=valid(a[key],p.triangleCount)
   allValid=allValid and good
   own=own and good and who==tonumber(e[key].owner)
   ref=ref and good and (who==0 or tonumber(a[key].reference)==tonumber(e[key].reference))
   dist=dist and good and math.abs(tonumber(a[key].distance)-tonumber(e[key].distance))<=.001+.0001*math.abs(tonumber(e[key].distance))
   local distanceMismatch=not good or math.abs(tonumber(a[key].distance)-tonumber(e[key].distance))>.001+.0001*math.abs(tonumber(e[key].distance))
   if (not good or who~=tonumber(e[key].owner) or (who>0 and tonumber(a[key].reference)~=tonumber(e[key].reference)) or distanceMismatch) and #stats.mismatches<8 then
    stats.mismatches[#stats.mismatches+1]={x=index%p.width,y=math.floor(index/p.width),query=key,
     cpuOwner=tonumber(e[key].owner),gpuOwner=who,cpuReference=tonumber(e[key].reference),gpuReference=tonumber(a[key].reference),
     cpuDistance=tonumber(e[key].distance),gpuDistance=finite(tonumber(a[key].distance)) and tonumber(a[key].distance) or nil}
   end
  end
  if own and ref and dist then stats.pixelsMatched=stats.pixelsMatched+1 end
  if not (own and ref and dist) and #job.gpuImageWitnesses<8 then
   job.gpuImageWitnesses[#job.gpuImageWitnesses+1]={index=index,bytes=data:sub(65+index*48,112+index*48)}
  end
  if not own then stats.ownerDisagreements=stats.ownerDisagreements+1 end
  if not ref then stats.primitiveDisagreements=stats.primitiveDisagreements+1 end
  if not dist then stats.distanceDisagreements=stats.distanceDisagreements+1 end
  if not allValid then stats.invalidPixels=stats.invalidPixels+1 end
  if a.primary.state==3 or a.full.state==3 or a.excluded.state==3 then stats.incompletePixels=stats.incompletePixels+1 end
  if allValid and a.primary.state==1 then
   local receiver=tonumber(a.primary.owner)
   if a.full.state==1 then
    if tonumber(a.full.owner)~=receiver then
     stats.fullOtherHits=stats.fullOtherHits+1
     if job.bounce.offscreenSourceBounds[tonumber(a.full.owner)].outside then stats.offscreenHits=stats.offscreenHits+1 end
    else
     stats.fullSelfHits=stats.fullSelfHits+1
     if a.excluded.state~=1 or a.excluded.owner~=a.full.owner or a.excluded.reference~=a.full.reference or a.excluded.distance~=a.full.distance then stats.selfHitChanges=stats.selfHitChanges+1 end
    end
   end
   if a.excluded.state==1 then
    if tonumber(a.excluded.owner)==receiver then stats.excludedSelfHits=stats.excludedSelfHits+1
    else stats.excludedOtherHits=stats.excludedOtherHits+1 end
   end
  end
  local x,y=index%p.width,math.floor(index/p.width)
  job.pixels[y*job.width+x+p.width+1]=pixel(a.primary,a.full,p.triangleCount)
  job.pixels[(y+p.height)*job.width+x+p.width+1]=pixel(a.primary,a.excluded,p.triangleCount)
  job.pixelsRendered=job.pixelsRendered+2
  work()
 end
 stats.sourceExcludedControlPassed=stats.fullOtherHits>0 and stats.excludedOtherHits==0
 stats.receiverSelfHitsRetained=stats.selfHitChanges==0
 stats.passed=stats.pixelsMatched==stats.pixels and stats.invalidPixels==0
 stats.offscreenGeometryControlsPassed=stats.offscreenHits>0 and stats.sourceExcludedControlPassed
  and stats.receiverSelfHitsRetained and stats.passed
 stats.phase=stats.passed and 'passed' or 'mismatch'
end
function M.checkRequest(p,endpoint,job)
 local witnesses=job.gpuImageWitnesses or {};assert(#witnesses<=8,'GPU linear recheck budget exceeded')
 local le=probe.encodeU32
 local header='BRGCHK1\0'..le(2)..le(#witnesses)..le(p.width)..le(p.height)..le(0)..le(0)..endpoint.token
 local indices=ffi.new('uint32_t[?]',math.max(1,#witnesses))
 for i,w in ipairs(witnesses)do indices[i-1]=w.index end
 return header,indices,#witnesses
end
function M.acceptRecheck(p,endpoint,data,job,stats)
 local witnesses=job.gpuImageWitnesses or {};local u=probe.decodeU32
 assert(#data==64+#witnesses*52 and data:sub(1,8)=='BRGCKO1\0' and u(data,9)==2 and u(data,13)==#witnesses
  and u(data,17)==p.width and u(data,21)==p.height and u(data,25)==1 and u(data,29)==52
  and data:sub(33,64)==endpoint.token,'Invalid GPU linear recheck identity/size')
 stats.gpuLinearRecheckRequired=#witnesses>0;stats.gpuLinearRecheckSamples=#witnesses
 stats.gpuLinearRecheckMatched=0;stats.gpuLinearRecheckBitExact=0;stats.gpuLinearRecheckDetails={}
 for i,w in ipairs(witnesses)do
  local offset=65+(i-1)*52;assert(u(data,offset)==w.index,'GPU linear recheck pixel mismatch')
  local linear=data:sub(offset+4,offset+51);local matched=true
  for hit=0,2 do
   local base=hit*16+1
   for _,field in ipairs({0,4,12})do if u(linear,base+field)~=u(w.bytes,base+field)then matched=false end end
   if u(linear,base+12)>1 or u(w.bytes,base+12)>1 then matched=false end
   local f=ffi.new('float[1]');ffi.copy(f,linear:sub(base+8,base+11),4);local a=tonumber(f[0])
   ffi.copy(f,w.bytes:sub(base+8,base+11),4);local b=tonumber(f[0])
   if not finite(a) or not finite(b) or math.abs(a-b)>1e-6+1e-6*math.abs(b)then matched=false end
  end
  if matched then stats.gpuLinearRecheckMatched=stats.gpuLinearRecheckMatched+1 end
  if linear==w.bytes then stats.gpuLinearRecheckBitExact=stats.gpuLinearRecheckBitExact+1 end
  stats.gpuLinearRecheckDetails[i]={x=w.index%p.width,y=math.floor(w.index/p.width),matched=matched,bitExact=linear==w.bytes}
 end
 stats.gpuLinearRecheckPassed=#witnesses>0 and stats.gpuLinearRecheckMatched==#witnesses
 stats.gpuLinearRecheckCoversAllDisagreements=#witnesses==stats.pixels-stats.pixelsMatched
 stats.primitiveOnlyCpuDisagreement=stats.gpuLinearRecheckPassed and stats.gpuLinearRecheckCoversAllDisagreements
  and stats.ownerDisagreements==0 and stats.distanceDisagreements==0 and stats.primitiveDisagreements>0
 -- The strict CPU result is NEVER changed by this separate GPU audit.
 stats.phase=stats.passed and 'passed' or 'mismatch'
 job.gpuImageWitnesses=nil
end
local function surface(db,reference)
 if not reference or reference<0 or reference>=db.count then return nil end
 local r=db.ranges[tonumber(db.range[reference])]
 return {vehicleId=r.vehicleId,kind=r.kind,mesh=r.meshName,material=r.materialName,
  nativeIndex=r.nativeIndex,primitive=r.primitive,triangleInPrimitive=tonumber(db.source[reference])}
end
function M.run(db,ids,snapshot,work,job,endpoint)
 local stats={phase='packing',backend='isolated GPU BVH image',passed=false,hardwareExecutionVerified=false,
  gameIntegrationVerified=false,dxrUsed=false,gpuGeneratedPrimaryRays=true,gpuGeneratedReflectedRays=true,
  cpuRayInputsUploaded=false,triangles=db.count,trianglesPacked=0,nodes=db.nodeCount,nodesPacked=0,bytesSent=0,
  allCapturedTriangleReferences=true,bvhBoundsRefitFromUploadedFloats=true,pixelsMatched=0,pixels=snapshot.sampleWidth*snapshot.sampleHeight,
  queryNodeBudget=8192,queryTriangleBudget=65536,protocolVersion=2}
 job.gpuImage=stats;job.phase='gpu-image-packing'
 local p=M.pack(db,ids,snapshot,work,stats,job.bounce.bounceMaxDistance)
 stats.packetBytes=64+p.triangleCount*52+p.nodeCount*16+64
 local data=probe.exchange(M.header(p,endpoint),{{p.triangles,p.triangleCount*48},{p.topology,p.nodeCount*16},
  {p.order,p.triangleCount*4},{p.camera,64}},64+p.width*p.height*48,endpoint,job,stats,60,true)
 M.publish(p,endpoint,data,job.gpuImageExpected,job,stats,work)
 for _,w in ipairs(stats.mismatches)do w.cpuSurface=surface(db,w.cpuReference);w.gpuSurface=surface(db,w.gpuReference)end
 local header,indices,count=M.checkRequest(p,endpoint,job)
 stats.packetBytes=stats.packetBytes+64+count*4
 local reply=probe.exchange(header,count>0 and {{indices,count*4}} or {},64+count*52,endpoint,job,stats,60)
 M.acceptRecheck(p,endpoint,reply,job,stats)
 job.gpuImageExpected=nil
end
return M
