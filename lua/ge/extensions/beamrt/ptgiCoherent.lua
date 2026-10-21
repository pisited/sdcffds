-- Session-only staging lease for PTGI + Coherent. No native setting writes.
-- GI children execute with their root; each history remains owned by its renderer.
local M = {requested=false, reason='Combined rendering is disabled.'}
local leases = {}
local roots = {
  {'BeamRT_SurfelCacheFx',48}, {'BeamRT_ReceiverResponseFx',47}, {'BeamRT_GIFx',46}
}

function M.release()
  M.requested=false
  local clean=true
  for name, lease in pairs(leases) do
    local ok=pcall(function()
      if scenetree.findObject(name)==lease.object then
        lease.object:setField('renderTime',0,lease.time)
        lease.object:setField('renderBin',0,lease.bin)
        lease.object.renderPriority=lease.priority
      end -- never restore fields on a foreign replacement
    end)
    if ok then leases[name]=nil else clean=false end
  end
  return clean, clean and nil or 'PTGI stage restoration failed; retry disable.'
end

function M.prepare()
  if next(leases) then return false,'An existing PTGI stage lease must be released first.' end
  local ok, failure=pcall(function()
    -- Validate the entire set before editing any stage. Only disabled GI roots
    -- can be leased; no live partial graph is moved between render bins.
    for _, root in ipairs(roots) do
      local object=scenetree.findObject(root[1])
      assert(object and not object:isEnabled(),'Missing or still-active PTGI root: '..root[1])
      assert(tostring(object:getField('shader',0)):match('^BeamRT_'),'Unrecognized PTGI shader')
      leases[root[1]]={object=object,time=object:getField('renderTime',0),
        bin=object:getField('renderBin',0),priority=object.renderPriority}
    end
    for _, root in ipairs(roots) do
      local object=leases[root[1]].object
      object:setField('renderTime',0,'PFXBeforeBin')
      object:setField('renderBin',0,'AfterPostFX')
      object.renderPriority=root[2]
    end
  end)
  if not ok then
    local restored=M.release()
    return false,tostring(failure)..(restored and '' or '; stage restoration incomplete')
  end
  return true
end

function M.validate()
  for _, root in ipairs(roots) do
    local lease=leases[root[1]]
    local ok, valid=pcall(function()
      return lease and scenetree.findObject(root[1])==lease.object
        and lease.object:getField('renderTime',0)=='PFXBeforeBin'
        and lease.object:getField('renderBin',0)=='AfterPostFX'
        and tonumber(lease.object.renderPriority)==root[2]
    end)
    if not ok or not valid then return false,'PTGI stage lease lost or modified: '..root[1] end
  end
  return true
end

function M.getStatus(api)
  local valid, reason=M.validate()
  local coherent=api.getCoherentSsrStatus()
  local gi=scenetree.findObject('BeamRT_GIFx')
  local legacy=scenetree.findObject('BeamRT_ReflectionFx')
  local ok, active=pcall(function()
    return M.requested and valid and coherent.active and gi and gi:isEnabled()
      and not (legacy and legacy:isEnabled())
  end)
  return {requested=M.requested,active=ok and active==true,stageValid=valid,
    reason=M.requested and (valid and M.reason or reason) or M.reason,
    gpuExecutionVerified=false,gameAppearanceVerified=false}
end

return M
