"""Actual Lua control methods and shared receiver helper contracts; no game IO."""
from pathlib import Path
import re
import unittest
import test_coherent_renderer as backend

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()


class GIColorExperiment(unittest.TestCase):
    def runtimes(self):
        for lua, _ in backend.CoherentRenderer().runtimes():
            lua.execute('''
            M={};PROGRESSIVE={receiverDeLight=0,marcherName='linear',screenRayStride=1}
            resets=0;constants=0
            function finiteNumber(v)
              if type(v)~='number' or v~=v or v==math.huge or v==-math.huge then return nil end
              return v
            end
            function beamrtLog()end
            function resetTemporalHistory()resets=resets+1 end
            function applyGIShaderConsts()constants=constants+1 end
            ''')
            for name in ('setGIReceiverDeLight', 'setScreenRayStride', 'setGIWideDdaExperiment'):
                lua.execute(re.search(r'^function M\.' + name + r'\([^\n]*\).*?\nend', MAIN, re.M | re.S).group())
            yield lua, lua.globals().M

    def test_receiver_is_opt_in_and_finite_and_invalidates_history(self):
        for lua, api in self.runtimes():
            self.assertEqual(lua.globals().PROGRESSIVE.receiverDeLight, 0)
            for invalid in (True, '1', -1, 1.1, float('nan'), float('inf')):
                self.assertFalse(api.setGIReceiverDeLight(invalid))
            self.assertEqual(lua.globals().resets, 0)
            self.assertTrue(api.setGIReceiverDeLight(1))
            self.assertEqual(lua.globals().PROGRESSIVE.receiverDeLight, 1)
            self.assertEqual(lua.globals().resets, 1)
            self.assertTrue(api.setGIReceiverDeLight(0))
            self.assertEqual(lua.globals().PROGRESSIVE.receiverDeLight, 0)

    def test_coverage_requires_dda_is_idempotent_and_undoes_exact_stride(self):
        for lua, api in self.runtimes():
            self.assertFalse(api.setGIWideDdaExperiment(True)[0])
            self.assertEqual(lua.globals().PROGRESSIVE.screenRayStride, 1)
            lua.execute("PROGRESSIVE.marcherName='screendda';PROGRESSIVE.screenRayStride=1.25")
            self.assertTrue(api.setGIWideDdaExperiment(True))
            self.assertEqual(lua.globals().PROGRESSIVE.screenRayStride, 2.5)
            self.assertTrue(api.setGIWideDdaExperiment(True))
            self.assertEqual(lua.globals().PROGRESSIVE.screenRayStride, 2.5)
            # Selecting linear later must not prevent undo of the saved DDA knob.
            lua.execute("PROGRESSIVE.marcherName='linear'")
            self.assertTrue(api.setGIWideDdaExperiment(False))
            self.assertEqual(lua.globals().PROGRESSIVE.screenRayStride, 1.25)
            self.assertIsNone(api._giDdaCoverageRestore)

    def test_setting_roundtrip_and_both_constant_update_paths(self):
        self.assertIn('giReceiverDeLight = PROGRESSIVE.receiverDeLight', MAIN)
        self.assertIn('{"giReceiverDeLight", M.setGIReceiverDeLight}', MAIN)
        self.assertEqual(MAIN.count('"$giReceiverDeLight", PROGRESSIVE.receiverDeLight'), 2)
        self.assertIn('beamrtReceiverResponseP_v002.hlsl', MAIN)
        body = re.search(r'^function M.setGIReceiverDeLight.*?\nend', MAIN, re.M | re.S).group()
        for unrelated in ('bounceSaturation =', 'giStrength =', 'giReceiverTint =', '.enable('):
            self.assertNotIn(unrelated, body)

    def test_legacy_entry_preserved_by_compile_time_opt_in(self):
        shader = (ROOT / 'shaders/beamrt/beamrtReceiverResponseP_v001.hlsl').read_text()
        self.assertIn('#ifdef BEAMRT_DELIT_RECEIVER', shader)
        self.assertIn('receiverResponse * (1.0 - metallicLikelihood)', shader)
        self.assertIn('receiverResponse * diffuseReceiverWeight', shader)
        helper = (ROOT / 'shaders/beamrt/beamrtReceiverColor.h.hlsl').read_text()
        self.assertIn('stable / max(y, 0.0001)', helper)
        self.assertIn('smoothstep(0.02, 0.15, directLight)', helper)


if __name__ == '__main__':
    unittest.main()
