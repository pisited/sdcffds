"""Native F0 routing and CPU reference math; not live G-buffer/GPU proof."""
import math
import unittest
import test_coherent_renderer as backend


class MaterialResponse(unittest.TestCase):
    def test_mode_is_explicit_preserves_quality_and_binds_only_apply_slot_five(self):
        for lua,r in backend.CoherentRenderer().runtimes():
            before={k:v for k,v in r.getOptions().items()}
            self.assertFalse(before['nativeMaterialResponse'])
            self.assertTrue(r.setParameter('nativeMaterialResponse',True))
            self.assertTrue(r.enable())
            lua.execute('for i=1,12 do renderer.update(1/60)end')
            self.assertTrue(r.getStatus().materialResponseActive)
            self.assertTrue(r.getStatus().active)
            for k,v in before.items():
                if k!='nativeMaterialResponse':self.assertEqual(r.getOptions()[k],v,k)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectApplyPass:getField("texture",5)'),'#prepass[RT1]')
            self.assertNotEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass:getField("texture",5)'),'#prepass[RT1]')
            for suffix in ('TracePass','NativeResolvePass','ApplyPass','TemporalPassA'):
                self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffect'+suffix+'._const["$uNativeMaterialResponse"]'),1)
            self.assertTrue(r.setParameter('nativeMaterialResponse',False))
            r.update(1/60)
            self.assertTrue(r.getStatus().active)
            self.assertFalse(r.getStatus().materialResponseActive)
            self.assertNotEqual(lua.eval('objects.BeamRTCoherentPostEffectApplyPass:getField("texture",5)'),'#prepass[RT1]')
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uNativeMaterialResponse"]'),0)

    def test_diagnostics_mission_refresh_restart_and_owned_binding_guard(self):
        for lua,r in backend.CoherentRenderer().runtimes():
            r.setParameter('nativeMaterialResponse',True);self.assertTrue(r.enable())
            r.setParameter('debugView',4);r.update(1/60)
            self.assertFalse(r.getStatus().materialResponseActive)
            r.setParameter('debugView',0);r.update(1/60)
            self.assertTrue(r.getStatus().materialResponseActive)
            lua.execute("local p=require('ge/extensions/beamrt/coherentPipeline');p.onMissionLoad(p)")
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectApplyPass:getField("texture",5)'),'#prepass[RT1]')
            for _ in range(3):
                self.assertTrue(r.disable());self.assertTrue(r.enable())
                self.assertTrue(r.getStatus().materialResponseActive)
                self.assertTrue(r.getStatus().active)
            lua.execute("objects.BeamRTCoherentPostEffectApplyPass:setField('texture',5,'#Foreign')")
            r.update(1/60)
            self.assertFalse(r.getStatus().active)

    def test_hdr_and_terrain_conflicts_refused_in_both_directions(self):
        for lua,r in backend.CoherentRenderer().runtimes():
            r.setParameter('hdrComposite',False)
            self.assertFalse(r.setParameter('nativeMaterialResponse',True)[0])
            r.setParameter('hdrComposite',True);r.setParameter('terrainMaskEnable',True)
            self.assertFalse(r.setParameter('nativeMaterialResponse',True)[0])
            r.setParameter('terrainMaskEnable',False);r.setParameter('nativeMaterialResponse',True)
            self.assertFalse(r.setParameter('terrainMaskEnable',True)[0])
            self.assertFalse(r.setParameter('hdrComposite',False)[0])

    def test_shader_contract_and_fresnel_energy_bounds(self):
        root=backend.ROOT/'shaders/beamrt/coherent'
        source=(root/'beamrt_coherent_composite.hlsl').read_text()
        self.assertIn('waterMask < 0.001 && puddleMask < 0.001',source)
        self.assertIn('if (mw>0 && mh>0)',source)
        self.assertIn('terrainTexTex.Load(int3(materialPixel,0)).rgb',source)
        self.assertIn('sceneColor+max(combinedReflectionColor,0.0)*F*saturate(alpha*uIntensity)',source)
        self.assertIn('viewportCoordToRenderTarget(viewportUV,rtParams5)',source)
        projection=(root/'beamrt_coherent_projection.hlsl').read_text()
        self.assertIn('uNativeMaterialResponse',projection)
        trace=(root/'beamrt_coherent_trace.hlsl').read_text()
        self.assertIn('puddleMask > 0.001 ? FresnelMask',trace)
        self.assertIn('? FresnelMask(viewToSurface, normalWS) : BrtcOrdinaryFresnelMask',source)
        # Linear-space Schlick reference: tinted metals, dielectric F0, grazing.
        for f0 in ((0,0,0),(.04,.04,.04),(.95,.6,.2),(1,1,1)):
            for nv in (0,.1,.5,1):
                f90=min(1,50*max(f0))
                F=[f+(f90-f)*(1-nv)**5 for f in f0]
                for f,Fc in zip(f0,F):self.assertTrue(f<=Fc<=1)
                beauty=(.1,.25,.5);incident=(2,1,.2)
                result=[b+c*f*.7 for b,c,f in zip(beauty,incident,F)]
                self.assertTrue(all(math.isfinite(x) and x>=b for x,b in zip(result,beauty)))
        self.assertEqual([f+(1-f)*(1-1)**5 for f in (.04,.04,.04)],[.04]*3)
        self.assertIn('float f90=saturate(50.0*max(f0.r,max(f0.g,f0.b)))',source)

if __name__=='__main__':unittest.main()
