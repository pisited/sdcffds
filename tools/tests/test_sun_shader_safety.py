"""Sunlight fail-closed source guards; GPU execution is tested separately."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SunShaderSafety(unittest.TestCase):
    def source(self, name):
        return (ROOT / name).read_text()

    def test_consumer_rejects_nonfinite_identity_before_indexing(self):
        shader = self.source('shaders/beamrt/beamrtMeshSunHook.h.hlsl')
        guard = shader.index('!all(isfinite(hpos.xy))')
        self.assertIn('!all(isfinite(worldPosition))', shader)
        self.assertLess(guard, shader.index('int2 pixel=int2(hpos.xy)'))
        self.assertIn('any(hpos.xy<0)', shader)
        self.assertLess(shader.index('!all(isfinite(value))'), shader.index('visibility=value.w==2?0:1'))

    def test_producer_rejects_invalid_receiver_toggle_and_direction(self):
        shader = self.source('shaders/beamrt/beamrtMeshSunVisibilityP_v001.hlsl')
        for guard in ('!all(isfinite(receiver))', 'receiver.w<=0', '!isfinite(meshVisibilityEnabled)',
                      '!all(isfinite(world))', '!all(isfinite(towardSun))', '!isfinite(magnitude)'):
            self.assertIn(guard, shader)
            self.assertLess(shader.index(guard), shader.index('int hit=beamrtMeshTrace'))

    def test_fixture_uses_actual_producer_and_exact_consumer(self):
        build = self.source('native/shadows/build.ps1')
        fixture = self.source('native/shadows/fixture.hlsl')
        self.assertIn('shaders/beamrt/beamrtMeshSunVisibilityP_v001.hlsl', build)
        self.assertIn('foreach($beamrtMode in 0..3)', build)
        self.assertIn('#include "shaders/beamrt/beamrtMeshSunHook.h.hlsl"', fixture)
        self.assertIn('beamrtResolveSunVisibility(nativeVisibility,cloudVisibility,position,world)', fixture)
        self.assertIn('float3(.2,.3,.4)+float3(1,2,3)*visibility', fixture)

    def test_gpu_cases_cover_ordinary_shadows_and_invalid_inputs(self):
        fixture = self.source('native/shadows/self_test.cpp')
        for case in ('thin zero-thickness mesh blocker missed', 'self/behind/bias-excluded face falsely blocked sun',
                     'stale receiver-position mismatch did not retain native sunlight',
                     'resolution mismatch did not retain native sunlight', 'OFF did not restore native sunlight',
                     'NaN relay receiver accepted as opaque shadow', 'NaN lighting receiver accepted as matching relay',
                     'invalid receiver depth certified sunlight', 'valid sunlight failed recovery after rejected inputs'):
            self.assertIn(case, fixture)
        self.assertIn('std::isfinite(values[i][c])', fixture)
        self.assertIn('readPixels(host,target.Get())', fixture)
        self.assertIn('nonuniformly scaled sun blocker misplaced', fixture)
        self.assertIn('mirrored sun blocker misplaced', fixture)

    def test_offline_host_shared_without_capture_or_adapter_changes(self):
        shared = self.source('native/gi/gpu_fixture_host.h')
        self.assertIn('gpu_fixture_pass.h', self.source('native/shadows/self_test.cpp'))
        self.assertIn('gpu_fixture_host.h', self.source('native/gi/gpu_fixture_pass.h'))
        self.assertIn('gpu_fixture_host.h', self.source('native/gi/test_support.h'))
        for forbidden in ('DetourAttach', 'LoadLibrary', 'BeamRT_GIRecord', 'BeamRT_CaptureStart'):
            self.assertNotIn(forbidden, shared)
        self.assertIn('queue->ExecuteCommandLists', shared)
        self.assertIn('queue->Signal', shared)


if __name__ == '__main__':
    unittest.main()
