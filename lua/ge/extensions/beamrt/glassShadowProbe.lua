-- Opt-in native window-shadow eligibility probe, NOT transmission rendering.
-- Changes only castShadows on live window Materials used by the player vehicle.
-- Native materials are shared: other instances using those materials are affected.
local M = {}
local leases = {}
local active = false
local vehicle
local report = {reason='Window shadow probe is off.', candidates={}, inspected=0, alreadyCasting=0}

local function field(object, name)
  local ok, value = pcall(object.getField, object, name, 0)
  if ok and value ~= nil then return tostring(value) end
end
local function boolean(value)
  if value=='1' or value=='true' then return true end
  if value=='0' or value=='false' then return false end
end
local function find(name)
  local ok, object = pcall(function() return scenetree.findObject(name) end)
  if ok then return object end
end
local function player()
  local ok, object = pcall(function() return be:getPlayerVehicle(0) end)
  if ok then return object end
end
local function filename(object)
  local ok, value = pcall(function() return object:getFilename() end)
  if ok and type(value)=='string' then return value:gsub('\\','/'):lower() end
end
local function isMaterial(object)
  local ok, tag = pcall(function() return object.___type end)
  if ok and type(tag)=='string' and tag~='' then return tag=='class<Material>' end
  local good, class = pcall(function() return object:getClassName() end)
  return good and class=='Material'
end
local function windowName(name)
  -- Deliberately narrow stock-style identities. Never a generic "glass" scan:
  -- that would also enable headlamp, beacon, instrument and building casters.
  for _,token in ipairs({'light','lamp','beacon','instrument','gauge','lens','mirror'}) do
    if name:find(token,1,true) then return false end
  end
  return name:match('_glass$') or name:match('_glass_int$')
    or name:match('_glass_dmg$') or name:match('_glass_dmg_int$')
    or name:match('_windshield$') or name:match('_windscreen$')
end
local function eligible(name, object)
  if type(name)~='string' or not windowName(name:lower()) or not object or not isMaterial(object) then return false end
  local path=filename(object)
  if not path or not ('/'..path):find('/vehicles/',1,true) then return false end
  local map=field(object,'mapTo')
  if map~=name or boolean(field(object,'translucent'))~=true
    or boolean(field(object,'alphaTest'))~=false
    or boolean(field(object,'castShadows'))==nil then return false end
  -- Glowing lenses and layered special materials are outside this first test.
  local layerText=field(object,'activeLayers')
  local layers=(layerText==nil or layerText=='') and 1 or tonumber(layerText)
  if layers~=1 then return false end
  for i=0,3 do
    local ok, value=pcall(object.getField,object,'emissive',i)
    if ok and boolean(tostring(value))==true then return false end
  end
  return true
end

function M.inspect()
  if active or #leases>0 then return false,'Restore the current probe before inspecting another vehicle.' end
  vehicle=player()
  report={reason='No player vehicle.', candidates={}, inspected=0, alreadyCasting=0}
  if not vehicle then return false,report.reason end
  local ok, names=pcall(vehicle.getMeshMaterialNames,vehicle)
  if not ok or type(names)~='table' then report.reason='Vehicle material names unavailable.';return false,report.reason end
  local unique={}
  for _,name in pairs(names) do
    report.inspected=report.inspected+1
    if report.inspected>512 then report.reason='Vehicle material budget exceeded; nothing changed.';report.candidates={};return false,report.reason end
    if type(name)=='string' and not unique[name] then
      unique[name]=true
      local object=find(name)
      if eligible(name,object) then
        report.candidates[#report.candidates+1]=name
        if boolean(field(object,'castShadows')) then report.alreadyCasting=report.alreadyCasting+1 end
      end
    end
  end
  table.sort(report.candidates)
  if #report.candidates>64 then report.candidates={};report.reason='Window material budget exceeded; nothing changed.';return false,report.reason end
  report.reason=#report.candidates>0 and 'Window materials identified; nothing changed. Native opacity handling is unverified.'
    or 'No supported live vehicle window materials. No name-only override was applied.'
  return #report.candidates>0,report.reason
end

function M.disable(reason)
  active=false
  local pending={}
  for _,lease in ipairs(leases) do
    local object=find(lease.name)
    -- Never write to a replacement Material or clobber a subsequent edit.
    if object==lease.object then
      local current=field(object,'castShadows')
      if boolean(current)==true or current==lease.original then
        local ok=pcall(function()
          if current~=lease.original then object:setField('castShadows',0,lease.original) end
          object:reload()
          assert(field(object,'castShadows')==lease.original,'restore readback mismatch')
        end)
        if not ok then pending[#pending+1]=lease end
      end
    end
  end
  leases=pending
  report.reason=#pending>0 and 'Window material restoration failed; retry Restore. Ownership retained.'
    or (reason or 'Original window shadow declarations restored.')
  return #pending==0,report.reason
end

function M.enable()
  if active then return true,report.reason end
  if #leases>0 then return false,'Retry Restore before enabling another probe.' end
  local ok,why=M.inspect();if not ok then return false,why end
  if #report.candidates==report.alreadyCasting then
    report.reason='These windows already request native shadows. Nothing changed; the native renderer may exclude transparent casters.'
    return false,report.reason
  end
  local changed,err=pcall(function()
    for _,name in ipairs(report.candidates) do
      local object=find(name)
      assert(player()==vehicle and eligible(name,object),'Vehicle/material changed during inspection')
      if boolean(field(object,'castShadows'))==false then
        assert(type(object.reload)=='function','Material reload API unavailable')
        local lease={name=name,object=object,original=field(object,'castShadows'),owned='1'}
        leases[#leases+1]=lease -- retain rollback even if setter/reload throws
        object:setField('castShadows',0,'1')
        local value=field(object,'castShadows')
        assert(boolean(value)==true,'Native castShadows write rejected')
        lease.owned=value
        object:reload()
        assert(field(object,'castShadows')==value,'Native reload rejected shadow request')
      end
    end
  end)
  if not changed then
    local restored=M.disable()
    if restored then report.reason='Window shadow probe failed; restored originals: '..tostring(err) end
    return false,report.reason
  end
  active=true
  report.reason='Native window shadow requests ON. GPU result unverified: may be ignored or cast solid shadows. Not tinted transmission.'
  return true,report.reason
end

function M.update()
  if not active then return end
  if player()~=vehicle then M.disable('Player vehicle changed; original window shadows restored.');return end
  for _,lease in ipairs(leases) do
    if find(lease.name)~=lease.object or field(lease.object,'castShadows')~=lease.owned
      or not eligible(lease.name,lease.object) then
      M.disable('Window material changed; probe stopped. Subsequent edits preserved.');return
    end
  end
end
function M.getStatus()
  local names={};for i,name in ipairs(report.candidates) do names[i]=name end
  return {enabled=active,reason=report.reason,candidates=names,inspected=report.inspected,
    alreadyCasting=report.alreadyCasting,owned=#leases,pendingRestore=not active and #leases or 0,
    partialTransmissionImplemented=false,tintedShadowsImplemented=false,gpuExecutionVerified=false,
    scope='shared native window Materials used by the selected player vehicle',
    fieldChanged='castShadows',opacityChanged=false,bodyMaterialsChanged=false,shaderChanges=false}
end
return M
