-- Vehicle haze discovery/telemetry only. Never changes vehicle lights/electrics.
-- Live prop transforms follow BeamNG's shipped veLightsDebug.lua convention.
local M={maxLights=4,maxVehicles=4,radius=180,beamReach=20,haloReach=3}
local requested=false
local selected,tracked={},{}
local elapsed,now,revision=1,0,0
local token,sink
local sequence=0
local reason='Vehicle haze is off.'
local counts={reported=0,eligible=0,redReported=0,redEligible=0,redSelected=0,merged=0}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function xyz(v)
  local kind=type(v)
  if kind~='table' and kind~='userdata' and kind~='cdata' then return end
  local r={v.x or v[1],v.y or v[2],v.z or v[3]}
  for i=1,3 do if not finite(r[i]) then return end end
  return r
end
local function resolve(id)
  if be and type(be.getObjectByID)=='function' then return be:getObjectByID(id) end
  return scenetree.findObject(id)
end
local function receive(packet)
  if not requested or type(packet)~='table' or packet.token~=token or packet.protocol~=2 then return end
  local entry=tracked[packet.vehicleId]
  if not entry or packet.sequence~=entry.pending or resolve(packet.vehicleId)~=entry.object then return end
  entry.pending=nil
  if type(packet.lights)~='table' or #packet.lights>32 then return end
  entry.lights=packet.lights;entry.received=now
end
function M.disable()
  requested=false;selected={};tracked={};token=nil;elapsed=1;now=0
  counts={reported=0,eligible=0,redReported=0,redEligible=0,redSelected=0,merged=0}
  if rawget(_G,'__BeamRTVehicleHazeSink')==sink then rawset(_G,'__BeamRTVehicleHazeSink',nil) end
  sink=nil;revision=revision+1;reason='Vehicle haze is off.';return true
end
function M.setParameter(key,value)
  local limit=({beamReach={5,50},haloReach={.5,8}})[key]
  if not limit or not finite(value) or value<limit[1] or value>limit[2] then return false end
  M[key]=value;return true
end
function M.enable()
  M.disable()
  if rawget(_G,'__BeamRTVehicleHazeSink')~=nil then reason='Vehicle haze callback name already owned.';return false,reason end
  token=tostring({})..':'..tostring(os.clock());sink=receive
  rawset(_G,'__BeamRTVehicleHazeSink',sink);requested=true
  reason='Waiting for vehicle light telemetry.';return true
end
local function source(entry,l,camera)
  if type(l)~='table' or not finite(l.pid) or l.pid<0 or l.pid>4096 or l.pid~=math.floor(l.pid) then return end
  if l.kind~='spot' and l.kind~='point' then return end
  local c=xyz(l.color)
  if not c or not finite(l.range) or l.range<=0 or l.range>80 or not finite(l.brightness)
    or l.brightness<=0 or l.brightness>100 then return end
  for i=1,3 do if c[i]<0 or c[i]>1 then return end end
  if math.max(c[1],c[2],c[3])<=0 then return end
  local prop=entry.object:getProp(l.pid);if not prop then return end
  local matrix=prop:getLiveTransformWorld()
  local localPosition=xyz(matrix:getColumn(3));local origin=xyz(entry.object:getPosition())
  if not localPosition or not origin then return end
  local position={};local distance=0
  for i=1,3 do position[i]=localPosition[i]+origin[i];distance=distance+(position[i]-camera[i])^2 end
  local red=c[1]>.05 and c[1]>1.75*math.max(c[2],c[3])
  local halo=l.kind=='point' or red
  local range=math.min(l.range,halo and M.haloReach or M.beamReach)
  if math.sqrt(distance)-range>=160 then return end
  local direction,inner,outer={0,0,0},-1,-2 -- point light bypasses cone, same deterministic integrator
  if l.kind=='spot' then
    if not finite(l.inner) or not finite(l.outer) or l.inner<0 or l.outer<=l.inner or l.outer>=179 then return end
    direction=xyz(matrix:getColumn(1));if not direction then return end
    local norm=math.sqrt(direction[1]^2+direction[2]^2+direction[3]^2)
    if not finite(norm) or norm<1e-8 then return end
    for i=1,3 do direction[i]=direction[i]/norm end
    inner=math.cos(math.rad(l.inner*.5));outer=math.cos(math.rad(l.outer*.5))
  end
  return {id=entry.id..':'..l.pid,vehicleId=entry.id,pid=l.pid,kind=l.kind,position=position,
    direction=direction,color=c,brightness=l.brightness,range=range,inner=inner,outer=outer,red=red,halo=halo,
    score=l.brightness*math.max(c[1],c[2],c[3])*range*range/(1+distance)}
end
function M.update(dt)
  if not requested then return end
  local step=finite(dt) and math.max(0,math.min(dt,1)) or 0
  now=now+step;elapsed=elapsed+step
  local ok,why=pcall(function()
    local p=xyz(core_camera.getPosition());assert(p,'Camera unavailable')
    assert(be and type(be.getObjectCount)=='function','Vehicle registry unavailable')
    if elapsed>=.5 then
      elapsed=0;local candidates={}
      for i=0,math.min(be:getObjectCount(),64)-1 do
        local o=be:getObject(i)
        if o then
          local good,q=pcall(function()return xyz(o:getPosition())end)
          if good and q then
            local d=0;for k=1,3 do d=d+(q[k]-p[k])^2 end
            if d<M.radius*M.radius then candidates[#candidates+1]={id=o:getID(),object=o,distance=d} end
          end
        end
      end
      table.sort(candidates,function(a,b)if a.distance==b.distance then return a.id<b.id end;return a.distance<b.distance end)
      local nextTracked={}
      for i=1,math.min(M.maxVehicles,#candidates) do
        local e=candidates[i];local old=tracked[e.id]
        if old and old.object==e.object then e=old end
        nextTracked[e.id]=e
      end
      tracked=nextTracked
    end
    local candidates={};local vehicles=0
    counts={reported=0,eligible=0,redReported=0,redEligible=0,redSelected=0,merged=0}
    for id,e in pairs(tracked) do
      if resolve(id)~=e.object then tracked[id]=nil else
        vehicles=vehicles+1
        if not e.sent or now-e.sent>=.1 and (not e.pending or now-e.sent>=.5) then
          sequence=sequence+1;e.pending=sequence;e.sent=now
          e.object:queueLuaCommand(string.format("if extensions.beamrtVehicleHaze and extensions.beamrtVehicleHaze.protocol~=2 then extensions.unload('beamrtVehicleHaze') end;if not extensions.beamrtVehicleHaze then extensions.load('beamrtVehicleHaze') end;extensions.beamrtVehicleHaze.sample(%q,%d)",token,sequence))
        end
        if e.received and now-e.received<=.35 then
          for _,l in ipairs(e.lights or {}) do
            counts.reported=counts.reported+1
            local c=type(l)=='table' and xyz(l.color)
            if c and c[1]>.05 and c[1]>1.75*math.max(c[2],c[3]) then counts.redReported=counts.redReported+1 end
            local good,item=pcall(source,e,l,p)
            if good and item then candidates[#candidates+1]=item end
          end
        end
      end
    end
    table.sort(candidates,function(a,b)if a.score==b.score then return a.id<b.id end;return a.score>b.score end)
    local unique={}
    for _,l in ipairs(candidates) do
      local duplicate=false
      for _,other in ipairs(unique) do
        if l.vehicleId==other.vehicleId and l.kind==other.kind then
          local d=0
          for k=1,3 do d=d+(l.position[k]-other.position[k])^2 end
          if d<.0144 then
            local dot,colorDot,c2,o2=0,0,0,0
            for k=1,3 do
              dot=dot+l.direction[k]*other.direction[k]
              colorDot=colorDot+l.color[k]*other.color[k];c2=c2+l.color[k]^2;o2=o2+other.color[k]^2
            end
            if (l.kind=='point' or dot>.995) and colorDot/math.sqrt(math.max(c2*o2,1e-12))>.995 then
              duplicate=true;break
            end
          end
        end
      end
      if duplicate then counts.merged=counts.merged+1 else unique[#unique+1]=l end
    end
    counts.eligible=#unique
    for _,l in ipairs(unique) do if l.red then counts.redEligible=counts.redEligible+1 end end
    selected={};local used={}
    -- Headlights can be thousands of times brighter than brake/tail props.
    -- Keep up to two active red/orange sources instead of ranking them out.
    for _,l in ipairs(unique) do
      if l.red and #selected<2 then selected[#selected+1]=l;used[l.id]=true end
    end
    for _,l in ipairs(unique) do
      if not used[l.id] and #selected<M.maxLights then selected[#selected+1]=l;used[l.id]=true end
    end
    for _,l in ipairs(selected) do if l.red then counts.redSelected=counts.redSelected+1 end end
    revision=revision+1
    reason=string.format('%d selected from %d eligible vehicle lights (%d nearby vehicles); red/orange %d / %d eligible. Read-only telemetry.',#selected,#unique,vehicles,counts.redSelected,counts.redEligible)
  end)
  if not ok then selected={};revision=revision+1;reason='Vehicle haze unavailable: '..tostring(why) end
end
function M.getLights()return selected end
function M.getStatus()return {requested=requested,count=#selected,maxLights=M.maxLights,maxVehicles=M.maxVehicles,
  reason=reason,revision=revision,counts=counts,beamReach=M.beamReach,haloReach=M.haloReach,
  gpuAppearanceVerified=false,nativeShadowVisibility=false} end
return M
