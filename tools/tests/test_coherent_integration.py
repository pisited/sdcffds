"""Main-module switching and lifecycle contracts for the isolated backend."""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()


def method(name):
    return re.search(r'^function M\.' + name + r'\([^\n]*\).*?\nend', MAIN, re.M | re.S).group()


class CoherentIntegration(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51, LuaJIT):
            lua = cls(unpack_returned_tuples=True)
            lua.execute(r'''
            events={};safe=true;frozen=false;capturing=false;requested=false;stopOK=true
            M={};PROGRESSIVE={reflectionSampling={isFrozen=function()return frozen end},
              reflectionDiagnostic={mode=0},lightingAudit={getStatus=function()return {active=capturing}end},
              rendererCompatibility={check=function()return {safe=safe,reason='native conflict'}end}}
            CLEAN_RADIANCE={}
            M._coherentRenderer={disable=function()requested=false;table.insert(events,'coherent stop');return true end,
              enable=function()requested=true;table.insert(events,'coherent start');return true end,
              getStatus=function()return {requested=requested,active=requested,reason='test'}end,
              setParameter=function(key,value)return key,value end}
            function M.disable()table.insert(events,'legacy stop');return stopOK end
            function M.openTuner()table.insert(events,'tuner')end
            function beamrtLog()end
            ''')
            for name in ('setCoherentSsrEnabled', 'getCoherentSsrStatus', 'setCoherentSsrParameter'):
                lua.execute(method(name))
            yield lua

    def test_camera_probe_stops_custom_renderer_and_respects_capture_guard(self):
        for lua in self.runtimes():
            lua.execute("M._planarCapture={start=function(height,mode)table.insert(events,mode);return true end,getStatus=function()return {reason='probe'}end}")
            lua.execute(method('startReflectionCaptureProbe'))
            self.assertFalse(lua.globals().M.startReflectionCaptureProbe('invalid')[0])
            self.assertFalse(lua.globals().M.startReflectionCaptureProbe('mirror',float('nan'))[0])
            self.assertEqual(len(lua.globals().events),0)
            lua.execute('capturing=true')
            self.assertFalse(lua.globals().M.startReflectionCaptureProbe('mirror',0)[0])
            self.assertEqual(len(lua.globals().events),0)
            lua.execute('capturing=false')
            self.assertTrue(lua.globals().M.startReflectionCaptureProbe('mirror',0)[0])
            self.assertEqual(list(lua.globals().events.values()),['legacy stop','mirror','tuner'])

    def test_extra_camera_is_stopped_on_all_lifecycle_boundaries(self):
        for name in ('enable','disable','onClientStartMission','onClientEndMission','onSettingsChanged','onExtensionUnloaded'):
            self.assertIn('M._planarCapture',method(name),name)

    def test_switch_is_explicit_exclusive_and_stop_does_not_start_legacy(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setCoherentSsrEnabled(True)[0])
            self.assertEqual(list(lua.globals().events.values()), ['legacy stop', 'coherent start', 'tuner'])
            self.assertTrue(lua.globals().M.setCoherentSsrEnabled(False))
            self.assertEqual(list(lua.globals().events.values())[-1], 'coherent stop')

    def test_bad_types_native_conflicts_capture_and_cleanup_failure_do_not_enable(self):
        for setup in ('safe=false', 'frozen=true', 'capturing=true', 'stopOK=false',
                      'PROGRESSIVE.reflectionDiagnostic.mode=1', 'materialCachePublication={}', 'CLEAN_RADIANCE.build={}'): 
            for lua in self.runtimes():
                lua.execute(setup)
                self.assertFalse(lua.globals().M.setCoherentSsrEnabled(True)[0], setup)
                self.assertFalse(lua.globals().requested)
        for lua in self.runtimes():
            self.assertFalse(lua.globals().M.setCoherentSsrEnabled('on')[0])

    def test_lifecycle_and_legacy_capture_guards_exist(self):
        for name in ('onClientStartMission', 'onClientEndMission', 'onSettingsChanged', 'onExtensionUnloaded', 'disable'):
            self.assertIn('M._coherentRenderer', method(name), name)
        for name in ('runLightingAudit', 'setReflectionDiagnostic', 'setReflectionConvergenceEnabled', 'setReflectionSourceProbeTarget'):
            self.assertIn('M._coherentRenderer.getStatus().requested', method(name), name)
        self.assertIn('M._coherentRenderer.update(frameDelta)', method('onPreRender'))
        self.assertIn('M._coherentRenderer.disable', method('enable'))


if __name__ == '__main__':
    unittest.main()
