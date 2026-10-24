-- Matched-source diagnostic: native, reconstructed GI, frozen GI net change.
local M = {}
local active,lastResult
local owned={}
local prefix='BeamRT_SourceProbe'
local pauseToken='beamrt_reflection_source_probe'
local cases={
  {name='original',target=nil,source='#BeamRT_SourceProbeLive'},
  {name='native',target='#BeamRT_SourceProbeNative',source='#BeamRT_SourceProbeNative'},
  {name='live-GI',target='#BeamRT_SourceProbeLive',source='#BeamRT_SourceProbeLive'},
  {name='frozen-GI',target='#BeamRT_SourceProbeFrozen',source='#BeamRT_SourceProbeFrozen'},
}
local function main() return extensions and extensions.beamrt_main or beamrt_main end
local function rendererCompatible(m)
  local ok,status=pcall(function()
    if not m or type(m.getRendererCompatibilityStatus)~='function' then return nil end
    return m.getRendererCompatibilityStatus()
  end)
  return ok and type(status)=='table' and status.safe==true
end
local function obj(name) return scenetree.findObject(prefix .. name) end
local function logResult(level,s) if log then log(level,'BeamRT.SourceProbe',s) end end
local function checked(fn,...)
  local ok,result=pcall(fn,...)
  if not ok then error(result,0) end
  if result==false then error('source-probe state change rejected',0) end
  return result
end
local function camera()
  local p,q=core_camera.getPosition(),core_camera.getQuat()
  local v=RenderViewManagerInstance:getView('main')
  return {p.x,p.y,p.z,q.x,q.y,q.z,q.w,core_camera.getFovDeg(),v.resolution.x,v.resolution.y}
end
local function moved(reference)
  local now=camera();local d,dot=0,0
  for i=1,3 do d=d+(now[i]-reference[i])^2 end
  for i=4,7 do dot=dot+now[i]*reference[i] end
  return d>0.000004 or math.abs(dot)<0.99999999 or math.abs(now[8]-reference[8])>.025
    or now[9]~=reference[9] or now[10]~=reference[10]
end
local function register(object,name)
  if obj(name) then error('source-probe object exists: '..name,0) end
  object:registerObject(prefix..name);owned[#owned+1]=prefix..name;return object
end
local function shader(name,file,samplers)
  local s=createObject('ShaderData');s.DXVertexShaderFile=file;s.DXPixelShaderFile=file;s.pixVersion=5
  for i,sampler in ipairs(samplers) do s:setField('samplerNames',i-1,sampler) end
  return register(s,name)
end
local function effect(name,shaderName,inputs,target,priority)
  local e=createObject('PostEffect');e.allowReflectPass=false
  e:setField('shader',0,prefix..shaderName);e:setField('stateBlock',0,'BeamRT_ReflectionTemporalState')
  for i,input in ipairs(inputs) do e:setField('texture',i-1,input) end
  e:setField('target',0,target);e:setField('targetScale',0,'1 1')
  if target~='$backBuffer' then e:setField('targetFormat',0,'GFXFormatR32G32B32A32F') end
  if priority then e.isEnabled=false;e.renderPriority=priority;e:setField('renderTime',0,'PFXAfterDiffuse') end
  return register(e,name)
end
local function destroy()
  for i=#owned,1,-1 do local e=scenetree.findObject(owned[i]);if e then e:delete() end end
  owned={}
  for _,name in ipairs({'NativeFx','LiveFx','DeltaFx','FrozenFx','DisplayFx'}) do rawset(_G,prefix..name..'Callbacks',nil) end
end
local function create(run)
  shader('CopyShader','shaders/beamrt/beamrtCopyP_v005.hlsl',{'inputTex'})
  shader('DeltaShader','shaders/beamrt/beamrtReflectionSourceDeltaP_v001.hlsl',{'liveTex','nativeTex'})
  shader('FrozenShader','shaders/beamrt/beamrtReflectionSourceFrozenP_v001.hlsl',{'nativeTex','deltaTex'})
  shader('DisplayShader','shaders/beamrt/beamrtReflectionSourceDisplayP_v001.hlsl',{'sourceTex','reflectionTex','deltaTex'})
  effect('NativeFx','CopyShader',{'$backBuffer'},'#BeamRT_SourceProbeNative',10003.5)
  local live=effect('LiveFx','CopyShader',{'$backBuffer'},'#BeamRT_SourceProbeLive',10001.875)
  local delta=effect('DeltaFx','DeltaShader',{'#BeamRT_SourceProbeLive','#BeamRT_SourceProbeNative'},'#BeamRT_SourceProbeDelta')
  live:add(delta)
  effect('FrozenFx','FrozenShader',{'#BeamRT_SourceProbeNative','#BeamRT_SourceProbeDelta'},'#BeamRT_SourceProbeFrozen',10001.78125)
  effect('DisplayFx','DisplayShader',{'#BeamRT_SourceProbeLive','#BeamRT_TemporalReflection','#BeamRT_SourceProbeDelta'},'$backBuffer',9998.5)
  for _,name in ipairs({'NativeFx','LiveFx','DeltaFx'}) do
    local callbacks={onEnabled=function() return true end}
    callbacks.preProcess=function()
      if active==run then run.copies[name]=run.copies[name]+1 end
    end
    rawset(_G,prefix..name..'Callbacks',callbacks)
  end
  for _,name in ipairs({'FrozenFx','DisplayFx'}) do
    rawset(_G,prefix..name..'Callbacks',{onEnabled=function() return true end})
  end
  checked(obj('NativeFx').enable,obj('NativeFx'))
  checked(obj('LiveFx').enable,obj('LiveFx'))
  checked(obj('FrozenFx').enable,obj('FrozenFx'))
end
local function bindCase(run)
  local c=cases[run.case]
  checked(main().setReflectionSourceProbeTarget,c.target)
  obj('DisplayFx'):setField('texture',0,c.source)
  obj('DisplayFx'):setShaderConst('$reflectionStrength',run.saved.settings.reflectionStrength)
  run.view=0;run.elapsed=0;run.phase='warmup';run.frozenReady=false
  logResult('I','Source case '..c.name..'; GI stays enabled, SSR source only changes.')
end
local function finish(outcome,reason)
  local run=active;if not run then return false end
  active=nil;local failures={}
  local function attempt(label,fn,...)
    local ok,r=pcall(fn,...);if not ok or r==false then failures[#failures+1]=label end
  end
  for _,name in ipairs({'NativeFx','LiveFx','FrozenFx','DisplayFx'}) do local e=obj(name);if e then pcall(function() e:disable() end) end end
  local m=main()
  if m and run.mutated then
    attempt('source binding',m.setReflectionSourceProbeTarget,nil)
    attempt('settings',m.applySettings,run.saved.settings)
    attempt('GI diagnostic',m.setLightingDiagnostic,run.saved.state.diagnostic or 'off')
    attempt('ray diagnostic',m.setRayHitDiagnostic,run.saved.state.rayHitDiagnostic or 'off')
    attempt('reflection diagnostic',m.restoreReflectionDiagnosticState,run.saved.reflectionDiagnostic)
    attempt('mode',m.setMode,run.saved.settings.mode)
    attempt('enabled',run.saved.state.enabled and m.enable or m.disable)
    attempt('tuner',run.saved.state.tunerOpen and m.openTuner or m.closeTuner)
  elseif run.mutated then failures[#failures+1]='BeamRT unavailable' end
  if run.pause then attempt('pause token',run.pause.popPauseRequest,pauseToken) end
  destroy()
  lastResult={active=false,outcome=#failures==0 and outcome or 'error',reason=reason,
    directory=run.directory,restored=#failures==0,restorationFailures=failures,captures=run.images,copies=run.copies}
  local manifest={version=1,beamrtVersion=run.saved.version,original=run.saved,result=lastResult,
    meaning='GI remains in displayed base in all cases; only SSR/color-pyramid source changes. Original source image is after-GI proxy, not shader input readback.',
    frozen='Matched signed linear-HDR after-GI minus before-GI net change held fixed; recompose with LIVE native color. Includes GI visibility/darkening, not guessed native-specular subtraction.',
    limitations='Frozen source retains GI spatial noise. Native source/exposure can vary; static spatial artifacts can persist without GI temporal variation. Snapshots do not prove normal $backBuffer cache routing by themselves.'}
  local ok,r=pcall(jsonWriteFile,run.directory..'/manifest.json',manifest,true)
  if not ok or r==false then logResult('E','Failed to write source-probe manifest') end
  logResult(lastResult.restored and 'I' or 'E','Source probe '..lastResult.outcome..': '..run.directory..'; restored='..tostring(lastResult.restored))
  return lastResult.restored
end
function M.start()
  if active then return false end
  local m=main()
  if not m or type(m.setReflectionSourceProbeTarget)~='function' then logResult('E','Load BeamRT v0.101 first');return false end
  if not rendererCompatible(m) then logResult('W','Renderer compatibility is unverified; source probe refused.');return false end
  if m.getReflectionSourceProbeTarget()~=nil then logResult('E','Another source override is active');return false end
  if m.getLightingAuditStatus().active or m.getReflectionConvergenceEnabled()
    or extensions and extensions.beamrt_reflectionConvergence and extensions.beamrt_reflectionConvergence.getStatus().active then
    logResult('E','Another reflection/lighting experiment is running');return false
  end
  local ok,api=pcall(require,'screenshot')
  if not ok or type(api.createScreenshotTracked)~='function' or type(api.getScreenshotJobsSnapshotJson)~='function' then return false end
  local pause=simTimeAuthority
  if not pause or type(pause.pushPauseRequest)~='function' or type(pause.popPauseRequest)~='function' or type(pause.getPause)~='function' then return false end
  local saved={settings=m.getSettings(),state=m.getLightingAuditState(),reflectionDiagnostic=m.getReflectionDiagnosticState(),version=m.getVersion(),
    originalTraceSource=scenetree.findObject('BeamRT_ReflectionFx'):getField('texture',2),physicsWasPaused=pause.getPause()}
  local base='/screenshots/beamrt-source-probe/'..os.date('%Y-%m-%d_%H-%M-%S')
  local directory,suffix=base,0
  while FS:directoryExists(directory) do suffix=suffix+1;directory=base..'_'..suffix end
  FS:directoryCreate(directory,true);if not FS:directoryExists(directory) then return false end
  local run={saved=saved,pause=pause,api=api,directory=directory,case=1,view=0,phase='warmup',elapsed=0,age=0,poll=0,
    images={},copies={NativeFx=0,LiveFx=0,DeltaFx=0}}
  active=run
  local setupOk,err=pcall(function()
    checked(pause.pushPauseRequest,pauseToken);if not pause.getPause() then error('physics pause denied',0) end
    run.camera=camera();run.mutated=true
    checked(m.closeTuner);checked(m.setReflectionDiagnostic,'off',false);checked(m.setLightingDiagnostic,'off');checked(m.setRayHitDiagnostic,'off')
    checked(m.setMode,'lighting');checked(m.setReflectionSamplingMode,'ggx');checked(m.setReflectionReconstruction,'playable')
    checked(m.setReflectionsEnabled,true);checked(m.enable)
    create(run);bindCase(run)
  end)
  if not setupOk then finish('error',tostring(err));return false end
  logResult('I','Source probe started; close console, keep camera still. Physics temporarily paused; 14 captures, settings restored afterward.')
  return true
end
function M.onPreRender(dtReal)
  local run=active;if not run then return end
  local ok,err=pcall(function()
    local m=main()
    if not rendererCompatible(m) then error('renderer compatibility changed; source probe cancelled',0) end
    if moved(run.camera) then error('camera/FOV/resolution moved',0) end
    if m.getLightingAuditStatus().active or m.getReflectionSamplingState().frozen or m.getLightingAuditState().mode~='lighting'
      or m.getReflectionSamplingState().name~='ggx' or m.getReflectionReconstructionState().name~='playable' then error('render selection changed',0) end
    local dt=tonumber(dtReal) or 0;if dt~=dt or dt<0 or dt==math.huge then dt=0 end
    run.elapsed=run.elapsed+dt;run.age=run.age+dt
    if run.age>90 then error('source-probe timeout',0) end
    if run.phase=='warmup' then
      if run.view==0 and run.elapsed<2 then return end
      if run.copies.NativeFx<1 or run.copies.LiveFx<1 or run.copies.DeltaFx<1 then return end
      if run.case==4 and not run.frozenReady then
        obj('DeltaFx').skip=true;run.frozenReady=true;run.freezeCopies=run.copies.DeltaFx
        run.elapsed=0;checked(m.resetReflectionHistory);return
      end
      if run.case==4 and run.copies.DeltaFx~=run.freezeCopies then error('frozen GI capture continued updating',0) end
      if run.elapsed<1 then return end
      local viewName=({'beauty','source','SSR-contribution','frozen-GI-net-A','frozen-GI-net-B'})[run.view+1]
      local filename=FS:expandFilename(run.directory..'/'..string.format('%02d-%s-%s',(run.case-1)*3+run.view+1,cases[run.case].name,viewName))
      run.job=run.api.createScreenshotTracked({filename=filename,writeJPG=false,superSampling=1,tiles=1,overlap=0,rescaleFactor=1,
        upload=false,jobType='full',bufferType='color',objectTypeWhitelistMask=0,objectTypeBlacklistMask=0,
        shadowCasterObjectTypeWhitelistMask=0,shadowCasterObjectTypeBlacklistMask=0})
      if not run.job or run.job==0 then error('screenshot rejected',0) end
      run.pending={filename=filename..'.png',case=cases[run.case].name,view=viewName,copies={native=run.copies.NativeFx,live=run.copies.LiveFx,delta=run.copies.DeltaFx},
        selectedTraceSource=scenetree.findObject('BeamRT_ReflectionFx'):getField('texture',2),sampling=m.getReflectionSamplingState(),gi=m.getProgressiveStatus()}
      run.phase='saving';run.elapsed=0;run.poll=0;return
    end
    if run.elapsed>15 then error('screenshot timeout',0) end
    run.poll=run.poll+dt;if run.poll<.1 then return end;run.poll=0
    local jobs=jsonDecode(run.api.getScreenshotJobsSnapshotJson());if type(jobs)~='table' then error('screenshot status unavailable',0) end
    for _,job in ipairs(jobs) do if job.id==run.job then
      if job.phase=='error' or job.result~=nil and job.result~=0 then error('screenshot failed',0) end
      if job.phase~='done' or job.result~=0 then return end
      local filename=type(job.filename)=='string' and job.filename~='' and job.filename or run.pending.filename
      if not FS:fileExists(filename) then return end
      run.pending.filename=filename;run.images[#run.images+1]=run.pending
      run.view=run.view+1;run.elapsed=0;run.phase='warmup'
      if run.view>(run.case==4 and 4 or 2) then
        run.case=run.case+1;if run.case>#cases then finish('complete');return end
        checked(obj('DisplayFx').disable,obj('DisplayFx'));bindCase(run)
      else
        obj('DisplayFx'):setShaderConst('$sourceDisplay',run.view)
        checked(obj('DisplayFx').enable,obj('DisplayFx'))
      end
      return
    end end
  end)
  if not ok then finish('error',tostring(err)) end
end
function M.cancel(reason) return finish('cancelled',reason or 'cancelled') end
function M.getStatus()
  return active and {active=true,directory=active.directory,case=cases[active.case].name,view=active.view,phase=active.phase} or lastResult or {active=false}
end
function M.onExtensionLoaded() if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end;M.start() end
function M.onExtensionUnloaded() M.cancel('source probe unloaded');destroy() end
return M
