"""Actual main status/setter/tuner block: no implicit load, unsupported UI inert."""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[2]


class Availability(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("package.path='lua/?.lua;'..package.path")
        self.policy=self.lua.eval("require('ge/extensions/beamrt/localLightAvailability')")
        main=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text(encoding='utf-8')
        self.lua.execute("M={localLightAvailability=require('ge/extensions/beamrt/localLightAvailability')}; loads=0; enables=0; disables=0; status={enabled=false}; extensions=setmetatable({load=function(name)assert(name=='beamrt_meshLocalLights');loads=loads+1;rawset(extensions,name,{getStatus=function()return status end,enable=function()enables=enables+1;status.enabled=true;return true end,disable=function()disables=disables+1;status.enabled=false;return true end})end},{__index=function()error('getter must not auto-load')end})")
        functions=re.search(r'function M.setMeshLocalLightsEnabled\(value\).*?(?=\nfunction M.captureVehicleGeometry)',main,re.S).group()
        self.lua.execute(functions)
        self.draw=re.search(r'    local localLights=M.getMeshLocalLightStatus\(\).*?(?=\n    im.PopItemWidth\(\))',main,re.S).group()

    def test_blocked_status_and_enable_do_not_load_or_touch_rendering(self):
        self.lua.globals().ClusteredShading=self.lua.table()
        status=self.lua.globals().M.getMeshLocalLightStatus()
        self.assertFalse(status.canEnable)
        self.assertIn('not connected',status.unavailableReason)
        ok,reason=self.lua.globals().M.setMeshLocalLightsEnabled(True)
        self.assertFalse(ok);self.assertIn('native lighting',reason)
        self.assertEqual(self.lua.globals().loads,0)
        self.assertEqual(self.lua.globals().enables,0)

    def test_legacy_enable_disable_remains_supported(self):
        self.assertTrue(self.lua.globals().M.getMeshLocalLightStatus().canEnable)
        self.assertTrue(self.lua.globals().M.setMeshLocalLightsEnabled(True))
        self.assertEqual(self.lua.globals().loads,1)
        self.assertEqual(self.lua.globals().enables,1)
        self.assertTrue(self.lua.globals().M.setMeshLocalLightsEnabled(False))
        self.assertEqual(self.lua.globals().disables,1)

    def test_existing_hook_stays_disableable_when_backend_exposure_changes(self):
        self.lua.globals().M.setMeshLocalLightsEnabled(True)
        self.lua.globals().ClusteredShading=self.lua.table()
        status=self.lua.globals().M.getMeshLocalLightStatus()
        self.assertTrue(status.enabled);self.assertTrue(status.canDisable)
        self.assertFalse(status.canEnable)
        self.assertTrue(self.lua.globals().M.setMeshLocalLightsEnabled(False))
        self.assertEqual(self.lua.globals().disables,1)

    def test_stale_backend_flag_is_conservative_not_an_integration_claim(self):
        status=self.lua.table_from({'enabled':False,'clusteredBackendExposed':True,'clusteredDispatchIntegrated':True})
        self.assertFalse(self.policy.resolve(status,False).canEnable)

    def test_invalid_request_and_disable_without_module_do_not_load(self):
        self.assertFalse(self.lua.globals().M.setMeshLocalLightsEnabled('true')[0])
        self.assertTrue(self.lua.globals().M.setMeshLocalLightsEnabled(False)[0])
        self.assertEqual(self.lua.globals().loads,0)

    def test_blocked_tuner_draw_has_no_clickable_activation(self):
        self.lua.globals().ClusteredShading=self.lua.table()
        self.lua.execute("texts={};im={Button=function()error('unavailable hook must not offer a button')end,TextUnformatted=function(value)texts[#texts+1]=value end};function tuningTooltip()end;function beamrtLog()error('UI must not log repeated failures')end")
        self.lua.execute(self.draw)
        self.assertIn('unavailable',self.lua.globals().texts[1])
        self.assertIn('not connected',self.lua.globals().texts[2])
        self.assertEqual(self.lua.globals().loads,0)

    def test_enabled_tuner_draw_can_restore_native_lighting(self):
        self.lua.globals().M.setMeshLocalLightsEnabled(True)
        self.lua.globals().ClusteredShading=self.lua.table()
        self.lua.execute("im={Button=function(label)assert(label=='Underground local-light visibility ON');return true end,TextUnformatted=function()end};function tuningTooltip()end;function beamrtLog()error('disable should succeed')end")
        self.lua.execute(self.draw)
        self.assertEqual(self.lua.globals().disables,1)


if __name__=='__main__':
    unittest.main(verbosity=2)
