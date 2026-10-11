"""Native-source integration contract and preservation, without game assets."""
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import beamrt_native_sun_hook as hook

SOURCE='''#include "farFrustumQuad.h.hlsl"
#include "farFrustumQuad.hlsl"
LightBufferOutput main(FarFrustumQuadConnectP IN)
{
    const float3 worldPos = perspectiveDiv(mul(screenToWorldPos0, float4(posNdc, 1))).xyz;
    unshadowed = sunShadowMaskTex.Load(int3(IN.hpos.xy, 0)).r;
    unshadowed *= cloudCookie;
    unshadowed = min(unshadowed, sss_mask);
    float Sat_NL_Att = saturate(dotNL * unshadowed) * lightBrightness * lastFrameExposure;
    specular = AL_CalcSpecular(material, -lightDirection, -wsEyeVec);
    lightinfoCondition(outData, lightColorOut * Sat_NL_Att, Sat_NL_Att, specular, 0);
    return outData;
}
'''

class Hook(unittest.TestCase):
    def test_hook_after_native_visibility_before_direct_shading(self):
        new=hook.generate(SOURCE)
        self.assertLess(new.index('unshadowed *= cloudCookie'),new.index('beamrtMeshSunFactor'))
        self.assertLess(new.index('unshadowed = min(unshadowed, sss_mask)'),new.index('beamrtMeshSunFactor'))
        self.assertLess(new.index('beamrtMeshSunFactor'),new.index('float Sat_NL_Att'))
        for line in SOURCE.splitlines()[4:]:self.assertIn(line,new)
        self.assertIn('if (subsurfaceIntensity <= 0.0)',new)
        self.assertIn('shaders/common/lighting/advanced/farFrustumQuad.h.hlsl',new)
    def test_unsupported_or_duplicate_contract_rejected(self):
        for text in (SOURCE+SOURCE,SOURCE.replace('sunShadowMaskTex','otherTex'),
                     SOURCE.replace('screenToWorldPos0','otherMatrix'),SOURCE+'\nTexture2D x:register(t14);',
                     SOURCE.replace('farFrustumQuad.hlsl','elsewhere.hlsl')):
            with self.assertRaises(ValueError):hook.generate(text)
    def test_no_installation_writes_and_content_addressed_private_output(self):
        with tempfile.TemporaryDirectory() as root:
            game=Path(root)/'game';mod=Path(root)/'mod';mod.mkdir()
            native=game/hook.NATIVE;native.parent.mkdir(parents=True);native.write_text(SOURCE)
            for name in ('farFrustumQuad.h.hlsl','farFrustumQuad.hlsl'):
                (native.parent/name).write_text('// fixture dependency\n')
            first=hook.prepare(game,mod);second=hook.prepare(game,mod)
            self.assertEqual(first['shaderPath'],second['shaderPath'])
            self.assertEqual(native.read_text(),SOURCE)
            self.assertFalse(first['gpuExecutionVerified'])
            self.assertEqual((mod/first['shaderPath']).read_text(),hook.generate(SOURCE))
    def test_overlap_and_slot_conflict_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            game=Path(root)/'game';mod=Path(root)/'mod';mod.mkdir()
            with self.assertRaises(ValueError):hook.prepare(game,game/'mods')
            native=game/hook.NATIVE;native.parent.mkdir(parents=True);native.write_text(SOURCE)
            (native.parent/'farFrustumQuad.h.hlsl').write_text('uniform_sampler2D(existing,14);')
            with self.assertRaises(ValueError):hook.prepare(game,mod)
            self.assertFalse((mod/'shaders').exists())

if __name__=='__main__':unittest.main(verbosity=2)
