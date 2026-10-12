"""Real Lua buffer graph/setters with mocked engine objects; not GPU/game proof."""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[2]
MOCK=r'''
package.path='lua/?.lua;'..package.path
objects={};prepareCalls=0
scenetree={findObject=function(name)return objects[name]end}
function createObject(class)
  local o={class=class,fields={},consts={},isEnabled=false}
  function o:setField(key,index,value)
    if key=='texture' or key=='samplerNames' then assert(type(index)=='number' and index>=0 and index<=5)end
    self.fields[key]=self.fields[key]or{};self.fields[key][index]=value
  end
  function o:setShaderConst(key,value)self.consts[key]=value end
  function o:getField(key,index)return self.fields[key]and self.fields[key][index]or''end
  function o:registerObject(name)self.name=name;objects[name]=self end
  function o:enable()self.isEnabled=true end
  function o:disable()self.isEnabled=false end
  function o:delete()objects[self.name]=nil end
  return o
end
trace=createObject('PostEffect');trace.renderPriority=10002;trace:registerObject('GI')
trace:setField('shader',0,'BeamRT_GIVisibilityConsumerShader')
scene={objectId=42,gpuData={texture='/art/beamrt/alignment/real.data.png'},policy={key='1 0',opaque=1}}
args={trace=trace,scene=scene,width=160,height=90,bias=.03,viewAvailable=true,
  surfels={{position={x=1.23456789,y=2,z=3},radius=1}},
  applySceneConsts=function(effect,data,enabled)effect:setShaderConst('$meshVisibilityEnabled',enabled and 1 or 0)end,
  prepareFrame=function()prepareCalls=prepareCalls+1 end}
'''


class Buffer(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True);self.lua.execute(MOCK)
        self.module=self.lua.eval("require('ge/extensions/beamrt/giVisibilityBuffer')")
        self.lua.globals().buffer=self.module

    def configure(self):
        result=self.module.configure(self.lua.globals().args)
        self.assertTrue(result is True or result[0])

    def object(self,name):return self.lua.globals().objects[name]
    def render_receiver(self):self.lua.globals().BeamRT_GIVisibilityReceiverFxCallbacks.preProcess()

    def test_unused_module_does_not_create_or_load_native_code(self):
        self.assertFalse(self.module.getStatus().active)
        self.assertIsNone(self.object('BeamRT_GIVisibilityReceiverFx'))
        self.assertFalse(self.module.getStatus().nativeWorkerAttached)

    def test_unowned_namespace_is_not_disabled_deleted_or_callbacks_cleared(self):
        self.lua.execute("for _,name in ipairs({'ReceiverFx','ProducerFx'})do local o=createObject('PostEffect');o:registerObject('BeamRT_GIVisibility'..name);o:enable()end;BeamRT_GIVisibilityReceiverFxCallbacks={external=true}")
        self.assertFalse(self.module.configure(self.lua.globals().args)[0]);self.module.release()
        self.assertTrue(self.object('BeamRT_GIVisibilityReceiverFx').isEnabled)
        self.assertTrue(self.lua.globals().BeamRT_GIVisibilityReceiverFxCallbacks.external)

    def test_order_dimensions_formats_sampler_capacity_and_no_final_color_target(self):
        self.configure();receiver=self.object('BeamRT_GIVisibilityReceiverFx');producer=self.object('BeamRT_GIVisibilityProducerFx')
        self.assertGreater(receiver.renderPriority,producer.renderPriority);self.assertGreater(producer.renderPriority,10002)
        self.assertEqual(receiver.fields.targetSize[0],'160 90');self.assertEqual(producer.fields.targetSize[0],'160 91')
        for fx in (receiver,producer):
            self.assertEqual(fx.fields.targetFormat[0],'GFXFormatR32G32B32A32F')
            self.assertNotEqual(fx.fields.target[0],'$backBuffer');self.assertFalse(fx.allowReflectPass)
        shader=self.object('BeamRT_GIVisibilityConsumerShader')
        self.assertEqual(shader.fields.samplerNames[5],'nativeGIVisibilityTex')
        self.assertEqual(self.object('GI').consts['$nativeGIVisibilityEnabled'],0)

    def test_matched_frame_prepares_once_and_repeat_or_missing_producer_is_invalid(self):
        self.configure();self.render_receiver();self.assertEqual(self.lua.globals().prepareCalls,1)
        self.assertTrue(self.module.consumePreparedFrame());self.assertFalse(self.module.consumePreparedFrame())
        self.assertEqual(self.object('GI').consts['$nativeGIVisibilityEnabled'],0)
        self.render_receiver();self.assertTrue(self.module.consumePreparedFrame());self.assertEqual(self.lua.globals().prepareCalls,2)

    def test_geometry_surfel_bias_resize_changes_invalidate_old_output(self):
        for change in ("scene.policy.key='0 0'","args.surfels[1].position.x=9","args.bias=.04","args.width=128"):
            self.configure();self.render_receiver();before=self.object('GI').consts['$nativeGIVisibilityKey']
            self.lua.execute(change);self.configure()
            self.assertNotEqual(self.object('GI').consts['$nativeGIVisibilityKey'],before)
            self.assertEqual(self.object('GI').consts['$nativeGIVisibilityEnabled'],0)

    def test_invalid_dimensions_budget_camera_bias_samples_disable_without_new_graph(self):
        for change in ("args.width=0","args.width=512;args.height=512;for i=2,32 do args.surfels[i]=args.surfels[1]end",
                       "args.viewAvailable=false","args.bias=0/0","args.surfels[1].position.x=nil","args.surfels={}"):
            self.setUp();self.lua.execute(change)
            self.assertFalse(self.module.configure(self.lua.globals().args)[0])
            self.assertFalse(self.module.getStatus().active);self.assertIsNone(self.object('BeamRT_GIVisibilityReceiverFx'))

    def test_exact_origin_precision_and_disable_release(self):
        self.configure();producer=self.object('BeamRT_GIVisibilityProducerFx')
        self.assertEqual(producer.consts['$surfelPositionRadius0'],'1.23456789 2 3 1')
        self.render_receiver();self.module.disable()
        self.assertFalse(producer.isEnabled);self.assertEqual(self.object('GI').consts['$nativeGIVisibilityEnabled'],0)
        self.module.release();self.assertIsNone(self.object('BeamRT_GIVisibilityConsumerShader'))
        self.assertIsNone(self.lua.globals().BeamRT_GIVisibilityReceiverFxCallbacks)

    def test_frame_prepare_failure_stops_producers(self):
        self.configure();self.lua.execute("args.prepareFrame=function()error('failed camera')end")
        self.configure()
        self.render_receiver();self.assertFalse(self.module.getStatus().active)
        self.assertIn('failed camera',self.module.getStatus().reason)

    def test_prepare_reconfigure_same_inputs_does_not_double_advance_or_disable(self):
        self.lua.execute('args.prepareFrame=function()prepareCalls=prepareCalls+1;assert(buffer.configure(args))end')
        self.configure();self.render_receiver();self.assertTrue(self.module.consumePreparedFrame())
        self.assertEqual(self.object('GI').consts['$nativeGIVisibilityEnabled'],1)


class MainBindings(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True);self.lua.execute(MOCK)
        text=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text(encoding='utf-8')
        self.lua.execute(r'''
          M={sharedMeshGI={enabled=true,effective=false,source='underground',backend='buffer',key='',shaderName='Inline'}}
          extensions=setmetatable({},{__index=function()error('must not auto-load old guardhouse/local lights')end})
          PROGRESSIVE={rayDebugMode=0,lightingDiagnostic={mode=0},inputPrep={imageWidth=160,imageHeight=90,applyConsts=function()end}}
          giSourceMode=0;worldGIStrength=.35;rayNormalBias=.03;surfels=args.surfels
          GI_EFFECT_NAME='GI';GI_TRACE_SHADER_NAME='Baseline';resets=0
          function effectIsEnabled()return true end
          function getRenderView()return{}end
          function resetTemporalHistory()resets=resets+1 end
          M._prepareGIFrame=args.prepareFrame
          package.loaded['ge/extensions/beamrt/meshLocalScene']={
            getBinding=function()if stale then return nil,'removed underground geometry'end;return scene end,
            applySceneConsts=args.applySceneConsts,prepare=function()return scene end}
          package.loaded['ge/extensions/beamrt/meshSceneInputs']={enable=function()return true end,disable=function()end}
        ''')
        source=re.search(r'function M._applySharedMeshGI\(effect\).*?(?=\nfunction M.setMeshSunShadowsEnabled)',text,re.S).group()
        self.lua.execute(source)
        self.lua.execute('function applyGIShaderConsts()M._applySharedMeshGI(trace)end')

    def test_real_main_selects_buffer_and_restores_original_bindings_on_off(self):
        main=self.lua.globals().M;fx=self.lua.globals().trace
        self.assertTrue(main._applySharedMeshGI(fx));self.assertEqual(fx.fields.shader[0],'BeamRT_GIVisibilityConsumerShader')
        self.assertEqual(fx.fields.texture[5],'#BeamRT_GIVisibilityBuffer')
        main.setSharedMeshVisibilityEnabled(False)
        self.assertEqual(fx.fields.shader[0],'Baseline');self.assertEqual(fx.fields.texture[3],'#lightinfo[RT0]')
        self.assertEqual(fx.fields.texture[5],'#prepass[RT1]')
        self.assertFalse(self.lua.eval("require('ge/extensions/beamrt/giVisibilityBuffer').getStatus().active"))

    def test_budget_falls_back_to_inline_without_losing_opaque_geometry(self):
        self.lua.execute('PROGRESSIVE.inputPrep.imageWidth=2048;PROGRESSIVE.inputPrep.imageHeight=1024')
        self.assertTrue(self.lua.globals().M._applySharedMeshGI(self.lua.globals().trace))
        self.assertEqual(self.lua.globals().trace.fields.shader[0],'Inline')
        self.assertIn('inline fallback',self.lua.globals().M.sharedMeshGI.reason)

    def test_stale_scene_disables_target_and_native_hook_is_not_loaded(self):
        main=self.lua.globals().M;fx=self.lua.globals().trace;main._applySharedMeshGI(fx)
        self.lua.globals().stale=True;self.assertFalse(main._applySharedMeshGI(fx))
        self.assertEqual(fx.fields.shader[0],'Baseline');self.assertFalse(main.getSharedMeshVisibilityStatus().nativeWorkerAttached)


if __name__=='__main__':unittest.main()
