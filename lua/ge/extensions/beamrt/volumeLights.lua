-- Independent, read-only haze source discovery. Never requests native shadows.
local M={radius=180,maxLights=8,maxDistance=160,maxRange=80}
local requested=false
local selected,pool,queue={},{},{}
local cursor,elapsed,scanElapsed,revision=1,1,5,0
local lastCamera,lastForward
local lookup,reason='Not started','Haze source discovery is off.'
local inspected=0
local poolCount=0
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function vector(p)
  if p and finite(p.x) and finite(p.y) and finite(p.z) then return {p.x,p.y,p.z} end
end
local function camera()
  if not core_camera or type(core_camera.getPosition)~='function' then return end
  local ok,p=pcall(core_camera.getPosition)
  if ok then return vector(p) end
end
local function read(o,key) return o:getField(key,0) end
local function truth(v) return v==true or v==1 or v=='1' or v=='true' end
local function source(o,p,forward)
  if o:getClassName()~='SpotLight' or not truth(read(o,'isEnabled')) then return end
  local fields=o:getFields()
  for _,key in ipairs({'color','brightness','range','innerAngle','outerAngle'}) do
    if fields[key]==nil then return end
  end
  local q=vector(o:getPosition());if not q then return end
  local dx,dy,dz=q[1]-p[1],q[2]-p[2],q[3]-p[3]
  local d2=dx*dx+dy*dy+dz*dz
  if d2>M.radius*M.radius then return end
  local function number(key)
    local n=tonumber(read(o,key));assert(finite(n),'Invalid haze source scalar');return n
  end
  local range,brightness=number('range'),number('brightness')
  local inner,outer=number('innerAngle'),number('outerAngle')
  if range<=0 or brightness<=0 or inner<0 or outer<=inner or outer>=179 then return end
  range=math.min(range,M.maxRange)
  if math.sqrt(d2)-range>=M.maxDistance then return end
  -- Reject spheres entirely behind the camera, not simply off-screen lamps:
  -- an off-screen source's volume can still intersect visible camera rays.
  if forward and dx*forward[1]+dy*forward[2]+dz*forward[3]+range<=0 then return end
  local color={}
  for v in tostring(read(o,'color')):gmatch('[^%s]+') do color[#color+1]=tonumber(v) end
  for i=1,3 do if not finite(color[i]) or color[i]<0 then return end;color[i]=math.min(color[i],8) end
  if math.max(color[1],color[2],color[3])<=0 then return end
  local direction=vector(o:getTransform():getColumn(1));if not direction then return end
  local n=math.sqrt(direction[1]^2+direction[2]^2+direction[3]^2)
  if n<=0 or not finite(n) then return end
  brightness=math.min(brightness,100)
  local edge=math.max(0,math.sqrt(d2)-range)
  return {id=o:getID(),position=q,direction={direction[1]/n,direction[2]/n,direction[3]/n},
    range=range,color=color,brightness=brightness,inner=math.cos(math.rad(inner*.5)),
    outer=math.cos(math.rad(outer*.5)),score=brightness*math.max(color[1],color[2],color[3])*range*range/(1+edge*edge)}
end
local function spatial(p)
  if type(findObjectList)~='function' or not SOTLight or not Box3F or not vec3 then return end
  local ok,hits=pcall(function()
    local b=Box3F();b:setExtents(vec3(M.radius*2,M.radius*2,M.radius*2));b:setCenter(vec3(p[1],p[2],p[3]))
    local result=findObjectList(b,SOTLight,0);assert(type(result)=='table');return result
  end)
  if ok then return hits end
end
function M.disable()
  requested=false;selected,pool,queue={},{},{};cursor,elapsed,scanElapsed=1,1,5
  lastCamera,lastForward=nil,nil;inspected=0;poolCount=0;lookup='Not started';reason='Haze source discovery is off.'
  revision=revision+1;return true
end
function M.enable() M.disable();requested=true;reason='Independent haze discovery starting.';return true end
function M.update(dt)
  if not requested then return end
  local step=finite(dt) and math.max(0,math.min(dt,1)) or 1/60
  elapsed,scanElapsed=elapsed+step,scanElapsed+step
  local p=camera()
  if not p then
    if #selected>0 then selected={};revision=revision+1 end
    lastCamera=nil;reason='Haze paused: camera unavailable.';return
  end
  local forward
  if type(core_camera.getForward)=='function' then
    local ok,v=pcall(core_camera.getForward);if ok then forward=vector(v) end
  end
  local moved=not lastCamera or (p[1]-lastCamera[1])^2+(p[2]-lastCamera[2])^2+(p[3]-lastCamera[3])^2>=16
  local turned=forward and (not lastForward or
    forward[1]*lastForward[1]+forward[2]*lastForward[2]+forward[3]*lastForward[3]<.995)
  local refresh=elapsed>=.25 or moved or turned
  local hits=refresh and spatial(p) or nil
  local discovered=false
  if hits then
    lookup='Native 180 m haze query (read-only)'
    pool={};poolCount=0 -- no retained stale identities outside this spatial query
    for i=1,math.min(512,#hits) do
      local ok,o=pcall(function()
        local token=hits[i]
        local object=(type(token)=='number' or type(token)=='string') and scenetree.findObject(token) or token
        if object and Sim and type(Sim.upcast)=='function' then object=Sim.upcast(object) or object end
        return object
      end)
      if ok and o then
        local valid,id=pcall(function()if o:getClassName()=='SpotLight' then return o:getID() end end)
        if valid and id and not pool[id] then pool[id]=o;poolCount=poolCount+1 end
      end
    end
    queue={};cursor=1
  elseif not hits and refresh then
    lookup='Incremental haze discovery (read-only fallback)'
    -- Free bounded cache slots after travel; old far sources must not prevent
    -- the next batch of nearby fallback candidates from being admitted.
    for id,o in pairs(pool) do
      local ok,q=pcall(function()return vector(o:getPosition()) end)
      if not ok or not q or (q[1]-p[1])^2+(q[2]-p[2])^2+(q[3]-p[3])^2>M.radius*M.radius then
        pool[id]=nil;poolCount=poolCount-1
      end
    end
    if cursor>#queue and scanElapsed>=5 then
      local ok,ids=pcall(scenetree.findClassObjects,'SpotLight')
      if ok and type(ids)=='table' then queue=ids;cursor=1;scanElapsed=0 end
    end
  end
  if lookup=='Incremental haze discovery (read-only fallback)' then
    local started=os.clock()
    for i=1,math.max(24,math.min(128,math.ceil(1440*step))) do
      if i>24 and os.clock()-started>=.002 then break end
      local token=queue[cursor];if token==nil then break end;cursor=cursor+1;inspected=inspected+1
      local ok,o=pcall(scenetree.findObject,token)
      if ok and o then
        local valid,id=pcall(function()
          if o:getClassName()~='SpotLight' then return end
          local q=vector(o:getPosition());if not q then return end
          if (q[1]-p[1])^2+(q[2]-p[2])^2+(q[3]-p[3])^2>M.radius*M.radius then return end
          return o:getID()
        end)
        if valid and id and (pool[id] or poolCount<512) then
          if not pool[id] then poolCount=poolCount+1 end
          discovered=discovered or pool[id]~=o;pool[id]=o
        end
      end
    end
  end
  -- Continue incremental discovery each frame, but bound source refresh to 4 Hz
  -- except on camera moves/turns and newly discovered candidates.
  if not refresh and not discovered then return end
  local candidates={}
  for id,o in pairs(pool) do
    local ok,live=pcall(scenetree.findObject,id)
    if not ok or live~=o then pool[id]=nil;poolCount=poolCount-1 else
      local valid,item=pcall(source,o,p,forward)
      if valid and item then candidates[#candidates+1]=item end
    end
  end
  table.sort(candidates,function(a,b)if a.score==b.score then return a.id<b.id end;return a.score>b.score end)
  selected={};for i=1,math.min(M.maxLights,#candidates) do selected[i]=candidates[i] end
  revision=revision+1;elapsed=0;lastCamera=p;lastForward=forward
  reason=string.format('%d haze sources selected; independent of native shadow requests.',#selected)
end
function M.getVolumetricLights() return selected end
function M.getStatus()
  return {requested=requested,radius=M.radius,maxLights=M.maxLights,maxDistance=M.maxDistance,
    lightCount=#selected,revision=revision,lookup=lookup,reason=reason,pendingJobs=math.max(0,#queue-cursor+1),
    inspected=inspected,cachedCandidates=poolCount,candidateLimit=512,shadowWrites=false}
end
return M
