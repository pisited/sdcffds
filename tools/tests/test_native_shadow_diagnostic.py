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
VIEW=(ROOT/'shaders/beamrt/beamrtNativeShadowViewP_v004.hlsl').read_text()
CAPTURE=(ROOT/'shaders/beamrt/beamrtNativeShadowCaptureP_v002.hlsl').read_text()
EXTRA=r'''
originalCreateObject=createObject
nextObjectId=100000
function createObject(class)
 local o=originalCreateObject(class);o.children={};nextObjectId=nextObjectId+1;o.nativeId=nextObjectId
 function o:getID()return self.nativeId end
 function o:getId()return self.nativeId end
 function o:getName()return self.name end
 function o:getClassName()return class end
 function o:add(child)table.insert(self.children,child)end
 function o:getCount()return #self.children end
 function o:getObject(i)
   local child=self.children[i+1];if not child then return nil end
   -- Native SimSet enumeration may return a distinct base-type Lua wrapper.
   return {getID=function()return child:getID()end,getName=function()return child.name end}
 end
 function o:getRenderTargetSize()return {x=1,y=1}end
 function o:enable()
   if self:getField('renderTime',0)=='PFXTexGenOnDemand'then return end
   local cb=_G[(self.name or '')..'Callbacks']
   self.enabled=not cb or not cb.onEnabled or cb.onEnabled()==true
 end
 return o
end
managerName='Advanced Lighting 1.5'
function getActiveLightManager()return managerName end
local nativeBin=createObject('AdvancedLightBinManager');nativeBin:registerObject('AL_LightBinMgr')
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
        for change in ("managerName='Advanced Lighting'",'ClusterShading={}','ClusteredShading={}',"objects[2].enabled='0'",
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

    def test_installed_cluster_namespace_blocks_all_probes_without_native_writes(self):
        for mode in ('visibility','dispatch','selector'):
            for vm,m in self.runtimes():
                vm.execute("ClusterShading=setmetatable({},{__index=function()error('no backend getters')end})")
                report=m.inspect(2)
                self.assertFalse(report.canStart);self.assertTrue(report.clusteredBackendExposed)
                self.assertFalse(m.enable(2,mode)[0])
                self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)
                self.assertIsNone(vm.globals().objects.BeamRT_NativeShadowNativeShader)
                self.assertTrue(m.getStatus().clusteredBackendExposed)
                self.assertFalse(m.getStatus().clusteredDispatchIntegrated)

    def test_new_cluster_namespace_exposure_restores_active_native_lease(self):
        for name in ('ClusterShading','ClusteredShading'):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2,'dispatch')[0])
                vm.execute(name+'={}')
                m.update()
                self.assertFalse(m.getStatus().enabled)
                self.assertFalse(m.getStatus().pendingRestore)
                self.assertIn('backend changed',m.getStatus().reason)
                self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')

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
            self.assertEqual(schedule.fields.renderBin[0],'AL_LightBinMgr')
            self.assertEqual(schedule.fields.renderTime[0],'PFXBeforeBin')
            self.assertEqual(schedule.fields.skipDraw[0],'0')
            self.assertEqual(capture_schedule.fields.skipDraw[0],'0')
            self.assertEqual(schedule.fields.targetSize[0],'1 1')
            self.assertEqual(schedule.getCount(schedule),1)
            self.assertEqual(capture.fields.renderTime[0],'PFXTexGenOnDemand')
            self.assertEqual(capture.fields.texture[1],'#lightinfo[RT1]')
            self.assertEqual(capture_schedule.fields.renderTime[0],'PFXAfterBin')
            self.assertEqual(view.fields.texture[1],'#BeamRT_NativeShadowSnapshot')
            self.assertIsNone(view.fields.texture[2])
            self.assertTrue(vm.globals().objects.BeamRT_NativeShadowViewShader.DXPixelShaderFile.endswith('P_v004.hlsl'))
            self.assertFalse(frame.allowReflectPass);self.assertFalse(view.allowReflectPass)
            self.assertFalse(frame.isEnabled(frame))
            self.assertFalse(capture.isEnabled(capture))
            self.assertTrue(schedule.isEnabled(schedule));self.assertTrue(view.isEnabled(view))
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
                vm.execute('BeamRT_NativeShadowFrameScheduleFxCallbacks.setShaderConsts(); BeamRT_NativeShadowCaptureScheduleFxCallbacks.setShaderConsts()')
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

    def test_on_demand_children_stay_manager_disabled_but_do_not_stop_diagnostic(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0])
            for suffix in ('FrameFx','CaptureFx'):
                child=vm.globals().objects['BeamRT_NativeShadow'+suffix]
                self.assertFalse(child.isEnabled(child));child.enable(child)
                self.assertFalse(child.isEnabled(child)) # engine returns early for on-demand enable
            m.update();self.assertTrue(m.getStatus().enabled,m.getStatus().reason)
            self.assertGreater(m.getStatus().epoch,32)
            vm.execute('objects.BeamRT_NativeShadowViewFx:disable()')
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertIn('View pass stopped',m.getStatus().reason)

    def test_scheduled_root_disable_still_stops_and_restores(self):
        for suffix in ('FrameScheduleFx','CaptureScheduleFx'):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2)[0])
                root=vm.globals().objects['BeamRT_NativeShadow'+suffix];root.disable(root)
                m.update();self.assertFalse(m.getStatus().enabled)
                self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')

    def test_child_identity_uses_engine_id_not_lua_wrapper_equality(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0])
            vm.execute('''
              local root=objects.BeamRT_NativeShadowFrameScheduleFx
              local child=objects.BeamRT_NativeShadowFrameFx
              assert(root:getObject(0)~=child)
              assert(root:getObject(0):getID()==child:getID())
            ''')
            m.update();self.assertTrue(m.getStatus().enabled,m.getStatus().reason)
            vm.execute('objects.BeamRT_NativeShadowFrameScheduleFx.children={objects.BeamRT_NativeShadowCaptureFx}')
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertIn('expectedID=',m.getStatus().reason)
            self.assertEqual(m.getStatus().lastAttachmentFailure['pass'],'Frame')
            self.assertNotEqual(m.getStatus().lastAttachmentFailure.expectedId,m.getStatus().lastAttachmentFailure.reportedId)

    def test_missing_child_identity_or_failed_add_refused_before_native_material_write(self):
        for change in ('''local original=createObject;createObject=function(class)
              local o=original(class);function o:add(child)end;return o end''',
                       '''local original=createObject;createObject=function(class)
              local o=original(class);o.getID=nil;o.getId=nil;return o end'''):
            for vm,m in self.runtimes():
                vm.execute(change);self.assertFalse(m.enable(2)[0])
                self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)
                self.assertFalse(m.getStatus().pendingRestore)
                self.assertIn('attachment mismatch',m.getStatus().reason)

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
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],0) # setup callback is not a frame signal
            vm.execute('BeamRT_NativeShadowFrameScheduleFxCallbacks.setShaderConsts(); BeamRT_NativeShadowCaptureScheduleFxCallbacks.setShaderConsts()')
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],m.getStatus().epoch)
            self.assertEqual(frame.consts['$nativeScheduledEpoch'],m.getStatus().epoch)
            m.update()
            self.assertEqual(capture.consts['$nativeScheduledEpoch'],0)
            self.assertEqual(frame.consts['$nativeScheduledEpoch'],0)
        self.assertLess(CAPTURE.index('nativeScheduledEpoch!=nativeShadowEpoch'),CAPTURE.index('nativeSpecTexTex.GetDimensions'))
        self.assertIn('relayFailure(13)',CAPTURE)

    def test_per_draw_updates_survive_once_only_preprocess_and_status_survives_stop(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0])
            vm.execute('''
              function simulateDraw(name)
                local o=objects[name];local cb=_G[name..'Callbacks']
                if not o.preProcessed then cb.preProcess();o.preProcessed=true end
                cb.setShaderConsts()
                for _,child in ipairs(o.children)do simulateDraw(child.name)end
              end
            ''')
            for _ in range(3):
                m.update()
                vm.execute('''simulateDraw('BeamRT_NativeShadowFrameScheduleFx')
                  simulateDraw('BeamRT_NativeShadowCaptureScheduleFx')
                  simulateDraw('BeamRT_NativeShadowViewFx')''')
                epoch=m.getStatus().epoch
                self.assertEqual(vm.globals().objects.BeamRT_NativeShadowFrameFx.consts['$nativeScheduledEpoch'],epoch)
                self.assertEqual(vm.globals().objects.BeamRT_NativeShadowCaptureFx.consts['$nativeScheduledEpoch'],epoch)
            live=m.getStatus()
            self.assertEqual(live.passes.CaptureFx.processCalls,1)
            self.assertEqual(live.passes.CaptureFx.drawCalls,3)
            self.assertFalse(live.gpuExecutionVerified)
            m.disable('test stop');stopped=m.getStatus()
            self.assertTrue(stopped.passesAreLastStop)
            self.assertEqual(stopped.passes.CaptureFx.drawCalls,3)
            self.assertEqual(stopped.passes.FrameScheduleFx.drawCalls,3)
            m.disable();self.assertEqual(m.getStatus().passes.CaptureFx.drawCalls,3)

    def test_lazy_child_cannot_authorize_itself_with_per_draw_callback(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0]);m.update()
            vm.execute('BeamRT_NativeShadowCaptureFxCallbacks.setShaderConsts()')
            self.assertEqual(vm.globals().objects.BeamRT_NativeShadowCaptureFx.consts['$nativeScheduledEpoch'],0)

    def test_false_native_field_does_not_require_false_lua_property(self):
        for value in ('0','false',False,0):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2)[0])
                root=vm.globals().objects.BeamRT_NativeShadowFrameScheduleFx
                root.skipDraw=None
                root.fields.skipDraw[0]=value
                # Mock getField normally collapses false with `or`; model the
                # native field reader returning its typed bool here instead.
                vm.execute('''local root=objects.BeamRT_NativeShadowFrameScheduleFx
                  local old=root.getField
                  root.getField=function(self,k,i)if k=='skipDraw'then return self.fields.skipDraw[i]end;return old(self,k,i)end''')
                m.update();self.assertTrue(m.getStatus().enabled,m.getStatus().reason)

    def test_scheduler_mismatch_names_exact_field_and_retains_actual_expected(self):
        for key,value in (('targetSize','2 1'),('targetFormat','GFXFormatR8G8B8A8'),('skipDraw','1'),('renderBin','OtherBin')):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2)[0])
                root=vm.globals().objects.BeamRT_NativeShadowFrameScheduleFx
                root.setField(root,key,0,value);m.update()
                status=m.getStatus();self.assertFalse(status.enabled)
                self.assertEqual(status.lastValidationFailure.field,key)
                self.assertIn('scheduler '+key+':',status.reason)

    def test_scheduler_readback_failure_refused_before_native_material_lease(self):
        for vm,m in self.runtimes():
            vm.execute('''local oldCreate=createObject
              createObject=function(class)local o=oldCreate(class);local oldSet=o.setField
                o.setField=function(self,k,i,v)
                  if self.name and self.name:find('ScheduleFx',1,true)and k=='renderBin'then return end
                  if k=='targetSize'and v=='1 1'then v='2 1'end
                  oldSet(self,k,i,v)
                end
                return o
              end''')
            self.assertFalse(m.enable(2)[0])
            self.assertIn('scheduler targetSize:',m.getStatus().reason)
            self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)

    def test_real_registered_lighting_manager_required_before_writes(self):
        for vm,m in self.runtimes():
            report=m.inspect(2);self.assertTrue(report.canStart)
            self.assertEqual(report.nativeBin.name,'AL_LightBinMgr')
            vm.execute("objects.AL_LightBin=objects.AL_LightBinMgr;objects.AL_LightBinMgr=nil")
            ok,why=m.enable(2);self.assertFalse(ok)
            self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)
            self.assertIn('no guessed render timing',why)

    def test_dispatch_and_selector_modes_are_explicit_not_shadow_results(self):
        for label,number in (('visibility',0),('dispatch',1),('selector',2)):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2,label)[0])
                shader=vm.globals().objects.BeamRT_NativeShadowNativeShader
                self.assertIn('BEAMRT_NATIVE_PROBE='+str(number),shader.fields.defines[0])
                self.assertEqual(vm.globals().objects.BeamRT_NativeShadowCaptureFx.consts['$nativeProbeMode'],number)
                self.assertEqual(m.getStatus().probeMode,number)
                self.assertFalse(m.getStatus().feedsGI);self.assertFalse(m.getStatus().gpuExecutionVerified)
                if number:self.assertIn('NOT shadows',m.getStatus().probeMeaning)
        for vm,m in self.runtimes():
            self.assertFalse(m.enable(2,'fake')[0])
            self.assertIsNone(vm.globals().objects.AL_SpotLightMaterial.reloads)

    def test_missing_early_callbacks_auto_restores_and_retains_counts(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0])
            for _ in range(40):m.update()
            status=m.getStatus();self.assertFalse(status.enabled)
            self.assertIn('No early CPU draw callbacks for AL_LightBinMgr',status.reason)
            self.assertTrue(status.passesAreLastStop)
            self.assertEqual(status.passes.FrameScheduleFx.drawCalls,0)
            self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')

    def test_manager_name_not_bin_type_drives_scheduled_callbacks(self):
        for vm,m in self.runtimes():
            self.assertTrue(m.enable(2)[0]);m.update()
            vm.execute('''function emitBin(name,when)
              for _,suffix in ipairs({'FrameScheduleFx','CaptureScheduleFx'})do
                local fx=objects['BeamRT_NativeShadow'..suffix]
                if fx:isEnabled()and fx:getField('renderBin',0)==name and fx:getField('renderTime',0)==when then
                  _G[fx.name..'Callbacks'].setShaderConsts()
                end
              end
            end
            emitBin('AL_LightBin','PFXBeforeBin');emitBin('AL_LightBin','PFXAfterBin')''')
            self.assertEqual(m.getStatus().passes.FrameScheduleFx.drawCalls,0)
            vm.execute("emitBin('AL_LightBinMgr','PFXBeforeBin');emitBin('AL_LightBinMgr','PFXAfterBin')")
            self.assertEqual(m.getStatus().passes.FrameScheduleFx.drawCalls,1)
            self.assertEqual(m.getStatus().passes.CaptureScheduleFx.drawCalls,1)

    def test_detached_child_or_changed_capture_binding_stops_and_restores(self):
        for change in ("objects.BeamRT_NativeShadowCaptureFx:setField('texture',1,'#prepass[RT1]')",
                       'objects.BeamRT_NativeShadowFrameScheduleFx.children={}',
                       'BeamRT_NativeShadowFrameFxCallbacks={}'):
            for vm,m in self.runtimes():
                self.assertTrue(m.enable(2)[0]);vm.execute(change);m.update()
                self.assertFalse(m.getStatus().enabled)
                self.assertEqual(vm.globals().objects.AL_SpotLightMaterial.fields.shader[0],'AL_SpotLightShader')


class GeneratedShader(unittest.TestCase):
    def test_dispatch_probe_bypasses_selector_and_tag_sampler_but_only_writes_alpha(self):
        generated=prepare.generate(NATIVE_FIXTURE,'Spot')
        dispatch=generated.split('#if BEAMRT_NATIVE_PROBE == 1',1)[1].split('#elif',1)[0]
        self.assertIn('outData.outB.a = -0.125;',dispatch)
        self.assertNotIn('beamrtNativeSelected',dispatch);self.assertNotIn('beamrtNativePacket',dispatch)
        self.assertLess(CAPTURE.index('nativeProbeMode==1||nativeProbeMode==2'),CAPTURE.index('nativeFrameTexTex.GetDimensions'))
        self.assertIn('packed==0',CAPTURE)
        self.assertIn('return relayFailure(18)',CAPTURE)
        self.assertIn('payload.z==positive',VIEW)
        self.assertIn('if(payload.z!=12)',VIEW) # visibility still requires its own status

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
