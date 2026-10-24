"""Actual Lua geometry packing/lifecycle and private shader generation. No game GPU proof."""
from pathlib import Path
import math
import re
import sys
import tempfile
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT
import test_mesh_sun_control as control
import test_native_sun_hook as native

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import beamrt_glass_sun_prepare as hook

GEOMETRY=(ROOT/'lua/ge/extensions/beamrt/glassGeometry.lua').read_text()
CONTROLLER=(ROOT/'lua/ge/extensions/beamrt/glassSunShadow.lua').read_text()
MAIN=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text()
SHADER=(ROOT/'shaders/beamrt/beamrtGlassSunP_v001.hlsl').read_text()
HELPER=(ROOT/'shaders/beamrt/beamrtGlassSunHook.h.hlsl').read_text()
GEOMETRY_FIXTURE=r'''
objects={};paused=true;released=0;invalidated=0
simTimeAuthority={getPause=function()return paused end}
FS={fileExists=function()return true end}
scenetree={findObject=function(name)return objects[name]end}
function glass(name)
 local m={___type='class<Material>',fields={mapTo=name,version='1.5',translucent='1',alphaTest='0',castShadows='0',
   activeLayers='1',opacityMap='vehicles/test/opacity.data.png',opacityFactor='0.6'}}
 function m:getFilename()return '/vehicles/test/main.materials.json'end
 function m:getField(k,i)return self.fields[k]or''end
 objects[name]=m;return m
end
glass('car_glass');glass('car_glass_tint');glass('car_glass_int')
vehicle={position={100,0,0}}
function vehicle:getID()return 41 end
function vehicle:getPosition()return self.position end
function vehicle:getSpawnWorldOOBB()
 return {getCenter=function()return {100,0,0}end,getHalfExtents=function()return {4,3,3}end,
 getAxis=function(_,i)local v={0,0,0};v[i+1]=1;return v end}
end
be={getPlayerVehicle=function()return vehicle end}
record={counts={vertices=3,indices=3,uv1=3},buffers={vertices={[0]=-1,0,1,1,0,1,0,2,1},
  uv1={[0]=0,0,1,0,.5,1},indices={[0]=0,1,2}},
  flexmeshes={{primitives={{materialName='car_glass_tint',firstIndex=0,indexCount=3}}}},propmeshes={},acquisitionWarnings={},
  mesh={free=function()released=released+1 end}}
package.loaded['ge/extensions/beamrt/providers/vehicleProvider']={
 capture=function(id,mesh,profile)assert(id==41 and profile=='glass');return record end,
 invalidate=function(id)invalidated=invalidated+1 end}
'''

CONTROLLER_FIXTURE=r'''
paused=true;freed=0;bitmapValues={};captures=0;valid=true;failGeometry=false
simTimeAuthority={getPause=function()return paused end}
FS={directoryCreate=function()return true end,directoryExists=function()return true end}
function GBitmap()
 return {allocateBitmap=function(self,w,h,_,format)assert(format=='GFXFormatR16');self.w=w;self.h=h end,
 setTexel=function(self,x,y,r,g,b,a)assert(r>=0 and r<=65535);bitmapValues[#bitmapValues+1]=r end,
 saveFile=function(self,path)cachePath=path;return true end}
end
vehicle={getID=function()return 41 end}
be={getPlayerVehicle=function()return vehicle end}
mesh={dataIsReady=false,free=function()freed=freed+1 end}
GPUMesh={bng_getGPUMesh=function(id)assert(id==41);captures=captures+1;return mesh end}
snapshot={materials={{name='car_glass_tint',path='/vehicles/car/opacity.data.png',factor=.7}},
  triangles={{}},nodes={{}},pose={},lo={99,-1,1},extent={2,2,.1},uvLo={0,0},uvExtent={1,1},coordinateMode='vehicle-origin-relative'}
package.loaded['ge/extensions/beamrt/glassGeometry']={width=256,pose=function()return {}end,
 checkTarget=function()if walking then return false,'Enter the car first'end;return true end,
 samePose=function()return valid end,valid=function()return paused and valid end,
 capture=function(v,m)assert(v==vehicle and m==mesh);if failGeometry then return nil,'bad geometry'end;return snapshot end,
 texels=function(d,tag)return {45678,1,tag,1,1,0,0,0}end}
manifest={schema='beamrt.glass.sun.v1',nativePath='shaders/common/lighting/advanced/vectorLightP.hlsl',
 nativeSource='native',shaderPath='shaders/beamrt/generated/beamrtGlassVector_123abc.hlsl',generatedSource='generated',
 dependencies={['shaders/beamrt/beamrtGlassSunHook.h.hlsl']='helper'}}
files={['/'..manifest.nativePath]='native',['/'..manifest.shaderPath]='generated',
 ['/shaders/beamrt/beamrtGlassSunHook.h.hlsl']='helper'}
function jsonReadFile()return manifest end
function readFile(p)return files[p]end
'''


class Geometry(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(GEOMETRY_FIXTURE)
            m=lua.execute(GEOMETRY);lua.globals().geometry=m
            yield lua,m

    def test_exterior_tinted_geometry_actual_uv_and_relative_frame(self):
        for lua,m in self.runtimes():
            d=m.capture(lua.globals().vehicle)
            self.assertEqual(len(d.triangles),1)
            self.assertEqual(d.triangles[1][1].p[1],99)
            self.assertEqual(d.triangles[1][3].uv[1],.5)
            self.assertEqual(d.coordinateMode,'vehicle-origin-relative')
            self.assertEqual(d.materials[1].name,'car_glass_tint')
            self.assertEqual(d.materials[1].factor,.6)
            self.assertEqual(lua.globals().released,1)
            self.assertEqual(lua.globals().invalidated,1)
            self.assertTrue(m.valid(d));lua.globals().paused=False;self.assertFalse(m.valid(d))

    def test_walking_character_is_not_silently_captured_as_the_car(self):
        for lua,m in self.runtimes():
            lua.execute("function vehicle:getJBeamFilename()return 'unicycle'end")
            ok,why=m.checkTarget(lua.globals().vehicle)
            self.assertFalse(ok);self.assertIn('walking character',why)
            result,why=m.capture(lua.globals().vehicle)
            self.assertIsNone(result);self.assertIn('Enter the car',why)
            self.assertEqual(lua.globals().released,0)
            lua.execute("function vehicle:getJBeamFilename()return 'fullsize'end")
            self.assertTrue(m.checkTarget(lua.globals().vehicle))

    def test_inspection_names_and_reasons_are_read_only_no_gpu_readback(self):
        for lua,m in self.runtimes():
            lua.execute('''
            function vehicle:getMeshMaterialNames()return {'car_glass','car_glass_tint','car_glass_int','car_glass'}end
            objects.car_glass.fields.castShadows='true'
            objects.car_glass_tint.fields.opacityMap=''
            ''')
            report=m.inspect(lua.globals().vehicle)
            self.assertEqual(report.accepted,0);self.assertEqual(report.rejected,3)
            rows={r.name:r for r in report.materials.values()}
            self.assertIn('castShadows=true',rows['car_glass'].reason)
            self.assertIn('opacityMap is empty',rows['car_glass_tint'].reason)
            self.assertIn('interior',rows['car_glass_int'].reason)
            self.assertEqual(rows['car_glass'].fields.castShadows,'true')
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'true')
            self.assertEqual(lua.globals().released,0);self.assertEqual(lua.globals().invalidated,0)

    def test_capture_failure_explains_exact_guard_instead_of_generic_no_triangles(self):
        for lua,m in self.runtimes():
            lua.execute("objects.car_glass_tint.fields.activeLayers='4'")
            result=m.capture(lua.globals().vehicle)
            self.assertIsNone(result[0]);self.assertIn('car_glass_tint: unsupported activeLayers=4',result[1])
            self.assertEqual(lua.globals().released,1)

    def test_inspection_handles_no_vehicle_and_missing_name_api_without_writes(self):
        for lua,m in self.runtimes():
            self.assertEqual(m.inspect(None).reason,'No player vehicle.')
            self.assertIn('names unavailable',m.inspect(lua.globals().vehicle).reason)
            self.assertEqual(lua.globals().released,0)

    def test_world_frame_accepted_only_inside_live_native_bounds(self):
        for lua,m in self.runtimes():
            lua.execute('for i=0,8,3 do record.buffers.vertices[i]=record.buffers.vertices[i]+100 end')
            d=m.capture(lua.globals().vehicle);self.assertEqual(d.coordinateMode,'world')
            self.assertEqual(d.triangles[1][1].p[1],99)
            lua.execute('for i=0,8,3 do record.buffers.vertices[i]=record.buffers.vertices[i]+500 end')
            self.assertIsNone(m.capture(lua.globals().vehicle)[0])

    def test_unsafe_materials_and_partial_meshes_fail_closed(self):
        for mutation in ("record.acquisitionWarnings={'missing UV'}", "record.counts.uv1=2",
                         "record.buffers.indices[1]=42", "objects.car_glass_tint.fields.opacityMapUseUV='1'",
                         "objects.car_glass_tint.fields.castShadows='1'", "objects.car_glass_tint.fields.alphaTest='1'",
                         "objects.car_glass_tint.fields.instanceOpacity='1'", "record.flexmeshes[1].primitives[1].materialName='car_glass_int'",
                         "record.flexmeshes[1].primitives[1].indexCount=4", "record.buffers.uv1[0]=0/0"):
            for lua,m in self.runtimes():
                lua.execute(mutation);result=m.capture(lua.globals().vehicle)
                self.assertIsNone(result[0],mutation);self.assertEqual(lua.globals().released,1)

    def test_native_handle_borrow_is_not_freed_by_geometry(self):
        for lua,m in self.runtimes():
            m.capture(lua.globals().vehicle,lua.table());self.assertEqual(lua.globals().released,0)

    def test_snapshot_material_edit_and_pose_change_invalidates(self):
        for lua,m in self.runtimes():
            d=m.capture(lua.globals().vehicle)
            lua.execute("objects.car_glass_tint.fields.opacityFactor='.1'")
            self.assertFalse(m.valid(d))
            lua.execute("objects.car_glass_tint.fields.opacityFactor='0.6';vehicle.position[1]=101")
            self.assertFalse(m.valid(d))

    def test_quantized_bvh_full_coverage_no_truncation(self):
        for lua,m in self.runtimes():
            lua.execute('''
            record.flexmeshes[1].primitives[1].indexCount=90;record.counts.indices=90
            for i=0,89 do record.buffers.indices[i]=i%3 end
            ''')
            d=m.capture(lua.globals().vehicle);self.assertEqual(len(d.triangles),30)
            packed=m.texels(d,42);values=list(packed.values())
            self.assertEqual(values[:5],[45678,30,42,1,len(d.nodes)])
            self.assertEqual(len(values),8+len(d.nodes)*8+30*16)
            self.assertTrue(all(isinstance(x,(int,float))and 0<=x<=65535 for x in values))
            leaves=[n for n in d.nodes.values()if n['count']is not None]
            self.assertEqual(sum(n['count']for n in leaves),30)
            self.assertEqual(sorted(i for n in leaves for i in range(n.first,n.first+n['count'])),list(range(30)))
            for n in leaves:
                self.assertLessEqual(n['count'],8)
            for i in range(30):
                start=8+len(d.nodes)*8+i*16
                decoded=[d.lo[j+1]+values[start+j]/65535*d.extent[j+1]for j in range(3)]
                self.assertAlmostEqual(decoded[0],99,places=4)
                self.assertEqual(values[start+15],0)


class Controller(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(control.MOCK);lua.execute(CONTROLLER_FIXTURE)
            m=lua.execute(CONTROLLER);lua.globals().glass=m
            yield lua,m

    def activate(self,lua,m):
        self.assertTrue(m.enable()[0]);lua.globals().mesh.dataIsReady=True;m.update(.1)
        self.assertTrue(m.getStatus().enabled,m.getStatus().reason)

    def test_walking_character_rejected_before_gpu_readback(self):
        for lua,m in self.runtimes():
            lua.globals().walking=True
            self.assertFalse(m.enable()[0]);self.assertEqual(lua.globals().captures,0)

    def test_async_capture_waits_does_not_reacquire_then_native_sun_binding(self):
        for lua,m in self.runtimes():
            self.assertFalse(m.getStatus().enabled);self.assertTrue(m.enable()[0]);m.update(.1)
            self.assertTrue(m.getStatus().pending);self.assertEqual(lua.globals().captures,1)
            self.assertEqual(lua.globals().objects.AL_VectorLightMaterial.fields.shader[0],'AL_VectorLightShader')
            lua.globals().mesh.dataIsReady=True;m.update(.1)
            self.assertTrue(m.getStatus().enabled,m.getStatus().reason)
            fx=lua.globals().objects.BeamRT_GlassSunTraceFx
            self.assertEqual(fx.fields.renderTime[0],'PFXBeforeBin')
            self.assertEqual(fx.fields.renderBin[0],'AL_LightBin')
            self.assertEqual(fx.fields.targetFormat[0],'GFXFormatR32G32B32A32F')
            self.assertEqual(fx.fields.targetScale[0],'1 1')
            self.assertEqual(sorted(fx.fields.texture.keys()),list(range(6)))
            self.assertFalse(fx.allowReflectPass);self.assertEqual(lua.globals().freed,1)
            self.assertFalse(m.getStatus().gpuExecutionVerified)
            self.assertEqual(lua.globals().objects.AL_VectorLightMaterial.fields.shader[0],'BeamRT_GlassSunNativeShader')

    def test_pause_resume_timeout_cancel_and_material_failure_release_readback(self):
        for lua,m in self.runtimes():
            lua.globals().paused=False;self.assertFalse(m.enable()[0]);self.assertEqual(lua.globals().captures,0)
            lua.globals().paused=True;m.enable();m.update(5.1)
            self.assertFalse(m.getStatus().requested);self.assertEqual(lua.globals().freed,1)
            m.enable();m.disable();self.assertEqual(lua.globals().freed,2)
            m.enable();lua.globals().mesh.dataIsReady=True;lua.globals().failGeometry=True;m.update(.1)
            self.assertFalse(m.getStatus().enabled);self.assertEqual(lua.globals().freed,3)

    def test_restore_and_restart_and_no_final_color_or_window_mutations(self):
        for lua,m in self.runtimes():
            for _ in range(2):
                self.activate(lua,m);self.assertTrue(m.setStrength(0))
                self.assertEqual(lua.globals().objects.BeamRT_GlassSunTraceFx.consts['$glassStrength'],0)
                self.assertTrue(m.disable()[0])
                mat=lua.globals().objects.AL_VectorLightMaterial
                self.assertEqual(mat.fields.shader[0],'AL_VectorLightShader')
                self.assertEqual(mat.fields.sampler.beamrtGlassSunVisibility,'')
                self.assertIsNone(lua.globals().objects.BeamRT_GlassSunTraceFx)
            self.assertNotIn('$backBuffer',CONTROLLER)
            self.assertNotIn("setField('castShadows'",CONTROLLER)

    def test_resume_pose_change_and_foreign_shader_stop_without_clobber(self):
        for mutation in ('paused=false','valid=false',"objects.AL_VectorLightMaterial:setField('shader',0,'ForeignShader')"):
            for lua,m in self.runtimes():
                self.activate(lua,m);lua.execute(mutation);m.update(.1)
                self.assertFalse(m.getStatus().requested)
                expected='ForeignShader'if'ForeignShader'in mutation else'AL_VectorLightShader'
                self.assertEqual(lua.globals().objects.AL_VectorLightMaterial.fields.shader[0],expected)

    def test_failed_reload_retains_lease_and_retry_then_restart(self):
        for lua,m in self.runtimes():
            self.activate(lua,m);lua.execute('objects.AL_VectorLightMaterial.failReload=true')
            self.assertFalse(m.disable()[0]);self.assertTrue(m.getStatus().pendingRestore)
            self.assertEqual(lua.globals().objects.BeamRT_GlassSunTraceFx.consts['$glassStrength'],0)
            self.assertFalse(m.enable()[0]);self.assertTrue(m.disable()[0]);self.activate(lua,m)

    def test_rejected_native_restore_keeps_neutral_producer_and_retry(self):
        for lua,m in self.runtimes():
            self.activate(lua,m)
            lua.execute('''
            local mat=objects.AL_VectorLightMaterial;oldSetter=mat.setField
            mat.setField=function(self,key,index,value)
              if key=='shader'and value=='AL_VectorLightShader'then return end
              return oldSetter(self,key,index,value)
            end
            ''')
            self.assertFalse(m.disable()[0]);self.assertTrue(m.getStatus().pendingRestore)
            fx=lua.globals().objects.BeamRT_GlassSunTraceFx
            self.assertTrue(fx.enabled);self.assertEqual(fx.consts['$glassStrength'],0)
            self.assertEqual(lua.globals().objects.AL_VectorLightMaterial.fields.sampler.beamrtGlassSunVisibility,'')
            lua.execute('objects.AL_VectorLightMaterial.setField=oldSetter')
            self.assertTrue(m.disable()[0])

    def test_foreign_hook_stale_source_and_snapshot_change_before_install(self):
        for mutation in ("objects.AL_VectorLightMaterial:setField('shader',0,'ForeignShader')",
                         "files['/'..manifest.nativePath]='changed'"):
            for lua,m in self.runtimes():
                lua.execute(mutation);self.assertFalse(m.enable()[0]);self.assertEqual(lua.globals().captures,0)
        for lua,m in self.runtimes():
            m.enable();lua.execute("objects.AL_VectorLightMaterial:setField('shader',0,'ForeignShader');mesh.dataIsReady=true")
            m.update(.1);self.assertFalse(m.getStatus().enabled)
            self.assertEqual(lua.globals().objects.AL_VectorLightMaterial.fields.shader[0],'ForeignShader')

    def test_replaced_producer_and_callback_are_not_deleted_or_overwritten(self):
        for lua,m in self.runtimes():
            self.activate(lua,m)
            lua.execute('''
            replacement=createObject('PostEffect');replacement:registerObject('BeamRT_GlassSunTraceFx')
            foreignCallbacks={};BeamRT_GlassSunTraceFxCallbacks=foreignCallbacks
            ''')
            m.update(.1);self.assertFalse(m.getStatus().requested)
            self.assertTrue(lua.eval('objects.BeamRT_GlassSunTraceFx==replacement'))
            self.assertTrue(lua.eval('BeamRT_GlassSunTraceFxCallbacks==foreignCallbacks'))
            self.assertEqual(lua.globals().objects.AL_VectorLightMaterial.fields.shader[0],'AL_VectorLightShader')


class PrivateHook(unittest.TestCase):
    def test_native_visibility_multiplied_not_replaced_before_direct_light(self):
        new=hook.generate(native.SOURCE)
        self.assertLess(new.index('unshadowed *= cloudCookie'),new.index('unshadowed *= beamrtGlassSunTransmission'))
        self.assertLess(new.index('unshadowed *= beamrtGlassSunTransmission'),new.index('float Sat_NL_Att'))
        for line in native.SOURCE.splitlines()[4:]:self.assertIn(line,new)
        for bad in (native.SOURCE*2,native.SOURCE+'\nTexture2D x:register(t14);',native.SOURCE.replace('sunShadowMaskTex','other')):
            with self.assertRaises(ValueError):hook.generate(bad)

    def test_prepare_is_private_content_addressed_and_slot_conflict_safe(self):
        with tempfile.TemporaryDirectory()as root:
            game=Path(root)/'game';mod=Path(root)/'mod';mod.mkdir()
            n=game/hook.NATIVE;n.parent.mkdir(parents=True);n.write_text(native.SOURCE)
            for f in ('farFrustumQuad.h.hlsl','farFrustumQuad.hlsl'):(n.parent/f).write_text('// header')
            h=mod/hook.HELPER;h.parent.mkdir(parents=True);h.write_text(HELPER)
            first=hook.prepare(game,mod);self.assertEqual(first,hook.prepare(game,mod))
            self.assertEqual(n.read_text(),native.SOURCE)
            self.assertFalse(first['gpuExecutionVerified'])
            self.assertEqual((mod/first['shaderPath']).read_text(),hook.generate(native.SOURCE))
            (n.parent/'farFrustumQuad.h.hlsl').write_text('uniform_sampler2D(occupied,14);')
            with self.assertRaises(ValueError):hook.prepare(game,mod)

    def test_extinction_seams_panes_and_native_body_shadow_math(self):
        def transmission(hits):
            unique=[]
            for distance,opacity in hits:
                for i,(old,alpha)in enumerate(unique):
                    if abs(old-distance)<.01:
                        unique[i]=(old,max(alpha,opacity));break
                else:unique.append((distance,opacity))
            if len(unique)>8:return 1
            return math.prod(1-alpha for _,alpha in unique)
        self.assertAlmostEqual(transmission([(1,.2),(1.001,.2),(2,.2)]),.64)
        self.assertAlmostEqual(transmission([(1,.8),(2,.8)]),.04)
        for native_visibility in (0,.2,1):
            self.assertLessEqual(native_visibility*transmission([(1,.8)]),native_visibility)
        self.assertEqual(transmission([(i,.4)for i in range(9)]),1)
        self.assertIn('value.w-1',HELPER);self.assertIn('worldPosition)>.01',HELPER)
        self.assertIn('if(hits>=8)return 1',SHADER)
        self.assertIn('glassOpacityFactor[m]',SHADER)
        self.assertIn('opacity*glassOpacityFactor[m]',SHADER)

    def test_preset_command_is_public_guarded_and_eight_rays_with_haze_off(self):
        body=re.search(r'^function M.startGlassTest\(\).*?\nend',MAIN,re.M|re.S).group()
        for value in ("simTimeAuthority.getPause()", "M.disable()", "M.setPtgiNamedHandoffEnabled(false)",
                      "{'stochasticRayCount',8}","{'nativeMaterialResponse',true}",
                      'M.setPtgiCoherentEnabled(true)','M.setAutomaticLampShadowsEnabled(true)',
                      'M.setGlassSunShadowsEnabled(true)'):
            self.assertIn(value,body)
        self.assertNotIn('setLocalVolumesEnabled(true)',body)
        self.assertNotIn('setValue(',body)

    def test_actual_preset_startup_order_pause_guard_and_failure_propagation(self):
        body=re.search(r'^function M.startGlassTest\(\).*?\nend',MAIN,re.M|re.S).group()
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True)
            lua.execute('''
            M={};events={};paused=false;safe=true;CLEAN_RADIANCE={}
            simTimeAuthority={getPause=function()return paused end}
            PROGRESSIVE={lightingAudit={getStatus=function()return {active=false}end},
              reflectionSampling={isFrozen=function()return false end},
              rendererCompatibility={check=function()return {safe=safe,reason='unsafe'}end}}
            function event(s)events[#events+1]=s end
            function beamrtLog()end
            function M.disable()event('disable');return true end
            function M.setPtgiNamedHandoffEnabled(v)assert(v==false);event('baseline');return true end
            function M.setCoherentSsrParameter(k,v)
              event(k..'='..tostring(v));if failParameter then return false,'parameter rejected'end;return true
            end
            function M.setPtgiCoherentEnabled(v)assert(v);event('combined');return true end
            function M.setAutomaticLampShadowsEnabled(v)assert(v);event('lamps');return true end
            M._glassSunShadow={checkTarget=function()return not walking,'Enter the car first'end,
              setStrength=function(v)assert(v==1);event('strength')end}
            function M.setGlassSunShadowsEnabled(v)assert(v);event('glass');return true,'waiting' end
            function M.openTuner()event('tuner')end
            ''')
            lua.execute(body)
            self.assertFalse(lua.globals().M.startGlassTest()[0]);self.assertEqual(len(lua.globals().events),0)
            lua.execute('paused=true;safe=false')
            self.assertFalse(lua.globals().M.startGlassTest()[0]);self.assertEqual(len(lua.globals().events),0)
            lua.execute('safe=true')
            lua.execute('walking=true')
            self.assertFalse(lua.globals().M.startGlassTest()[0]);self.assertEqual(len(lua.globals().events),0)
            lua.execute('walking=false')
            self.assertTrue(lua.globals().M.startGlassTest()[0])
            events=list(lua.globals().events.values())
            self.assertEqual(events[:2],['disable','baseline'])
            self.assertLess(events.index('stochasticRayCount=8'),events.index('combined'))
            self.assertEqual(events[-4:],['lamps','strength','glass','tuner'])
            lua.execute('events={};failParameter=true')
            self.assertFalse(lua.globals().M.startGlassTest()[0])
            self.assertNotIn('combined',list(lua.globals().events.values()))

if __name__=='__main__':unittest.main()
