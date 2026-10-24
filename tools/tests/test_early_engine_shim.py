"""Mocked early startup scheduling, never a BeamNG launch or readiness proof."""
from pathlib import Path
import importlib.util
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT21

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "native/startup/unattended"
_spec = importlib.util.spec_from_file_location("_unattended_harness", ROOT / "tools/tests/test_unattended_observation.py")
_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixture)
ENGINE_HARNESS = _fixture.ENGINE_HARNESS


HARNESS = r"""
function makeEarlyHarness()
  local h={time=0,filename='',calls={},proxies={},hooks={},abortReasons={},returnedArmed=true,manualNames={}}
  local function count(name) h.calls[name]=(h.calls[name] or 0)+1 end
  h.count=function(name) return h.calls[name] or 0 end
  h.config={timeout=20,bootstrapSourcePath='C:/frozen/source/bootstrap.lua',bootstrap={
    runDirectory='C:/fixture/run',controllerSourcePath='C:/frozen/source/controller.lua',
    adapterSourcePath='C:/frozen/source/engine_adapter.lua',controller={
      token='0123456789abcdef0123456789abcdef',expectedLevel='west_coast_usa',
      loadTimeout=300,captureTimeout=120,overallTimeout=480,
      stableSeconds=2,stableFrames=8,quitGrace=10}}}
  h.env={worldReadyState=-1,os={clockhp=function()
      count('clock'); if h.clockHook then h.clockHook() end
      if h.clockThrows then error('clock failure') end; return h.time end},
    getMissionFilename=function()
      count('mission'); if h.missionHook then h.missionHook() end
      if h.missionThrows then error('mission failure') end; return h.filename end,
    io={open=function() count('io'); error('unexpected fixture I/O') end},
    jsonDecode=function() end,jsonEncode=function() end,
    Engine={getStartingArgs=function() count('args'); return {} end},
    quit=function() count('quit') end,extensions={load=function() count('loadGI') end},
    core_levels={getLevelName=function() return '' end},
    core_modmanager={isReady=function() return false end},
    core_gamestate={loading=function() return true end,getGameState=function() return {} end}}
  h.run={controller={abort=function(reason) count('abort'); h.abortReasons[#h.abortReasons+1]=reason end,
    status=function() return {armed=h.returnedArmed} end},hooks={},runtime={},proxy={}}
  h.env.newExtensionProxy=function(object,name)
    count('proxy'); h.proxyName=name; assert(object==nil)
    if h.proxyHook then h.proxyHook() end
    if h.proxyThrows then error('proxy failure') end
    if h.badProxy then return h.badProxy end
    local proxy={extName='beamrtEarlyUnattended_virtual_1',submitEventSinks=function(self,sinks)
      count('submit'); h.hooks=sinks[1]
      if h.submitHook then h.submitHook() end
      if h.submitThrows then error('submit failure') end
      if h.submitFalse then return false end
    end}
    h.proxies[#h.proxies+1]=proxy; return proxy
  end
  h.env.setExtensionUnloadMode=function(name,mode)
    count('unloadMode'); assert(name=='beamrtEarlyUnattended_virtual_1' and mode=='manual')
    if h.retentionHook then h.retentionHook() end
    if h.retentionThrows then error('retention failure') end
    if h.retentionFalse then return false end
    h.manualNames[name]=true
  end
  h.env.dofile=function(path)
    count('dofile'); h.loadedPath=path
    if h.loadHook then h.loadHook() end
    if h.loadThrows then error('load failure') end
    if h.badFactory then return h.badFactory end
    return function(config,env)
      count('bootstrap'); h.receivedConfig=config; h.receivedEnv=env
      if h.bootstrapHook then h.bootstrapHook() end
      if h.bootstrapThrows then error('bootstrap failure') end
      if h.bootstrapNil then return nil,'fixture refusal' end
      return h.run
    end
  end
  h.new=function() h.shim=Early.new(h.config,h.env); return h.shim end
  -- Most cases exercise the waiting path. Temporarily missing physical-loader
  -- readiness during explicit arm models genuinely early engine API startup.
  h.arm=function()
    local loader=h.env.dofile; h.env.dofile=nil
    local result=h.shim.arm(h.config.bootstrap.controller.token)
    h.env.dofile=loader; return result
  end
  h.tick=function(seconds) h.time=h.time+(seconds or 0); return h.shim.update() end
  return h
end
"""


class EarlyContracts:
    runtime = None

    def setUp(self):
        self.lua = self.runtime(unpack_returned_tuples=True)
        self.lua.globals().Early = self.lua.execute((SOURCES / "early_shim.lua").read_text())
        self.lua.execute(HARNESS)
        self.h = self.lua.globals().makeEarlyHarness()
        self.h.new()

    def fresh(self):
        h = self.lua.globals().makeEarlyHarness()
        h.new()
        return h

    def failed(self, h, reason=None, *, claimed=False):
        status = h.shim.status()
        self.assertIn(status.phase, ("failed", "rejected"))
        if reason:
            self.assertEqual(status.reason, reason)
        self.assertEqual(status.claimed, claimed)
        self.assertEqual(h.count("quit"), 0)
        self.assertEqual(h.count("loadGI"), 0)
        return status

    def test_import_constructor_and_unarmed_update_are_inert(self):
        self.assertEqual(self.h.shim.status().phase, "unarmed")
        self.assertFalse(self.h.shim.update())
        self.assertEqual(len(list(self.h.calls)), 0)

    def test_requires_explicit_environment_and_configuration(self):
        check = self.lua.eval("function(config,env) return pcall(Early.new,config,env) end")
        for config, env in ((None, self.h.env), (self.h.config, None), (self.lua.table(), self.h.env)):
            self.assertFalse(check(config, env)[0])
        self.assertEqual(len(list(self.h.calls)), 0)

    def test_timeout_configuration_is_bounded_finite(self):
        check = self.lua.eval("function(config,env) return pcall(Early.new,config,env) end")
        for value in (None, 0, -1, 30.001, float("inf"), float("nan"), "20", True):
            self.h.config.timeout = value
            self.assertFalse(check(self.h.config, self.h.env)[0])
        self.assertEqual(len(list(self.h.calls)), 0)

    def test_source_path_is_absolute_literal_and_reviewed_leaf(self):
        check = self.lua.eval("function(config,env) return pcall(Early.new,config,env) end")
        for path in ("bootstrap.lua", "C:/../bootstrap.lua", "C:/a/./bootstrap.lua", "C:/NUL/bootstrap.lua",
                     "C:/a/other.lua", "C:/a//bootstrap.lua", "C:/a:stream/bootstrap.lua", "C:/a /bootstrap.lua",
                     "\\\\server\\bootstrap.lua", "C:/a/boot\x00strap.lua", "C:/a/BOOTSTRAP.lua"):
            self.h.config.bootstrapSourcePath = path
            self.assertFalse(check(self.h.config, self.h.env)[0], path)
        self.assertEqual(len(list(self.h.calls)), 0)

    def test_identity_configuration_is_not_inferred(self):
        check = self.lua.eval("function(config,env) return pcall(Early.new,config,env) end")
        for value in (None, "x" * 32, "A" * 32, "a" * 31):
            self.h.config.bootstrap.controller.token = value
            self.assertFalse(check(self.h.config, self.h.env)[0])
        self.h.config.bootstrap.controller.token = "a" * 32
        self.h.config.bootstrap.controller.expectedLevel = "smallgrid"
        self.assertFalse(check(self.h.config, self.h.env)[0])

    def test_wrong_token_does_not_install_or_quit(self):
        self.assertFalse(self.h.shim.arm("f" * 32))
        self.failed(self.h, "early_token_mismatch")
        self.assertEqual(self.h.count("proxy"), 0)

    def test_existing_or_unreadable_mission_is_not_late_attached(self):
        for value in ("/levels/west_coast_usa/main.level.json", None, 0):
            h = self.fresh(); h.filename = value
            self.assertFalse(h.arm()); self.failed(h, "early_mission_already_started")
            self.assertEqual(h.count("proxy"), 0)
        h = self.fresh(); h.missionThrows = True
        self.assertFalse(h.arm()); self.failed(h, "early_mission_already_started")

    def test_mission_prestart_and_ready_world_are_not_recovered(self):
        for value in (0, 1, 2, "-1", False):
            h = self.fresh(); h.env.worldReadyState = value
            self.assertFalse(h.arm()); self.failed(h, "early_mission_already_started")

    def test_minimum_clock_and_mission_apis_required_before_hooks(self):
        for name in ("os", "getMissionFilename"):
            h = self.fresh(); h.env[name] = None
            self.assertFalse(h.arm()); self.failed(h)
            self.assertEqual(h.count("proxy"), 0)
        for value in (None, -1, float("nan"), float("inf"), "0", False):
            h = self.fresh(); h.time = value
            self.assertFalse(h.arm()); self.failed(h, "early_clock_invalid")
        h = self.fresh(); h.clockThrows = True
        self.assertFalse(h.arm()); self.failed(h, "early_clock_invalid")

    def test_proxy_creation_and_registration_fail_closed_without_claim(self):
        h = self.fresh(); h.env.newExtensionProxy = None
        self.assertFalse(h.arm()); self.failed(h, "early_proxy_unavailable")
        for field in ("proxyThrows", "submitThrows", "submitFalse", "retentionThrows", "retentionFalse"):
            h = self.fresh(); h[field] = True
            self.assertFalse(h.arm()); self.failed(h)
            self.assertEqual(h.count("bootstrap"), 0)
        h = self.fresh(); h.badProxy = self.lua.table()
        self.assertFalse(h.arm()); self.failed(h, "early_proxy_invalid")

    def test_missing_retention_api_refuses_before_registering_unowned_hooks(self):
        self.h.env.setExtensionUnloadMode = None
        self.assertFalse(self.h.arm()); self.failed(self.h, "early_proxy_unavailable")
        self.assertEqual(self.h.count("proxy"), 0)

    def test_foreign_or_invalid_virtual_name_never_enters_manual_unload_list(self):
        for name in ("other_virtual_1", "beamrtEarlyUnattended_virtual_x", "", "a" * 129):
            h = self.fresh()
            h.badProxy = self.lua.eval("function(name) return {extName=name,submitEventSinks=function() end} end")(name)
            self.assertFalse(h.arm()); self.failed(h, "early_proxy_invalid")
            self.assertEqual(h.count("unloadMode"), 0)

    def test_arm_installs_early_proxy_without_synchronous_bootstrap(self):
        self.assertTrue(self.h.arm())
        self.assertEqual(self.h.proxyName, "beamrtEarlyUnattended")
        self.assertEqual(self.h.shim.status().phase, "waiting_api")
        self.assertEqual(self.h.count("dofile"), 0)
        self.assertEqual(self.h.count("bootstrap"), 0)
        self.assertEqual(self.h.count("args"), 0)
        self.assertEqual(self.h.count("io"), 0)
        self.assertEqual(self.h.count("unloadMode"), 1)
        self.assertTrue(self.h.manualNames["beamrtEarlyUnattended_virtual_1"])

    def test_explicit_arm_bootstraps_immediately_when_all_apis_exist(self):
        self.assertTrue(self.h.shim.arm(self.h.config.bootstrap.controller.token))
        self.assertEqual(self.h.shim.status().phase, "handed_off")
        self.assertEqual(self.h.count("bootstrap"), 1)
        self.assertEqual(self.h.count("unloadMode"), 1)
        self.assertFalse(self.h.tick())
        self.assertEqual(self.h.count("bootstrap"), 1)

    def test_waits_for_each_nonminimum_api_and_then_hands_off(self):
        for name in ("dofile", "io", "jsonDecode", "jsonEncode", "Engine", "quit", "core_levels",
                     "core_modmanager", "core_gamestate", "extensions"):
            h = self.fresh(); original = h.env[name]; h.env[name] = None
            self.assertTrue(h.arm()); self.assertTrue(h.tick(1))
            self.assertEqual(h.count("bootstrap"), 0, name)
            self.assertEqual(h.shim.status().phase, "waiting_api", name)
            h.env[name] = original; self.assertTrue(h.tick(1))
            self.assertEqual(h.shim.status().phase, "handed_off", name)

    def test_present_but_malformed_api_shapes_wait_instead_of_guessing(self):
        for container, field in (("Engine", "getStartingArgs"), ("io", "open"), ("core_levels", "getLevelName"),
                                 ("core_modmanager", "isReady"), ("core_gamestate", "loading"),
                                 ("core_gamestate", "getGameState"), ("extensions", "load")):
            h = self.fresh(); h.env[container][field] = True
            self.assertTrue(h.arm()); self.assertTrue(h.tick(1))
            self.assertEqual(h.count("bootstrap"), 0)
            h.tick(19); self.failed(h, "early_api_timeout")

    def test_exact_deadline_precedes_bootstrap_even_when_apis_arrive(self):
        self.assertTrue(self.h.arm()); self.assertFalse(self.h.tick(20))
        self.failed(self.h, "early_api_timeout")
        self.assertEqual(self.h.count("dofile"), 0)
        h = self.fresh(); h.config.timeout = 30; h.new(); h.arm(); h.tick(29.9)
        self.assertEqual(h.shim.status().phase, "handed_off")

    def test_waiting_callbacks_do_not_restart_deadline(self):
        self.h.env.io = None; self.h.arm()
        for _ in range(19): self.assertTrue(self.h.tick(1))
        self.assertFalse(self.h.tick(1)); self.failed(self.h, "early_api_timeout")
        self.assertFalse(self.h.tick(1)); self.assertEqual(self.h.count("dofile"), 0)

    def test_clock_regression_or_failure_after_arm_is_unclaimed_stop(self):
        for field, value in (("time", -1), ("time", float("inf")), ("clockThrows", True)):
            h = self.fresh(); h.time = 10; h.arm(); h[field] = value
            self.assertFalse(h.tick()); self.failed(h, "early_clock_invalid")

    def test_mission_filename_change_while_waiting_prevents_bootstrap(self):
        self.h.arm(); self.h.filename = "/levels/west_coast_usa/main.level.json"
        self.assertFalse(self.h.tick()); self.failed(self.h, "early_mission_already_started")
        self.assertEqual(self.h.count("dofile"), 0)

    def test_mission_and_reload_hooks_before_handoff_refuse_unclaimed(self):
        for event in ("onClientStartMission", "onClientEndMission", "onSerialize", "onDeserialized"):
            h = self.fresh(); h.arm(); h.hooks[event]()
            self.failed(h); self.assertEqual(h.count("abort"), 0)
            self.assertFalse(h.tick()); self.assertEqual(h.count("bootstrap"), 0)

    def test_success_hands_off_once_and_early_update_mission_hooks_are_passive(self):
        self.h.arm(); self.assertTrue(self.h.tick())
        status = self.h.shim.status()
        self.assertEqual(status.phase, "handed_off")
        self.assertTrue(status.claimed); self.assertTrue(status.bootstrapInstalled)
        self.assertEqual(status.bootstrapLoads, 1); self.assertEqual(status.bootstrapCalls, 1)
        for _ in range(10):
            self.h.hooks.onUpdate(); self.h.hooks.onClientStartMission(); self.h.hooks.onClientEndMission()
        self.assertEqual(self.h.count("bootstrap"), 1)
        self.assertEqual(self.h.count("abort"), 0)
        self.assertEqual(self.h.count("quit"), 0)
        self.assertEqual(self.h.count("loadGI"), 0)

    def test_physical_loader_failure_or_nonfunction_never_invokes_bootstrap(self):
        for field, value in (("loadThrows", True), ("badFactory", self.lua.table())):
            h = self.fresh(); h[field] = value; h.arm(); h.tick()
            status = self.failed(h, "early_bootstrap_load_failed")
            self.assertEqual(status.bootstrapLoads, 1); self.assertEqual(status.bootstrapCalls, 0)
            self.assertEqual(h.count("bootstrap"), 0)

    def test_bootstrap_refusal_or_exception_does_not_infer_ownership(self):
        for field in ("bootstrapThrows", "bootstrapNil"):
            h = self.fresh(); h[field] = True; h.arm(); h.tick()
            self.failed(h, "early_bootstrap_refused")
            self.assertEqual(h.count("abort"), 0)
            self.assertEqual(h.count("bootstrap"), 1)
            h.tick(); self.assertEqual(h.count("bootstrap"), 1)

    def test_malformed_owned_run_is_retained_and_aborted_normally(self):
        self.h.run.runtime = None; self.h.arm(); self.h.tick()
        self.failed(self.h, "early_bootstrap_refused", claimed=True)
        self.assertEqual(self.h.count("abort"), 1)
        self.assertTrue(self.lua.eval("function(h) return h.shim.retainedRun()==h.run end")(self.h))

    def test_unarmed_or_unreadable_returned_controller_does_not_allow_abort(self):
        h = self.fresh(); h.returnedArmed = False; h.arm(); h.tick()
        self.failed(h, "early_bootstrap_refused"); self.assertEqual(h.count("abort"), 0)
        h = self.fresh(); self.lua.execute("function throwStatus() error('status failed') end")
        h.run.controller.status = self.lua.globals().throwStatus; h.arm(); h.tick()
        self.failed(h, "early_bootstrap_refused"); self.assertEqual(h.count("abort"), 0)

    def test_reentrant_arm_minimum_calls_never_bootstraps(self):
        for field in ("clockHook", "missionHook", "proxyHook", "submitHook", "retentionHook"):
            h = self.fresh()
            h[field] = self.lua.eval("function(h) return function() h.shim.update() end end")(h)
            self.assertFalse(h.arm()); self.failed(h, "early_shim_reentrant")
            self.assertTrue(h.shim.status().reentrancyObserved)
            self.assertEqual(h.count("bootstrap"), 0)

    def test_reentrant_physical_loader_refuses_before_bootstrap(self):
        self.h.arm()
        self.h.loadHook = self.lua.eval("function(h) return function() h.shim.update() end end")(self.h)
        self.h.tick(); self.failed(self.h, "early_shim_reentrant")
        self.assertEqual(self.h.count("bootstrap"), 0)

    def test_loader_return_after_deadline_does_not_invoke_bootstrap(self):
        self.h.arm()
        self.h.loadHook = self.lua.eval("function(h) return function() h.time=20 end end")(self.h)
        self.h.tick(); self.failed(self.h, "early_api_timeout")
        self.assertEqual(self.h.count("bootstrap"), 0)

    def test_bootstrap_return_after_deadline_aborts_only_claimed_run(self):
        self.h.arm()
        self.h.bootstrapHook = self.lua.eval("function(h) return function() h.time=20 end end")(self.h)
        self.h.tick(); self.failed(self.h, "early_api_timeout", claimed=True)
        self.assertEqual(self.h.count("bootstrap"), 1)
        self.assertEqual(self.h.count("abort"), 1)

    def test_reentrant_bootstrap_aborts_only_returned_claimed_controller(self):
        self.h.arm()
        self.h.bootstrapHook = self.lua.eval("function(h) return function() h.shim.update() end end")(self.h)
        self.h.tick(); self.failed(self.h, "early_shim_reentrant", claimed=True)
        self.assertEqual(self.h.count("abort"), 1)

    def test_mission_event_during_bootstrap_aborts_newly_claimed_run(self):
        self.h.arm()
        self.h.bootstrapHook = self.lua.eval("function(h) return function() h.hooks.onClientStartMission() end end")(self.h)
        self.h.tick(); self.failed(self.h, "early_shim_reentrant", claimed=True)
        self.assertEqual(self.h.count("abort"), 1)

    def test_world_change_during_bootstrap_aborts_owned_run(self):
        self.h.arm()
        self.h.bootstrapHook = self.lua.eval("function(h) return function() h.env.worldReadyState=0 end end")(self.h)
        self.h.tick(); self.failed(self.h, "early_mission_already_started", claimed=True)
        self.assertEqual(self.h.count("abort"), 1)

    def test_rearm_fails_and_only_claimed_handoff_can_abort(self):
        self.h.arm(); self.assertFalse(self.h.arm()); self.failed(self.h, "early_rearm_refused")
        self.assertEqual(self.h.count("abort"), 0)
        h = self.fresh(); h.arm(); h.tick(); self.assertFalse(h.arm())
        self.failed(h, "early_rearm_refused", claimed=True); self.assertEqual(h.count("abort"), 1)
        h.arm(); self.assertEqual(h.count("abort"), 1)

    def test_configuration_is_copied_before_delayed_handoff(self):
        original_token = self.h.config.bootstrap.controller.token
        self.h.config.bootstrap.controller.token = "f" * 32
        self.h.config.bootstrap.runDirectory = "C:/changed/run"
        self.h.config.bootstrapSourcePath = "C:/changed/bootstrap.lua"
        self.assertTrue(self.h.shim.arm(original_token)); self.h.tick()
        self.assertEqual(self.h.loadedPath, "C:/frozen/source/bootstrap.lua")
        self.assertEqual(self.h.receivedConfig.runDirectory, "C:/fixture/run")
        self.assertEqual(self.h.receivedConfig.controller.token, original_token)

    def test_status_is_a_copy_and_references_are_retained(self):
        status = self.h.shim.status(); status.phase = "handed_off"; status.claimed = True
        self.assertEqual(self.h.shim.status().phase, "unarmed")
        self.h.arm(); self.h.tick()
        self.assertTrue(self.lua.eval("function(h) return h.shim.retainedRun()==h.run and h.shim.retainedProxy()==h.proxies[1] end")(self.h))

    def test_existing_gi_module_requires_real_start_and_audit_shapes(self):
        for module in (self.lua.table(), self.lua.table_from({"start": True})):
            h = self.fresh(); h.env.beamrt_main = module; h.arm(); h.tick()
            self.assertEqual(h.count("bootstrap"), 0)
        h = self.fresh()
        h.env.beamrt_main = self.lua.eval("{start=function() end,getLightingAuditState=function() end}")
        h.env.extensions = None; h.arm(); h.tick()
        self.assertEqual(h.shim.status().phase, "handed_off")

    def test_serialization_after_handoff_aborts_only_owned_controller_once(self):
        self.h.arm(); self.h.tick(); self.assertIsNone(self.h.hooks.onSerialize())
        self.failed(self.h, "early_serialization_refused", claimed=True)
        self.h.hooks.onDeserialized(); self.assertEqual(self.h.count("abort"), 1)

    def engine(self):
        for name in ("Controller", "Adapter", "Bootstrap"):
            filename = {"Controller": "controller.lua", "Adapter": "engine_adapter.lua", "Bootstrap": "bootstrap.lua"}[name]
            self.lua.globals()[name] = self.lua.execute((SOURCES / filename).read_text())
        self.lua.execute(ENGINE_HARNESS)
        h = self.lua.globals().makeEngineHarness()
        self.lua.eval(r"""function(h)
          h.filename=''; h.env.worldReadyState=-1
          local originalLoader=h.env.dofile
          h.env.dofile=function(path)
            if path=='C:/beamrt-fixture/source/bootstrap.lua' then return Bootstrap end
            return originalLoader(path)
          end
          local originalProxy=h.env.newExtensionProxy
          local originalRetention=h.env.setExtensionUnloadMode
          h.manualNames={}
          h.env.setExtensionUnloadMode=function(name,mode)
            if name=='beamrtEarlyUnattended_virtual_1' then
              assert(mode=='manual'); h.manualNames[name]=true; return
            end
            return originalRetention(name,mode)
          end
          h.env.newExtensionProxy=function(object,name)
            if name=='beamrtEarlyUnattended' then
              return {extName='beamrtEarlyUnattended_virtual_1',submitEventSinks=function(self,sinks) h.earlyHooks=sinks[1] end}
            end
            return originalProxy(object,name)
          end
          h.earlyConfig={timeout=20,bootstrapSourcePath='C:/beamrt-fixture/source/bootstrap.lua',bootstrap=h.config}
          h.shim=Early.new(h.earlyConfig,h.env)
        end""")(h)
        return h

    def test_actual_bootstrap_receipt_and_quit_coupling_has_no_duplicate_events(self):
        h = self.engine(); self.assertTrue(h.shim.arm(h.config.controller.token))
        self.assertEqual(h.shim.status().phase, "handed_off"); run = h.shim.retainedRun()
        self.assertEqual(h.count("startGI"), 0)
        # Simulate unloadExcept(manualUnloadExtensions), not __manuallyLoaded__.
        self.assertTrue(h.manualNames["beamrtEarlyUnattended_virtual_1"])
        self.assertTrue(h.manualNames["beamrtUnattended_virtual_1"])
        self.lua.eval("function(h) if not h.manualNames['beamrtEarlyUnattended_virtual_1'] then h.earlyHooks=nil end; if not h.manualNames['beamrtUnattended_virtual_1'] then h.installedHooks=nil end end")(h)
        self.assertIsNotNone(h.earlyHooks); self.assertIsNotNone(h.installedHooks)
        h.filename = "/levels/west_coast_usa/main.level.json"; h.env.worldReadyState = 2
        h.earlyHooks.onClientStartMission(); run.hooks.onClientStartMission()
        self.assertEqual(run.controller.status().missionCount, 1)
        h.earlyHooks.onUpdate(); run.hooks.onUpdate()
        h.time = 2
        for _ in range(8): run.hooks.onPreRender()
        h.earlyHooks.onUpdate(); run.hooks.onUpdate(); run.hooks.onUpdate()
        self.assertEqual(h.count("startGI"), 1)
        h.receipt(); run.hooks.onUpdate()
        self.assertTrue(run.controller.status().receiptValidated)
        self.assertEqual(h.count("quit"), 1)
        self.assertFalse(run.controller.status().processExitVerified)
        self.assertEqual(h.count("kill"), 0)

    def test_actual_bootstrap_missing_context_refuses_without_quit(self):
        h = self.engine(); h.files[h.path("process-context.json")] = None
        self.assertFalse(h.shim.arm(h.config.controller.token)); self.assertFalse(h.shim.update())
        self.assertEqual(h.shim.status().phase, "failed")
        self.assertFalse(h.shim.status().claimed)
        self.assertEqual(h.count("quit"), 0); self.assertEqual(h.count("startGI"), 0)

    def test_actual_bootstrap_after_claim_hook_failure_requests_only_normal_quit(self):
        h = self.engine(); h.failSubmit = True
        self.assertFalse(h.shim.arm(h.config.controller.token)); self.assertFalse(h.shim.update())
        self.assertEqual(h.shim.status().phase, "failed")
        # Bootstrap owns this failure and requests normal quit before returning nil.
        self.assertFalse(h.shim.status().claimed)
        self.assertEqual(h.count("quit"), 1); self.assertEqual(h.count("startGI"), 0)
        self.assertEqual(h.count("kill"), 0)


class EarlyLua51(EarlyContracts, unittest.TestCase):
    runtime = Lua51


class EarlyLuaJIT21(EarlyContracts, unittest.TestCase):
    runtime = LuaJIT21


if __name__ == "__main__":
    unittest.main()
