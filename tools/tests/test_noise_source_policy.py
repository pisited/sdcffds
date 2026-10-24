"""Actual Lua noise selection and binding safety; no texture/GPU loading claim."""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[2]


class NoisePolicy(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("package.path='lua/?.lua;'..package.path")
        self.policy=self.lua.eval("require('ge/extensions/beamrt/noiseSourcePolicy')")

    def test_native_aliases_keep_original_mode_and_path(self):
        for name in ('beamng','native','gtao','BEAMNG',' beam_ng '):
            result=self.policy.resolve(name)
            self.assertEqual((result.mode,result.name),(0,'beamng'))
        self.assertEqual(self.policy.nativeTexture,'/shaders/common/postFx/gtao/noiseBlue.png')

    def test_every_experimental_alias_is_refused_with_reason(self):
        self.assertFalse(self.policy.atlasAvailable)
        for name in ('stbn','beamrt','spatiotemporal','STBN','spatio-temporal'):
            selected,reason=self.policy.resolve(name)
            self.assertIsNone(selected)
            self.assertIn('DDS',reason)
            self.assertIn('native noise retained',reason)

    def test_invalid_values_never_select_a_source(self):
        for value in (None,12,'unsupported'):
            self.assertIsNone(self.policy.resolve(value)[0])

    def test_unused_bank_binds_native_resource_not_broken_dds(self):
        self.assertEqual(self.policy.atlasBinding(),self.policy.nativeTexture)
        main=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text(encoding='utf-8')
        self.assertIn('auxiliary:setField("texture", 3, M.noiseSourcePolicy.atlasBinding())',main)
        self.assertIn('auxiliary:setField("texture", 4, M.noiseSourcePolicy.nativeTexture)',main)
        self.assertNotIn('beamrtSTBN_128x128x64_rgb_atlas_linear_v094.dds',main)

    def test_real_main_setter_refuses_atlas_without_mutation_or_history_reset(self):
        main=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text(encoding='utf-8')
        setter=re.search(r'function M.setBlueNoiseSource\(value\).*?(?=\nfunction M.setHitRefinementSteps)',main,re.S).group()
        self.lua.execute("M={noiseSourcePolicy=require('ge/extensions/beamrt/noiseSourcePolicy')}; PROGRESSIVE={blueNoiseMode=0,blueNoiseSource='beamng'}; resets=0; logs={}; function resetTemporalHistory()resets=resets+1 end; function beamrtLog(level,message)logs[#logs+1]=message end")
        self.lua.execute(setter)
        self.assertFalse(self.lua.globals().M.setBlueNoiseSource('stbn'))
        self.assertEqual(self.lua.globals().PROGRESSIVE.blueNoiseMode,0)
        self.assertEqual(self.lua.globals().PROGRESSIVE.blueNoiseSource,'beamng')
        self.assertEqual(self.lua.globals().resets,0)
        self.assertTrue(self.lua.globals().M.setBlueNoiseSource('native'))
        self.assertEqual(self.lua.globals().resets,1)

    def test_active_wrapper_only_suppresses_reserved_stbn_bank(self):
        wrapper=(ROOT/'shaders/beamrt/beamrtAuxiliaryPackP_v002.hlsl').read_text(encoding='utf-8')
        source=(ROOT/'shaders/beamrt/beamrtAuxiliaryPackP_v001.hlsl').read_text(encoding='utf-8')
        self.assertIn('#define BEAMRT_SKIP_STBN_BANK 1',wrapper)
        self.assertIn('#include "beamrtAuxiliaryPackP_v001.hlsl"',wrapper)
        self.assertRegex(source,r'if \(noisePixel.x < 1024\)\s*\{\s*#ifdef BEAMRT_SKIP_STBN_BANK\s*return 0\.0;\s*#else\s*return stbnNoiseTexTex.Load')
        self.assertIn('return blueNoiseTexTex.Load(int3(noisePixel - int2(1024, 0), 0));',source)
        self.assertIn('return surfelRadianceTexTex.Load(int3(surfelPixel, 0));',source)


if __name__=='__main__':
    unittest.main(verbosity=2)
