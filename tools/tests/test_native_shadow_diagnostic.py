"""Native relay controller/generation/half-packet contracts; not live GPU proof."""
import math
from pathlib import Path
import struct
import sys
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT
import test_light_visibility_diagnostic as existing
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import beamrt_native_shadow_diagnostic as prepare
SOURCE=(ROOT/'lua/ge/extensions/beamrt/nativeShadowDiagnostic.lua').read_text()
HELPER=(ROOT/'shaders/beamrt/beamrtNativeShadowRelay.h.hlsl').read_text()
VIEW=(ROOT/'shaders/beamrt/beamrtNativeShadowViewP_v003.hlsl').read_text()
CAPTURE=(ROOT/'shaders/beamrt/beamrtNativeShadowCaptureP_v001.hlsl').read_text()
EXTRA=r'''
originalCreateObject=createObject
function createObject(class)
 local o=originalCreateObject(class);o.children={}
 function o:add(child)table.insert(self.children,child)end
 function o:getCount()return #self.children end
 function o:getObject(i)return self.children[i+1]end
 function o:getRenderTargetSize()return {x=1,y=1}end
 return o
end
managerName='Advanced Lighting 1.5'
function getActiveLightManager()return managerName end
function setShadowVizLight()error('Do not mutate native shadow visualizer')end
manifest={schema='beamrt.native.visibility.v1',dependencies={['shaders/beamrt/beamrtNativeShadowRelay.h.hlsl']='helper'},lights={}}
files={['/shaders/beamrt/beamrtNativeShadowRelay.h.hlsl']='helper'}
for _,kind in ipairs({'Point','Spot'})do
 local native='shaders/common/lighting/advanced/'..kind:lower()..'LightP.hlsl'
 local path='shaders/beamrt/generated/beamrtNativeVisibility'..kind..'_123abc.hlsl'
 manifest.lights[kind]={nativePath=native,nativeSource='native'..kind,shaderPath=path,generatedSource='private'..kind}
 files['/'..native]='native'..kind;files['/'..path]='private'..kind
 local s=createObject('ShaderData');s:setField('DXPixelShaderFile',0,native)
 s:setField('DXVertexShaderFile',0,'shaders/common/lighting/advanced/convexGeometryV.hlsl')
 s:setField('pixVersion',0,'5');s:registerObject('AL_'..kind..'LightShader')
 local m=createObject('CustomMaterial');m:setField('shader',0,'AL_'..kind..'LightShader')
 m:setField('sampler','shadowMap','$dynamiclight');m:setField('target',0,'lightinfo')
 m:registerObject('AL_'..kind..'LightMaterial')
 function m:reload()self.reloads=(self.reloads or 0)+1;if self.failReload then self.failReload=false;error('reload failed')end end
end
function readFile(path)return files[path]end
function jsonReadFile()return manifest end
'''
NATIVE_FIXTURE='''#include "convexGeometry.h.hlsl"
LightBufferOutput main(ConvexConnectP IN)
{
    float4 p=mul(cb.worldToLightProj, float4(0,0,0,1));
#ifdef NO_SHADOW
    float shadowed = 1.0;
#else
    float shadowed = nativeShadowFilter(p);
#endif
    float4 lightColorMod = cb.lightColor;
    float3 lightColorOut=lightColorMod.rgb;float irradiance=shadowed;float retroMul=1;
    float4 specular=0;LightBufferOutput outData=(LightBufferOutput)0;
    lightinfoCondition(outData, lightColorOut * irradiance * retroMul, irradiance, specular, 0);
    return outData;
}
'''

class Controller(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            vm=cls(unpack_returned_tuples=True);vm.execute(existing.FIXTURE);vm.execute(EXTRA)
            m=vm.execute(SOURCE);vm.globals().native=m
            yield vm,m

    def test_inspection_is_read_only_and_does_not_treat_backend_absence_as_proof(self):
        for vm,m in self.runtimes():
            report=m.inspect(2);self.assertTrue(report.canStart,report.reason)
            self.assertFalse(report.gpuExecutionVerified);self.assertIn('unverified',report.reason)
            self.assertFalse(m.getStatus().enabled);self.assertEqual(len(vm.globals().deletes),0)
            self.assertEqual(vm.globals().writes,0)
            self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)

    def test_supported_manager_source_and_unique_native_light_are_required(self):
        for change in ("managerName='Advanced Lighting'",'ClusteredShading={}',"objects[2].enabled='0'",
            "objects.AL_SpotLightMaterial:setField('sampler','shadowMap','#unknown')",
            "files['/'..manifest.lights.Spot.nativePath]='changed'"):
            for vm,m in self.runtimes():
                vm.execute(change);self.assertFalse(m.enable(2)[0]);self.assertFalse(m.getStatus().enabled)
                self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)
        for vm,m in self.runtimes():
            vm.execute("objects[3]=objects[2];originalQuery=scenetree.findClassObjects;scenetree.findClassObjects=function(c)return c=='SpotLight'and{2,3}or{1}end")
            # Repeated same object token is deduplicated by acquisition.
            self.assertTrue(m.inspect(2).canStart)
            vm.execute("lamp(3,'SpotLight')")
            self.assertFalse(m.inspect(2).canStart)

    def test_native_shader_and_only_extra_sampler_are_leased_then_restored(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0]);m.update()
            material=vm.globals().objects.AL_SpotLightMaterial
            self.assertEqual(material.fields.shader[0],'BeamRT_NativeShadowNativeShader')
            self.assertEqual(material.fields.sampler.shadowMap,'$dynamiclight')
            shader=vm.globals().objects.BeamRT_NativeShadowNativeShader
            self.assertIn('BEAMRT_NATIVE_POSITION=float3(1,2,3)',shader.fields.defines[0])
            self.assertEqual(shader.fields.samplerNames[14],'beamrtNativeFrame')
            frame=vm.globals().objects.BeamRT_NativeShadowFrameFx
            view=vm.globals().objects.BeamRT_NativeShadowViewFx
            self.assertEqual(frame.fields.targetSize[0],'1 1')
            self.assertEqual(frame.fields.renderTime[0],'PFXTexGenOnDemand')
            schedule=vm.globals().objects.BeamRT_NativeShadowFrameScheduleFx
            capture=vm.globals().objects.BeamRT_NativeShadowCaptureFx
            capture_schedule=vm.globals().objects.BeamRT_NativeShadowCaptureScheduleFx
            self.assertEqual(schedule.fields.renderBin[0],'AL_LightBin')
            self.assertEqual(schedule.fields.renderTime[0],'PFXBeforeBin')
            self.assertTrue(schedule.skipDraw);self.assertTrue(capture_schedule.skipDraw)
            self.assertEqual(schedule.getCount(schedule),1)
            self.assertEqual(capture.fields.renderTime[0],'PFXTexGenOnDemand')
            self.assertEqual(capture.fields.texture[1],'#lightinfo[RT1]')
            self.assertEqual(capture_schedule.fields.renderTime[0],'PFXAfterBin')
            self.assertEqual(view.fields.texture[1],'#BeamRT_NativeShadowSnapshot')
            self.assertIsNone(view.fields.texture[2])
            self.assertTrue(vm.globals().objects.BeamRT_NativeShadowViewShader.DXPixelShaderFile.endswith('P_v003.hlsl'))
            self.assertFalse(frame.allowReflectPass);self.assertFalse(view.allowReflectPass)
            self.assertFalse(m.getStatus().nativeAttenuationChanged)
            self.assertFalse(m.getStatus().beautyRGBChanged);self.assertFalse(m.getStatus().feedsGI)
            self.assertFalse(m.getStatus().nativeDispatchObserved)
            self.assertEqual(vm.globals().writes,0)
            self.assertTrue(m.disable()[0])
            self.assertEqual(material.fields.shader[0],'AL_SpotLightShader')
            self.assertEqual(material.fields.sampler.beamrtNativeFrame,'')
            self.assertIsNone(vm.globals().objects.BeamRT_NativeShadowFrameFx)

    def test_failed_reload_or_restore_retains_lease_and_neutralizes_packets(self):
        for vm,m in self.runtimes():
            vm.globals().objects.AL_SpotLightMaterial.failReload=True
            self.assertFalse(m.enable(2)[0]);self.assertFalse(m.getStatus().enabled)
            self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')
            self.assertTrue(m.enable(2)[0]);vm.globals().objects.AL_SpotLightMaterial.failReload=True
            self.assertFalse(m.disable()[0]);self.assertTrue(m.getStatus().pendingRestore)
            self.assertEqual(vm.globals().objects.BeamRT_NativeShadowFrameFx.consts['$nativeShadowEpoch'],0)
            self.assertEqual(vm.globals().objects.BeamRT_NativeShadowViewFx.consts['$nativeShadowEpoch'],0)
            self.assertTrue(m.disable()[0]);self.assertTrue(m.enable(2)[0])

    def test_foreign_shader_pass_modification_light_movement_and_disabled_light_stop(self):
        for change in ("objects.AL_SpotLightMaterial:setField('shader',0,'Foreign')",'objects[2].position={9,2,3}',
            "objects[2].enabled='0'", "objects.BeamRT_NativeShadowViewFx:setField('texture',1,'#prepass[RT0]')"):
            for vm,m in self.runtimes():
                m.enable(2);vm.execute(change);m.update();self.assertFalse(m.getStatus().enabled)
                expected='Foreign'if'Foreign'in change else'AL_SpotLightShader'
                self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],expected)

    def test_frame_tags_do_not_repeat_then_expire_and_restore(self):
        for vm,m in self.runtimes():
            m.enable(2);tags=[]
            for _ in range(2050):
                if not m.getStatus().enabled:break
                tags.append(m.getStatus().epoch);m.update()
            self.assertEqual(len(tags),len(set(tags)))
            self.assertNotIn(480,tags)
            self.assertFalse(any(992<=x<=1055 for x in tags))
            self.assertEqual(len(tags),1919)
            self.assertFalse(m.getStatus().enabled);self.assertIn('budget',m.getStatus().reason)
            self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')

    def test_manual_stop_restart_does_not_reuse_the_previous_frame_tag(self):
        for vm,m in self.runtimes():
            m.enable(2);m.update();old=m.getStatus().epoch;m.disable()
            self.assertTrue(m.enable(2)[0]);self.assertGreater(m.getStatus().epoch,old)

    def test_callback_counts_are_not_gpu_proof_and_own_callbacks_are_removed(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0])
            vm.execute('BeamRT_NativeShadowFrameFxCallbacks.preProcess(); BeamRT_NativeShadowCaptureFxCallbacks.preProcess()')
            status=m.getStatus()
            self.assertEqual(status.passes.FrameFx.processCalls,1)
            self.assertEqual(status.passes.CaptureFx.processCalls,1)
            self.assertTrue(status.processCountsAreCPUOnly)
            self.assertFalse(status.gpuExecutionVerified)
            self.assertTrue(m.disable()[0])
            self.assertIsNone(vm.globals().BeamRT_NativeShadowFrameFxCallbacks)
            self.assertIsNone(vm.globals().BeamRT_NativeShadowCaptureFxCallbacks)

    def test_only_early_parent_callback_authorizes_capture_for_current_epoch(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0])
            capture=vm.globals().objects.BeamRT_NativeShadowCaptureFx
            frame=vm.globals().objects.BeamRT_NativeShadowFrameFx
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],0)
            vm.execute('BeamRT_NativeShadowCaptureFxCallbacks.preProcess()')
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],0) # lazy read is NOT authorization
            vm.execute('BeamRT_NativeShadowFrameScheduleFxCallbacks.preProcess(); BeamRT_NativeShadowCaptureScheduleFxCallbacks.preProcess()')
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],m.getStatus().epoch)
            self.assertEqual(frame.consts['$nativeScheduledEpoch'],m.getStatus().epoch)
            m.update()
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],0)
            self.assertEqual(frame.consts['$nativeScheduledEpoch'],0)
        self.assertLess(CAPTURE.index('nativeScheduledEpoch!=nativeShadowEpoch'),CAPTURE.index('nativeSpecTexTex.GetDimensions'))
        self.assertIn('relayFailure(13)',CAPTURE)

    def test_detached_child_or_changed_capture_binding_stops_and_restores(self):
        for change in ("objects.BeamRT_NativeShadowCaptureFx:setField('texture',1,'#prepass[RT1]')",
                       'objects.BeamRT_NativeShadowFrameScheduleFx.children={}',
                       'BeamRT_NativeShadowFrameFxCallbacks={}'):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2)[0]);vm.execute(change);m.update()
                self.assertFalse(m.getStatus().enabled)
                self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')


class GeneratedShader(unittest.TestCase):
    def test_transport_failures_have_seven_distinct_numbered_stages(self):
        for stage in range(1,8):
            self.assertIn('relayFailure('+str(stage)+')',CAPTURE)
        self.assertIn('bar<stage',VIEW)
        self.assertIn('frame.x!=nativeShadowEpoch',CAPTURE)
        self.assertIn('sw!=rw||sh!=rh||sw<=1||sh<=1',CAPTURE)
        self.assertNotIn('nativeSpecTex',VIEW) # late display NEVER reads lightinfo
        self.assertIn('payload.y!=nativeShadowEpoch',VIEW)
        self.assertIn('point',VIEW.lower())

    def test_native_math_and_rgb_output_preserved_alpha_only_instrumentation(self):
        for kind in ('Point','Spot'):
            generated=prepare.generate(NATIVE_FIXTURE,kind)
            self.assertIn('float beamrtNativeVisibility = shadowed;',generated)
            self.assertIn('float shadowed = nativeShadowFilter(p);',generated)
            self.assertIn('outData.outB.a = beamrtNativePacket',generated)
            self.assertNotIn('outData.outA =',generated)
            self.assertNotIn('outData.outB.rgb =',generated)
            self.assertNotIn('shadowed *=',generated)
            self.assertIn('#ifndef NO_SHADOW',generated)
            self.assertIn('#ifdef BNG_LIGHTING_1_5',generated)
        self.assertNotIn('prepass',HELPER.lower())
        self.assertNotIn('worldToLight',VIEW)
        self.assertNotIn('visibilityProject',VIEW)

    def test_changed_contracts_refused(self):
        for token in ('float4 lightColorMod = cb.lightColor;','return outData;','cb.worldToLightProj'):
            with self.assertRaises(ValueError):prepare.generate(NATIVE_FIXTURE.replace(token,'changed'),'Spot')
        with self.assertRaises(ValueError):prepare.generate(NATIVE_FIXTURE+'\nbeamrtNative','Spot')

    def test_every_packet_round_trips_binary16_with_finite_normal_unique_epochs(self):
        values=set()
        for epoch in range(32,2016):
            if epoch==480 or 992<=epoch<=1055:continue
            for code in range(17):
                bits=(epoch<<5)|code
                value=struct.unpack('<e',struct.pack('<H',bits))[0]
                self.assertTrue(math.isfinite(value));self.assertGreaterEqual(abs(value),2**-14)
                self.assertNotEqual(value,1) # missing alpha defaults must never be a valid frame
                returned=struct.unpack('<H',struct.pack('<e',value))[0]
                self.assertEqual(returned>>5,epoch);self.assertEqual(returned&31,code)
                values.add(returned)
        self.assertEqual(len(values),1919*17)
        self.assertIn('epoch!=(uint)nativeShadowEpoch',VIEW)
        self.assertIn('code>=16',VIEW)

if __name__=='__main__':unittest.main()
