-- Isolated 128-frame reference, not a gameplay denoiser or saved photo mode.
local M = {}
local active, lastResult
local prefix = 'BeamRT_Convergence'
local pauseToken = 'beamrt_reflection_convergence'
local owned = {}
local captures = {
  {name='01-playable-source-filter-off', display=0},
  {name='02-raw-128-beauty', display=0},
  {name='03-raw-128-contribution', display=1},
  {name='04-relative-standard-deviation', display=2},
  {name='05-coverage-unknown-accepted-knownzero', display=3},
  {name='06-accepted-dark-rate', display=4},
  {name='07-sample-count-128', display=5},
}

local function mainModule() return extensions and extensions.beamrt_main or beamrt_main end
local function report(level, message) if log then log(level, 'BeamRT.Convergence', message) end end
local function checked(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then error(result, 0) end
  if result == false then error('convergence state change rejected', 0) end
  return result
end
local function object(name) return scenetree.findObject(prefix .. name) end
local function camera()
  local p, q = core_camera.getPosition(), core_camera.getQuat()
  local view = RenderViewManagerInstance:getView('main')
  return {p.x,p.y,p.z,q.x,q.y,q.z,q.w,core_camera.getFovDeg(),view.resolution.x,view.resolution.y}
end
local function cameraMoved(before)
  local now = camera()
  local distance, dot = 0, 0
  for i=1,3 do distance=distance+(now[i]-before[i])^2 end
  for i=4,7 do dot=dot+now[i]*before[i] end
  return distance > 0.000004 or math.abs(dot) < 0.99999999 or math.abs(now[8]-before[8]) > 0.025
    or now[9] ~= before[9] or now[10] ~= before[10]
end
local function destroy()
  for i=#owned,1,-1 do
    local obj=scenetree.findObject(owned[i])
    if obj then obj:delete() end
  end
  owned={}
  rawset(_G,prefix .. 'MeanFxCallbacks',nil)
end
local function register(obj,name)
  if scenetree.findObject(prefix .. name) then error('convergence object already exists: ' .. name,0) end
  obj:registerObject(prefix .. name)
  owned[#owned+1]=prefix .. name
  return obj
end
local function shader(name,file,samplers)
  local obj=createObject('ShaderData')
  obj.DXVertexShaderFile=file;obj.DXPixelShaderFile=file;obj.pixVersion=5.0
  for i,sampler in ipairs(samplers) do obj:setField('samplerNames',i-1,sampler) end
  return register(obj,name)
end
local function effect(name,shaderName,inputs,target,format)
  local obj=createObject('PostEffect')
  obj.allowReflectPass=false
  obj:setField('shader',0,prefix .. shaderName)
  obj:setField('stateBlock',0,'BeamRT_ReflectionTemporalState')
  for i,input in ipairs(inputs) do obj:setField('texture',i-1,input) end
  obj:setField('target',0,target)
  obj:setField('targetScale',0,'1 1')
  if format then obj:setField('targetFormat',0,format) end
  return obj
end
local function create(run)
  shader('MeanShader','shaders/beamrt/beamrtReflectionConvergenceMeanP_v001.hlsl',
    {'currentTex','meanHistoryTex','prepassTex','depthTex'})
  shader('MomentsShader','shaders/beamrt/beamrtReflectionConvergenceMomentsP_v001.hlsl',
    {'currentTex','meanHistoryTex','momentHistoryTex','currentMeanTex'})
  shader('DisplayShader','shaders/beamrt/beamrtReflectionConvergenceDisplayP_v001.hlsl',
    {'sceneTex','meanTex','momentsTex'})
  shader('CopyShader','shaders/beamrt/beamrtCopyP_v005.hlsl',{'inputTex'})
  local mean=effect('MeanFx','MeanShader',{'#BeamRT_CurrentReflection','#BeamRT_ConvergenceMeanHistory',
    '#prepass[RT0]','#prepass[Depth]'},'#BeamRT_ConvergenceMean','GFXFormatR32G32B32A32F')
  mean.isEnabled=false;mean.renderPriority=10000.5
  mean:setField('renderTime',0,'PFXAfterDiffuse')
  local moments=register(effect('MomentsFx','MomentsShader',{'#BeamRT_CurrentReflection',
    '#BeamRT_ConvergenceMeanHistory','#BeamRT_ConvergenceMomentHistory','#BeamRT_ConvergenceMean'},
    '#BeamRT_ConvergenceMoments','GFXFormatR32G32B32A32F'),'MomentsFx')
  local display=register(effect('DisplayFx','DisplayShader',{'$backBuffer','#BeamRT_ConvergenceMean',
    '#BeamRT_ConvergenceMoments'},'$backBuffer'),'DisplayFx')
  local copyMean=register(effect('MeanCopyFx','CopyShader',{'#BeamRT_ConvergenceMean'},
    '#BeamRT_ConvergenceMeanHistory','GFXFormatR32G32B32A32F'),'MeanCopyFx')
  local copyMoments=register(effect('MomentCopyFx','CopyShader',{'#BeamRT_ConvergenceMoments'},
    '#BeamRT_ConvergenceMomentHistory','GFXFormatR32G32B32A32F'),'MomentCopyFx')
  -- Both accumulations read OLD mean/moments before either history copy writes.
  mean:add(moments);moments:add(display);display:add(copyMean);copyMean:add(copyMoments)
  register(mean,'MeanFx')
  local callbacks={onEnabled=function() return true end}
  callbacks.preProcess=function()
    if active ~= run then return end
    run.draws=run.draws+1
    local valid=run.draws>1 and 1 or 0
    object('MeanFx'):setShaderConst('$experimentHistoryValid',valid)
    object('MeanFx'):setShaderConst('$reflectionMaxRoughness',run.saved.settings.reflectionMaxRoughness)
    object('MomentsFx'):setShaderConst('$experimentHistoryValid',valid)
    object('DisplayFx'):setShaderConst('$experimentDisplay',captures[run.stage].display)
    object('DisplayFx'):setShaderConst('$reflectionStrength',run.saved.settings.reflectionStrength)
  end
  callbacks.setShaderConsts=function()
    if active ~= run then return end
    object('DisplayFx'):setShaderConst('$experimentDisplay',captures[run.stage].display)
    object('DisplayFx'):setShaderConst('$reflectionStrength',run.saved.settings.reflectionStrength)
  end
  rawset(_G,prefix .. 'MeanFxCallbacks',callbacks)
end

local function finish(outcome,reason)
  local run=active
  if not run then return false end
  active=nil
  local failures={}
  local function attempt(label,fn,...)
    local ok,result=pcall(fn,...)
    if not ok or result==false then failures[#failures+1]=label end
  end
  local mean=object('MeanFx');if mean then pcall(function() mean:disable() end) end
  local main=mainModule()
  if main and run.mainMutated then
    attempt('diagnostic gate',main.setReflectionConvergenceEnabled,false)
    attempt('settings',main.applySettings,run.saved.settings)
    attempt('GI diagnostic',main.setLightingDiagnostic,run.saved.state.diagnostic or 'off')
    attempt('ray diagnostic',main.setRayHitDiagnostic,run.saved.state.rayHitDiagnostic or 'off')
    attempt('reflection diagnostic',main.restoreReflectionDiagnosticState,run.saved.reflectionDiagnostic)
    attempt('mode',main.setMode,run.saved.settings.mode)
    attempt('enabled',run.saved.state.enabled and main.enable or main.disable)
    attempt('tuner',run.saved.state.tunerOpen and main.openTuner or main.closeTuner)
  elseif run.mainMutated then failures[#failures+1]='BeamRT unavailable' end
  if run.pause then attempt('pause token',run.pause.popPauseRequest,pauseToken) end
  destroy()
  lastResult={active=false,outcome=outcome,reason=reason,directory=run.directory,
    restored=#failures==0,restorationFailures=failures,draws=run.draws,captures=run.images}
  if #failures>0 then lastResult.outcome='error' end
  local manifest={version=1,beamrtVersion=run.saved.version,result=lastResult,original=run.saved,
    samplesPerEligiblePixel=128,
    estimand='Mean of confidence/BRDF-weighted VISIBLE SSR addition. Unknown misses contribute zero only to this term, not black physical environment radiance.',
    comparison='SSR-only native scene; GI disabled for both stages, source color pyramid OFF in both. Same selected near-mirror approximation; no raw spatial filtering, reprojection or history clamps.',
    variance='GPU M1/M2 of raw weighted linear HDR sample; displayed as CV/(1+CV), not numerical float export.',
    categories='Coverage R=unknown miss rate G=accepted geometry rate B=known BRDF-domain zero rate; dark-rate image uses accepted weighted radiance <=1e-6.'}
  local ok,result=pcall(jsonWriteFile,run.directory .. '/manifest.json',manifest,true)
  if not ok or result==false then report('E','Could not write convergence manifest.') end
  report(lastResult.restored and 'I' or 'E','Convergence ' .. lastResult.outcome .. ': ' .. run.directory
    .. '; restored=' .. tostring(lastResult.restored) .. (reason and '; ' .. reason or ''))
  return lastResult.restored
end

function M.start()
  if active then return false end
  local main=mainModule()
  if not main or type(main.setReflectionConvergenceEnabled)~='function' then
    report('E','Load BeamRT v0.100 before starting convergence.');return false
  end
  if main.getReflectionConvergenceEnabled() then report('E','Another raw convergence gate is already active.');return false end
  if main.getLightingAuditStatus().active then report('E','Finish the current lighting audit first.');return false end
  local ok,api=pcall(require,'screenshot')
  if not ok or type(api.createScreenshotTracked)~='function' or type(api.getScreenshotJobsSnapshotJson)~='function' then
    report('E','Tracked screenshot API unavailable.');return false
  end
  local pause=simTimeAuthority
  if not pause or type(pause.pushPauseRequest)~='function' or type(pause.popPauseRequest)~='function'
    or type(pause.getPause)~='function' then report('E','Native pause-token API unavailable.');return false end
  local saved={settings=main.getSettings(),state=main.getLightingAuditState(),
    reflectionDiagnostic=main.getReflectionDiagnosticState(),version=main.getVersion()}
  saved.physicsWasPaused=pause.getPause()
  local base='/screenshots/beamrt-convergence/' .. os.date('%Y-%m-%d_%H-%M-%S')
  local directory,suffix=base,0
  while FS:directoryExists(directory) do suffix=suffix+1;directory=base .. '_' .. suffix end
  FS:directoryCreate(directory,true)
  if not FS:directoryExists(directory) then report('E','Cannot create convergence directory.');return false end
  active={saved=saved,directory=directory,api=api,pause=pause,stage=1,phase='warmup',
    elapsed=0,pollElapsed=0,age=0,draws=0,images={}}
  local run=active
  local setupOk,err=pcall(function()
    checked(pause.pushPauseRequest,pauseToken)
    if not pause.getPause() then error('Physics pause not allowed; test cancelled.',0) end
    run.camera=camera()
    run.mainMutated=true
    checked(main.closeTuner)
    checked(main.setReflectionDiagnostic,'off',false)
    checked(main.setRayHitDiagnostic,'off')
    checked(main.setLightingDiagnostic,'off')
    checked(main.setMode,'reflections')
    checked(main.setReflectionSamplingMode,'ggx')
    checked(main.setReflectionReconstruction,'playable')
    checked(main.setReflectionColorFilterEnabled,false)
    checked(main.enable)
    create(run)
  end)
  if not setupOk then finish('error',tostring(err));return false end
  report('I','Convergence started: physics temporarily paused; keep camera still. Seven captures; no permanent setting changes.')
  return true
end

function M.onPreRender(dtReal)
  local run=active;if not run then return end
  local ok,err=pcall(function()
    if cameraMoved(run.camera) then error('camera/FOV/resolution moved; reference cancelled',0) end
    local main=mainModule()
    local selection=main.getReflectionSamplingState()
    if main.getLightingAuditStatus().active or selection.frozen or selection.name~='ggx'
      or main.getReflectionReconstructionState().name~='playable' or main.getLightingAuditState().mode~='reflections' then
      error('rendering selection changed; reference cancelled',0)
    end
    local dt=tonumber(dtReal) or 0
    if dt~=dt or dt<0 or dt==math.huge then dt=0 end
    run.elapsed=run.elapsed+dt;run.age=run.age+dt
    if run.age>60 then error('convergence timeout',0) end
    if run.phase=='warmup' then
      if run.stage==1 and run.elapsed<2 then return end
      if run.stage>1 and run.draws<128 then return end
      if run.stage>2 and run.elapsed<0.25 then return end
      local filename=FS:expandFilename(run.directory .. '/' .. captures[run.stage].name)
      run.job=run.api.createScreenshotTracked({filename=filename,writeJPG=false,superSampling=1,tiles=1,
        overlap=0,rescaleFactor=1,upload=false,jobType='full',bufferType='color',
        objectTypeWhitelistMask=0,objectTypeBlacklistMask=0,shadowCasterObjectTypeWhitelistMask=0,
        shadowCasterObjectTypeBlacklistMask=0})
      if not run.job or run.job==0 then error('screenshot rejected',0) end
      run.pending=filename .. '.png';run.phase='saving';run.elapsed=0;run.pollElapsed=0
      return
    end
    if run.elapsed>15 then error('screenshot timeout',0) end
    run.pollElapsed=run.pollElapsed+dt
    if run.pollElapsed<0.1 then return end
    run.pollElapsed=0
    local jobs=jsonDecode(run.api.getScreenshotJobsSnapshotJson())
    if type(jobs)~='table' then error('screenshot status unavailable',0) end
    for _,job in ipairs(jobs) do
      if job.id==run.job then
        if job.phase=='error' or job.result~=nil and job.result~=0 then error('screenshot failed',0) end
        if job.phase~='done' or job.result~=0 then return end
        local filename=type(job.filename)=='string' and job.filename~='' and job.filename or run.pending
        if not FS:fileExists(filename) then return end
        run.images[#run.images+1]={name=captures[run.stage].name,filename=filename,
          cpuDraws=run.draws,sampling=mainModule().getReflectionSamplingState()}
        run.stage=run.stage+1;run.elapsed=0;run.phase='warmup'
        if run.stage>#captures then finish('complete');return end
        if run.stage==2 then
          checked(mainModule().setReflectionConvergenceEnabled,true)
          checked(object('MeanFx').enable,object('MeanFx'))
        end
        object('DisplayFx'):setShaderConst('$experimentDisplay',captures[run.stage].display)
        return
      end
    end
  end)
  if not ok then finish('error',tostring(err)) end
end

function M.cancel(reason) return finish('cancelled',reason or 'cancelled') end
function M.getStatus()
  if not active then return lastResult or {active=false} end
  return {active=true,stage=active.stage,phase=active.phase,directory=active.directory,draws=active.draws}
end
function M.onExtensionLoaded()
  if setExtensionUnloadMode then setExtensionUnloadMode(M,'manual') end
  M.start()
end
function M.onExtensionUnloaded() M.cancel('diagnostic unloaded');destroy() end
return M
