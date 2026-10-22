"""Real Lua acquisition/lifecycle tests, not game GPU output verification."""
from pathlib import Path
import math
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/lightVisibilityDiagnostic.lua').read_text()
PROVIDER=(ROOT/'lua/ge/extensions/beamrt/providers/lightProvider.lua').read_text()
SHADER=(ROOT/'shaders/beamrt/beamrtLightVisibilityP_v001.hlsl').read_text()
FIXTURE=r'''
package.path='lua/?.lua;'..package.path
objects={};enumerations=0;writes=0;deletes={}
scenetree={findObject=function(id)return objects[id]end,
 findClassObjects=function(class)enumerations=enumerations+1;return class=='PointLight'and{1}or{2}end}
core_camera={getPosition=function()return {0,0,0}end}
function lamp(id,class)
 local o={___type='class<'..class..'>',id=id,brightness=2,color='1 .8 .5 1',
  radius=20,range=30,innerAngle=20,outerAngle=60,enabled='1',castShadows='1',shadowType='Spot',
  position={1,2,3},axis={0,0,-1}}
 function o:getID()return self.id end
 function o:getName()return 'lamp'..id end
 function o:getPosition()return self.position end
 function o:getTransform()return {getColumn=function(_,i)assert(i==1);return self.axis end}end
 function o:getField(key)return self[key]==nil and ''or self[key]end
 function o:setField()writes=writes+1;error('Native light write forbidden')end
 objects[id]=o;return o
end
lamp(1,'PointLight');lamp(2,'SpotLight')
function createObject(class)
 local o={fields={},consts={},enabled=false}
 function o:setField(k,i,v)self.fields[k]=self.fields[k]or{};self.fields[k][i]=v end
 function o:getField(k,i)return self.fields[k]and self.fields[k][i]or''end
 function o:registerObject(name)self.name=name;objects[name]=self end
 function o:inheritParentFields()end
 function o:setShaderConst(k,v)self.consts[k]=v end
 function o:enable()self.enabled=true end
 function o:disable()if failDisable then failDisable=false;error('disable failed')end;self.enabled=false end
 function o:isEnabled()return self.enabled end
 function o:delete()deletes[#deletes+1]=self.name;objects[self.name]=nil end
 return o
end
objects.PFX_DefaultStateBlock={}
'''

class Diagnostic(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(FIXTURE)
            module=lua.execute(SOURCE);lua.globals().diagnostic=module
            yield lua,module

    def test_read_only_candidates_do_not_change_shared_provider_cache(self):
        for lua,m in self.runtimes():
            provider=lua.eval("require('ge/extensions/beamrt/providers/lightProvider')")
            self.assertFalse(provider.isValid())
            report=m.list();self.assertEqual(report.total,2)
            self.assertFalse(provider.isValid());self.assertEqual(lua.globals().writes,0)
            self.assertTrue(report.lights[1].enabledKnown)
            self.assertFalse(report.lights[1].nativeVisibility.available)
            self.assertEqual(report.lights[1].nativeVisibility.source,'unavailable')
            self.assertEqual(lua.globals().enumerations,2)
            m.getStatus();self.assertEqual(lua.globals().enumerations,2)

    def test_enabled_unknown_disabled_method_and_cones_are_not_guessed(self):
        for lua,m in self.runtimes():
            point=lua.globals().objects[1]
            point.enabled=None
            self.assertFalse(m.sample(point).enabledKnown)
            point.enabled='0';self.assertFalse(m.sample(point).enabled)
            point.enabled=None
            lua.execute('objects[1].isEnabled=function(self)return true end')
            self.assertTrue(m.sample(point).enabled)
            spot=m.sample(lua.globals().objects[2])
            self.assertAlmostEqual(spot.outer,math.cos(math.radians(30)))
            self.assertAlmostEqual(spot.inner,math.cos(math.radians(10)))
            self.assertEqual(spot.direction[3],-1)
            lua.execute('objects[2].axis={0,0,0}')
            result,why=m.sample(lua.globals().objects[2]);self.assertIsNone(result);self.assertIn('Zero',why)
            lua.execute('objects[2].axis={0,0,-1};objects[2].innerAngle=80')
            self.assertIsNone(m.sample(lua.globals().objects[2])[0])

    def test_invalid_parameters_no_native_mutation_or_automatic_selection(self):
        for lua,m in self.runtimes():
            self.assertFalse(m.enable(None,'visibility')[0])
            self.assertFalse(m.enable(1,'beauty')[0])
            self.assertFalse(m.getStatus().enabled)
            lua.execute('objects[1].brightness=nil')
            self.assertFalse(m.enable(1,'visibility')[0]);self.assertEqual(lua.globals().writes,0)

    def test_start_modes_live_fields_and_stop_leave_beauty_and_native_untouched(self):
        for lua,m in self.runtimes():
            self.assertTrue(m.enable(2,'visibility')[0]);m.update()
            fx=lua.globals().objects.BeamRT_LightVisibilityFx
            self.assertEqual(fx.fields.texture[0],'$backBuffer')
            self.assertEqual(fx.fields.texture[1],'#prepass[RT0]')
            self.assertEqual(fx.fields.texture[2],'#prepass[Depth]')
            self.assertEqual(fx.fields.renderBin[0],'AfterPostFX')
            self.assertEqual(fx.renderPriority,1);self.assertFalse(fx.allowReflectPass)
            self.assertEqual(fx.consts['$diagnosticMode'],3)
            lua.execute('objects[2].enabled="0";objects[2].brightness=8')
            m.update();self.assertEqual(fx.consts['$diagnosticEnabled'],0)
            self.assertEqual(fx.consts['$diagnosticColor'],'1 0.8 0.5 8')
            m.setMode('native');self.assertEqual(fx.consts['$diagnosticMode'],4)
            self.assertFalse(m.getStatus().appliesShadowAttenuation)
            self.assertFalse(m.getStatus().feedsGI)
            self.assertTrue(m.disable()[0]);self.assertIsNone(lua.globals().objects.BeamRT_LightVisibilityFx)
            self.assertEqual(lua.globals().writes,0)
            self.assertTrue(m.enable(1,'direction')[0]);m.update()
            self.assertTrue(m.getStatus().enabled)

    def test_stop_on_removed_replaced_light_and_changed_pass_no_queries_per_frame(self):
        for change in ('objects[1]=nil', "lamp(1,'PointLight')",
                       "objects.BeamRT_LightVisibilityFx:setField('texture',2,'bad')"):
            for lua,m in self.runtimes():
                self.assertTrue(m.enable(1,'visibility')[0])
                lua.execute(change);m.update()
                self.assertFalse(m.getStatus().enabled)
                self.assertEqual(lua.globals().enumerations,0)

    def test_failed_cleanup_can_retry_and_foreign_effect_not_deleted(self):
        for lua,m in self.runtimes():
            m.enable(1,'visibility');lua.globals().failDisable=True
            self.assertFalse(m.disable()[0]);self.assertTrue(m.getStatus().pendingCleanup)
            self.assertEqual(lua.globals().objects.BeamRT_LightVisibilityFx.consts['$diagnosticMode'],0)
            self.assertIsNotNone(lua.globals().objects.BeamRT_LightVisibilityShader)
            self.assertTrue(m.disable()[0]);m.enable(1,'visibility')
            lua.execute("foreign=createObject('PostEffect');foreign:registerObject('BeamRT_LightVisibilityFx')")
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertTrue(lua.eval('objects.BeamRT_LightVisibilityFx==foreign'))

    def test_shader_provenance_no_miss_means_clear_or_native_atlas_claim(self):
        self.assertIn('bool screenBlocker',SHADER)
        self.assertIn('i<32',SHADER)
        self.assertIn('12.0',SHADER)
        self.assertIn('float3(1,.55,.02)',SHADER)  # miss=amber unknown, not green clear
        self.assertNotIn('uniform_sampler2D(shadow',SHADER)
        self.assertNotIn('beauty.rgb*',SHADER)
        self.assertIn('diagnosticMode>3.5||diagnosticEnabled<0',SHADER)
        self.assertIn('(sampleUv-rtParams1.xy)/rtParams1.zw',SHADER)
        self.assertIn('any(abs(rtParams1-rtParams2)>1e-6)',SHADER)
        self.assertIn('sampleDepth-surface.w',SHADER)
        self.assertNotIn('tex2D(sceneTex',SHADER[SHADER.index('bool screenBlocker'):SHADER.index('float4 mainP')])

if __name__=='__main__':unittest.main()
