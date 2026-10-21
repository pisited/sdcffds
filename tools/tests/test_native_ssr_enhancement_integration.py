"""Execute the native SSR experiment's real main.lua wiring offline.

These Lua 5.1/LuaJIT tests prove forwarding, ownership retention and UI routing,
not availability of native object fields or native rendering/performance.
"""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()
PRESETS = (ROOT / 'lua/ge/extensions/beamrt/presets.lua').read_text()
KEY = 'ge/extensions/beamrt/nativeSsrEnhancement'


def method(name):
    found = re.search(r'^function M\.' + re.escape(name) + r'\([^\n]*\).*?\nend', MAIN, re.M | re.S)
    assert found, name
    return found.group()


LOADER_START = MAIN.index('do\n  local key = "' + KEY + '"')
LOADER = MAIN[LOADER_START:MAIN.index('\nlocal LOG_TAG', LOADER_START)]
UI_START = MAIN.index('  if im.CollapsingHeader1("Native SSR: dense-ray comparison"')
NATIVE_UI = MAIN[UI_START:MAIN.index('\n  if im.CollapsingHeader1("Archived BeamRT reflection controls")', UI_START)]
PRESET_UI = re.search(r'  im\.TextUnformatted\("Presets"\)\n.*?'
                      r'(?=  im\.TextUnformatted\("Last preset:)', MAIN, re.S).group()

MOCK = r'''
M={}; events={}; logs={}; nativeStatus={reason='offline mock',requested=false}
nativeReport={readOnly=true,token='diagnostic receipt'};dumpedReports={}
apiOK=true;apiResult={token='forwarded'};nativeOK=true
function record(name,value)table.insert(events,{name=name,value=value})end
function beamrtLog(level,message)table.insert(logs,{level=level,message=message})end
function dump(report)table.insert(dumpedReports,report)end
M._nativeSsrEnhancement={
  enable=function()record('native.enable');return apiOK,apiResult end,
  disable=function(reason)record('native.disable',reason);return nativeOK,apiResult end,
  setComparisonMode=function(mode)record('native.compare',mode);return apiOK,apiResult end,
  getStatus=function()return nativeStatus end,
  inspect=function()record('native.inspect');return nativeReport end,
  update=function()record('native.update')end,
}
settings={setValue=function()error('Unexpected native settings mutation')end}
function createObjects()error('Unexpected renderer creation')end
function applyShaderConsts()error('Unexpected renderer uniforms')end
function finiteNumber(value)return tonumber(value)end
function effectIsEnabled()return false end
function resetTemporalHistory(reason)record('gi.reset',reason)end
function resetReflectionHistory(reason)record('reflection.reset',reason)end
function markAllMaterialCachesStale(reason)record('cache.stale',reason)end
function markSurfelGeometryDirty()record('surfel.dirty')end
function destroyObjects()record('renderer.destroy')end
function syncEffectEnablement()record('renderer.sync')end
function M.setMeshSunShadowsEnabled(value)record('sun',value)end
function M.setMeshLocalLightsEnabled(value)record('lights',value)end
function M.setSharedMeshVisibilityEnabled(value)record('mesh',value)end
PROGRESSIVE={
  refreshRendererCompatibility=function()record('compatibility');return false end,
  waterPreview={enabled=false,
    provider={clear=function(reason)record('water.clear',reason)end},
    sync=function()record('water.sync')end},
  lightingAudit={cancel=function(_,reason)record('audit.cancel',reason)end},
  reflectionReconstruction={},reflectionSampling={},
}
CLEAN_RADIANCE={}
sceneDatabase={invalidate=function(reason)record('scene.invalidate',reason)end,
  scheduleLevelBuild=function(delay)record('scene.schedule',delay)end}
MATERIAL_CACHE_CONFIGS={};enabledRequested=true
tuningWindowOpen={[0]=true};VERSION='offline';uiButtons={};uiText={}
function tuningTooltip(text)assert(type(text)=='string')end
im={TreeNodeFlags_DefaultOpen=1,
  CollapsingHeader1=function()return true end,
  TextWrapped=function(text)table.insert(uiText,text)end,
  TextUnformatted=function(text)table.insert(uiText,text)end,
  SameLine=function()end,Separator=function()end,
  Button=function(text)table.insert(uiButtons,text);return text==clickButton end}
'''


class NativeSsrIntegration(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            for name in ('enableNativeSsrEnhancement', 'disableNativeSsrEnhancement',
                         'setNativeSsrComparison', 'getNativeSsrEnhancementStatus',
                         'logNativeSsrDiagnostics'):
                lua.execute(method(name))
            yield lua

    def events(self, lua):
        return [(entry.name, entry.value) for _, entry in lua.globals().events.items()]

    def test_public_api_forwards_arguments_results_and_failure(self):
        for lua in self.runtimes():
            lua.execute('function assertForward(ok,result)assert(ok==apiOK and result==apiResult)end;'
                        'assertForward(M.enableNativeSsrEnhancement());'
                        'assertForward(M.setNativeSsrComparison("native"));'
                        'apiOK=false;assertForward(M.setNativeSsrComparison("invalid"));'
                        'assertForward(M.enableNativeSsrEnhancement());'
                        'assert(M.getNativeSsrEnhancementStatus()==nativeStatus)')
            self.assertEqual(self.events(lua), [('native.enable', None), ('native.compare', 'native'),
                                              ('native.compare', 'invalid'), ('native.enable', None)])
            self.assertTrue(lua.globals().enabledRequested)
            self.assertEqual(len(lua.globals().logs), 4)

    def test_disable_forwards_restore_failure_without_enabling_custom_renderer(self):
        for lua in self.runtimes():
            lua.execute('nativeOK=false;local ok,result=M.disableNativeSsrEnhancement();'
                        'assert(ok==false and result==apiResult)')
            self.assertEqual(self.events(lua), [('native.disable', 'native SSR experiment stopped')])
            self.assertTrue(lua.globals().enabledRequested)

    def test_diagnostic_wrapper_returns_and_dumps_exact_read_only_report(self):
        for lua in self.runtimes():
            lua.execute('local report=M.logNativeSsrDiagnostics();'
                        'assert(report==nativeReport and dumpedReports[1]==report);'
                        'assert(nativeReport.token=="diagnostic receipt" and nativeReport.readOnly==true)')
            self.assertEqual(self.events(lua), [('native.inspect', None)])
            self.assertTrue(lua.globals().enabledRequested)
            self.assertEqual(len(lua.globals().dumpedReports), 1)
            self.assertIn('read-only', lua.globals().logs[1].message)
            self.assertIn('not GPU execution proof', lua.globals().logs[1].message)

    def test_diagnostic_wrapper_remains_read_only_when_dump_is_unavailable(self):
        for lua in self.runtimes():
            lua.execute('dump=nil;assert(M.logNativeSsrDiagnostics()==nativeReport)')
            self.assertEqual(self.events(lua), [('native.inspect', None)])
            self.assertEqual(len(lua.globals().dumpedReports), 0)
            self.assertTrue(lua.globals().enabledRequested)

    def test_pre_render_updates_native_ownership_before_compatibility(self):
        for lua in self.runtimes():
            lua.execute(method('onPreRender'))
            lua.execute('M.onPreRender(.016,.016,.016)')
            self.assertEqual(self.events(lua)[:3], [('native.update', None), ('compatibility', None),
                                                  ('water.sync', None)])
            self.assertEqual(lua.globals().PROGRESSIVE.reflectionReconstruction.frameDelta, .016)

    def test_settings_hook_stops_native_experiment_before_compatibility_reset(self):
        for lua in self.runtimes():
            lua.execute(method('onSettingsChanged'))
            lua.execute('M.onSettingsChanged()')
            events = self.events(lua)
            self.assertEqual(events[:2], [('native.disable', 'graphics/settings changed'),
                                         ('compatibility', None)])
            self.assertIn(('reflection.reset', 'settings/graphics state changed'), events)

    def test_mission_start_end_and_unload_forward_restoration(self):
        cases = (('onClientStartMission', 'mission changed'),
                 ('onClientEndMission', 'mission ended'),
                 ('onExtensionUnloaded', 'BeamRT unloaded'))
        for name, reason in cases:
            for lua in self.runtimes():
                lua.execute(method(name))
                lua.globals().M[name]()
                self.assertEqual(self.events(lua)[0], ('native.disable', reason), name)
                self.assertEqual(sum(event == 'native.disable' for event, _ in self.events(lua)), 1)

    def test_public_disable_returns_native_failure_and_stops_custom_effects(self):
        for expected in (False, True):
            for lua in self.runtimes():
                lua.execute(method('disable'))
                lua.globals().nativeOK = expected
                self.assertEqual(lua.globals().M.disable(), expected)
                self.assertFalse(lua.globals().enabledRequested)
                self.assertEqual(self.events(lua), [
                    ('native.disable', 'native SSR experiment stopped'), ('sun', False),
                    ('lights', False), ('renderer.sync', None)])

    def test_reload_replaces_module_only_after_successful_restoration(self):
        for runtime in (Lua51, LuaJIT):
            for outcome in ('true', 'false', 'nil', 'error("restore failed")'):
                lua = runtime(unpack_returned_tuples=True)
                lua.execute('M={};reloads=0;restores=0;fresh={token="fresh"};'
                            'previous={token="owned",disable=function(reason)'
                            'assert(reason=="BeamRT module reloaded");restores=restores+1;'
                            + ('return ' + outcome if not outcome.startswith('error') else outcome)
                            + ' end};package.loaded["' + KEY + '"]=previous;'
                            'package.preload["' + KEY + '"]=function()reloads=reloads+1;return fresh end')
                lua.execute(LOADER)
                lua.execute('assert(restores==1);assert(M._nativeSsrEnhancement=='
                            + ('fresh' if outcome == 'true' else 'previous') + ')')
                self.assertEqual(lua.globals().reloads, 1 if outcome == 'true' else 0)

    def test_first_load_requires_module_without_claiming_previous_ownership(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute('M={};fresh={};loads=0;package.loaded["' + KEY + '"]=nil;'
                        'package.preload["' + KEY + '"]=function()loads=loads+1;return fresh end')
            lua.execute(LOADER)
            lua.execute('assert(M._nativeSsrEnhancement==fresh and loads==1)')

    def test_native_ui_remains_available_independently_of_unsafe_custom_compatibility(self):
        legacy_panel = re.search(r'^function M\._tunerPanels\.legacy\(\).*?^end', MAIN, re.M | re.S).group()
        self.assertIn(NATIVE_UI, legacy_panel)
        self.assertNotIn('compatibility.safe', legacy_panel)
        self.assertNotIn('compatibility.safe', NATIVE_UI)
        for lua in self.runtimes():
            lua.execute('function M.getRendererCompatibilityStatus()'
                        'return {safe=false,reason="native SSR active"}end;'
                        'function drawNative()\n' + NATIVE_UI + '\nend')
            lua.globals().drawNative()
            buttons = list(lua.globals().uiButtons.values())
            self.assertEqual(buttons, ['Use dense native rays##NativeSSR',
                                       'Use native baseline##NativeSSR',
                                       'Log native SSR details##NativeSSR'])
            self.assertEqual(self.events(lua), [])

    def test_native_ui_routes_dense_baseline_and_restore_without_preset_or_custom_start(self):
        cases = ((False, False, 'Use dense native rays##NativeSSR', 'native.enable', None),
                 (True, False, 'Use dense native rays##NativeSSR', 'native.compare', 'enhanced'),
                 (True, False, 'Use native baseline##NativeSSR', 'native.compare', 'native'),
                 (True, False, 'Restore / stop##NativeSSR', 'native.disable', 'native SSR experiment stopped'),
                 (False, True, 'Restore / stop##NativeSSR', 'native.disable', 'native SSR experiment stopped'))
        for requested, pending, click, expected, argument in cases:
            for lua in self.runtimes():
                lua.execute('function M.start()error("Unexpected custom start")end;'
                            'function M.applyPreset()error("Unexpected preset")end;'
                            'function drawNative()\n' + NATIVE_UI + '\nend')
                lua.globals().nativeStatus.requested = requested
                lua.globals().nativeStatus.restorePending = pending
                lua.globals().clickButton = click
                lua.globals().drawNative()
                self.assertEqual(self.events(lua), [(expected, argument)], click)

    def test_diagnostics_button_only_inspects_in_inactive_active_and_pending_states(self):
        for requested, pending in ((False, False), (True, False), (False, True)):
            for lua in self.runtimes():
                lua.execute('function M.start()error("Unexpected custom start")end;'
                            'function M.applyPreset()error("Unexpected preset")end;'
                            'function drawNative()\n' + NATIVE_UI + '\nend')
                lua.globals().nativeStatus.requested = requested
                lua.globals().nativeStatus.restorePending = pending
                lua.globals().clickButton = 'Log native SSR details##NativeSSR'
                lua.globals().drawNative()
                self.assertEqual(self.events(lua), [('native.inspect', None)])
                lua.execute('assert(#dumpedReports==1 and dumpedReports[1]==nativeReport)')
                self.assertEqual(lua.globals().nativeStatus.requested, requested)
                self.assertEqual(lua.globals().nativeStatus.restorePending, pending)

    def test_native_controls_do_not_expand_or_route_through_four_custom_presets(self):
        for lua in self.runtimes():
            lua.globals().TUNING_PRESETS = lua.execute(PRESETS)
            lua.execute(method('getPresets'))
            lua.execute('function M.applyPreset(id)record("preset",id);return true end;'
                        'function syncTuningPointers()end;'
                        'function drawPresets()\n' + PRESET_UI + '\nend')
            lua.globals().drawPresets()
            self.assertEqual(list(lua.globals().uiButtons.values()), [
                'Performance##BeamRTPreset', 'Balanced##BeamRTPreset',
                'Quality##BeamRTPreset', 'Cinematic##BeamRTPreset'])
            self.assertEqual(self.events(lua), [])
            lua.execute('uiButtons={};clickButton="Quality##BeamRTPreset";drawPresets()')
            self.assertEqual(self.events(lua), [('preset', 'quality')])


if __name__ == '__main__':
    unittest.main()
