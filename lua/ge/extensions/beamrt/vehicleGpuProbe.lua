-- One explicitly requested, bounded loopback transfer to an isolated GPU host.
-- No DLL loads, native pointers, game-device access or geometry files.
local M={endpoint='/settings/beamrtGpuProbeEndpoint.json'}
local ffi=require('ffi')
local bvh=require('ge/extensions/beamrt/vehicleGeometryBVH')
if not pcall(ffi.typeof,'beamrt_gpu_triangle_v1')then ffi.cdef[[
  typedef struct {float a[3];uint32_t owner;float b[3];uint32_t reference;float c[3];uint32_t reserved;} beamrt_gpu_triangle_v1;
  typedef struct {float origin[3];float reach;float direction[3];uint32_t excluded;} beamrt_gpu_ray_v1;
]]end
assert(ffi.sizeof('beamrt_gpu_triangle_v1')==48 and ffi.sizeof('beamrt_gpu_ray_v1')==32,'GPU probe layout mismatch')
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function le(n)
  local s={};for j=1,4 do s[j]=string.char(n%256);n=math.floor(n/256)end;return table.concat(s)
end
local function u32(s,p)
  local a,b,c,d=s:byte(p,p+3);assert(d,'Truncated GPU reply');return a+b*256+c*65536+d*16777216
end
function M.preflight(path,schema,lifetime)
  local c=jsonReadFile(path or M.endpoint)
  assert(type(c)=='table' and c.schema==(schema or 'beamrt.gpu-ray-probe.v1'),'Start the local GPU probe helper first')
  assert(c.host=='127.0.0.1' and type(c.port)=='number' and c.port%1==0 and c.port>=1024 and c.port<=65535,'Invalid loopback GPU endpoint')
  assert(c.hardware==true,'GPU probe requires the hardware helper; software results are not hardware evidence')
  assert(type(c.token)=='string' and #c.token==32 and c.token:match('^%x+$'),'Invalid GPU session')
  assert(finite(c.expires) and c.expires>os.time() and c.expires<=os.time()+(lifetime or 610),'GPU helper endpoint expired; start a new helper')
  local socket=require('socket');assert(type(socket.tcp)=='function' and type(socket.gettime)=='function','Nonblocking LuaSocket unavailable')
  return {host=c.host,port=c.port,token=c.token,expires=c.expires}
end
local function owner(ids,id)
  if id==nil then return 0 end
  if id==ids[1]then return 1 elseif id==ids[2]then return 2 end
  error('Unknown GPU probe vehicle identity')
end
function M.packTriangles(db,ids,snapshot,work,stats)
  assert(db.count>0 and db.count%1==0 and db.count<=500000 and ids[1]~=ids[2],'Invalid GPU geometry count/identity')
  local triangles=ffi.new('beamrt_gpu_triangle_v1[?]',db.count)
  for i=0,db.count-1 do
    local range=db.ranges[tonumber(db.range[i])];local out=triangles[i]
    out.owner=owner(ids,range.vehicleId);out.reference=i;out.reserved=0
    for j=1,3 do
      local a=tonumber(db.vertices[i*9+j-1])-snapshot.position[j]
      local b=tonumber(db.vertices[i*9+j+2])-snapshot.position[j]
      local c=tonumber(db.vertices[i*9+j+5])-snapshot.position[j]
      assert(finite(a) and finite(b) and finite(c) and math.abs(a)<=10000 and math.abs(b)<=10000 and math.abs(c)<=10000,'GPU rebased position out of range')
      out.a[j-1]=a;out.b[j-1]=b;out.c[j-1]=c
    end
    stats.trianglesPacked=i+1;work()
  end
  return triangles
end
function M.pack(db,ids,snapshot,casts,controls,work,stats,sourceBounds)
  assert(db.count>0 and db.count%1==0 and db.count<=500000 and ids[1]~=ids[2],'Invalid GPU geometry count/identity')
  assert(#casts>0 and #casts<=8 and #controls.rays==4,'Invalid GPU comparison budget')
  local comparisons={}
  local function add(origin,direction,reach,excluded,expected,label,offscreenSource)
    comparisons[#comparisons+1]={origin=origin,direction=direction,reach=reach,excluded=owner(ids,excluded),
      owner=expected and owner(ids,expected.vehicleId) or 0,reference=expected and expected.reference or nil,
      distance=expected and expected.distance or 0,label=label,offscreenSource=offscreenSource or false}
  end
  for i,r in ipairs(controls.rays)do
    add(r.origin,r.direction,r.length,r.excludedVehicleId,bvh.trace(db,r.origin,r.direction,r.length,r.excludedVehicleId,work),'direct-'..i)
  end
  for i,c in ipairs(casts)do
    local offscreenSource=false
    if c.full and c.full.vehicleId==c.sourceId then
      for _,bound in ipairs(sourceBounds or {})do
        if bound.vehicleId==c.sourceId and bound.outside then offscreenSource=true end
      end
    end
    add(c.origin,c.direction,c.far,nil,c.full,'bounce-'..i..'-full',offscreenSource)
    add(c.origin,c.direction,c.far,c.sourceId,c.excluded,'bounce-'..i..'-excluded')
  end
  assert(#comparisons<=32,'GPU ray budget exceeded')
  local triangles=M.packTriangles(db,ids,snapshot,work,stats)
  local rays=ffi.new('beamrt_gpu_ray_v1[?]',#comparisons)
  for i,r in ipairs(comparisons)do
    local out=rays[i-1]
    for j=1,3 do out.origin[j-1]=r.origin[j]-snapshot.position[j];out.direction[j-1]=r.direction[j]end
    out.reach=r.reach;out.excluded=r.excluded
  end
  return {triangles=triangles,rays=rays,comparisons=comparisons,triangleCount=db.count,rayCount=#comparisons}
end
function M.header(packet,endpoint)
  return 'BRGIN01\0'..le(1)..le(packet.triangleCount)..le(packet.rayCount)..le(48)..le(32)
    ..le(packet.triangleCount*48+packet.rayCount*32)..endpoint.token
end
function M.compare(packet,endpoint,data)
  assert(#data==64+packet.rayCount*16 and data:sub(1,8)=='BRGOUT1\0' and u32(data,9)==1,'Invalid GPU reply header/size')
  assert(u32(data,13)==0 and u32(data,17)==packet.triangleCount and u32(data,21)==packet.rayCount
    and u32(data,25)==1 and u32(data,29)==16 and data:sub(33,64)==endpoint.token,'GPU reply identity/hardware mismatch')
  local out={matched=0,mismatches={},hardwareExecutionVerified=true,passed=false,offscreenRaysMatched=0,
    offscreenGeometryComparisonPassed=false}
  for i,r in ipairs(packet.comparisons)do
    local p=65+(i-1)*16
    local gotOwner,reference,state=u32(data,p),u32(data,p+4),u32(data,p+12)
    local f=ffi.new('float[1]');ffi.copy(f,data:sub(p+8,p+11),4);local distance=tonumber(f[0])
    local matches=false
    if r.owner==0 then matches=state==0 and gotOwner==4294967295 and reference==4294967295 and distance==0
    else matches=state==1 and gotOwner==r.owner and reference==r.reference and finite(distance)
      and math.abs(distance-r.distance)<=.001+.0001*math.abs(r.distance)end
    if matches then
      out.matched=out.matched+1
      if r.offscreenSource then out.offscreenRaysMatched=out.offscreenRaysMatched+1 end
    else
      out.mismatches[#out.mismatches+1]={ray=i,label=r.label,expectedOwner=r.owner,actualOwner=gotOwner,
        expectedReference=r.reference,actualReference=reference,expectedDistance=r.distance,actualDistance=finite(distance) and distance or nil,state=state}
    end
  end
  out.passed=out.matched==packet.rayCount
  out.offscreenGeometryComparisonPassed=out.passed and out.offscreenRaysMatched>0
  return out
end
function M.exchange(header,parts,replyBytes,endpoint,job,stats,timeout,keepOpen)
  assert(endpoint and endpoint.expires>os.time(),'GPU session expired before transfer')
  local socket=require('socket');local sock=job.gpuSocket
  local existing=sock~=nil
  if not sock then sock=assert(socket.tcp());job.gpuSocket=sock;assert(sock:settimeout(0))end
  local started=socket.gettime()
  local function yieldFrame()
    assert(socket.gettime()-started<(timeout or 30),'GPU transfer/readback timed out')
    coroutine.yield()
  end
  if not existing then
    local ok,err=sock:connect('127.0.0.1',endpoint.port)
    assert(ok or err=='timeout' or err=='Operation already in progress','GPU helper connection failed')
    while not sock:getpeername()do yieldFrame()end
  end
  local function sendChunk(data)
    local pos=1
    while pos<=#data do
      local last,why,partial=sock:send(data,pos)
      local consumed=last or partial or (pos-1)
      assert(consumed>=pos-1 and consumed<=#data,'Invalid nonblocking send count')
      stats.bytesSent=stats.bytesSent+consumed-pos+1;pos=consumed+1
      assert(not why or why=='timeout','GPU helper disconnected during transfer')
      yieldFrame()
    end
  end
  stats.phase='sending';job.phase='gpu-sending';sendChunk(header)
  for _,part in ipairs(parts)do
    -- BeamNG rejected byte-pointer addition in the first live transfer. Its
    -- shipped lpack.lua uses ffi.string(ownedArray, byteLength); use that
    -- contract and ordinary Lua string slicing, with no pointer arithmetic.
    -- At most one additional 24 MB immutable string is retained at a time.
    local bytes=ffi.string(part[1],part[2])
    for offset=1,#bytes,65536 do sendChunk(bytes:sub(offset,offset+65535))end
  end
  stats.phase='waiting';job.phase='gpu-readback'
  local reply='';local size=replyBytes
  while #reply<size do
    local data,why,partial=sock:receive(size-#reply);reply=reply..(data or partial or '')
    assert(#reply==size or not why or why=='timeout','GPU helper closed before complete readback')
    if #reply<size then yieldFrame()end
  end
  if not keepOpen then sock:close();job.gpuSocket=nil end
  return reply
end
M.encodeU32=le;M.decodeU32=u32
function M.run(db,ids,snapshot,casts,controls,work,job,endpoint)
  local stats={phase='packing',backend='isolated D3D12 compute',passed=false,hardwareExecutionVerified=false,
    gameIntegrationVerified=false,dxrUsed=false,triangles=db.count,trianglesPacked=0,rays=0,bytesSent=0,
    matched=0,mismatches={},distanceAbsoluteToleranceMetres=.001,distanceRelativeTolerance=.0001,
    floatPositionsRebasedToCamera=true,allCapturedTriangleReferences=true,
    offscreenRaysMatched=0,offscreenGeometryComparisonPassed=false}
  job.gpuProbe=stats;job.phase='gpu-packing'
  local packet=M.pack(db,ids,snapshot,casts,controls,work,stats,job.bounce.offscreenSourceBounds)
  stats.rays=packet.rayCount;stats.packetBytes=64+db.count*48+packet.rayCount*32
  local reply=M.exchange(M.header(packet,endpoint),{{packet.triangles,packet.triangleCount*48},{packet.rays,packet.rayCount*32}},
    64+packet.rayCount*16,endpoint,job,stats)
  local result=M.compare(packet,endpoint,reply)
  for key,value in pairs(result)do stats[key]=value end
  stats.phase=stats.passed and 'passed' or 'mismatch'
end
return M
