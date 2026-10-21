-- Session-only staging lease for PTGI + Coherent. No native setting writes.
-- GI children execute with their root; each history remains owned by its renderer.
local M = {requested=false, reason='Combined rendering is disabled.'}
local leases = {}
local composeLease
M.sceneTarget = '#BeamRT_PTGI_LitScene'
M.namedHandoff = false -- opt-in until the named-target GPU route is validated in-game
function M.getSceneSource() return M.namedHandoff and M.sceneTarget or '$backBuffer' end
local roots = {
  {'BeamRT_SurfelCacheFx',48}, {'BeamRT_ReceiverResponseFx',47}, {'BeamRT_GIFx',46}
}

function M.hasLease() return next(leases)~=nil or composeLease~=nil end

function M.release()
  M.requested=false
  local clean=true
  if composeLease then
    local ok=pcall(function()
      if scenetree.findObject('BeamRT_ComposeFx')==composeLease.object then
        for key,value in pairs(composeLease.fields) do
          composeLease.object:setField(key,0,value)
          assert(composeLease.object:getField(key,0)==value,'PTGI scene target restoration rejected')
        end
      end
    end)
    if ok then composeLease=nil else clean=false end
  end
  for name, lease in pairs(leases) do
    local ok=pcall(function()
      if scenetree.findObject(name)==lease.object then
        if lease.object:isEnabled() then lease.object:disable() end
        lease.object:setField('renderTime',0,lease.time)
        lease.object:setField('renderBin',0,lease.bin)
        lease.object.renderPriority=lease.priority
      end -- never restore fields on a foreign replacement
    end)
    if ok then leases[name]=nil else clean=false end
  end
  if not clean then
    M.reason='PTGI stage restoration failed; retry disable.'
    return false,M.reason
  end
  M.reason='Combined rendering is disabled.'
  return true
end

function M.prepare()
  if M.hasLease() then return M.validate() end
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
    local compose=scenetree.findObject('BeamRT_ComposeFx')
    assert(compose and tostring(compose:getField('shader',0)):match('^BeamRT_'),'Missing PTGI scene producer')
    composeLease={object=compose,fields={}}
    for _,key in ipairs({'target','targetFormat','targetScale'}) do composeLease.fields[key]=compose:getField(key,0) end
    if M.namedHandoff then
      compose:setField('target',0,M.sceneTarget)
      compose:setField('targetFormat',0,'GFXFormatR16G16B16A16F')
      compose:setField('targetScale',0,'1 1')
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
  local outputOK,outputValid=pcall(function()
    return composeLease and scenetree.findObject('BeamRT_ComposeFx')==composeLease.object
      and composeLease.object:getField('target',0)==M.getSceneSource()
      and (not M.namedHandoff or (composeLease.object:getField('targetFormat',0)=='GFXFormatR16G16B16A16F'
        and composeLease.object:getField('targetScale',0)=='1 1'))
  end)
  if not outputOK or not outputValid then return false,'PTGI scene producer lease lost or modified.' end
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
    return M.requested and valid and coherent.active
      and coherent.options.hdrComposite==true and coherent.options.debugView==0
      and coherent.sceneColorSource==M.getSceneSource()
      and gi and gi:isEnabled()
      and not (legacy and legacy:isEnabled())
  end)
  return {requested=M.requested,active=ok and active==true,stageValid=valid,
    reason=M.requested and (valid and M.reason or reason) or M.reason,
    sceneTarget=M.getSceneSource(),sceneColorSource=coherent.sceneColorSource,namedHandoff=M.namedHandoff,
    gpuExecutionVerified=false,gameAppearanceVerified=false}
end

return M
