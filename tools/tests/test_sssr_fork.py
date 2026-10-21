"""Owned fork control contracts. Engine scheduling/visual parity are not mocked proof."""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()


def method(name):
    return re.search(r'^function M\.' + name + r'\([^\n]*\).*?\nend', MAIN, re.M | re.S).group()


MOCK = r'''
M={};objects={};events={};safe=true;frozen=false;resets=0;applies=0;enabledRequested=false
REFLECTION_TRACE_SHADER_NAME='Original';REFLECTION_EFFECT_NAME='Trace'
MODE_IDS={reflections=1,diffusegi=2};debugMode=2;reflectionOverlayEnabled=true
PROGRESSIVE={sssrFork={backend='experimental',shaderName='Fork',shaderEntry='owned'},
 reflectionSampling={isFrozen=function()return frozen end},reflectionConvergenceEnabled=false,
 rendererCompatibility={check=function()return {safe=safe,reason='Native material buffer conflict.'}end},
 reflectionHit={enabled=true},reflectionReconstruction={mode=1}}
function record(name)table.insert(events,name)end
function findObject(name)return objects[name]end
objects.Original={};objects.Fork={}
objects.Trace={shader='Original',enabled=false,
 getField=function(self,key,index)assert(key=='shader'and index==0);return self.shader end,
 setField=function(self,key,index,value)assert(key=='shader'and index==0);self.shader=value end}
function effectIsEnabled(name)return objects[name]and objects[name].enabled or false end
function createObjects()record('create');if not refuseCreate then objects.Fork={}end end
function resetReflectionHistory(reason,resetGI)assert(resetGI==false);resets=resets+1 end
function applyReflectionShaderConsts()
 applies=applies+1;objects.Trace.shader=PROGRESSIVE.sssrFork.backend=='fork'and'Fork'or'Original'
end
function beamrtLog()end
function M.setMode(mode)assert(mode=='reflections');record('mode');debugMode=1;return true end
function M.openTuner()record('tuner')end
function M.enable()record('enable');enabledRequested=true;objects.Trace.enabled=true;return true end
function M.disable()record('disable');enabledRequested=false;objects.Trace.enabled=false;return true end
function M.setReflectionsEnabled(value)record('overlay');reflectionOverlayEnabled=value;return true end
settings={setValue=function()error('Must not write native settings')end}
im={TreeNodeFlags_DefaultOpen=1,CollapsingHeader1=function()return true end,
 TextWrapped=function()end,SameLine=function()end,
 Button=function(name)return name==clicked end}
function tuningTooltip()end
'''


class SssrFork(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            for name in ('setReflectionTraceBackend', 'setSsrForkEnabled', 'getSsrForkStatus'):
                lua.execute(method(name))
            yield lua

    def test_selection_only_switches_owned_trace_and_reflection_history(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setReflectionTraceBackend('fork'))
            self.assertEqual(lua.globals().objects.Trace.shader, 'Fork')
            self.assertEqual(lua.globals().resets, 1)
            self.assertFalse(lua.globals().enabledRequested)
            self.assertTrue(lua.globals().M.setReflectionTraceBackend('experimental'))
            self.assertEqual(lua.globals().objects.Trace.shader, 'Original')
            self.assertEqual(lua.globals().resets, 2)
            self.assertEqual(len(lua.globals().events), 0)

    def test_idempotent_selection_does_not_reset(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setReflectionTraceBackend('experimental'))
            self.assertEqual(lua.globals().resets, 0)

    def test_real_uniform_upload_selects_the_registered_backend_shader(self):
        start = MAIN.index('  local selectedShader = PROGRESSIVE.sssrFork')
        end = MAIN.index('  PROGRESSIVE.reflectionHit.updateSizes()', start)
        for lua in self.runtimes():
            lua.execute('function bindActual()local traceEffect=objects.Trace\n' + MAIN[start:end] + '\nend')
            lua.execute("PROGRESSIVE.sssrFork.backend='fork';bindActual()")
            self.assertEqual(lua.globals().objects.Trace.shader, 'Fork')
            lua.execute("PROGRESSIVE.sssrFork.backend='experimental';bindActual()")
            self.assertEqual(lua.globals().objects.Trace.shader, 'Original')
            lua.execute('PROGRESSIVE.sssrFork=nil;bindActual()')
            self.assertEqual(lua.globals().objects.Trace.shader, 'Original')

    def test_invalid_backend_and_enabled_values_do_not_mutate(self):
        for lua in self.runtimes():
            for value in (None, True, 1, 'native', 'FORK', ''):
                self.assertFalse(lua.globals().M.setReflectionTraceBackend(value)[0])
            for value in (None, 1, 'true'):
                self.assertFalse(lua.globals().M.setSsrForkEnabled(value)[0])
            self.assertEqual(lua.globals().resets, 0)
            self.assertEqual(len(lua.globals().events), 0)

    def test_capture_frozen_and_convergence_block_changes(self):
        for setting in ('frozen=true', 'PROGRESSIVE.reflectionConvergenceEnabled=true',
                        "PROGRESSIVE.reflectionSourceProbeTarget='#Captured'"):
            for lua in self.runtimes():
                lua.execute(setting)
                self.assertFalse(lua.globals().M.setReflectionTraceBackend('fork')[0])
                self.assertEqual(lua.globals().resets, 0)

    def test_native_on_refuses_before_mode_enable_or_shader_change(self):
        for lua in self.runtimes():
            lua.execute('safe=false')
            ok, reason = lua.globals().M.setSsrForkEnabled(True)
            self.assertFalse(ok)
            self.assertIn('native SSR off', reason)
            self.assertEqual(lua.globals().PROGRESSIVE.sssrFork.backend, 'experimental')
            self.assertEqual(len(lua.globals().events), 0)

    def test_enable_runs_owned_path_without_native_control_calls(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setSsrForkEnabled(True))
            state = lua.globals().M.getSsrForkStatus()
            self.assertTrue(state.active)
            self.assertTrue(state.shaderBound)
            self.assertFalse(state.integratedNativeRendererUsed)
            self.assertFalse(state.nativeSettingsChanged)
            self.assertFalse(state.gameAppearanceVerified)
            self.assertEqual(list(lua.globals().events.values()), ['mode', 'tuner', 'enable'])
            self.assertEqual(state.mipLevels, 1)
            self.assertFalse(state.waterReceivers)
            self.assertFalse(state.nativeDenoiserParity)

    def test_disable_stops_fork_not_unrelated_experimental_renderer(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setSsrForkEnabled(False))
            self.assertEqual(len(lua.globals().events), 0)
            lua.globals().M.setSsrForkEnabled(True)
            lua.execute('events={}')
            self.assertTrue(lua.globals().M.setSsrForkEnabled(False))
            self.assertEqual(list(lua.globals().events.values()), ['disable'])
            self.assertFalse(lua.globals().M.getSsrForkStatus().active)

    def test_disable_gi_overlay_preserves_gi_mode(self):
        for lua in self.runtimes():
            lua.execute("PROGRESSIVE.sssrFork.backend='fork';enabledRequested=true")
            self.assertTrue(lua.globals().M.setSsrForkEnabled(False))
            self.assertTrue(lua.globals().enabledRequested)
            self.assertEqual(lua.globals().debugMode, 2)
            self.assertFalse(lua.globals().reflectionOverlayEnabled)

    def test_missing_shader_refuses_without_changing_backend(self):
        for lua in self.runtimes():
            lua.execute('objects.Fork=nil;refuseCreate=true')
            self.assertFalse(lua.globals().M.setReflectionTraceBackend('fork')[0])
            self.assertEqual(lua.globals().PROGRESSIVE.sssrFork.backend, 'experimental')

    def test_active_status_requires_correct_binding_and_current_compatibility(self):
        for change in ("objects.Trace.shader='Original'", 'safe=false', 'objects.Trace.enabled=false'):
            for lua in self.runtimes():
                lua.globals().M.setSsrForkEnabled(True)
                lua.execute(change)
                self.assertFalse(lua.globals().M.getSsrForkStatus().active)

    def test_fork_excludes_unverified_hit_history_helper(self):
        body = re.search(r'function PROGRESSIVE\.reflectionHit\.configured\(\).*?\nend', MAIN, re.S).group()
        for lua in self.runtimes():
            lua.execute('PROGRESSIVE.reflectionSampling.mode=1;' + body)
            self.assertTrue(lua.globals().PROGRESSIVE.reflectionHit.configured())
            lua.execute("PROGRESSIVE.sssrFork.backend='fork'")
            self.assertFalse(lua.globals().PROGRESSIVE.reflectionHit.configured())

    def test_ui_routes_fork_enable_disable_and_reference(self):
        start = MAIN.index('  if im.CollapsingHeader1("BeamRT SSSR fork (prototype)"')
        block = MAIN[start:MAIN.index('\n  if im.CollapsingHeader1("Reflection comparison lab"', start)]
        for clicked, expected in (('Enable BeamRT fork##SssrFork', 'fork'),
                                  ('Use experimental tracer##SssrFork', 'experimental')):
            for lua in self.runtimes():
                lua.execute('function drawFork()\n' + block + '\nend')
                lua.globals().clicked = clicked
                lua.globals().drawFork()
                self.assertEqual(lua.globals().PROGRESSIVE.sssrFork.backend, expected)

    def test_local_fork_license_and_shader_contract(self):
        folder = ROOT / 'shaders/beamrt/nativeSsr'
        core = (folder / 'ffx_sssr_fork.h.hlsl').read_text()
        adapter = (folder / 'adapter.h.hlsl').read_text()
        trace = (folder / 'traceP_v001.hlsl').read_text()
        self.assertIn('Copyright (c) 2021 Advanced Micro Devices', core)
        self.assertIn('Permission is hereby granted', core)
        self.assertNotIn('WaveActiveCountBits(', core)
        self.assertIn('const int max_mip = 0;', core)
        self.assertIn('#include "ffx_sssr_fork.h.hlsl"', adapter)
        self.assertIn('remaining -= cost', adapter)
        self.assertIn('screenTravel > 1.00001', adapter)
        self.assertIn('#include "adapter.h.hlsl"', trace)
        self.assertNotIn('stepIndex', trace)
        self.assertIn('forkConfidence * beamrtEdgeConfidence', trace)
        self.assertIn('shaders/beamrt/nativeSsr/traceP_v002.hlsl', MAIN)
        self.assertNotIn('PostFxSSSR', adapter + trace)


if __name__ == '__main__':
    unittest.main()
