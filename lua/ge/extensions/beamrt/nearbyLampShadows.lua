-- Incremental all-scene native lamp shadows, with fixed-cohort diagnostic API.
-- No shader injection,
-- map save, global graphics setting, light creation or appearance gain writes.
local M = {requested=false, reason='Nearby lamp shadow experiment is off.'}
local leases = {}
local selected = {}
local automatic = false
local queue, cursor, elapsed = {}, 1, 5
local seen, validationIds, validationSet = {}, {}, {}
local validationCursor, visited, skipped = 1, 0, 0
local pool, prioritized = {}, {}
local priorityAssist, priorityElapsed, priorityRejected = true, 1, 0
local scanCycles, newLightsThisScan = 0, 0
local priorityCamera, nearbyLookup = nil, 'Not checked yet'
local NEAR_RADIUS=100 -- camera discovery/priority only; native lamp ranges stay intact
local function cameraPosition()
  if not core_camera or type(core_camera.getPosition)~='function' then return end
  local ok,p=pcall(core_camera.getPosition)
  if ok and p and type(p.x)=='number' and type(p.y)=='number' and type(p.z)=='number'
    and p.x==p.x and p.y==p.y and p.z==p.z
    and math.abs(p.x)<math.huge and math.abs(p.y)<math.huge and math.abs(p.z)<math.huge then return p end
end
local function truth(value)
  if value == true or value == 1 or value == '1' or value == 'true' then return true end
  if value == false or value == 0 or value == '0' or value == 'false' then return false end
end
local function same(a, b, field)
  if field == 'castShadows' then return truth(a) ~= nil and truth(a) == truth(b) end
  return tonumber(a) ~= nil and tonumber(a) == tonumber(b)
end
local function owner(lease)
  local o = scenetree.findObject(lease.id)
  return o == lease.object and o:getID() == lease.id and o:getClassName() == lease.class
    and o.getField == lease.reader and o.setField == lease.writer
end
local function read(lease, key)
  assert(owner(lease), 'Lamp identity or binding changed')
  local value = lease.reader(lease.object, key, 0)
  assert(type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean', 'Lamp field unreadable')
  return value
end

local function restoreField(lease,key,field)
    local value=read(lease,key)
    if same(value,field.original,key) then
      lease.fields[key]=nil
    elseif field.applied~=nil and same(value,field.applied,key) then
      lease.writer(lease.object,key,0,tostring(field.original))
      assert(same(read(lease,key),field.original,key),'Lamp restoration rejected')
      lease.fields[key]=nil
    else
      lease.fields[key]=nil -- externally changed: relinquish, never overwrite
    end
end

local function restoreLease(lease)
  if not owner(lease) then return end
  for key, field in pairs(lease.fields) do
    restoreField(lease,key,field)
  end
end

function M.disable(reason)
  M.requested = false
  automatic = false
  local failed = false
  for id, lease in pairs(leases) do
    local ok = pcall(restoreLease,lease)
    if ok then leases[id] = nil
    else failed = true end
  end
  if failed then
    M.reason = 'Lamp restoration failed; retry Restore lamp shadows before re-enabling.'
    return false, M.reason
  end
  selected = {}
  queue,cursor,elapsed={},1,5
  seen,validationIds,validationSet={},{},{}
  validationCursor,visited,skipped=1,0,0
  pool,prioritized={},{}
  priorityElapsed,priorityRejected,scanCycles,newLightsThisScan=1,0,0,0
  priorityCamera,nearbyLookup=nil,'Not checked yet'
  M.reason = reason or 'Original lamp shadow settings restored.'
  return true
end

function M.enableAutomatic()
  if M.requested and automatic then return true end
  if M.requested and not M.disable() then return false,M.reason end
  if next(leases) then return false,'Restore pending lamp settings first.' end
  automatic,M.requested=true,true
  elapsed=5 -- discovery starts on update, never in a renderer-enable callback
  M.reason='Automatic native lamp shadows starting; discovery is spread across frames.'
  return true
end

local function discover()
  local nextQueue={}
  for _,class in ipairs({'SpotLight','PointLight'}) do
    local tokens=scenetree.findClassObjects(class)
    assert(type(tokens)=='table','Lamp enumeration unavailable')
    for _,token in ipairs(tokens) do nextQueue[#nextQueue+1]=token end
  end
  queue,cursor,elapsed=nextQueue,1,0
  scanCycles,newLightsThisScan=scanCycles+1,0
end

local function addValidation(entry)
  leases[entry.id]=entry
  if not validationSet[entry.id] then
    validationSet[entry.id]=true;validationIds[#validationIds+1]=entry.id
  end
end

local function locate(entry)
  local ok=pcall(function()
    local p=entry.object:getPosition()
    assert(type(p.x)=='number' and type(p.y)=='number' and type(p.z)=='number','Position unavailable')
    assert(p.x==p.x and p.y==p.y and p.z==p.z,'Invalid position')
    entry.position={x=p.x,y=p.y,z=p.z}
    entry.enabled=truth(entry.object:getField('isEnabled',0))==true
  end)
  if not ok then entry.position=nil end
end

local function applyAutomatic(token)
  local o=scenetree.findObject(token)
  if not o then return false end
  local class=o:getClassName()
  if class~='SpotLight' and class~='PointLight' then return false end
  local id=o:getID()
  if seen[id]==o then
    if pool[id] and not pool[id].blocked then locate(pool[id]) end
    return false
  end
  -- Retire stale identity before leasing a replacement with a recycled ID.
  if leases[id] then restoreLease(leases[id]);leases[id]=nil end
  seen[id]=o
  local fields=o:getFields()
  if type(fields)~='table' or fields.castShadows==nil then skipped=skipped+1;return false end
  local original=o:getField('castShadows',0)
  if truth(original)==nil then skipped=skipped+1;return false end
  local entry={object=o,id=id,class=class,reader=o.getField,writer=o.setField,fields={},name=o:getName()}
  if not truth(original) then entry.fields.castShadows={original=original,wanted='1'} end
  -- Preserve distant native map sizes. Raising thousands of maps to 1024
  -- wastes the finite clustered shadow atlas without guaranteeing selection.
  if fields.texSize~=nil then entry.baseMap=o:getField('texSize',0) end
  if fields.priority~=nil then entry.basePriority=o:getField('priority',0) end
  locate(entry);pool[id]=entry
  visited=visited+1
  newLightsThisScan=newLightsThisScan+1
  if #selected<8 then selected[#selected+1]={id=id,name=entry.name,class=class,distance=0} end
  if not next(entry.fields) then return false end
  addValidation(entry) -- publish rollback before the first native write
  for key,field in pairs(entry.fields) do
    assert(same(read(entry,key),field.original,key),'Lamp changed before automatic request')
    field.applied=field.wanted
    local wrote,accepted=pcall(entry.writer,o,key,0,field.wanted)
    local observed=read(entry,key);field.applied=observed
    assert(wrote and accepted~=false and same(observed,field.wanted,key),'Automatic lamp shadow write rejected')
  end
  return true
end

local function assistField(entry,key,base,wanted)
  local field=entry.fields[key]
  if not wanted then
    if field then restoreField(entry,key,field);return true end
    return false
  end
  if not tonumber(base) or tonumber(base)~=tonumber(base) or math.abs(tonumber(base))==math.huge then return false end
  if field and same(field.applied,wanted,key) then return false end
  local current=read(entry,key)
  if not same(current,field and field.applied or base,key) then return false end
  if not field then
    field={original=base};entry.fields[key]=field;addValidation(entry)
  end
  field.applied=wanted
  local wrote,accepted=pcall(entry.writer,entry.object,key,0,tostring(wanted))
  local observed=read(entry,key);field.applied=observed
  if not wrote or accepted==false or not same(observed,wanted,key) then
    restoreField(entry,key,field)
    if key=='priority' then entry.priorityUnsupported=true;priorityRejected=priorityRejected+1 end
    return false
  end
  return true
end

-- The engine spatial query bypasses the level-wide queue. Its existence and
-- SOTLight flag are optional: unavailable/rejected queries retain the safe scan.
-- Query enumeration is read-only; only the nearest 16 supported enabled lamps
-- enter the ordinary ownership/rollback path. Bound Lua inspection to 256 hits.
local function inspectNearby(p)
  if type(findObjectList)~='function' or not SOTLight or not Box3F or not vec3 then
    nearbyLookup='Background fallback (native nearby query unavailable)'
    return false
  end
  local ok,candidates=pcall(function()
    local box=Box3F()
    box:setExtents(vec3(NEAR_RADIUS*2,NEAR_RADIUS*2,NEAR_RADIUS*2));box:setCenter(vec3(p.x,p.y,p.z))
    local hits=findObjectList(box,SOTLight,0)
    assert(type(hits)=='table','Nearby query unavailable')
    local result,ids={},{}
    for i=1,math.min(256,#hits) do
      local readable,item=pcall(function()
        local raw=hits[i]
        local o=(type(raw)=='number' or type(raw)=='string') and scenetree.findObject(raw) or raw
        if o and Sim and type(Sim.upcast)=='function' then o=Sim.upcast(o) or o end
        local class=o and o:getClassName()
        if class~='SpotLight' and class~='PointLight' then return end
        local id=o:getID()
        if ids[id] or (pool[id] and pool[id].object==o and pool[id].blocked) then return end
        ids[id]=true
        if truth(o:getField('isEnabled',0))~=true then return end
        local q=o:getPosition()
        local d=(q.x-p.x)^2+(q.y-p.y)^2+(q.z-p.z)^2
        if d==d and d<=NEAR_RADIUS*NEAR_RADIUS then return {id=id,distance=d} end
      end)
      if readable and item then result[#result+1]=item end
    end
    table.sort(result,function(a,b)
      if a.distance==b.distance then return a.id<b.id end
      return a.distance<b.distance
    end)
    return result
  end)
  if not ok then nearbyLookup='Background fallback (native nearby query rejected)';return false end
  nearbyLookup='Native nearby query active'
  local changed,nearIds=false,{}
  for i=1,math.min(16,#candidates) do
    local id=candidates[i].id
    changed=applyAutomatic(id) or changed
    nearIds[id]=true
  end
  return changed,nearIds
end

local function updatePriority(nearIds)
  local nextSet, candidates={},{}
  if priorityAssist and core_camera and type(core_camera.getPosition)=='function' then
    local readable,p=pcall(core_camera.getPosition)
    if not readable or not p or type(p.x)~='number' or type(p.y)~='number' or type(p.z)~='number'
      or p.x~=p.x or p.y~=p.y or p.z~=p.z then return false end
    if p then
      for id in pairs(nearIds or pool) do
        local entry=pool[id]
        local q=entry and entry.position
        if q and entry.enabled and not entry.blocked then
          local d=(q.x-p.x)^2+(q.y-p.y)^2+(q.z-p.z)^2
          if d==d and d<=NEAR_RADIUS*NEAR_RADIUS then candidates[#candidates+1]={id=id,distance=d} end
        end
      end
      table.sort(candidates,function(a,b)
        if a.distance==b.distance then return a.id<b.id end
        return a.distance<b.distance
      end)
      for i=1,math.min(8,#candidates) do nextSet[candidates[i].id]=true end
    end
  end
  local changed=false
  for id in pairs(prioritized) do
    if not nextSet[id] then
      local entry=pool[id]
      if entry and owner(entry) then
        changed=assistField(entry,'priority',entry.basePriority,nil) or changed
        changed=assistField(entry,'texSize',entry.baseMap,nil) or changed
      end
    end
  end
  for id in pairs(nextSet) do
    local entry=pool[id]
    if owner(entry) then
      if entry.basePriority~=nil and not entry.priorityUnsupported then
        local base=tonumber(entry.basePriority)
        if base then changed=assistField(entry,'priority',entry.basePriority,base+4) or changed end
      end
      local size=tonumber(entry.baseMap)
      local desired=entry.class=='PointLight' and 512 or 1024
      if size and size>0 and size<desired then
        changed=assistField(entry,'texSize',entry.baseMap,desired) or changed
      end
    end
  end
  prioritized=nextSet
  return changed
end

local function updateAutomatic(dt)
  local changed=false
  local ok,why=pcall(function()
    local step=tonumber(dt)
    if not step or step~=step or step==math.huge or step==-math.huge then step=1/60 end
    step=math.max(0,math.min(step,1))
    elapsed=elapsed+step
    priorityElapsed=priorityElapsed+step
    local p=cameraPosition()
    local moved=p and (not priorityCamera or
      (p.x-priorityCamera.x)^2+(p.y-priorityCamera.y)^2+(p.z-priorityCamera.z)^2>=4*4)
    local refresh=priorityElapsed>=.25 or moved
    if cursor>#queue and elapsed>=5 then discover() end
    -- Near-camera work runs first, even on the initial low-FPS frame. No
    -- whole-level flush, allocations for distant maps, or extra renderer start.
    local nearIds
    if refresh and p then
      local nearbyChanged
      nearbyChanged,nearIds=inspectNearby(p)
      changed=nearbyChanged or changed
      priorityCamera={x=p.x,y=p.y,z=p.z}
    end
    -- Keep roughly the old per-second throughput at low FPS, not merely 24
    -- jobs per slow frame. Extra work has a soft 2 ms CPU budget and hard caps;
    -- individual native calls cannot be interrupted. No catch-up backlog.
    local started=os.clock()
    local jobs=math.max(24,math.min(192,math.ceil(1440*step)))
    for job=1,jobs do
      if job>24 and os.clock()-started>=.002 then break end
      local token=queue[cursor];if token==nil then break end
      cursor=cursor+1
      changed=applyAutomatic(token) or changed
    end
    local checks=math.max(16,math.min(128,math.ceil(960*step)))
    for check=1,math.min(checks,#validationIds) do
      if check>16 and os.clock()-started>=.002 then break end
      if validationCursor>#validationIds then validationCursor=1 end
      local id=validationIds[validationCursor];validationCursor=validationCursor+1
      local lease=leases[id]
      if lease then
        local valid=owner(lease)
        if valid then for key,field in pairs(lease.fields) do
          if not same(read(lease,key),field.applied,key) then valid=false;break end
        end end
        if not valid then
          -- Yield only the conflicting lamp, not the entire level. The seen
          -- identity prevents later rescans from fighting its other owner.
          restoreLease(lease);leases[id]=nil;changed=true
          if pool[id] then pool[id].blocked=true end
          prioritized[id]=nil
        end
      end
    end
    if refresh then
      priorityElapsed=0
      changed=updatePriority(nearIds) or changed
    end
  end)
  if not ok then
    M.disable('Automatic lamp shadows stopped: '..tostring(why))
    return true
  end
  M.reason=string.format('Automatic native lamp shadows: %d supported lights inspected; %d background discovery checks left; %d unsupported skipped. Checks are not new shadow maps.',
    visited,math.max(0,#queue-cursor+1),skipped)
  return changed
end

function M.enable()
  if M.requested then return true, M.getStatus() end
  if next(leases) then return false, 'Restore the pending lamp settings first.' end
  local ok, result = pcall(function()
    assert(core_camera and type(core_camera.getPosition) == 'function', 'Camera position unavailable')
    local camera = core_camera.getPosition()
    assert(camera and camera.x and camera.y and camera.z, 'Camera position unavailable')
    local candidates, seen = {}, {}
    for _, class in ipairs({'SpotLight', 'PointLight'}) do
      local tokens = scenetree.findClassObjects(class)
      assert(type(tokens) == 'table', 'Lamp enumeration unavailable')
      for _, token in ipairs(tokens) do
        local readable, entry = pcall(function()
          local o = scenetree.findObject(token)
          if not o or o:getClassName() ~= class then return end
          local id = o:getID()
          if seen[id] then return end
          seen[id] = true
          local p = o:getPosition()
          local distance2 = (p.x-camera.x)^2 + (p.y-camera.y)^2 + (p.z-camera.z)^2
          if distance2 ~= distance2 or distance2 > 30*30 then return end
          local fields = o:getFields()
          -- Require advertised native fields: never create dynamic lookalikes.
          if type(fields) ~= 'table' or fields.castShadows == nil then return end
          if truth(o:getField('isEnabled', 0)) ~= true then return end
          local original = o:getField('castShadows', 0)
          if truth(original) == nil then return end
          local entry = {object=o,id=id,class=class,reader=o.getField,writer=o.setField,
            distance=math.sqrt(distance2),fields={},name=o:getName()}
          if not truth(original) then entry.fields.castShadows={original=original,wanted='1'} end
          if fields.texSize ~= nil then
            local size = o:getField('texSize', 0)
            if tonumber(size) and tonumber(size) > 0 and tonumber(size) < 1024 then
              entry.fields.texSize={original=size,wanted='1024'}
            end
          end
          return entry
        end)
        if readable and entry then candidates[#candidates+1] = entry end
      end
    end
    table.sort(candidates, function(a,b)
      if a.distance == b.distance then return a.id < b.id end
      return a.distance < b.distance
    end)
    assert(#candidates > 0, 'No readable, enabled native point/spot lamps within 30 m.')
    -- Fix selection until restore. No per-frame search or shadow-map churn.
    for i=1,math.min(4,#candidates) do
      local entry=candidates[i]
      selected[#selected+1]={id=entry.id,name=entry.name,class=entry.class,distance=entry.distance}
      if next(entry.fields) then leases[entry.id]=entry end
    end
    for _, lease in pairs(leases) do
      for key, field in pairs(lease.fields) do
        assert(same(read(lease,key),field.original,key), 'Lamp changed before shadow request')
        field.applied=field.wanted -- restoration can recover throw-after-write
        local wrote, accepted=pcall(lease.writer,lease.object,key,0,field.wanted)
        local observed=read(lease,key)
        field.applied=observed -- retain actual clamped native value for rollback
        assert(wrote and accepted ~= false and same(observed,field.wanted,key), 'Native lamp shadow write rejected')
      end
    end
    return #candidates
  end)
  if not ok then
    local restored = M.disable()
    if restored then M.reason = tostring(result) end
    return false, M.reason
  end
  M.requested = true
  M.reason = 'Native shadows requested for '..#selected..' nearby lamps; GPU output unverified. Restore before selecting a new location.'
  if not next(leases) then M.reason='Selected lamps already request native shadows at 1024 or higher; no fields changed. Missing shadows need further diagnosis.' end
  return true, M.getStatus()
end

function M.update(dt)
  if not M.requested then return end
  if automatic then return updateAutomatic(dt) end
  for _, lease in pairs(leases) do
    local ok, valid = pcall(function()
      if not owner(lease) then return false end
      for key, field in pairs(lease.fields) do
        if not same(read(lease,key),field.applied,key) then return false end
      end
      return true
    end)
    if not ok or not valid then M.disable('Lamp ownership changed; experiment stopped.');return end
  end
end

function M.getStatus()
  local pending, fields=0,0
  for _, lease in pairs(leases) do
    pending=pending+1;for _ in pairs(lease.fields) do fields=fields+1 end
  end
  local lights={}
  for i, light in ipairs(selected) do
    lights[i]={id=light.id,name=light.name,class=light.class,distance=light.distance}
  end
  local near={}
  for id in pairs(prioritized) do
    local entry=pool[id]
    if entry then near[#near+1]={id=id,name=entry.name,class=entry.class,
      priorityRequested=entry.fields.priority and entry.fields.priority.applied,
      mapRequested=entry.fields.texSize and entry.fields.texSize.applied} end
  end
  return {requested=M.requested,reason=M.reason,selected=lights,selectedCount=#lights,
    pendingRestore=pending>0,changedFields=fields,radius=not automatic and 30 or nil,maximumLights=not automatic and 4 or nil,
    automatic=automatic,processedLights=visited,pendingJobs=math.max(0,#queue-cursor+1),skippedLights=skipped,
    priorityAssist=priorityAssist,prioritizedLights=near,priorityRejected=priorityRejected,
    scanCycles=scanCycles,newLightsThisScan=newLightsThisScan,
    nearbyLookup=nearbyLookup,priorityRadius=NEAR_RADIUS,
    globalGraphicsSettingsChanged=false,lightColorOrIntensityChanged=false,gpuExecutionVerified=false}
end

function M.setPriorityAssist(value)
  if type(value)~='boolean' then return false end
  priorityAssist=value;priorityElapsed=1;priorityCamera=nil
  return true
end

function M.getNearbyReport()
  local result={lights={},note='Read-only native fields; not proof of allocated GPU shadow views or caster materials.'}
  local ok,why=pcall(function()
    local p=core_camera.getPosition()
    local entries={}
    for _,entry in pairs(pool) do
      local q=entry.position
      if q then
        local d=(p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2
        if d==d and d<=NEAR_RADIUS*NEAR_RADIUS then entries[#entries+1]={entry=entry,distance=math.sqrt(d)} end
      end
    end
    table.sort(entries,function(a,b)return a.distance<b.distance end)
    for i=1,math.min(12,#entries) do
      local entry=entries[i].entry
      local valid,light=pcall(function()
        if not owner(entry) then return nil end
        local light={id=entry.id,name=entry.name,class=entry.class,distance=entries[i].distance,
          ownershipYielded=entry.blocked==true,prioritized=prioritized[entry.id]==true,fields={}}
        local fields=entry.object:getFields()
        for _,key in ipairs({'isEnabled','castShadows','texSize','priority','shadowType','sourceRadius'}) do
          if fields[key]~=nil then light.fields[key]=read(entry,key) end
        end
        return light
      end)
      if valid and light then result.lights[#result.lights+1]=light end
    end
  end)
  if not ok then result.error=tostring(why) end
  return result
end

function M.isRequested() return M.requested end

-- Read-only, bounded handoff to the optional local haze experiment. Reuse the
-- selected native lamp identities; never launch a second whole-level scan.
function M.getVolumetricLights()
  local result={}
  if not automatic or not M.requested then return result end
  local p=cameraPosition();if not p then return result end
  local candidates={}
  for id in pairs(prioritized) do
    local entry=pool[id]
    local q=entry and entry.position
    if q and entry.class=='SpotLight' and not entry.blocked then
      candidates[#candidates+1]={entry=entry,d=(q.x-p.x)^2+(q.y-p.y)^2+(q.z-p.z)^2}
    end
  end
  table.sort(candidates,function(a,b)
    if a.d==b.d then return a.entry.id<b.entry.id end
    return a.d<b.d
  end)
  for _,candidate in ipairs(candidates) do
    if #result>=4 then break end
    local ok,light=pcall(function()
      local entry=candidate.entry
      if not owner(entry) or truth(read(entry,'isEnabled'))~=true then return end
      local fields=entry.object:getFields()
      for _,key in ipairs({'color','brightness','range','innerAngle','outerAngle'}) do
        if fields[key]==nil then return end
      end
      local function number(key)
        local value=tonumber(read(entry,key))
        assert(value and value==value and math.abs(value)<math.huge,'Invalid lamp scalar')
        return value
      end
      local color={}
      for value in tostring(read(entry,'color')):gmatch('[^%s]+') do color[#color+1]=tonumber(value) end
      for i=1,3 do assert(color[i] and color[i]>=0 and color[i]<math.huge,'Invalid lamp color') end
      local q=entry.object:getPosition()
      for _,v in ipairs({q.x,q.y,q.z}) do assert(type(v)=='number' and v==v and math.abs(v)<math.huge,'Invalid lamp position') end
      local d=entry.object:getTransform():getColumn(1)
      local n=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
      assert(n>0 and n<math.huge,'Invalid lamp direction')
      local range,brightness=number('range'),number('brightness')
      local inner,outer=number('innerAngle'),number('outerAngle')
      if range<=0 or brightness<=0 or inner<0 or outer<=inner or outer>=179 then return end
      return {id=entry.id,position={q.x,q.y,q.z},direction={d.x/n,d.y/n,d.z/n},
        range=math.min(range,80),color={math.min(color[1],8),math.min(color[2],8),math.min(color[3],8)},
        brightness=math.min(brightness,100),inner=math.cos(math.rad(inner*.5)),outer=math.cos(math.rad(outer*.5))}
    end)
    if ok and light then result[#result+1]=light end
  end
  return result
end

return M
