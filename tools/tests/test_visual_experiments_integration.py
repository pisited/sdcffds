"""Actual main methods against mocked engine state, not game appearance proof."""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()


def method(name):
    found = re.search(r'^function ' + re.escape(name) + r'\([^\n]*\).*?\nend', MAIN, re.M | re.S)
    assert found, name
    return found.group()


MOCK = r'''
M={};objects={};refreshes=0;constApplies=0;resets=0
camera={x=1,y=2,z=10};available=true;safe=true;frozen=false
enabledRequested=true;debugMode=1;materialCachePublication=nil;CLEAN_RADIANCE={}
MODE_IDS={diffusegi=1,reflections=2}
PROGRESSIVE={
  reflectionLocalResolve={enabled=false,strength=.35},
  reflectionSampling={mode=1,isFrozen=function()return frozen end},
  reflectionReconstruction={mode=1},reflectionConvergenceEnabled=false,
  rendererCompatibility={check=function()return {safe=safe}end},
  rayDebugMode=0,lightingDiagnostic={mode=0},
  waterPreview={enabled=false,effectName='Water',shaderName='WaterShader',provider={}}
}
function findObject(n)return objects[n]end
function effectIsEnabled(n)return objects[n]and objects[n].enabled or false end
function finiteNumber(n)if type(n)~='number'or n~=n or math.abs(n)==math.huge then return nil end;return n end
function finiteComponent(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
function getCurrentCameraPosition()return camera end
function applyReflectionShaderConsts()constApplies=constApplies+1 end
function resetReflectionHistory()resets=resets+1 end
function beamrtLog()end
function createObject(class)
  local o={fields={},consts={},enabled=false}
  function o:setField(k,i,v)self.fields[k]=self.fields[k]or{};self.fields[k][i]=v end
  function o:getField(k,i)return self.fields[k]and self.fields[k][i]end
  function o:setShaderConst(k,v)self.consts[k]=v end
  function o:registerObject(n)assert(not objects[n]);assert(self.fields.target[0]);objects[n]=self end
  function o:enable()self.enabled=true end
  function o:disable()self.enabled=false end
  return o
end
function setEffectEnabled(n,value)local o=objects[n];if o then o.enabled=value==true end end
function PROGRESSIVE.waterPreview.provider.getStatus()
  return{available=available,ownershipVerified=false,normalLightingAffected=false,reason='prototype'}
end
function PROGRESSIVE.waterPreview.provider.refresh(options)
  assert(options.maxDistance==250);refreshes=refreshes+1;return available,'prototype'
end
function PROGRESSIVE.waterPreview.provider.getShaderConstants()
  return{waterReceiverPlane='0 1 0 0',waterReceiverBlockMin='0 0 0 0',
    waterReceiverBlockMax='0 0 0 0',waterReceiverMaxDistance=250}
end
'''


class VisualExperimentIntegration(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            for name in ('PROGRESSIVE.waterPreview.createEffect', 'PROGRESSIVE.waterPreview.applyConsts',
                         'PROGRESSIVE.waterPreview.sync', 'M.refreshWaterReceiverPreview',
                         'M.setWaterReceiverPreviewEnabled', 'M.getWaterReceiverPreviewStatus',
                         'M.setReflectionLocalResolveEnabled', 'M.setReflectionLocalResolveStrength'):
                lua.execute(method(name))
            lua.execute('PROGRESSIVE.waterPreview.createEffect()')
            yield lua

    def test_water_preview_starts_off_and_binds_only_scene_and_depth(self):
        for lua in self.runtimes():
            self.assertFalse(lua.globals().objects.Water.enabled)
            self.assertEqual(lua.globals().objects.Water.fields.texture[0], '$backBuffer')
            self.assertEqual(lua.globals().objects.Water.fields.texture[1], '#prepass[Depth]')
            self.assertIsNone(lua.globals().objects.Water.fields.texture[2])
            self.assertEqual(lua.globals().refreshes, 0)
            self.assertFalse(lua.globals().M.getWaterReceiverPreviewStatus().requested)

    def test_enable_refresh_and_disable_do_not_write_native_settings(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setWaterReceiverPreviewEnabled(True))
            self.assertTrue(lua.globals().objects.Water.enabled)
            self.assertEqual(lua.globals().objects.Water.consts['$eyePosWorld'], '1 2 10')
            self.assertEqual(lua.globals().objects.Water.consts['$waterReceiverPlane'], '0 1 0 0')
            self.assertEqual(lua.globals().refreshes, 0, 'cached preview must not rescan every frame')
            lua.globals().M.refreshWaterReceiverPreview()
            self.assertEqual(lua.globals().refreshes, 1)
            lua.globals().M.setWaterReceiverPreviewEnabled(False)
            self.assertFalse(lua.globals().objects.Water.enabled)
            self.assertFalse(lua.globals().M.getWaterReceiverPreviewStatus().ownershipVerified)
            self.assertFalse(lua.globals().M.getWaterReceiverPreviewStatus().gameAppearanceVerified)

    def test_unknown_camera_and_modes_or_capture_disable_preview(self):
        blockers = ('safe=false', 'enabledRequested=false', 'debugMode=99', 'materialCachePublication={}',
                    'CLEAN_RADIANCE.build={}', 'frozen=true', 'PROGRESSIVE.reflectionConvergenceEnabled=true',
                    "PROGRESSIVE.reflectionSourceProbeTarget='#Frozen'", 'PROGRESSIVE.rayDebugMode=1',
                    'PROGRESSIVE.lightingDiagnostic.mode=1', 'camera=nil', 'camera.x=0/0', 'available=false')
        for blocker in blockers:
            for lua in self.runtimes():
                lua.globals().M.setWaterReceiverPreviewEnabled(True)
                lua.execute(blocker + ';PROGRESSIVE.waterPreview.sync()')
                self.assertFalse(lua.globals().objects.Water.enabled, blocker)

    def test_no_supported_water_and_invalid_types_cannot_enable(self):
        for lua in self.runtimes():
            for bad in (None, 0, 'true'):
                self.assertFalse(lua.globals().M.setWaterReceiverPreviewEnabled(bad))
            lua.execute('available=false')
            result = lua.globals().M.setWaterReceiverPreviewEnabled(True)
            self.assertEqual(result, (False, 'prototype'))
            self.assertEqual(lua.globals().refreshes, 1)
            self.assertFalse(lua.globals().objects.Water.enabled)

    def test_local_cleanup_changes_uniforms_without_resetting_history(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setReflectionLocalResolveEnabled(True))
            self.assertTrue(lua.globals().M.setReflectionLocalResolveStrength(.4))
            self.assertEqual(lua.globals().PROGRESSIVE.reflectionLocalResolve.strength, .4)
            self.assertEqual(lua.globals().constApplies, 2)
            self.assertEqual(lua.globals().resets, 0)
            for value in (None, 'true', 0):
                self.assertFalse(lua.globals().M.setReflectionLocalResolveEnabled(value))
            for value in (None, float('nan'), float('inf'), -0.1, 1.1):
                self.assertFalse(lua.globals().M.setReflectionLocalResolveStrength(value))
            self.assertEqual(lua.globals().constApplies, 2)

    def test_actual_local_uniform_gates_keep_legacy_and_frozen_paths(self):
        start = MAIN.index('  setIfPresent(REFLECTION_COMPOSE_EFFECT_NAME, "$reflectionLocalResolveEnabled",')
        end = MAIN.index('  local composeEffect =', start)
        section = MAIN[start:end]
        for lua in self.runtimes():
            lua.execute("lab={raw=false};REFLECTION_COMPOSE_EFFECT_NAME='Compose';objects.Compose=createObject('PostEffect');function setIfPresent(n,k,v)objects[n]:setShaderConst(k,v)end")
            lua.execute('function applyLocal()\n' + section + '\nend')
            lua.globals().M.setReflectionLocalResolveEnabled(True)
            lua.execute('applyLocal()')
            self.assertEqual(lua.globals().objects.Compose.consts['$reflectionLocalResolveEnabled'], 1)
            for blocker in ('PROGRESSIVE.reflectionSampling.mode=0', 'PROGRESSIVE.reflectionReconstruction.mode=0',
                            'frozen=true', 'PROGRESSIVE.reflectionConvergenceEnabled=true'):
                lua.execute(blocker + ';applyLocal()')
                self.assertEqual(lua.globals().objects.Compose.consts['$reflectionLocalResolveEnabled'], 0)
                lua.execute('PROGRESSIVE.reflectionSampling.mode=1;PROGRESSIVE.reflectionReconstruction.mode=1;frozen=false;PROGRESSIVE.reflectionConvergenceEnabled=false')

    def test_lifecycle_and_settings_keep_preview_transient(self):
        for name in ('M.onClientStartMission', 'M.onExtensionUnloaded'):
            source = method(name)
            self.assertIn('PROGRESSIVE.waterPreview.enabled = false', source)
            self.assertIn('PROGRESSIVE.waterPreview.provider.clear(', source)
        source = MAIN[MAIN.index('local function destroyObjects()'):MAIN.index('local function finiteNumber(')]
        self.assertIn('deleteObject(PROGRESSIVE.waterPreview.effectName)', source)
        self.assertIn('deleteObject(PROGRESSIVE.waterPreview.shaderName)', source)
        self.assertIn('PROGRESSIVE.waterPreview.effectName .. "Callbacks", nil', source)
        for name in ('M.getSettings', 'M.settingsCommand'):
            source = method(name)
            self.assertIn('reflectionLocalResolve', source)
            self.assertNotIn('WaterReceiverPreviewEnabled', source)


if __name__ == '__main__':
    unittest.main()
