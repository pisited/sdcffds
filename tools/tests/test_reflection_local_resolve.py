"""Shader contracts; behavior is checked by actual production GPU fixtures."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReflectionLocalResolve(unittest.TestCase):
    def source(self, path):
        return (ROOT / path).read_text()

    def test_versioned_composer_and_bounded_inputs(self):
        wrapper = self.source('shaders/beamrt/beamrtReflectionComposeP_v034.hlsl')
        self.assertIn('#define BEAMRT_REFLECTION_LOCAL_RESOLVE 1', wrapper)
        self.assertIn('#include "beamrtReflectionComposeP_v033.hlsl"', wrapper)
        self.assertNotIn('BEAMRT_REFLECTION_LOCAL_RESOLVE', self.source('shaders/beamrt/beamrtReflectionComposeP_v033.hlsl'))
        header = self.source('shaders/beamrt/beamrtReflectionCompose.h.hlsl')
        self.assertIn('uniform_sampler2D(prepassDepthTex, 4)', header)
        for uniform in ('reflectionLocalResolveEnabled', 'reflectionLocalResolveStrength'):
            self.assertIn('uniform float ' + uniform, header)
        self.assertNotIn('register(t5)', header)

    def test_filter_is_display_only_and_has_no_brightness_validity(self):
        source = self.source('shaders/beamrt/beamrtReflectionLocalResolve.h.hlsl')
        code = re.sub(r'//[^\n]*', '', source)
        for evidence in ('center.a <= 0.000001', 'roughness <= 0.08', 'reflectionSamplingMode <= 0.5',
                         'reflectionDebugMode > 0.5', 'const int2 offsets[4]', 'neighbor.a <= 0.000001',
                         'depthWeight * normalWeight * roughnessWeight * f0Weight',
                         'return float4(lerp(center.rgb, filtered, amount), center.a)'):
            self.assertIn(evidence, code)
        for unsupported in ('RWTexture', 'historyTex', 'confidenceWeight', 'Luminance', 'reflectionThickness', 'bestHit'):
            self.assertNotIn(unsupported, code)
        self.assertIn('total += neighbor.rgb * weight', code)
        self.assertIn('weightSum += weight', code)
        self.assertNotRegex(code, r'if\s*\([^\n]*(?:center|neighbor)\.r(?:gb)?\b')

    def test_actual_target_extents_and_coherent_receiver_tuples(self):
        source = self.source('shaders/beamrt/beamrtReflectionLocalResolve.h.hlsl')
        for texture in ('temporalReflectionTexTex', 'prepassTexTex', 'prepassDepthTexTex', 'materialSpecTexTex'):
            self.assertIn(texture + '.GetDimensions', source)
        self.assertIn('viewportCoordToRenderTarget(viewUv, rtParams2)', source)
        self.assertIn('viewportCoordToRenderTarget(viewUv, rtParams3)', source)
        self.assertIn('if (!beamrtReflectionLocalFinite4(center)) return 0.0', source)
        compose = self.source('shaders/beamrt/beamrtReflectionComposeP_v026.hlsl')
        self.assertLess(compose.index('reflection = beamrtReflectionLocalResolve(IN, reflection)'),
                        compose.index('if (reflectionStrength <= 0.0'))

    def test_gpu_checks_zero_mean_edges_alpha_and_disable_reference(self):
        build = self.source('native/lighting/build_reflection_local_resolve.ps1')
        self.assertIn('/Ges /WX /O3', build)
        self.assertIn("@('033','034')", build)
        self.assertIn("Join-Path $env:TEMP 'brt-rdisp'", build)
        self.assertNotIn('Start-Process', build)
        fixture = self.source('native/lighting/reflection_local_resolve_test.cpp')
        for evidence in ('valid GGX zero neighbors', 'rare bright sample', 'thin material island',
                         'normal boundary', 'foreground depth boundary', 'categorical grace-frame lifetime',
                         'v034 OFF differs from production v033', 'polished reflection detail',
                         'original scene alpha', 'nonfinite active center'):
            self.assertIn(evidence, fixture)


if __name__ == '__main__':
    unittest.main()
