-- On-demand, read-only vehicle prop telemetry. No update hook or light writes.
-- Activation/scaling follows the shipped vehicle/props.lua control path.
local M={protocol=2}
local function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function clamp(v,a,b)return math.min(b,math.max(a,v))end
local function color(value)
  if type(value)=='table' then return {value.r,value.g,value.b} end
  if type(value)=='string' and value:match('^#%x%x%x%x%x%x%x%x$') then
    return {tonumber(value:sub(2,3),16),tonumber(value:sub(4,5),16),tonumber(value:sub(6,7),16)}
  end
end
local function light(p)
  if p.disabled or p.hidden or (p.mesh~='SPOTLIGHT' and p.mesh~='POINTLIGHT') then return end
  local val=electrics.values[p.func]
  if type(val)=='boolean' then val=val and 1 or 0 end
  if not finite(val) or val<=0 or not finite(p.pid) or p.pid<0 then return end
  local c=color(p.lightColor);if not c then return end
  local brightness=p.lightBrightness
  -- Same authored-unit conversions as common/jbeam/sections/meshs.lua.
  if p.mesh=='SPOTLIGHT' and p.lightIntensityCd then brightness=p.lightIntensityCd/5000
  elseif p.mesh=='POINTLIGHT' and p.lightIntensityLm then brightness=p.lightIntensityLm/(5000*4*math.pi) end
  brightness=brightness or 1
  if not finite(brightness) or brightness<=0 then return end
  if p.scaleLight then
    local lo,hi=p.scaleLightBrightnessMinInput or 0,p.scaleLightBrightnessMaxInput or 1
    if not finite(lo) or not finite(hi) or hi<=lo then return end
    brightness=brightness*clamp((val-lo)/(hi-lo),0,1)
    for i,key in ipairs({'scaleLightColorOffsetRed','scaleLightColorOffsetGreen','scaleLightColorOffsetBlue'}) do
      local offset=p[key] or ({0,60,80})[i]
      if not finite(c[i]) or not finite(offset) then return end
      c[i]=c[i]-offset*(1-val)
    end
  else brightness=brightness*clamp(val,0,1) end
  for i=1,3 do if not finite(c[i]) then return end;c[i]=clamp(c[i]/255,0,1) end
  local range=p.lightRange or 10
  if not finite(range) or range<=0 or brightness<=0 then return end
  local inner,outer=p.lightInnerAngle or 40,p.lightOuterAngle or 45
  if p.mesh=='SPOTLIGHT' and (not finite(inner) or not finite(outer) or inner<0 or outer<=inner or outer>=179) then return end
  return {pid=p.pid,kind=p.mesh=='SPOTLIGHT' and 'spot' or 'point',color=c,
    brightness=clamp(brightness,0,100),range=math.min(range,80),inner=inner,outer=outer}
end
function M.sample(token,sequence)
  if type(token)~='string' or #token>128 or not finite(sequence) or sequence~=math.floor(sequence) then return end
  local lights,red,neutral,checked={},{},{},0
  for _,p in pairs(v and v.data and v.data.props or {}) do
    checked=checked+1;if checked>512 then break end
    local ok,item=pcall(light,p)
    if ok and item then
      local c=item.color
      local bucket=c[1]>.05 and c[1]>1.75*math.max(c[2],c[3]) and red or neutral
      bucket[#bucket+1]=item
    end
  end
  table.sort(red,function(a,b)return a.pid<b.pid end)
  table.sort(neutral,function(a,b)return a.pid<b.pid end)
  for i=1,math.min(16,#red) do lights[#lights+1]=red[i] end
  for i=1,math.min(32-#lights,#neutral) do lights[#lights+1]=neutral[i] end
  for i=17,#red do if #lights>=32 then break end;lights[#lights+1]=red[i] end
  local packet={protocol=M.protocol,token=token,sequence=sequence,vehicleId=obj:getID(),lights=lights}
  -- serialize quotes data; neither prop names nor payload text becomes code.
  obj:queueGameEngineLua('if __BeamRTVehicleHazeSink then __BeamRTVehicleHazeSink('..serialize(packet)..') end')
  return packet -- also permits deterministic offline tests
end
return M
