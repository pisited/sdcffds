"""Actual Lua lifecycle plus receiver-frame numerical references/source contracts.

The numerical reference checks analytic geometry, not game GPU execution.
"""
from pathlib import Path
import math
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/lightVisibilityDiagnostic.lua').read_text()
PROVIDER=(ROOT/'lua/ge/extensions/beamrt/providers/lightProvider.lua').read_text()
SHADER=(ROOT/'shaders/beamrt/beamrtLightVisibilityP_v003.hlsl').read_text()
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

    def test_status_recognizes_installed_cluster_name_without_backend_getters(self):
        for lua,m in self.runtimes():
            lua.execute("ClusterShading=setmetatable({},{__index=function()error('no backend getters')end})")
            self.assertTrue(m.getStatus().clusteredBackendExposed)
            self.assertFalse(m.getStatus().geometryVisibilityAvailable)
            self.assertFalse(m.getStatus().feedsGI)

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

    def test_geometric_bias_and_centre_reconstruction_are_wired_to_the_probe(self):
        self.assertIn('visibilityReceiverFrame(receiver,ray,du,dv,uv,size,normal,normalBias,planeTolerance)',SHADER)
        self.assertIn('receiver+normal*normalBias',SHADER)
        self.assertIn('sampleUv=(floor(sampleUv*size)+.5)/size',SHADER)
        self.assertIn('candidate=eyePosWorld+sampleRay*surface.w',SHADER)
        self.assertIn('visibilitySeparateReceiver(receiver,candidate,normal,planeTolerance)',SHADER)
        self.assertIn('dot(candidate-receiver,normal)>tolerance',SHADER)
        self.assertIn('normalBias=clamp(.004+.1*footprint,.005,.025)',SHADER)
        self.assertIn('planeTolerance=clamp(.002+.05*footprint,.003,.015)',SHADER)
        self.assertNotIn('normal*.035',SHADER)
        self.assertNotIn('screenBlocker(world,receiver.xyz',SHADER)
        for lua,m in self.runtimes():
            self.assertIn('geometric frame',m.getStatus().receiverBias)
            m.enable(1,'visibility')
            fx_shader=lua.globals().objects.BeamRT_LightVisibilityShader
            self.assertTrue(fx_shader.DXPixelShaderFile.endswith('_v003.hlsl'))

    def test_crossing_refinement_is_wired_without_the_old_isolated_hit_band(self):
        self.assertIn('previousValid&&visibilityCrossed(previousGap,gap)',SHADER)
        self.assertIn('refine<6',SHADER)
        self.assertIn('refinements>=2',SHADER)
        self.assertIn('abs(gap)<=.02&&visibilitySeparateReceiver',SHADER)
        self.assertIn('if(!valid){previousValid=false;continue;}',SHADER)
        self.assertNotIn('gap>.015&&gap<.12',SHADER)
        for lua,m in self.runtimes():
            self.assertIn('crossing refinements',m.getStatus().rayPolicy)


def subtract(a,b):return tuple(x-y for x,y in zip(a,b))
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def length(a):return math.sqrt(dot(a,a))
def cross(a,b):return(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def frame(receiver,ray,neighbours,expected):
    """Numerical reference for the shader's frame, bounds and plane test."""
    tangents=[]
    for previous,following in ((neighbours[0],neighbours[1]),(neighbours[2],neighbours[3])):
        candidates=[]
        if previous is not None:candidates.append(subtract(receiver,previous))
        if following is not None:candidates.append(subtract(following,receiver))
        if not candidates:return None
        tangents.append(min(candidates,key=length))
    tx,ty=tangents;lx,ly=dot(tx,tx),dot(ty,ty)
    if min(lx,ly)<1e-12 or max(lx,ly)>max(.25,expected*8)**2:return None
    normal=cross(tx,ty);area=dot(normal,normal)
    if area<lx*ly*1e-6:return None
    normal=tuple(x/math.sqrt(area)for x in normal)
    if dot(normal,tuple(-x for x in ray))<0:normal=tuple(-x for x in normal)
    footprint=math.sqrt(min(lx,ly))
    bias=min(.025,max(.005,.004+.1*footprint))
    tolerance=min(.015,max(.003,.002+.05*footprint))
    return normal,bias,tolerance


class ReceiverGeometryReference(unittest.TestCase):
    def test_flat_and_sloped_receivers_reject_their_own_plane(self):
        for ax,ay in ((0,0),(.7,0),(0,-.9),(.4,.6)):
            centre=(0,0,0)
            n,bias,tolerance=frame(centre,(0,0,-10),
                ((-.01,0,-ax*.01),(.01,0,ax*.01),(0,-.01,-ay*.01),(0,.01,ay*.01)),.01)
            for x,y in ((0,0),(.2,.3),(4,-2),(-3,1)):
                self.assertLessEqual(dot((x,y,ax*x+ay*y),n),tolerance)
            self.assertGreaterEqual(bias,.005);self.assertLessEqual(bias,.025)

    def test_separate_parallel_blockers_and_nearby_contacts_remain_eligible(self):
        for footprint in (.005,.02,.2):
            n,bias,tolerance=frame((0,0,0),(0,0,-10),
                ((-footprint,0,0),(footprint,0,0),(0,-footprint,0),(0,footprint,0)),footprint)
            self.assertLessEqual(tolerance,.015)
            # Same normal is NOT enough to reject a distinct parallel blocker.
            self.assertGreater(dot((.1,0,.02),n),tolerance)
            self.assertGreater(dot((.03,0,.04),n),tolerance)
            self.assertLessEqual(dot((.1,0,-.1),n),tolerance)

    def test_silhouette_prefers_near_depth_and_missing_geometry_is_unknown(self):
        n,_,_=frame((0,0,0),(0,0,-10),((-.01,0,0),(10,0,20),(0,-.01,0),(0,.01,0)),.01)
        self.assertAlmostEqual(n[2],1)
        self.assertIsNone(frame((0,0,0),(0,0,-10),(None,None,(0,-.01,0),(0,.01,0)),.01))
        self.assertIsNone(frame((0,0,0),(0,0,-10),((-10,0,20),(10,0,20),(0,-10,20),(0,10,20)),.01))
        self.assertIsNone(frame((0,0,0),(0,0,-10),((-.01,0,0),(.01,0,0),(-.02,0,0),(.02,0,0)),.01))

    def test_texel_centre_ray_avoids_inventing_a_sloped_surface_offset(self):
        # Plane z=10+.5*x, perspective ray=(u,0,1). Depth is sampled at
        # the texel centre .105, not at the continuous ray's requested .110.
        centre_u,requested_u=.105,.110
        sampled_depth=10/(1-.5*centre_u)
        wrong=(requested_u*sampled_depth,0,sampled_depth)
        correct=(centre_u*sampled_depth,0,sampled_depth)
        def plane_error(p):return p[2]-10-.5*p[0]
        self.assertGreater(abs(plane_error(wrong)),.015)
        self.assertAlmostEqual(plane_error(correct),0,places=12)


def crossing(a,b):return a<=0<=b or b<=0<=a
def refined_hit(sample):
    """Numerical reference: sample returns (signed gap, separate receiver) or None.

    Mirrors v003's 32 samples / two 6-step brackets, not GPU integration.
    """
    previous=None;refinements=0
    for i in range(32):
        travel=.06+(12-.06)*i/31
        value=sample(travel)
        if value is None:previous=None;continue
        if previous is not None and crossing(previous[1][0],value[0])and(previous[1][1]or value[1]):
            refinements+=1;low,lo=previous;high,hi=travel,value;valid=True
            for _ in range(6):
                mid=.5*(low+high);test=sample(mid)
                if test is None:valid=False;break
                if crossing(lo[0],test[0]):high,hi=mid,test
                else:low,lo=mid,test
            best=lo if abs(lo[0])<abs(hi[0])else hi
            if valid and abs(best[0])<=.02 and best[1]:return True
            if refinements>=2:return False
        previous=travel,value
    return False


class CrossingReference(unittest.TestCase):
    def test_old_hit_band_stripes_across_phase_new_refinement_finds_the_plane(self):
        old_hits=0
        for phase in range(100):
            hit_distance=2+(phase+.5)/100*(12-.06)/31
            old_hits+=any(.015<t-hit_distance<.12 for t in(.06+(12-.06)*(i+.5)/32 for i in range(32)))
            self.assertTrue(refined_hit(lambda t:(t-hit_distance,True)))
        self.assertGreater(old_hits,0);self.assertLess(old_hits,60)

    def test_either_crossing_direction_can_find_a_separate_opaque_surface(self):
        for slope in (-1,1):
            for distance in (.12,1,4,8,11.8):
                self.assertTrue(refined_hit(lambda t:(slope*(t-distance),True)))

    def test_depth_step_does_not_become_a_surface_without_convergence(self):
        self.assertFalse(refined_hit(lambda t:(-1 if t<2 else 1,True)))

    def test_sky_resets_bracket_and_receiver_plane_is_not_an_occluder(self):
        self.assertFalse(refined_hit(lambda t:None if 1<t<3 else(-1 if t<=1 else 1,True)))
        self.assertFalse(refined_hit(lambda t:(t-2,False)))
        self.assertFalse(refined_hit(lambda t:(0,False)))

    def test_no_hit_does_not_prove_clear_and_work_is_bounded(self):
        calls=[]
        def sample(t):
            calls.append(t)
            # Two discontinuous sign flips, neither converges to visible depth.
            return (-1 if t<1 or t>2 else 1,True)
        self.assertFalse(refined_hit(sample));self.assertLessEqual(len(calls),44)
        self.assertFalse(refined_hit(lambda t:(-1,True)))

if __name__=='__main__':unittest.main()
