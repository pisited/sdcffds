-- Inert import. Only calling the returned function validates/claims a run and
-- installs virtual hooks. No active extension, autostart setting, or search path
-- is modified. A future reviewed owner must supply its child's process context.
local function sourcePath(value, expectedLeaf)
  assert(type(value) == 'string' and #value <= 2048, 'invalid_source_path')
  local path = value:gsub('\\', '/')
  assert(path:match('^[A-Za-z]:/') and not path:find('[%z\1-\31<>"|?*]')
    and not path:sub(3):find(':', 1, true) and not path:find('//', 1, true), 'invalid_source_path')
  for component in path:sub(4):gmatch('[^/]+') do
    assert(component ~= '.' and component ~= '..' and not component:match('[ .]$'), 'invalid_source_path')
  end
  assert(path:sub(-#expectedLeaf - 1) == '/' .. expectedLeaf, 'unexpected_source_file')
  return path
end

return function(config, environment)
  local env = environment or _G
  local ok, runOrReason, reason = pcall(function()
    assert(type(config) == 'table' and type(config.controller) == 'table' and type(env) == 'table', 'explicit_configuration_required')
    assert(type(env.dofile) == 'function', 'physical_loader_unavailable')
    local adapterPath = sourcePath(config.adapterSourcePath, 'engine_adapter.lua')
    local controllerPath = sourcePath(config.controllerSourcePath, 'controller.lua')
    local adapter = env.dofile(adapterPath)
    assert(type(adapter) == 'table' and type(adapter.new) == 'function', 'invalid_adapter_factory')
    local runtime = adapter.new(config, env)
    local valid, why = runtime.validateContext()
    if not valid then return nil, why end
    assert(type(env.newExtensionProxy) == 'function' and type(env.setExtensionUnloadMode) == 'function', 'extension_proxy_unavailable')
    local factory = env.dofile(controllerPath)
    assert(type(factory) == 'table' and type(factory.new) == 'function', 'invalid_controller_factory')
    local settings = {}
    for key, value in pairs(config.controller) do settings[key] = value end
    settings.expectedPid = runtime.expectedPid
    local controller = factory.new(settings, runtime.api)
    local hooks = runtime.bind(controller)
    local proxy = env.newExtensionProxy(nil, 'beamrtUnattended')
    assert(type(proxy) == 'table' and type(proxy.submitEventSinks) == 'function'
      and type(proxy.extName) == 'string' and #proxy.extName <= 128
      and proxy.extName:match('^beamrtUnattended_virtual_%d+$'), 'invalid_extension_proxy')
    if not controller.arm(settings.token) then return nil, 'arm_refused' end
    local installed, result = pcall(proxy.submitEventSinks, proxy, {hooks})
    if not installed or result == false then
      controller.abort('hook_install_failed')
      return nil, 'hook_install_failed'
    end
    -- The freeroam loader unloads virtual modules unless their exact extension
    -- names are in main.lua's in-memory manual-unload list. This is not an
    -- autostart/user setting, and __manuallyLoaded__ by itself is insufficient.
    local retained, modeResult = pcall(env.setExtensionUnloadMode, proxy.extName, 'manual')
    if not retained or modeResult == false then
      controller.abort('hook_retention_failed')
      return nil, 'hook_retention_failed'
    end
    return {controller=controller, runtime=runtime, hooks=hooks, proxy=proxy}
  end)
  if not ok then return nil, tostring(runOrReason) end
  return runOrReason, reason
end
