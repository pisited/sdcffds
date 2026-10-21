"""Source contracts accompanying actual v041/v042 GPU range fixtures."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReflectionRadianceSafety(unittest.TestCase):
    def source(self, path):
        return (ROOT / path).read_text()

    def test_new_entry_opts_in_without_changing_old_entry(self):
        new = self.source('shaders/beamrt/beamrtReflectionTraceP_v042.hlsl')
        self.assertIn('#define BEAMRT_REFLECTION_SAFE_RADIANCE 1', new)
        self.assertIn('#include "beamrtReflectionTraceP_v041.hlsl"', new)
        self.assertNotIn('BEAMRT_REFLECTION_SAFE_RADIANCE', self.source('shaders/beamrt/beamrtReflectionTraceP_v041.hlsl'))

    def test_exponent_guard_and_output_limit_are_rgb_only(self):
        source = self.source('shaders/beamrt/beamrtReflectionRadianceSafety.h.hlsl')
        self.assertIn('asuint(radiance) & 0x7f800000u', source)
        self.assertIn('return all(exponents != 0x7f800000u)', source)
        self.assertIn('return clamp(radiance, 0.0, 65504.0)', source)
        code = re.sub(r'//[^\n]*', '', source)
        self.assertNotIn('float4', code)
        self.assertNotIn('isfinite', code)

    def test_source_guard_precedes_weights_and_output_guard_precedes_metadata(self):
        source = self.source('shaders/beamrt/beamrtReflectionTraceP_v024.hlsl')
        self.assertLess(source.index('reflectedLinear = reflectionSourceFinite'),
                        source.index('bestRadiance = max(reflectedLinear, 0.0) * confidence'))
        self.assertLess(source.index('bool reflectionSourceFinite = beamrtReflectionRadianceIsFinite(reflectedLinear)'),
                        source.index('reflectedLinear = beamrtReflectionFilteredSource'))
        self.assertLess(source.index('bestRadiance *= reflectionThroughput'),
                        source.index('bestRadiance = beamrtReflectionSafeRadiance(bestRadiance)'))
        self.assertLess(source.index('bestRadiance = beamrtReflectionSafeRadiance(bestRadiance)'),
                        source.index('return float4(bestRadiance, bestGeometryCategory)'))
        for metadata in ('bestConfidence', 'bestHitMetadata', 'bestGeometryCategory'):
            self.assertIn(f'return float4(bestRadiance, {metadata})', source)
        self.assertEqual(source.count('#ifdef BEAMRT_REFLECTION_SAFE_RADIANCE'), 4)

    def test_native_fixture_runs_actual_trace_and_both_target_formats(self):
        build = self.source('native/lighting/build_reflection_radiance.ps1')
        for name in ('beamrtReflectionTraceP_v041.hlsl', 'beamrtReflectionTraceP_v042.hlsl'):
            self.assertIn(name, build)
        self.assertIn('/Ges /WX /O3', build)
        self.assertNotIn('Start-Process', build)
        fixture = self.source('native/lighting/reflection_radiance_test.cpp')
        for evidence in ('hits>0', 'oldOverflow', 'sameBits', 'packedHits>0',
                         'DXGI_FORMAT_R16G16B16A16_FLOAT', 'DXGI_FORMAT_R32G32B32A32_FLOAT',
                         'std::numeric_limits<float>::quiet_NaN()', 'std::numeric_limits<float>::infinity()'):
            self.assertIn(evidence, fixture)


if __name__ == '__main__':
    unittest.main()
