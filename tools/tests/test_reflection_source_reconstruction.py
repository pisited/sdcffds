"""Contracts for source-tap ownership; the GPU fixture tests actual behaviour."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReflectionSourceReconstruction(unittest.TestCase):
    def source(self, path):
        return (ROOT / path).read_text()

    def test_versioned_opt_in_and_explicit_reversible_uniform(self):
        wrapper = self.source('shaders/beamrt/beamrtReflectionTraceP_v043.hlsl')
        self.assertIn('#define BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION 1', wrapper)
        self.assertIn('#include "beamrtReflectionTraceP_v042.hlsl"', wrapper)
        header = self.source('shaders/beamrt/beamrtReflectionTrace.h.hlsl')
        self.assertRegex(header, r'#ifdef BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION\s+uniform float reflectionSourceReconstructionEnabled;\s+#endif')
        old = self.source('shaders/beamrt/beamrtReflectionTraceP_v042.hlsl')
        self.assertNotIn('BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION', old)

    def test_point_depth_ownership_precedes_each_original_colour_load(self):
        source = self.source('shaders/beamrt/beamrtReflectionSourceReconstruction.h.hlsl')
        for evidence in ('prepassDepthTexTex.Load', 'backBufferTexTex.Load', 'predictedInverse',
                         'sourceViewportMin', 'depthViewportMin', 'sourceCoverage += weight',
                         'if (backwards * forwards <= 0.0) return 0.0',
                         'beamrtReflectionRadianceIsFinite(tapRadiance)', 'accumulated / sourceCoverage'):
            self.assertIn(evidence, source)
        self.assertLess(source.index('abs(tapDepth - predictedDepth) > tolerance'),
                        source.index('hdrDecode(backBufferTexTex.Load'))
        code = re.sub(r'//[^\n]*', '', source)
        self.assertNotIn('tex2D', code)
        self.assertNotIn('reflectionThickness', code)

    def test_no_unvalidated_rough_atlas_after_source_reconstruction(self):
        source = self.source('shaders/beamrt/beamrtReflectionTraceP_v024.hlsl')
        self.assertIn('bool reconstructSource = reflectionSourceReconstructionEnabled > 0.5', source)
        self.assertIn('&& !reconstructSource', source)
        self.assertLess(source.index('beamrtReflectionReconstructedSource(refinedUv'),
                        source.index('bestRadiance = max(reflectedLinear, 0.0) * confidence'))
        for metadata in ('bestConfidence', 'bestHitMetadata', 'bestGeometryCategory'):
            self.assertIn(f'return float4(bestRadiance, {metadata})', source)
        # Source rejection must not turn the ray into another traversal attempt.
        helper = self.source('shaders/beamrt/beamrtReflectionSourceReconstruction.h.hlsl')
        self.assertNotIn('bestHitMetadata', re.sub(r'//[^\n]*', '', helper))

    def test_gpu_fixture_reproduces_linear_leak_and_checks_actual_versions(self):
        build = self.source('native/lighting/build_reflection_source_reconstruction.ps1')
        self.assertIn('/Ges /WX /O3', build)
        self.assertIn("@('042','043')", build)
        self.assertIn("Join-Path $env:TEMP 'brt-rsrc'", build)
        self.assertNotIn('Start-Process', build)
        fixture = self.source('native/lighting/reflection_source_reconstruction_test.cpp')
        for evidence in ('D3D12_FILTER_MIN_MAG_MIP_LINEAR', 'leaking[0]>20',
                         'disabled v043 differs from v042', 'packedHits>0',
                         'reciprocal-depth planar slope was rejected',
                         'thin-feature depth extrema',
                         'different source/depth dimensions', 'source viewport boundary',
                         'std::numeric_limits<float>::quiet_NaN()', 'std::numeric_limits<float>::infinity()'):
            self.assertIn(evidence, fixture)


if __name__ == '__main__':
    unittest.main()
