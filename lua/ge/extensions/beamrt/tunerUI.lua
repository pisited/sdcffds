-- Presentation only. Selecting/opening a tab never changes a renderer or setting.
local M = {}

local function tip(im, text)
  if text and im.IsItemHovered() then im.SetTooltip(text) end
end

local function set(api, id, value)
  local ok, reason = api.setCoherentSsrParameter(id, value)
  if not ok and type(log) == 'function' then log('W', 'BeamRT', tostring(reason)) end
end

local function toggle(im, api, options, id, label, help)
  local pointer = im.BoolPtr(options[id] == true)
  if im.Checkbox(label .. '##BeamRTSSR_' .. id, pointer) then set(api, id, pointer[0]) end
  tip(im, help)
end

local function slider(im, api, options, id, label, low, high, help)
  -- A full-width ImGui slider puts its trailing visible label outside the
  -- content region. Draw a wrapping label on its own line; keep a hidden ID.
  im.TextWrapped(label)
  tip(im, help)
  local pointer = im.FloatPtr(options[id])
  if im.SliderFloat('##BeamRTSSR_' .. id, pointer, low, high, '%.2f') then
    set(api, id, pointer[0])
  end
  tip(im, help)
end

function M.reflections(im, api)
  local status = api.getCoherentSsrStatus()
  local options = status.options
  if im.Button(status.requested and 'Disable reflections##BeamRTSSR' or 'Enable reflections##BeamRTSSR') then
    api.setCoherentSsrEnabled(not status.requested)
  end
  im.SameLine()
  if im.Button('Reset reflection history##BeamRTSSR') then api._coherentRenderer.resetHistory() end
  im.TextWrapped('Screen-space reflections. Integrated BeamNG SSR must be off. Lighting & GI offers the optional combined PTGI mode.')
  if not status.requested or not status.active then im.TextWrapped(status.reason) end
  if not status.accumulationConfigured then
    im.TextWrapped('Accumulation OFF: history retention has no effect. Rough reflections can remain noisy.')
  elseif not status.freshSampling and options.stochasticSSR then
    im.TextWrapped('Sampling is frozen: accumulation cannot collect new GGX ray directions.')
  elseif status.active then
    im.TextWrapped(status.accumulationReady and 'Accumulation: history reuse scheduled (CPU state, not GPU proof).'
      or 'Accumulation: warming / waiting for valid camera history.')
  end
  if im.Button('Apply high-sample cleanup (slow)##BeamRTSSR') then
    api._coherentRenderer.applyNoiseQuality()
  end
  tip(im,'Full-resolution 16-ray stratified sampling, accumulation and geometry-aware reuse. Leaves brightness, material reflectivity, water color and waves unchanged. Very costly; does not enable rendering.')
  if status.noiseRestoreAvailable then
    im.SameLine()
    if im.Button('Undo cleanup settings##BeamRTSSR') then api._coherentRenderer.restoreNoiseQuality() end
  end

  im.PushItemWidth(-1)
  if im.CollapsingHeader1('Look', im.TreeNodeFlags_DefaultOpen) then
    slider(im,api,options,'intensity','Reflection strength',0,2)
    slider(im,api,options,'roughnessEnd','Roughness cutoff',0.05,1,'Restricts which surfaces receive reflections. This is not global scene exposure.')
    slider(im,api,options,'faceOnReflectance','Face-on reflectivity',0,1,'Lower this if dry asphalt or concrete looks too mirror-like.')
    slider(im,api,options,'surfaceDetail','Preserve surface detail',0,1)
  end
  if im.CollapsingHeader1('Quality') then
    slider(im,api,options,'renderScale','Trace resolution',0.25,1)
    slider(im,api,options,'traceQuality','Trace work budget',0,1)
    if im.Button('One ray##BeamRTSSR') then set(api,'stochasticRayCount',1) end
    im.SameLine()
    if im.Button('Four rays##BeamRTSSR') then set(api,'stochasticRayCount',4) end
    im.SameLine()
    if im.Button('Six rays##BeamRTSSR') then set(api,'stochasticRayCount',6) end
    im.SameLine()
    if im.Button('Eight rays##BeamRTSSR') then set(api,'stochasticRayCount',8) end
    im.SameLine()
    if im.Button('Sixteen rays##BeamRTSSR') then set(api,'stochasticRayCount',16) end
    im.TextUnformatted('Rays per trace pixel: ' .. tostring(options.stochasticRayCount))
    toggle(im,api,options,'stochasticSSR','Rough GGX reflections')
    toggle(im,api,options,'filteredColor','Rough reflection color pyramid')
    toggle(im,api,options,'pixelRebuild','Glossy detail rebuild')
  end
  if im.CollapsingHeader1('Noise and temporal stability') then
    toggle(im,api,options,'temporalDenoising','Temporal accumulation',
      'ON animates and averages fresh samples. OFF freezes a noisy sample pattern; it does not clean it. Retention must be above zero. More retention can retain trails; motion/disocclusion still rejects history.')
    toggle(im,api,options,'nativeTemporal','Full-resolution history')
    toggle(im,api,options,'traceSubpixelJitter','Subpixel sampling')
    toggle(im,api,options,'geometryReconstruction','Surface-aware reconstruction')
    toggle(im,api,options,'virtualReprojection','Reflection-motion reprojection')
    toggle(im,api,options,'roughStability','Rough stability (experimental)',
      'Rough opaque GGX only. Adds geometry-gated diagonal reuse and gentler coverage clipping. Can soften detail or retain trails; compare ON/OFF.')
    slider(im,api,options,'temporalStrength','History retention',0,0.98)
    slider(im,api,options,'stochasticReuse','Spatial reuse',0,1)
  end
  if im.CollapsingHeader1('Water') then
    toggle(im,api,options,'waterSSR','Water reflections')
    toggle(im,api,options,'waterRivers','Baked river coverage')
    slider(im,api,options,'waterSSRStrength','Water reflection strength',0,2)
    slider(im,api,options,'waterColorStrength','Added tint (0 = stock color)',0,1)
    im.TextWrapped('Stock water rendering remains intact. Reflection waves are an approximation, not a custom water renderer.')
  end
  if im.CollapsingHeader1('Optional appearance experiments') then
    toggle(im,api,options,'skyReflection','Sky fill (heuristic)')
    toggle(im,api,options,'overhangFill','Overhang fill (heuristic)')
    slider(im,api,options,'puddleStrength','Procedural puddle coverage',0,1)
    slider(im,api,options,'virtualParallaxScale','Reflection translation',0,1.5)
    im.TextWrapped('Fill estimates are not measured off-screen visibility. Camera and custom-water work remain parked.')
  end
  im.PopItemWidth()
  im.TextWrapped('Controls are session-only. The four saved quality presets belong to Lighting & GI / Legacy, not this backend.')
end

function M.diagnostics(im, api)
  local status = api.getCoherentSsrStatus()
  local options = status.options
  im.TextWrapped('Reflection diagnostics change the display only when clicked. Opening this tab does not start a renderer or a capture.')
  im.TextUnformatted('Current reflection view: ' .. tostring(options.debugView))
  if im.Button('Restore reflection beauty##BeamRTDebug') then set(api,'debugView',0) end
  if im.CollapsingHeader1('Reflection stages', im.TreeNodeFlags_DefaultOpen) then
    for index, view in ipairs({{20,'Raw trace'},{21,'History'},{22,'Temporal delta'},
      {23,'Temporal state'},{27,'Water ownership'},{31,'Trace work'},{32,'Trace exits'},
      {33,'Hi-Z pyramid'},{44,'History acceptance'},{45,'History weight'},
      {46,'History clipping'},{47,'Motion source'},{49,'Rebuild / history'},
      {50,'Traced source UV'},{51,'Traced distance'},{52,'Sampling pattern'},{53,'Hit confidence'}}) do
      if index % 3 ~= 1 then im.SameLine() end
      if im.Button(view[2] .. '##BeamRTDebug') then set(api,'debugView',view[1]) end
    end
  end
  if im.CollapsingHeader1('Trace and history experiments') then
    if im.Button((options.samplingMode == 1 and 'Use legacy ordered sampling' or 'Use non-tiled sampling') .. '##BeamRTDebug') then
      set(api,'samplingMode',options.samplingMode == 1 and 0 or 1)
    end
    toggle(im,api,options,'referenceTrace','Leaf-only trace reference',
      'Disables hierarchical skipping and allows up to 256 steps. Slow diagnostic; does not add hidden geometry.')
    toggle(im,api,options,'interleavedHistory','Interleaved history (experimental)')
    im.TextUnformatted('Scheduled frames: ' .. tostring(status.frame))
    im.TextUnformatted('Water map available: ' .. tostring(status.waterMapAvailable))
    im.TextWrapped('CPU state is not GPU output proof. Compare stillness, motion and disocclusion in-game.')
  end
end

function M.giExperiments(im, api)
  if not api.setGIReceiverDeLight or not im.CollapsingHeader1('GI color and coverage experiments') then return end
  local settings = api.getSettings()
  local enabled = (settings.giReceiverDeLight or 0) > 0
  if im.Button((enabled and 'Restore original receiver color' or 'Try de-lit receiver color') .. '##BeamRTGI') then
    api.setGIReceiverDeLight(enabled and 0 or 1)
  end
  tip(im, 'Estimates material tint after removing direct-light color. Keeps Bounce color, GI intensity, source light color, metallic rejection and native reflections unchanged. Approximate, not measured albedo.')
  im.TextWrapped('Warm lamps should remain warm. This targets repeated orange/brown receiver tint, not all colored bounce. Reversible; default OFF.')
  if im.Button((api._giDdaCoverageRestore and 'Undo wider DDA coverage' or 'Try wider DDA coverage') .. '##BeamRTGI') then
    local ok, reason = api.setGIWideDdaExperiment(not api._giDdaCoverageRestore)
    if not ok and type(log) == 'function' then log('W', 'BeamRT', tostring(reason)) end
  end
  tip(im, 'Doubles screen-pixel stride only; requires Screen DDA. Same depth-sample budget and world reach. May miss thin geometry. Does not change Coherent tracing, GI brightness or select a renderer.')
end

function M.lampShadows(im, api)
  if not api.getNearbyLampShadowStatus or not im.CollapsingHeader1('Automatic lamp shadows') then return end
  local status=api.getNearbyLampShadowStatus()
  local label=status.pendingRestore and not status.requested and 'Retry lamp restoration'
    or (status.automaticPreference~=false and 'Disable automatic lamp shadows' or 'Enable automatic lamp shadows')
  if im.Button(label..'##BeamRTLamps') then
    local ok,reason=api.setAutomaticLampShadowsEnabled(status.automaticPreference==false and not status.pendingRestore)
    if not ok and type(log)=='function' then log('W','BeamRT',tostring(reason)) end
  end
  tip(im,'Default ON when starting GI, Coherent or combined rendering. Requests shadows for all advertised scene PointLight/SpotLight objects, including currently disabled lights. Distant maps keep native size. Optional nearby assist helps important lamps compete for the finite shadow atlas. Disable restores owned fields.')
  im.TextWrapped(status.reason)
  im.TextWrapped('No camera-radius or four-light limit. Native GPU shadow budgets and caster materials still apply. No light color, intensity, range or global quality changes. Disable-all restores shadows; the next renderer start resumes automatic mode unless opted out this session.')
  if status.automatic then
    im.TextUnformatted(string.format('Inspected: %d | Discovery checks: %d | Owned fields: %d',
      status.processedLights or 0,status.pendingJobs or 0,status.changedFields or 0))
    im.TextWrapped('Discovery checks repeat periodically; these are not thousands of newly allocated shadow maps.')
    if api.setNearbyLampPriorityAssistEnabled then
      if im.Button((status.priorityAssist and 'Nearby shadow priority ON' or 'Nearby shadow priority OFF')..'##BeamRTLamps') then
        api.setNearbyLampPriorityAssistEnabled(not status.priorityAssist)
      end
      tip(im,'Reversible priority boost on up to eight enabled lamps within 80 m, refreshed once a second from cached positions. Nearby spot maps are at least 1024; point maps at least 512. Original larger maps remain. This can help native selection but cannot repair non-shadow-casting materials or create unlimited atlas capacity.')
      im.TextUnformatted('Nearby priority candidates: '..tostring(#(status.prioritizedLights or {})))
      if (status.priorityRejected or 0)>0 then im.TextWrapped('Native priority writes rejected: '..status.priorityRejected..'; baseline shadows retained.') end
    end
    if api.logNearbyLampShadowInputs and im.Button('Log nearby light shadow inputs##BeamRTLamps') then
      api.logNearbyLampShadowInputs()
    end
  end
end

function M.draw(im, api, panels)
  if not im.BeginTabBar('BeamRTTunerTabs') then return end
  for _, tab in ipairs({{'Reflections','reflections'}, {'Lighting & GI','lighting'},
    {'Diagnostics','diagnostics'}, {'Legacy','legacy'}}) do
    if im.BeginTabItem(tab[1]) then
      if tab[2] == 'lighting' and api.getPtgiCoherentStatus then
        local combined=api.getPtgiCoherentStatus()
        if im.Button(combined.requested and 'Disable PTGI + Coherent##BeamRTCombined' or 'Enable PTGI + Coherent##BeamRTCombined') then
          local ok,reason=api.setPtgiCoherentEnabled(not combined.requested)
          if not ok and type(log)=='function' then log('W','BeamRT',tostring(reason)) end
        end
        im.TextWrapped('Experimental: PTGI diffuse lighting, then Coherent reflections. Older SSR and water overlay stay off. Existing ray count and lighting tuning are retained.')
        im.TextWrapped(combined.reason)
      end
      if tab[2] == 'lighting' then M.giExperiments(im,api) end
      if tab[2] == 'lighting' then M.lampShadows(im,api) end
      if tab[2] == 'reflections' then M.reflections(im,api) end
      if tab[2] == 'diagnostics' then M.diagnostics(im,api) end
      if panels[tab[2]] then panels[tab[2]]() end
      im.EndTabItem()
    end
  end
  im.EndTabBar()
end

return M
