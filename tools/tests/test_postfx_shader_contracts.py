"""Small source guards; installed-header compilation is a separate test."""
from pathlib import Path
import re
import unittest
from validate_postfx_shaders import shader_entries

ROOT = Path(__file__).resolve().parents[2]


class PostFXShaderContracts(unittest.TestCase):
    def test_gi_moments_has_no_executable_reflection_example(self):
        source = (ROOT / 'shaders/beamrt/beamrtMomentsP_v001.hlsl').read_text()
        code = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
        self.assertNotIn('currentReflectionTex', code)
        self.assertNotIn('previousMoments', code)
        self.assertIn('tex2D(currentGITex, IN.uv0)', code)
        self.assertIn('currentReflectionTex', source)  # Example preserved, not deleted.

    def test_registered_entries_include_visible_gi_and_reflection_stages(self):
        entries = shader_entries((ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text())
        for name in ('beamrtMomentsP_v001.hlsl', 'beamrtTemporalP_v071.hlsl',
                     'beamrtReflectionTemporalP_v040.hlsl', 'beamrtReflectionMomentsP_v001.hlsl',
                     'beamrtLightingComposeP_v079.hlsl'):
            self.assertIn('shaders/beamrt/' + name, entries)
        self.assertTrue(all((ROOT / entry).is_file() for entry in entries))

    def test_entry_discovery_deduplicates_both_lua_quote_styles(self):
        source = "shaderEntry='shaders/beamrt/a.hlsl'; shaderEntry=\"shaders/beamrt/a.hlsl\"; status='a.hlsl'"
        self.assertEqual(shader_entries(source), ['shaders/beamrt/a.hlsl'])


if __name__ == '__main__':
    unittest.main()
