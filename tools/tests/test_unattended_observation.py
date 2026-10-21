"""Execute the inert unattended driver with injected APIs; never launch BeamNG.

These are CPU state-machine/adapter contracts, not game-readiness, native receipt,
GPU correctness, normal-exit, or crash-recovery evidence.
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT21


ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "native/startup/unattended"
TOKEN = "0123456789abcdef0123456789abcdef"


HARNESS = r"""
function makeHarness()
  local h = {time=0, calls={}, events={}, throws={}, hooks={}, claimResult=true,
    emitResult=true, startResult=true, quitResult=nil, ack=nil, ownerStopResult=false}
  h.sample = {level='', missionStarted=false, modReady=false, loading=true,
    freeroam=false, worldReadyState=-1, renderFrames=0, giEnabled=false, giMode='off'}
  local function invoked(name)
    h.calls[name]=(h.calls[name] or 0)+1
    if h.hooks[name] then h.hooks[name]() end
    if h.throws[name] then error('injected '..name..' failure') end
  end
  h.config={token='0123456789abcdef0123456789abcdef', expectedPid=12345, expectedLevel='west_coast_usa',
    loadTimeout=300, captureTimeout=120, overallTimeout=480,
    stableSeconds=2, stableFrames=8, quitGrace=10}
  h.api={
    now=function() invoked('now'); return h.time end,
    claim=function(token) invoked('claim'); h.claimToken=token; return h.claimResult end,
    sample=function() invoked('sample'); return h.sample end,
    startGI=function() invoked('startGI'); return h.startResult end,
    pollAck=function() invoked('pollAck'); return h.ack end,
    emit=function(event,state) invoked('emit'); h.events[#h.events+1]={event,state};
      if h.failEvent==event then return false end; return h.emitResult end,
    requestQuit=function() invoked('requestQuit'); return h.quitResult end
  }
  h.controller=Controller.new(h.config,h.api)
  h.enableOwnerStop=function()
    h.api.pollOwnerStop=function() invoked('pollOwnerStop'); return h.ownerStopResult end
  end
  h.count=function(name) return h.calls[name] or 0 end
  h.arm=function() return h.controller.arm(h.config.token) end
  h.ready=function()
    h.sample.level='west_coast_usa'; h.sample.missionStarted=true
    h.sample.modReady=true; h.sample.loading=false; h.sample.freeroam=true
    h.sample.worldReadyState=2
    return h.controller.missionStarted()
  end
  h.tick=function(seconds,frames)
    h.time=h.time+(seconds or 0); h.sample.renderFrames=h.sample.renderFrames+(frames or 0)
    return h.controller.update()
  end
  h.start=function()
    assert(h.arm()); assert(h.ready()); h.tick(); h.tick(2,8)
    assert(h.count('startGI')==1)
  end
  h.confirm=function() h.sample.giEnabled=true; h.sample.giMode='lighting'; h.tick() end
  h.validAck=function(kind)
    return {token=h.config.token,kind=kind or 'receipt_validated',expectedPid=12345,
      resourceABI=7,profile=2,mode=1,cbvProbeBytes=0,digest=string.rep('a',64)}
  end
  return h
end
"""


ENGINE_HARNESS = r"""
function makeEngineHarness()
  local h={calls={},files={},objects={},time=0,giEnabled=false,giMode='lighting',
    filename='/levels/west_coast_usa/main.level.json',ready=true,loading=false,
    gameState='freeroam',encoded=0,openErrors={},readErrors={},decodeErrors={},
    failWrite=false,failClose=false}
  local function count(name) h.calls[name]=(h.calls[name] or 0)+1 end
  h.count=function(name) return h.calls[name] or 0 end
  h.config={runDirectory='C:/beamrt-fixture/run',
    controllerSourcePath='C:/beamrt-fixture/source/controller.lua',
    adapterSourcePath='C:/beamrt-fixture/source/engine_adapter.lua',
    controller={token='0123456789abcdef0123456789abcdef',expectedLevel='west_coast_usa',
      loadTimeout=300,captureTimeout=120,overallTimeout=480,
      stableSeconds=2,stableFrames=8,quitGrace=10}}
  h.path=function(name) return h.config.runDirectory..'/'..name end
  h.args={'BeamNG.drive.x64.exe','-level','west_coast_usa',
    '-beamrtObservationToken',h.config.controller.token}
  h.objects.approval={token=h.config.controller.token,
    scope='beamrt-unattended-observation-v1',allow=true}
  h.objects.context={token=h.config.controller.token,expectedPid=12345}
  h.files[h.path('launch-approval.json')]='approval'
  h.files[h.path('process-context.json')]='context'
  local function fileOpen(path,mode)
    count('open')
    if h.openErrors[path] then return nil,'injected open error',h.openErrors[path] end
    if mode=='rb' and h.files[path]==nil then return nil,'missing',2 end
    if mode=='wb' then h.files[path]='' end
    local file={}
    function file:read(limit)
      count('read'); if h.readErrors[path] then error('injected read error') end
      return string.sub(h.files[path],1,limit)
    end
    function file:write(bytes)
      count('write'); if h.failWrite then return nil,'injected write error' end
      h.files[path]=(h.files[path] or '')..bytes; return self
    end
    function file:close() count('close'); if h.failClose then return nil,'injected close error' end; return true end
    return file
  end
  h.beamrt={
    start=function() count('startGI'); h.giEnabled=true; return h.startResult~=false end,
    getLightingAuditState=function() return {enabled=h.giEnabled,mode=h.giMode} end
  }
  h.env={io={open=fileOpen},os={clockhp=function() count('clock'); return h.time end},
    Engine={getStartingArgs=function() count('args'); return h.args end},
    jsonDecode=function(raw)
      count('decode'); if h.decodeHook then h.decodeHook(raw) end
      if h.decodeErrors[raw] then error('injected decode error') end
      return h.objects[raw]
    end,
    jsonEncode=function(value)
      count('encode'); h.encoded=h.encoded+1; local bytes='encoded'..h.encoded
      h.objects[bytes]=value; return bytes
    end,
    dofile=function(path)
      count('dofile')
      if path==h.config.adapterSourcePath then return Adapter end
      if path==h.config.controllerSourcePath then return Controller end
      error('unexpected physical file')
    end,
    newExtensionProxy=function(object,name)
      count('proxy'); assert(name=='beamrtUnattended')
      return {extName='beamrtUnattended_virtual_1',submitEventSinks=function(self,sinks)
        count('submit'); if h.failSubmit then error('injected hook install failure') end
        if h.falseSubmit then return false end
        h.installedHooks=sinks[1]
      end}
    end,
    setExtensionUnloadMode=function(name,mode)
      count('unloadMode'); assert(name=='beamrtUnattended_virtual_1' and mode=='manual')
      if h.failRetention then error('injected retention failure') end
      if h.falseRetention then return false end
      h.manualNames=h.manualNames or {}; h.manualNames[name]=true
    end,
    getMissionFilename=function() return h.filename end,
    core_levels={getLevelName=function(path) count('level'); return h.level or 'west_coast_usa' end},
    core_modmanager={isReady=function() return h.ready end},
    core_gamestate={loading=function() return h.loading end,
      getGameState=function() return {state=h.gameState} end},
    worldReadyState=2,
    beamrt_main=h.beamrt,
    quit=function() count('quit') end,
    extensions={load=function(name) count('load'); assert(name=='beamrt/main'); h.env.beamrt_main=h.beamrt end}
  }
  h.env.os.execute=function() count('kill'); error('process execution forbidden') end
  h.env.os.exit=function() count('kill'); error('process exit forbidden') end
  h.bootstrap=function() return Bootstrap(h.config,h.env) end
  h.new=function() return Adapter.new(h.config,h.env) end
  h.receipt=function()
    h.objects.ack={token=h.config.controller.token,kind='receipt_validated',expectedPid=12345,
      resourceABI=7,profile=2,mode=1,cbvProbeBytes=0,digest=string.rep('b',64)}
    h.files[h.path('driver-ack.json')]='ack'
  end
  h.ownerStop=function()
    h.objects.owner_stop={token=h.config.controller.token,expectedPid=12345,
      kind='normal_quit_requested'}
    h.files[h.path('owner-stop.json')]='owner_stop'
  end
  return h
end
"""


class ControllerContracts:
    runtime = None

    def setUp(self):
        self.lua = self.runtime(unpack_returned_tuples=True)
        self.lua.globals().Controller = self.lua.execute((DRIVER / "controller.lua").read_text())
        self.lua.execute(HARNESS)
        self.h = self.lua.globals().makeHarness()

    def state(self):
        return self.h.controller.status()

    def stopped(self, reason=None):
        state = self.state()
        self.assertTrue(state.quitRequested)
        self.assertEqual(state.quitCalls, 1)
        self.assertEqual(self.h.count("requestQuit"), 1)
        self.assertFalse(state.processExitVerified)
        if reason:
            self.assertEqual(state.reason, reason)

    def test_constructor_and_unarmed_callbacks_are_inert(self):
        self.assertEqual(self.state().phase, "unarmed")
        self.assertEqual(len(list(self.h.calls.keys())), 0)
        self.h.controller.update()
        self.h.controller.missionStarted()
        self.h.controller.missionEnded()
        self.h.controller.abort("not_owned")
        self.assertEqual(len(list(self.h.calls.keys())), 0)
        self.assertFalse(self.state().armed)

    def test_optional_owner_stop_is_inert_until_claim_and_precedes_actions(self):
        self.h.enableOwnerStop()
        self.h.ownerStopResult = True
        self.h.tick()
        self.assertEqual(self.h.count("pollOwnerStop"), 0)
        self.assertEqual(self.h.count("requestQuit"), 0)
        self.assertTrue(self.h.arm())
        self.h.tick(300, 100)
        self.stopped("owner_shutdown_requested")
        self.assertEqual(self.h.count("pollOwnerStop"), 1)
        for method in ("sample", "startGI", "pollAck"):
            self.assertEqual(self.h.count(method), 0)
        self.h.tick(11, 100); self.h.tick(100, 100)
        self.assertEqual(self.h.count("pollOwnerStop"), 1)
        self.assertEqual(self.state().phase, "quit_unconfirmed")
        self.assertEqual(self.h.count("requestQuit"), 1)
        self.assertFalse(self.state().processExitVerified)

    def test_invalid_owner_stop_api_or_result_fails_closed(self):
        constructor = self.lua.eval("function(config,api) return pcall(Controller.new,config,api) end")
        h = self.lua.globals().makeHarness(); h.api.pollOwnerStop = True
        self.assertFalse(constructor(h.config, h.api)[0])
        self.assertEqual(len(list(h.calls.keys())), 0)
        for value in (None, 1, "true", self.lua.table()):
            h = self.lua.globals().makeHarness(); h.enableOwnerStop(); h.arm()
            h.ownerStopResult = value; h.tick()
            self.assertEqual(h.controller.status().reason, "owner_stop_invalid")
            self.assertEqual(h.count("requestQuit"), 1)
            self.assertEqual(h.count("sample"), 0)
            self.assertFalse(h.controller.status().processExitVerified)
        h = self.lua.globals().makeHarness(); h.enableOwnerStop(); h.arm()
        h.throws.pollOwnerStop = True; h.tick()
        self.assertEqual(h.controller.status().reason, "owner_stop_invalid")
        self.assertEqual(h.count("requestQuit"), 1)
        self.assertEqual(h.count("sample"), 0)

    def test_reentrant_owner_stop_poll_cannot_start_gi_or_quit_twice(self):
        self.h.enableOwnerStop(); self.h.arm(); self.h.ready()
        self.lua.execute("local h=...; h.hooks.pollOwnerStop=function() h.controller.update() end", self.h)
        self.h.ownerStopResult = True; self.h.tick(2, 8)
        self.stopped("reentrant_callback")
        self.assertTrue(self.state().reentrancyObserved)
        self.assertEqual(self.h.count("pollOwnerStop"), 1)
        self.assertEqual(self.h.count("sample"), 0)
        self.assertEqual(self.h.count("startGI"), 0)
        self.h.tick(11, 100)
        self.assertEqual(self.h.count("requestQuit"), 1)

    def test_exact_arm_token_and_single_claim(self):
        self.assertFalse(self.h.controller.arm("f" * 32))
        self.assertEqual(self.state().reason, "arm_token_mismatch")
        self.assertFalse(self.h.arm())
        self.assertEqual(self.h.count("claim"), 0)
        self.assertEqual(self.h.count("requestQuit"), 0)

    def test_claim_failure_and_throw_do_not_quit_unowned_game(self):
        for throwing in (False, True):
            h = self.lua.globals().makeHarness()
            h.claimResult = False
            h.throws.claim = throwing
            self.assertFalse(h.arm())
            self.assertEqual(h.controller.status().reason, "claim_refused")
            self.assertFalse(h.controller.status().armed)
            self.assertEqual(h.count("claim"), 1)
            self.assertEqual(h.count("requestQuit"), 0)

    def test_readiness_requires_both_time_and_rendered_frames(self):
        self.assertTrue(self.h.arm())
        self.assertTrue(self.h.ready())
        self.h.tick()
        self.h.tick(2, 7)
        self.assertEqual(self.h.count("startGI"), 0)
        self.h.tick(0, 1)
        self.assertEqual(self.h.count("startGI"), 1)
        self.assertEqual(self.h.count("pollAck"), 0)
        self.assertFalse(self.state().giConfirmed)
        self.h.tick(0, 20)
        self.assertEqual(self.h.count("startGI"), 1)
        self.assertEqual(self.h.count("pollAck"), 0)

    def test_frame_delta_does_not_replace_time_requirement(self):
        self.h.arm(); self.h.ready(); self.h.tick()
        self.h.tick(1.99, 100)
        self.assertEqual(self.h.count("startGI"), 0)
        self.h.tick(0.02, 0)
        self.assertEqual(self.h.count("startGI"), 1)

    def test_missing_mission_event_never_starts_gi(self):
        self.h.arm()
        self.lua.execute("local h=...; h.sample={level='west_coast_usa',missionStarted=true,modReady=true,loading=false,freeroam=true,worldReadyState=2,renderFrames=100,giEnabled=false,giMode='off'}", self.h)
        self.h.tick(); self.h.tick(3, 100)
        self.assertEqual(self.h.count("startGI"), 0)
        self.h.tick(297, 1)
        self.stopped("load_timeout")

    def test_each_readiness_field_gates_start_and_resets_window(self):
        fields = {"missionStarted": False, "modReady": False, "loading": True,
                  "freeroam": False, "worldReadyState": 1, "level": ""}
        for field, bad in fields.items():
            with self.subTest(field=field):
                h = self.lua.globals().makeHarness()
                h.arm(); h.ready(); h.tick(); h.tick(1, 8)
                good = h.sample[field]
                h.sample[field] = bad
                h.tick(0.5, 8)
                h.sample[field] = good
                h.tick(0.5, 8); h.tick(1.9, 8)
                self.assertEqual(h.count("startGI"), 0)
                h.tick(0.11, 0)
                self.assertEqual(h.count("startGI"), 1)

    def test_world_ready_state_two_is_not_inferred_from_mission(self):
        self.h.arm(); self.h.ready()
        for state in (-1, 0, 1):
            self.h.sample.worldReadyState = state
            self.h.tick(3, 20)
            self.assertEqual(self.h.count("startGI"), 0)
        self.h.sample.worldReadyState = 2
        self.h.tick(); self.h.tick(2, 8)
        self.assertEqual(self.h.count("startGI"), 1)

    def test_start_must_succeed_then_be_confirmed_by_later_sample(self):
        self.h.start()
        self.h.sample.giEnabled = True
        self.h.sample.giMode = "reflection"
        self.h.tick(1, 1)
        self.assertFalse(self.state().giConfirmed)
        self.assertEqual(self.h.count("pollAck"), 0)
        self.h.sample.giMode = "lighting"
        self.h.tick()
        self.assertTrue(self.state().giConfirmed)
        self.assertEqual(self.h.count("pollAck"), 1)
        self.assertEqual(self.state().phase, "waiting_receipt")

    def test_start_gi_false_or_error_stops_once(self):
        for throwing in (False, True):
            h = self.lua.globals().makeHarness()
            h.startResult = False; h.throws.startGI = throwing
            h.arm(); h.ready(); h.tick(); h.tick(2, 8)
            self.assertEqual(h.controller.status().reason, "gi_start_failed")
            self.assertEqual(h.count("startGI"), 1)
            self.assertEqual(h.count("requestQuit"), 1)
            h.tick(1, 10)
            self.assertEqual(h.count("startGI"), 1)

    def test_missing_gi_confirmation_deadline(self):
        self.h.start(); self.h.tick(9.99, 8)
        self.assertFalse(self.state().quitRequested)
        self.h.tick(0.01, 0)
        self.stopped("gi_not_enabled")
        self.assertEqual(self.h.count("pollAck"), 0)

    def test_valid_host_receipt_requests_quit_not_exit_proof(self):
        self.h.start(); self.h.ack = self.h.validAck()
        self.assertEqual(self.h.count("pollAck"), 0)
        self.h.confirm()
        self.stopped("receipt_validated")
        self.assertTrue(self.state().receiptValidated)
        self.assertEqual(self.state().receiptPid, 12345)
        self.assertEqual(self.state().receiptDigest, "a" * 64)
        self.assertTrue(self.state().quitCallReturned)
        self.h.tick(9.9, 100)
        self.assertEqual(self.state().phase, "quit_requested")
        self.h.tick(0.11, 100)
        self.assertEqual(self.state().phase, "quit_unconfirmed")
        self.h.tick(100, 100)
        self.assertEqual(self.h.count("requestQuit"), 1)
        self.assertFalse(self.state().processExitVerified)

    def test_host_refusal_is_not_receipt_success(self):
        self.h.start(); self.h.ack = self.h.validAck("host_refused"); self.h.confirm()
        self.stopped("host_refused")
        self.assertFalse(self.state().receiptValidated)

    def test_raw_receipt_like_table_is_not_host_ack(self):
        self.h.start(); self.h.ack = self.lua.table_from({"receipt": "exists"}); self.h.confirm()
        self.stopped("invalid_ack")
        self.assertFalse(self.state().receiptValidated)

    def test_malformed_stale_foreign_or_extended_ack_is_rejected(self):
        mutants = {"token": "f" * 32, "kind": "receipt_exists", "expectedPid": 12346,
                   "resourceABI": 6, "profile": 1, "mode": 0, "cbvProbeBytes": 4,
                   "digest": "g" * 64, "extra": True}
        for field, value in mutants.items():
            with self.subTest(field=field):
                h = self.lua.globals().makeHarness(); h.start()
                h.ack = h.validAck(); h.ack[field] = value; h.confirm()
                self.assertEqual(h.controller.status().reason, "invalid_ack")
                self.assertFalse(h.controller.status().receiptValidated)
                self.assertEqual(h.count("requestQuit"), 1)
        for pid in (-1, 1.5, 4294967296, float("nan"), float("inf")):
            h = self.lua.globals().makeHarness(); h.start()
            h.ack = h.validAck(); h.ack.expectedPid = pid; h.confirm()
            self.assertEqual(h.controller.status().reason, "invalid_ack")

    def test_absent_ack_waits_until_capture_deadline(self):
        self.h.start(); self.h.confirm(); self.h.tick(119.9, 10)
        self.assertFalse(self.state().quitRequested)
        self.h.tick(0.11, 1)
        self.stopped("capture_timeout")
        self.assertFalse(self.state().receiptValidated)

    def test_absolute_overall_deadline_cannot_be_reset_by_readiness(self):
        self.h.config.overallTimeout = 20
        self.h.controller = self.lua.globals().Controller.new(self.h.config, self.h.api)
        self.h.arm(); self.h.ready(); self.h.tick(19, 1)
        self.h.sample.loading = True; self.h.tick(0.5, 1)
        self.h.sample.loading = False; self.h.tick(0.51, 1)
        self.stopped("overall_timeout")
        self.assertEqual(self.h.count("startGI"), 0)

    def test_unexpected_level_mission_end_reload_and_rearm_stop(self):
        operations = ("level", "end", "reload", "rearm")
        for operation in operations:
            with self.subTest(operation=operation):
                h = self.lua.globals().makeHarness(); h.arm(); h.ready()
                if operation == "level":
                    h.sample.level = "east_coast_usa"; h.tick()
                    reason = "unexpected_level"
                elif operation == "end":
                    h.controller.missionEnded(); reason = "mission_ended"
                elif operation == "reload":
                    h.controller.missionStarted(); reason = "multiple_missions"
                else:
                    h.arm(); reason = "rearm_refused"
                self.assertEqual(h.controller.status().reason, reason)
                self.assertEqual(h.count("requestQuit"), 1)
                self.assertEqual(h.count("claim"), 1)

    def test_post_start_readiness_and_gi_regression_stop(self):
        for mode in ("loading", "worldReadyState", "giEnabled", "giMode"):
            with self.subTest(mode=mode):
                h = self.lua.globals().makeHarness(); h.start(); h.confirm()
                h.sample[mode] = {"loading": True, "worldReadyState": 1,
                                  "giEnabled": False, "giMode": "reflection"}[mode]
                h.tick()
                self.assertEqual(h.controller.status().reason,
                                 "readiness_lost" if mode in ("loading", "worldReadyState") else "gi_state_changed")
                self.assertEqual(h.count("requestQuit"), 1)

    def test_invalid_and_regressing_clock(self):
        for value in (float("nan"), float("inf"), -1):
            h = self.lua.globals().makeHarness(); h.time = value
            self.assertFalse(h.arm())
            self.assertEqual(h.count("claim"), 0)
            self.assertEqual(h.count("requestQuit"), 0)
            h = self.lua.globals().makeHarness(); h.arm(); h.time = value; h.tick()
            self.assertEqual(h.controller.status().reason, "invalid_clock")
            self.assertEqual(h.count("requestQuit"), 1)
        self.h.time = 10; self.h.arm(); self.h.time = 9; self.h.tick()
        self.stopped("clock_regressed")

    def test_regressing_render_counter_and_invalid_sample(self):
        self.h.arm(); self.h.ready(); self.h.sample.renderFrames = 10; self.h.tick()
        self.h.sample.renderFrames = 9; self.h.tick()
        self.stopped("render_counter_regressed")
        mutants = {"level": 7, "modReady": 1, "loading": "false", "missionStarted": 1,
                   "freeroam": 1, "worldReadyState": 3, "renderFrames": float("nan"),
                   "giEnabled": 0, "giMode": 1}
        for field, value in mutants.items():
            h = self.lua.globals().makeHarness(); h.arm(); h.ready()
            h.sample[field] = value; h.tick()
            self.assertEqual(h.controller.status().reason, "invalid_sample")
            self.assertEqual(h.count("requestQuit"), 1)

    def test_api_errors_fail_closed(self):
        for method, reason in (("sample", "sample_error"), ("pollAck", "ack_read_error")):
            h = self.lua.globals().makeHarness(); h.start(); h.throws[method] = True; h.confirm()
            self.assertEqual(h.controller.status().reason, reason)
            self.assertEqual(h.count("requestQuit"), 1)

    def test_audit_failure_stops_and_never_masks_shutdown(self):
        self.h.emitResult = False
        self.assertFalse(self.h.arm())
        self.stopped("event_write_failed")
        self.assertTrue(self.state().auditFailed)
        self.assertTrue(self.state().quitCallReturned)

    def test_failed_gi_start_audit_never_calls_or_counts_start(self):
        self.h.arm(); self.h.ready(); self.h.tick()
        self.h.failEvent = "gi_start_requested"
        self.h.tick(2, 8)
        self.stopped("event_write_failed")
        self.assertTrue(self.state().auditFailed)
        self.assertEqual(self.state().giStartCalls, 0)
        self.assertEqual(self.h.count("startGI"), 0)

    def test_quit_throw_or_false_is_truthful_and_never_retried(self):
        for throwing in (False, True):
            h = self.lua.globals().makeHarness(); h.start(); h.confirm()
            h.quitResult = False; h.throws.requestQuit = throwing
            h.ack = h.validAck(); h.tick()
            state = h.controller.status()
            self.assertTrue(state.quitCallError)
            self.assertFalse(state.quitCallReturned)
            self.assertFalse(state.processExitVerified)
            h.tick(11, 100); h.controller.abort("again"); h.controller.missionEnded()
            self.assertEqual(h.count("requestQuit"), 1)
            self.assertEqual(h.controller.status().phase, "quit_unconfirmed")

    def test_reentrant_injected_callbacks_stop_without_second_action(self):
        for method in ("claim", "sample", "startGI", "pollAck", "emit", "requestQuit"):
            with self.subTest(method=method):
                h = self.lua.globals().makeHarness()
                self.lua.execute("local h,method=...; h.hooks[method]=function() h.controller.update() end", h, method)
                if method in ("claim", "emit"):
                    h.arm()
                elif method == "sample":
                    h.arm(); h.ready(); h.tick()
                else:
                    h.start(); h.confirm()
                    if method == "requestQuit":
                        h.controller.abort("fixture_abort")
                self.assertTrue(h.controller.status().reentrancyObserved)
                self.assertLessEqual(h.count("requestQuit"), 1)
                self.assertLessEqual(h.count("startGI"), 1)
                self.assertFalse(h.controller.status().processExitVerified)
                if h.controller.status().armed:
                    self.assertTrue(h.controller.status().quitRequested)

    def test_status_and_config_are_copied(self):
        state = self.state(); state.armed = True; state.phase = "forged"
        self.assertFalse(self.state().armed)
        self.h.config.token = "f" * 32
        self.assertTrue(self.h.controller.arm(TOKEN))
        self.h.config.overallTimeout = 999999
        self.h.tick(480)
        self.stopped("overall_timeout")

    def test_invalid_configuration_has_no_api_calls(self):
        invalid = {"token": "F" * 32, "expectedPid": 0, "expectedLevel": "other", "loadTimeout": 301,
                   "captureTimeout": 121, "overallTimeout": 481, "stableSeconds": 0,
                   "stableFrames": 8.5, "quitGrace": 31}
        constructor = self.lua.eval("function(config,api) return pcall(Controller.new,config,api) end")
        for field, value in invalid.items():
            h = self.lua.globals().makeHarness(); h.config[field] = value
            result = constructor(h.config, h.api)
            self.assertFalse(result[0])
            self.assertEqual(len(list(h.calls.keys())), 0)


class ControllerLua51(ControllerContracts, unittest.TestCase):
    runtime = Lua51


class ControllerLuaJIT21(ControllerContracts, unittest.TestCase):
    runtime = LuaJIT21


class EngineContracts:
    runtime = None

    def setUp(self):
        self.lua = self.runtime(unpack_returned_tuples=True)
        for name, filename in (("Controller", "controller.lua"), ("Adapter", "engine_adapter.lua"),
                               ("Bootstrap", "bootstrap.lua")):
            self.lua.globals()[name] = self.lua.execute((DRIVER / filename).read_text())
        self.lua.execute(ENGINE_HARNESS)
        self.h = self.lua.globals().makeEngineHarness()

    def runtime_and_claim(self):
        runtime = self.h.new()
        self.assertTrue(runtime.validateContext())
        self.assertEqual(runtime.expectedPid, 12345)
        self.assertTrue(runtime.api.claim(TOKEN))
        return runtime

    def test_all_module_imports_and_adapter_constructor_are_inert(self):
        lua = self.runtime(unpack_returned_tuples=True)
        lua.execute("""
          calls=0
          local function forbidden(...) calls=calls+1; error('import side effect') end
          io={open=forbidden}; os={execute=forbidden,exit=forbidden,clockhp=forbidden}
          Engine={getStartingArgs=forbidden}; quit=forbidden; dofile=forbidden
          extensions={load=forbidden}; newExtensionProxy=forbidden
        """)
        for filename in ("controller.lua", "engine_adapter.lua", "bootstrap.lua"):
            self.assertIsNotNone(lua.execute((DRIVER / filename).read_text()))
        self.assertEqual(lua.globals().calls, 0)
        runtime = self.h.new()
        self.assertIsNotNone(runtime.api)
        self.assertEqual(len(list(self.h.calls.keys())), 0)

    def test_explicit_context_and_claim_bind_pid_and_persistent_marker(self):
        runtime = self.runtime_and_claim()
        marker = self.h.files[self.h.path("started.json")]
        self.assertIn(TOKEN, marker)
        self.assertIn('"expectedPid":12345', marker)
        self.assertFalse(runtime.api.claim(TOKEN))
        replay = self.h.new()
        refused = replay.validateContext()
        self.assertIsNone(refused[0])
        self.assertEqual(self.h.count("startGI"), 0)
        self.assertEqual(self.h.count("quit"), 0)

    def test_zero_indexed_engine_arguments_are_supported(self):
        self.h.args = self.lua.table_from({0: "game.exe", 1: "-level", 2: "west_coast_usa",
                                         3: "-beamrtObservationToken", 4: TOKEN})
        self.assertTrue(self.h.new().validateContext())

    def test_wrong_duplicate_case_equal_or_sparse_bound_arguments_refuse(self):
        mutants = (
            ["game", "-level", "east_coast_usa", "-beamrtObservationToken", TOKEN],
            ["game", "-level", "west_coast_usa", "-beamrtObservationToken", "f" * 32],
            ["game", "-level", "west_coast_usa", "-level", "west_coast_usa", "-beamrtObservationToken", TOKEN],
            ["game", "-level", "west_coast_usa", "-beamrtObservationToken", TOKEN, "-beamrtObservationToken", TOKEN],
            ["game", "-Level", "west_coast_usa", "-beamrtObservationToken", TOKEN],
            ["game", "-level=west_coast_usa", "-beamrtObservationToken", TOKEN],
            ["game", "-level", "west_coast_usa", "-beamrtObservationToken=" + TOKEN],
        )
        for values in mutants:
            h = self.lua.globals().makeEngineHarness(); h.args = self.lua.table_from(values)
            result = h.bootstrap()
            self.assertIsNone(result[0])
            self.assertEqual(h.count("startGI"), 0)
            self.assertEqual(h.count("quit"), 0)
            self.assertEqual(h.count("submit"), 0)
        self.h.args[2] = None
        self.assertIsNone(self.h.new().validateContext()[0])

    def test_missing_foreign_extra_or_denied_context_refuses_without_ownership(self):
        variants = ("approval_missing", "process_missing", "approval_foreign", "approval_extra",
                    "approval_denied", "process_foreign", "process_extra", "process_bad_pid", "started_denied")
        for variant in variants:
            with self.subTest(variant=variant):
                h = self.lua.globals().makeEngineHarness()
                if variant.endswith("missing"):
                    h.files[h.path("launch-approval.json" if variant.startswith("approval") else "process-context.json")] = None
                elif variant == "approval_foreign": h.objects.approval.token = "f" * 32
                elif variant == "approval_extra": h.objects.approval.other = True
                elif variant == "approval_denied": h.objects.approval.allow = False
                elif variant == "process_foreign": h.objects.context.token = "f" * 32
                elif variant == "process_extra": h.objects.context.other = True
                elif variant == "process_bad_pid": h.objects.context.expectedPid = 0
                else: h.openErrors[h.path("started.json")] = 13
                result = h.bootstrap()
                self.assertIsNone(result[0])
                self.assertEqual(h.count("startGI"), 0)
                self.assertEqual(h.count("quit"), 0)
                self.assertEqual(h.count("submit"), 0)

    def test_context_pid_cannot_change_between_validation_and_claim(self):
        runtime = self.h.new()
        self.assertTrue(runtime.validateContext())
        self.h.objects.context.expectedPid = 12346
        self.assertFalse(runtime.api.claim(TOKEN))
        self.assertEqual(runtime.expectedPid, 12345)
        self.assertEqual(self.h.count("write"), 0)

    def test_stale_ack_events_or_owner_stop_refuse_before_arm_without_overwrite(self):
        for leaf in ("driver-ack.json", "unattended-events.jsonl", "owner-stop.json"):
            for existing in ("", "prior run evidence must survive"):
                with self.subTest(leaf=leaf, existing=bool(existing)):
                    h = self.lua.globals().makeEngineHarness()
                    path = h.path(leaf); h.files[path] = existing
                    run, reason = h.bootstrap()
                    self.assertIsNone(run)
                    self.assertIn("already_present", reason)
                    self.assertEqual(h.files[path], existing)
                    self.assertIsNone(h.files[h.path("started.json")])
                    for operation in ("write", "encode", "startGI", "load", "quit", "submit"):
                        self.assertEqual(h.count(operation), 0)
        for leaf in ("driver-ack.json", "unattended-events.jsonl", "owner-stop.json"):
            h = self.lua.globals().makeEngineHarness()
            h.openErrors[h.path(leaf)] = 13
            run, reason = h.bootstrap()
            self.assertIsNone(run)
            self.assertIn("absence_not_proven", reason)
            self.assertIsNone(h.files[h.path("started.json")])
            self.assertEqual(h.count("write"), 0)
            self.assertEqual(h.count("startGI"), 0)
            self.assertEqual(h.count("quit"), 0)

    def test_ack_events_or_owner_stop_appearing_after_validation_block_claim(self):
        for leaf in ("driver-ack.json", "unattended-events.jsonl", "owner-stop.json"):
            with self.subTest(leaf=leaf):
                h = self.lua.globals().makeEngineHarness(); runtime = h.new()
                self.assertTrue(runtime.validateContext())
                path = h.path(leaf); h.files[path] = "racing evidence must survive"
                self.assertFalse(runtime.api.claim(TOKEN))
                self.assertEqual(h.files[path], "racing evidence must survive")
                self.assertIsNone(h.files[h.path("started.json")])
                for operation in ("write", "encode", "startGI", "load", "quit", "submit"):
                    self.assertEqual(h.count(operation), 0)

    def test_claim_write_close_or_wrong_token_refuses_before_gi(self):
        for failure in ("write", "close", "token"):
            h = self.lua.globals().makeEngineHarness(); runtime = h.new()
            if failure == "write": h.failWrite = True
            elif failure == "close": h.failClose = True
            result = runtime.api.claim("f" * 32 if failure == "token" else TOKEN)
            self.assertFalse(result)
            self.assertEqual(h.count("startGI"), 0)
            self.assertEqual(h.count("quit"), 0)

    def test_sample_uses_actual_hooks_world_state_and_lighting_audit(self):
        runtime = self.runtime_and_claim()
        hooks = runtime.bind(self.lua.table_from({
            name: self.lua.eval("function() return true end")
            for name in ("update", "missionStarted", "missionEnded", "abort")}))
        before = runtime.api.sample()
        self.assertFalse(before.missionStarted)
        self.assertEqual(before.renderFrames, 0)
        hooks.onClientStartMission()
        for _ in range(8): hooks.onPreRender()
        self.h.env.worldReadyState = 1
        sample = runtime.api.sample()
        self.assertTrue(sample.missionStarted)
        self.assertEqual(sample.renderFrames, 8)
        self.assertEqual(sample.worldReadyState, 1)
        self.assertFalse(sample.giEnabled)
        hooks.onClientEndMission()
        self.assertFalse(runtime.api.sample().missionStarted)

    def test_gi_start_and_normal_quit_are_single_calls_without_process_kill(self):
        runtime = self.runtime_and_claim()
        self.assertTrue(runtime.api.startGI())
        self.assertFalse(runtime.api.startGI())
        self.assertEqual(self.h.count("startGI"), 1)
        self.assertTrue(runtime.api.sample().giEnabled)
        self.assertTrue(runtime.api.requestQuit())
        self.assertFalse(runtime.api.requestQuit())
        self.assertEqual(self.h.count("quit"), 1)
        self.assertEqual(self.h.count("kill"), 0)

    def test_explicit_gi_loader_only_runs_when_needed(self):
        self.h.env.beamrt_main = None
        runtime = self.runtime_and_claim()
        self.assertFalse(runtime.api.sample().giEnabled)
        self.assertTrue(runtime.api.startGI())
        self.assertEqual(self.h.count("load"), 1)
        self.assertEqual(self.h.count("startGI"), 1)
        self.assertFalse(runtime.api.startGI())

    def test_raw_receipt_presence_is_never_host_validation(self):
        runtime = self.runtime_and_claim()
        self.h.files[self.h.path("resource.receipt")] = "not an acknowledgement"
        self.h.files[self.h.path("validated-ack.json")] = "wrong fixed filename"
        self.assertIsNone(runtime.api.pollAck())
        self.h.receipt()
        self.assertEqual(runtime.api.pollAck().expectedPid, 12345)
        self.h.objects.ack.expectedPid = 12346
        check = self.lua.eval("function(fn) return pcall(fn) end")
        self.assertFalse(check(runtime.api.pollAck)[0])
        self.assertEqual(self.h.count("quit"), 0)

    def test_owner_stop_poll_requires_claim_and_missing_request_is_false(self):
        runtime = self.h.new()
        check = self.lua.eval("function(fn) return pcall(fn) end")
        self.assertFalse(check(runtime.api.pollOwnerStop)[0])
        self.assertEqual(self.h.count("open"), 0)
        self.assertEqual(self.h.count("quit"), 0)
        self.assertTrue(runtime.api.claim(TOKEN))
        self.assertFalse(runtime.api.pollOwnerStop())
        self.assertEqual(self.h.count("quit"), 0)

    def test_owned_stop_during_loading_and_receipt_wait_requests_quit_once(self):
        for phase in ("loading", "waiting_receipt"):
            with self.subTest(phase=phase):
                h = self.lua.globals().makeEngineHarness()
                if phase == "loading":
                    h.loading = True; h.ready = False; h.filename = ""
                    h.env.worldReadyState = 0
                run, reason = h.bootstrap()
                self.assertIsNone(reason)
                if phase == "waiting_receipt":
                    run.hooks.onClientStartMission(); run.hooks.onUpdate()
                    for _ in range(8): run.hooks.onPreRender()
                    h.time = 2; run.hooks.onUpdate(); run.hooks.onUpdate()
                    self.assertEqual(run.controller.status().phase, "waiting_receipt")
                    self.assertEqual(h.count("startGI"), 1)
                    h.receipt()  # An owner stop takes precedence even over a valid ACK.
                else:
                    self.assertEqual(h.count("startGI"), 0)
                h.ownerStop(); run.hooks.onUpdate()
                state = run.controller.status()
                self.assertEqual(state.reason, "owner_shutdown_requested")
                self.assertTrue(state.quitRequested)
                self.assertTrue(state.quitCallReturned)
                self.assertFalse(state.receiptValidated)
                self.assertFalse(state.processExitVerified)
                self.assertEqual(h.count("quit"), 1)
                for _ in range(3): run.hooks.onUpdate()
                h.time = h.time + 11; run.hooks.onUpdate()
                self.assertEqual(run.controller.status().phase, "quit_unconfirmed")
                self.assertEqual(h.count("quit"), 1)
                self.assertEqual(h.count("kill"), 0)
                self.assertFalse(run.controller.status().processExitVerified)

    def test_foreign_malformed_and_extended_owner_stops_fail_closed(self):
        mutants = (("token", "f" * 32), ("expectedPid", 12346), ("expectedPid", 0),
                   ("expectedPid", True), ("expectedPid", 1.5),
                   ("expectedPid", 4294967296), ("expectedPid", float("nan")),
                   ("expectedPid", float("inf")), ("kind", "force_quit"),
                   ("extra", True), ("token", None), ("expectedPid", None), ("kind", None))
        for field, value in mutants:
            with self.subTest(field=field, value=value):
                h = self.lua.globals().makeEngineHarness(); run, reason = h.bootstrap()
                self.assertIsNone(reason)
                h.ownerStop(); h.objects.owner_stop[field] = value
                run.hooks.onUpdate()
                self.assertEqual(run.controller.status().reason, "owner_stop_invalid")
                self.assertEqual(h.count("quit"), 1)
                self.assertEqual(h.count("startGI"), 0)
                self.assertFalse(run.controller.status().receiptValidated)
                self.assertFalse(run.controller.status().processExitVerified)
                run.hooks.onUpdate()
                self.assertEqual(h.count("quit"), 1)

    def test_owner_stop_json_open_read_close_and_decode_errors_fail_closed(self):
        for failure in ("json", "oversize", "open", "read", "close", "decode"):
            with self.subTest(failure=failure):
                h = self.lua.globals().makeEngineHarness(); run, reason = h.bootstrap()
                self.assertIsNone(reason)
                h.ownerStop(); path = h.path("owner-stop.json")
                if failure == "json": h.files[path] = "not valid JSON"
                elif failure == "oversize": h.files[path] = "x" * 4097
                elif failure == "open": h.openErrors[path] = 13
                elif failure == "read": h.readErrors[path] = True
                elif failure == "close": h.failClose = True
                else: h.decodeErrors.owner_stop = True
                run.hooks.onUpdate()
                self.assertEqual(run.controller.status().reason, "owner_stop_invalid")
                self.assertEqual(h.count("quit"), 1)
                self.assertEqual(h.count("startGI"), 0)
                self.assertFalse(run.controller.status().receiptValidated)
                self.assertFalse(run.controller.status().processExitVerified)
                self.assertEqual(h.count("kill"), 0)

    def test_reentrant_owner_stop_decode_stops_without_accepting_request(self):
        run, reason = self.h.bootstrap()
        self.assertIsNone(reason)
        self.h.ownerStop()
        self.lua.execute("local h,run=...; h.decodeHook=function(raw) if raw=='owner_stop' then run.hooks.onUpdate() end end", self.h, run)
        run.hooks.onUpdate()
        state = run.controller.status()
        self.assertTrue(state.reentrancyObserved)
        self.assertEqual(state.reason, "reentrant_callback")
        self.assertEqual(self.h.count("quit"), 1)
        self.assertEqual(self.h.count("startGI"), 0)
        self.assertFalse(state.receiptValidated)
        self.assertFalse(state.processExitVerified)
        run.hooks.onUpdate()
        self.assertEqual(self.h.count("quit"), 1)

    def test_bootstrap_executes_real_controller_and_only_quits_after_host_ack(self):
        run, reason = self.h.bootstrap()
        self.assertIsNone(reason)
        self.assertEqual(run.controller.status().phase, "waiting_ready")
        self.assertEqual(self.h.count("submit"), 1)
        self.assertEqual(self.h.count("startGI"), 0)
        run.hooks.onClientStartMission(); run.hooks.onUpdate()
        for _ in range(8): run.hooks.onPreRender()
        self.h.time = 2; run.hooks.onUpdate()
        self.assertEqual(self.h.count("startGI"), 1)
        self.assertEqual(self.h.count("quit"), 0)
        run.hooks.onUpdate()
        self.assertTrue(run.controller.status().giConfirmed)
        self.h.files[self.h.path("resource.receipt")] = "raw only"
        run.hooks.onUpdate()
        self.assertFalse(run.controller.status().receiptValidated)
        self.assertEqual(self.h.count("quit"), 0)
        self.h.receipt(); run.hooks.onUpdate()
        self.assertTrue(run.controller.status().receiptValidated)
        self.assertEqual(run.controller.status().receiptPid, 12345)
        self.assertEqual(self.h.count("quit"), 1)
        self.assertEqual(self.h.count("kill"), 0)
        self.assertFalse(run.controller.status().processExitVerified)

    def test_bootstrap_hook_error_and_reload_abort_normally(self):
        self.h.failSubmit = True
        result = self.h.bootstrap()
        self.assertIsNone(result[0])
        self.assertEqual(result[1], "hook_install_failed")
        self.assertEqual(self.h.count("quit"), 1)
        self.assertEqual(self.h.count("startGI"), 0)
        h = self.lua.globals().makeEngineHarness(); h.falseSubmit = True
        result = h.bootstrap()
        self.assertIsNone(result[0])
        self.assertEqual(result[1], "hook_install_failed")
        self.assertEqual(h.count("quit"), 1)
        self.assertEqual(h.count("startGI"), 0)
        for hook in ("onSerialize", "onDeserialized", "onClientEndMission"):
            h = self.lua.globals().makeEngineHarness(); run, reason = h.bootstrap()
            self.assertIsNone(reason)
            run.hooks[hook]()
            self.assertTrue(run.controller.status().quitRequested)
            self.assertEqual(h.count("quit"), 1)
            self.assertFalse(run.controller.status().processExitVerified)

    def test_bootstrap_requires_manual_retention_api_before_claim(self):
        self.h.env.setExtensionUnloadMode = None
        result = self.h.bootstrap()
        self.assertIsNone(result[0])
        self.assertIn("extension_proxy_unavailable", result[1])
        self.assertEqual(self.h.count("quit"), 0)
        self.assertEqual(self.h.count("startGI"), 0)
        self.assertIsNone(self.h.files[self.h.path("started.json")])

    def test_bootstrap_retention_failure_aborts_claimed_run_without_gi(self):
        for field in ("failRetention", "falseRetention"):
            h = self.lua.globals().makeEngineHarness(); h[field] = True
            result = h.bootstrap()
            self.assertIsNone(result[0]); self.assertEqual(result[1], "hook_retention_failed")
            self.assertEqual(h.count("submit"), 1)
            self.assertEqual(h.count("unloadMode"), 1)
            self.assertEqual(h.count("quit"), 1)
            self.assertEqual(h.count("startGI"), 0)
            self.assertIsNotNone(h.files[h.path("started.json")])

    def test_bootstrap_full_proxy_survives_simulated_freeroam_unload(self):
        run, reason = self.h.bootstrap(); self.assertIsNone(reason)
        self.assertEqual(self.h.count("unloadMode"), 1)
        self.assertTrue(self.h.manualNames["beamrtUnattended_virtual_1"])
        # Mirrors unloadExcept's exact-name exception list; a virtual module's
        # __manuallyLoaded__ flag is not consulted by this engine boundary.
        self.lua.eval("function(h) if not h.manualNames['beamrtUnattended_virtual_1'] then h.installedHooks=nil end end")(self.h)
        self.assertIsNotNone(self.h.installedHooks)
        self.h.installedHooks.onClientStartMission()
        self.assertEqual(run.controller.status().missionCount, 1)

    def test_event_budget_write_failure_and_oversize_json_fail_closed(self):
        runtime = self.runtime_and_claim()
        for _ in range(64):
            self.assertTrue(runtime.api.emit("fixture", self.lua.table_from({"armed": True})))
        self.assertFalse(runtime.api.emit("fixture", self.lua.table_from({"armed": True})))
        self.assertFalse(runtime.api.emit("fixture", self.lua.table_from({"bad": self.lua.table()})))
        h = self.lua.globals().makeEngineHarness(); runtime = h.new()
        h.files[h.path("launch-approval.json")] = "x" * 4097
        self.assertIsNone(runtime.validateContext()[0])


class EngineLua51(EngineContracts, unittest.TestCase):
    runtime = Lua51


class EngineLuaJIT21(EngineContracts, unittest.TestCase):
    runtime = LuaJIT21


if __name__ == "__main__":
    unittest.main()
