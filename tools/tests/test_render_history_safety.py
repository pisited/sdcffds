"""Source guards for the GPU-reproduced HDR/history defects."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RenderHistorySafety(unittest.TestCase):
    def source(self, name):
        return (ROOT / name).read_text()

    def target_format(self, name):
        lua = self.source('lua/ge/extensions/beamrt/main.lua')
        pattern = r'(?P<object>\w+):setField\("target", 0, "' + re.escape(name) + r'"\).*?(?P=object):setField\("targetFormat", 0, "([^"]+)"\)'
        match = re.search(pattern, lua, re.S)
        self.assertIsNotNone(match, name)
        return match.group(2)

    def test_only_gi_statistics_targets_need_full_float(self):
        for name in ('#BeamRT_CurrentMoments', '#BeamRT_HistoryMoments'):
            self.assertEqual(self.target_format(name), 'GFXFormatR32G32B32A32F')
        for name in ('#BeamRT_CurrentGI', '#BeamRT_TemporalGI', '#BeamRT_HistoryGI'):
            self.assertEqual(self.target_format(name), 'GFXFormatR16G16B16A16F')

    def test_invalid_histories_never_enter_accumulation(self):
        moments = self.source('shaders/beamrt/beamrtMomentsP_v001.hlsl')
        self.assertLess(moments.index('all(isfinite(previous))'), moments.index('mean = lerp(previous.r'))
        gi = self.source('shaders/beamrt/beamrtTemporalP_v061.hlsl')
        guard = gi.index('if (all(isfinite(history)) && isfinite(historyDepth))')
        self.assertLess(guard, gi.index('historySupport = saturate(history.a)'))
        reflection = self.source('shaders/beamrt/beamrtReflectionTemporalP_v025.hlsl')
        self.assertLess(reflection.index('if (all(isfinite(history)))'), reflection.index('historyFresh = history.a'))

    def test_invalid_samples_skipped_before_weighting_and_metadata(self):
        gi = self.source('shaders/beamrt/beamrtTemporalP_v061.hlsl')
        self.assertIn('if (!all(isfinite(centerGI))) return 0.0;', gi)
        self.assertEqual(gi.count('if (!all(isfinite(sampleGI))) continue;'), 2)
        reflection = self.source('shaders/beamrt/beamrtReflectionTemporalP_v025.hlsl')
        for guard in ('if (!all(isfinite(rawCurrent))) return 0.0;',
                      'if (!all(isfinite(sampleReflection))) continue;',
                      'if (!all(isfinite(history))) continue;'):
            self.assertIn(guard, reflection)

    def test_fixture_executes_actual_entries_and_reads_actual_lua_formats(self):
        build = self.source('native/lighting/build.ps1')
        for shader in ('beamrtMomentsP_v001.hlsl', 'beamrtTemporalP_v071.hlsl', 'beamrtReflectionTemporalP_v038.hlsl'):
            self.assertIn(shader, build)
        for target in ('CurrentMoments', 'HistoryMoments'):
            self.assertIn(target, build)
        self.assertIn('lua/ge/extensions/beamrt/main.lua', build)
        fixture = self.source('native/lighting/self_test.cpp')
        self.assertIn('momentFormat', fixture)
        self.assertIn('readPixels(host,target)', fixture)

    def test_gpu_controls_preserve_zero_samples_black_hits_and_normal_history(self):
        fixture = self.source('native/lighting/self_test.cpp')
        for case in ('finite bright/dark moment history lost expected variance',
                     'valid zero GGX estimator sample erased history', 'valid black mirror hit lost geometric lifetime',
                     'valid GI history blend changed', 'valid playable GGX history blend changed',
                     'invalid zero-weight history tap poisoned reflection color filter',
                     'invalid current reflection retained false history lifetime',
                     'invalid current GI retained false hit support'):
            self.assertIn(case, fixture)
        self.assertIn('Pixel{150,45000,2,.1f}', fixture)
        self.assertIn('65504.f', fixture)


if __name__ == '__main__':
    unittest.main()
