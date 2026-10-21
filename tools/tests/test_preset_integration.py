"""Exercise main.lua's real preset/settings methods with offline Lua mocks.

The tests validate wiring and settings compatibility, not live render behavior.
No BeamNG process, filesystem settings writes, or graphics APIs are used.
"""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()
PRESETS = (ROOT / 'lua/ge/extensions/beamrt/presets.lua').read_text()
IDS = ('performance', 'balanced', 'quality', 'cinematic')


def method(name):
    found = re.search(r'^function M\.' + re.escape(name) + r'\([^\n]*\).*?\nend', MAIN, re.M | re.S)
    assert found, name
    return found.group()


SETTERS = dict(re.findall(r'\{"(\w+)", M\.(\w+)\}', method('applySettings')))
SETTERS.update(giSource='setGISource', mode='setMode')

MOCK = r'''
M={};PROGRESSIVE={lastPresetId=nil};state={};calls={};logs={}
refreshes=0;resets=0;applies=0;reads=0;writes=0;opens=0;enables=0;pointerSyncs=0
TUNING_FILE='offline-existing-settings.json'
function beamrtLog(level,message)table.insert(logs,{level,message})end
function refreshSurfels(force)assert(force==false);refreshes=refreshes+1 end
function resetTemporalHistory(reason,log)resets=resets+1 end
function applyShaderConsts()applies=applies+1 end
function applyGIShaderConsts()end
function jsonWriteFile(...)writes=writes+1;error('Unexpected settings write')end
function jsonReadFile(path)assert(path==TUNING_FILE);reads=reads+1;return saved end
function makeSetter(key)
  return function(value)
    calls[key]=value
    if failSetting==key then return false end
    state[key]=value
    return true
  end
end
function M.enable()enables=enables+1;return true end
function M.openTuner()opens=opens+1;return true end
function syncTuningPointers()pointerSyncs=pointerSyncs+1 end
function tuningTooltip(text)assert(type(text)=='string' and #text>0)end
uiButtons={};uiTexts={}
im={
  TextUnformatted=function(text)table.insert(uiTexts,text)end,
  SameLine=function()end,
  Button=function(text)table.insert(uiButtons,text);return text==clickButton end
}
'''


class PresetIntegration(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            lua.globals().TUNING_PRESETS = lua.execute(PRESETS)
            for key, setter in SETTERS.items():
                lua.globals().M[setter] = lua.globals().makeSetter(key)
            for name in ('applySettings', 'applyPreset', 'getPresets', 'applyExperimentalPreset', 'loadTuning'):
                lua.execute(method(name))
            yield lua

    def test_every_preset_key_is_wired_to_a_defined_main_setter(self):
        self.assertIn('require("ge/extensions/beamrt/presets")', MAIN)
        for lua in self.runtimes():
            for name in IDS:
                preset, _ = lua.globals().TUNING_PRESETS.resolve(name)
                for key in preset.keys():
                    self.assertIn(key, SETTERS, name + ':' + key)
                    self.assertRegex(MAIN, r'function M\.' + re.escape(SETTERS[key]) + r'\(')

    def test_each_preset_deterministically_clears_old_filters_and_applies_all_keys(self):
        for lua in self.runtimes():
            for name in ('cinematic', 'performance', 'quality', 'balanced'):
                lua.execute('state.reflectionVarianceEnabled=true;state.reflectionVariancePasses=3;'
                            'state.reflectionLocalResolveEnabled=true;state.reflectionLocalResolveStrength=.99;calls={}')
                self.assertTrue(lua.globals().M.applyPreset(name))
                preset, canonical = lua.globals().TUNING_PRESETS.resolve(name)
                expected = dict(preset.items())
                self.assertEqual(dict(lua.globals().calls.items()), expected)
                self.assertEqual(dict(lua.globals().state.items()), expected)
                self.assertEqual(lua.globals().PROGRESSIVE.lastPresetId, canonical)
                self.assertFalse(lua.globals().state.reflectionVarianceEnabled)
                self.assertEqual(lua.globals().state.reflectionVariancePasses, 1)
                self.assertEqual(lua.globals().state.reflectionLocalResolveEnabled,
                                 name in ('quality', 'cinematic'))
                self.assertEqual(lua.globals().state.reflectionLocalResolveStrength, .35)
            self.assertEqual(lua.globals().refreshes, 4)
            self.assertEqual(lua.globals().resets, 4)
            self.assertEqual(lua.globals().reads, 0)
            self.assertEqual(lua.globals().writes, 0)

    def test_main_uses_fresh_module_copies_and_canonical_alias_marker(self):
        for lua in self.runtimes():
            expected = dict(lua.globals().TUNING_PRESETS.resolve('balanced')[0].items())
            lua.execute('function M.applySettings(value)value.giStrength=999;value.injected=true;return true end')
            self.assertTrue(lua.globals().M.applyPreset('  PTGIPLAYREFLECT  '))
            self.assertEqual(lua.globals().PROGRESSIVE.lastPresetId, 'balanced')
            self.assertEqual(dict(lua.globals().TUNING_PRESETS.resolve('balanced')[0].items()), expected)
            self.assertEqual(lua.globals().writes, 0)

    def test_failed_or_unknown_preset_never_marks_a_successful_selection(self):
        for lua in self.runtimes():
            lua.execute("PROGRESSIVE.lastPresetId='balanced';failSetting='giStrength'")
            self.assertFalse(lua.globals().M.applyPreset('quality'))
            self.assertEqual(lua.globals().PROGRESSIVE.lastPresetId, 'balanced')
            before = dict(lua.globals().state.items())
            for name in ('fifth-tier', None, False, 4):
                self.assertFalse(lua.globals().M.applyPreset(name))
                self.assertEqual(dict(lua.globals().state.items()), before)
            self.assertEqual(lua.globals().writes, 0)

    def test_actual_ui_fragment_displays_exactly_four_buttons_and_selects_by_id(self):
        block = re.search(r'  im\.TextUnformatted\("Presets"\)\n.*?'
                          r'(?=  im\.TextUnformatted\("Last preset:)', MAIN, re.S)
        self.assertIsNotNone(block)
        for lua in self.runtimes():
            lua.execute('function drawPresetButtons()\n' + block.group() + '\nend')
            lua.globals().drawPresetButtons()
            self.assertEqual(tuple(lua.globals().uiButtons[i] for i in range(1, 5)),
                             ('Performance##BeamRTPreset', 'Balanced##BeamRTPreset',
                              'Quality##BeamRTPreset', 'Cinematic##BeamRTPreset'))
            self.assertEqual(len(lua.globals().uiButtons), 4)
            lua.execute("uiButtons={};clickButton='Quality##BeamRTPreset';drawPresetButtons()")
            self.assertEqual(lua.globals().PROGRESSIVE.lastPresetId, 'quality')
            self.assertEqual(lua.globals().pointerSyncs, 1)
            self.assertEqual(lua.globals().writes, 0)

    def test_partial_saved_tuning_remains_partial_and_is_not_rewritten(self):
        for lua in self.runtimes():
            lua.execute('saved={version="older-version",giStrength=1.2,reflectionsEnabled=false,oldUnknownKey=7};'
                        'state.reflectionLocalResolveEnabled=true;state.reflectionLocalResolveStrength=.2;'
                        'state.reflectionReceiverHistoryEnabled=false')
            before = dict(lua.globals().saved.items())
            self.assertTrue(lua.globals().M.loadTuning())
            self.assertEqual(dict(lua.globals().saved.items()), before)
            self.assertEqual(dict(lua.globals().calls.items()), {'giStrength': 1.2, 'reflectionsEnabled': False})
            self.assertTrue(lua.globals().state.reflectionLocalResolveEnabled)
            self.assertEqual(lua.globals().state.reflectionLocalResolveStrength, .2)
            self.assertFalse(lua.globals().state.reflectionReceiverHistoryEnabled)
            self.assertEqual(lua.globals().reads, 1)
            self.assertEqual(lua.globals().writes, 0)
            self.assertIsNone(lua.globals().PROGRESSIVE.lastPresetId)

    def test_existing_saved_transient_contract_is_preserved(self):
        settings = method('getSettings')
        self.assertIn('reflectionLocalResolveEnabled =', settings)
        self.assertIn('reflectionLocalResolveStrength =', settings)
        for transient in ('reflectionReceiverHistoryEnabled', 'reflectionSourceReconstructionEnabled',
                          'reflectionVarianceEnabled', 'reflectionVariancePasses', 'reflectionVarianceStrength'):
            self.assertNotRegex(settings, r'\b' + transient + r'\s*=')

    def test_bounded_work_values_pass_the_actual_main_validation_methods(self):
        for lua in self.runtimes():
            lua.execute('function finiteNumber(value)local n=tonumber(value);'
                        'if not n or n~=n or n==math.huge or n==-math.huge then return nil end;return n end')
            for setter in ('setScreenDdaMaxPaths', 'setScreenDdaMaxSteps', 'setGIPathCount', 'setRaySteps'):
                lua.execute(method(setter))
            for name in IDS:
                preset, _ = lua.globals().TUNING_PRESETS.resolve(name)
                self.assertTrue(lua.globals().M.setScreenDdaMaxPaths(preset.screenDdaMaxPaths), name)
                self.assertTrue(lua.globals().M.setScreenDdaMaxSteps(preset.screenDdaMaxSteps), name)
                self.assertTrue(lua.globals().M.setGIPathCount(preset.giPathCount), name)
                self.assertTrue(lua.globals().M.setRaySteps(preset.rayMaxSteps), name)
                self.assertEqual(lua.globals().PROGRESSIVE.screenDdaMaxPaths, preset.screenDdaMaxPaths)
                self.assertEqual(lua.globals().PROGRESSIVE.screenDdaMaxSteps, preset.screenDdaMaxSteps)
            self.assertFalse(lua.globals().M.setScreenDdaMaxSteps(7))
            self.assertFalse(lua.globals().M.setScreenDdaMaxSteps(129))
            self.assertFalse(lua.globals().M.setScreenDdaMaxPaths(0))
            self.assertFalse(lua.globals().M.setScreenDdaMaxPaths(9))

    def test_legacy_experimental_entry_point_selects_balanced_and_only_then_enables(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.applyExperimentalPreset())
            self.assertEqual(lua.globals().PROGRESSIVE.lastPresetId, 'balanced')
            self.assertEqual(lua.globals().enables, 1)
            self.assertEqual(lua.globals().opens, 1)
            self.assertEqual(lua.globals().writes, 0)


if __name__ == '__main__':
    unittest.main()
