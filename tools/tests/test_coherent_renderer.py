"""Execute the actual opt-in controller and pass graph, not a second renderer.

Engine object mocks establish CPU contracts only, not scheduling/GPU appearance.
"""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / 'lua/ge/extensions/beamrt'
MOCK = r'''
objects={};messages={};native=false;failCreate=false;failDelete=false
local methods={}
function methods:setField(key,index,value)
 assert(key~='texture' or index>=0 and index<=5,'Six-slot budget exceeded')
 self._fields[key..'['..index..']']=value
end
function methods:getField(key,index)return self._fields[key..'['..index..']']or ''end
function methods:registerObject(name)self._fields.name=name;objects[name]=self end
function methods:inheritParentFields()end
function methods:setShaderConst(key,value)self._const[key]=value end
function methods:enable()self._fields.enabled=true end
function methods:disable()self._fields.enabled=false end
function methods:isEnabled()return self._fields.enabled==true end
function methods:delete()
 if failDelete then error('Deletion refused')end
 objects[self._fields.name]=nil
end
function createObject(class)
 if failCreate then error('Creation refused')end
 return setmetatable({_fields={class=class,enabled=false},_const={}}, {
  __index=function(self,key)return methods[key]or self._fields[key]end,
  __newindex=function(self,key,value)
   if key=='isEnabled'then self._fields.enabled=value else self._fields[key]=value end
  end})
end
objects.PFX_DefaultStateBlock=createObject('GFXStateBlockData')
scenetree={findObject=function(name)return objects[name]end,findClassObjects=function()return {}end}
settings={getValue=function(key)
 if key=='PostFXSSREnabled'then return native end
 if key=='GraphicShadowsQuality'then return 'High'end
 return false
 end,setValue=function()error('Native settings must not change')end}
GFXDevice={getVideoMode=function()return {width=160,height=96}end}
function getCameraPosition()return {x=0,y=0,z=4}end
function getCameraQuat()return {x=0,y=0,z=0,w=1}end
function getCameraFovDeg()return 75 end
function getMissionFilename()return 'levels/test/main.level.json'end
FS={fileExists=function()return false end}
function log(level,tag,message)table.insert(messages,message)end
be={getPlayerVehicle=function()return nil end}
'''


class CoherentRenderer(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51, LuaJIT):
            lua = cls(unpack_returned_tuples=True)
            lua.execute(MOCK)
            cache = {}

            def require(name):
                key = name.rsplit('/', 1)[-1]
                if key not in cache:
                    cache[key] = lua.execute((MODULES / (key + '.lua')).read_text(encoding='utf-8'))
                return cache[key]

            lua.globals().require = require
            renderer = require('coherentRenderer')
            lua.globals().renderer = renderer
            yield lua, renderer

    def test_import_is_disabled_and_allocates_no_render_objects(self):
        for lua, renderer in self.runtimes():
            self.assertFalse(renderer.getStatus().requested)
            self.assertEqual(lua.eval('(function()local n=0;for _ in pairs(objects)do n=n+1 end;return n end)()'), 1)
            options = renderer.getOptions()
            self.assertEqual(options.waterColorStrength, 0)
            for key in ('interleavedHistory', 'skyReflection', 'overhangFill', 'engineVelocity', 'fillEngineVelocityHole'):
                self.assertFalse(options[key], key)

    def test_enable_routes_a_complete_independent_pipeline_and_cleanup(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.enable(), lua.eval('table.concat(messages,"; ")'))
            self.assertTrue(renderer.getStatus().active)
            self.assertFalse(renderer.getStatus().gpuExecutionVerified)
            lua.execute('for i=1,12 do renderer.update(1/60)end')
            status = renderer.getStatus()
            self.assertTrue(status.active, status.reason)
            self.assertTrue(status.cameraHistoryReady)
            self.assertEqual(status.frame, 12)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uProjectionValid"]'), 1)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectApplyPass._const["$uWaterColorStrength"]'), 0)
            objects = lua.globals().objects
            for suffix in ('HiZ0Pass', 'HiZ6Pass', 'HiZPackedPass', 'TracePass', 'NativeResolvePass', 'ApplyPass'):
                self.assertIsNotNone(objects['BeamRTCoherentPostEffect' + suffix])
            self.assertEqual(objects.BeamRTCoherentPostEffectTemporalPassA.getField(objects.BeamRTCoherentPostEffectTemporalPassA, 'targetFormat', 0), 'GFXFormatR32G32B32A32F')
            self.assertEqual(objects.BeamRTCoherentPostEffectCameraHistoryPass.getField(objects.BeamRTCoherentPostEffectCameraHistoryPass, 'targetSize', 0), '2 2')
            self.assertTrue(renderer.disable())
            self.assertFalse(renderer.getStatus().active)
            self.assertEqual(lua.eval('(function()local n=0;for _ in pairs(objects)do n=n+1 end;return n end)()'), 1)

    def test_ping_pong_never_reads_its_own_output(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.enable())
            lua.execute(r'''
            for i=1,12 do
             renderer.update(1/60)
             local a=objects.BeamRTCoherentPostEffectTemporalPassA
             local b=objects.BeamRTCoherentPostEffectTemporalPassB
             assert(a:getField('skip','0')~=b:getField('skip','0'))
             for _,p in ipairs({a,b})do
              assert(p:getField('target',0)~=p:getField('texture',3))
             end
            end
            ''')

    def test_controls_change_uploaded_values_and_reset_history(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.enable())
            lua.execute('for i=1,8 do renderer.update(1/60)end')
            self.assertTrue(renderer.setParameter('interleavedHistory', True))
            self.assertTrue(renderer.setParameter('traceSubpixelJitter', False))
            self.assertTrue(renderer.setParameter('stochasticReuse', 0))
            self.assertTrue(renderer.setParameter('waterSSR', False))
            renderer.update(1/60)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uWaterSSR"]'), 0)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uTraceJitterUV"]'), '0 0')
            self.assertTrue(renderer.getStatus().options.interleavedHistory)
            self.assertFalse(renderer.getStatus().cameraHistoryReady)

    def test_full_resolution_still_uses_requested_spatial_filter(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.setParameter('renderScale', 1))
            self.assertTrue(renderer.enable())
            lua.execute('for i=1,8 do renderer.update(1/60)end')
            self.assertTrue(lua.eval('objects.BeamRTCoherentPostEffectReusePass:isEnabled()'))
            self.assertTrue(renderer.setParameter('stochasticReuse', 0))
            renderer.update(1/60)
            self.assertFalse(lua.eval('objects.BeamRTCoherentPostEffectReusePass:isEnabled()'))

    def test_reference_and_hit_diagnostics_change_real_pass_routing(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.enable())
            self.assertTrue(renderer.setParameter('referenceTrace', True))
            self.assertTrue(renderer.setParameter('samplingMode', 0))
            renderer.update(1/60)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uReferenceTrace"]'), 1)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uHiZMaxLevel"]'), 0)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uSamplingMode"]'), 0)
            self.assertTrue(renderer.setParameter('debugView', 50))
            lua.execute('for i=1,4 do renderer.update(1/60)end')
            self.assertFalse(lua.eval('objects.BeamRTCoherentPostEffectNativeResolvePass:isEnabled()'))
            self.assertTrue(lua.eval('string.find(objects.BeamRTCoherentPostEffectTracePass:getField("shader",0),"P0$")~=nil'))

    def test_rough_stability_is_toggleable_and_invalidates_history_without_changing_water_or_gain(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.getOptions().roughStability)
            baseline=renderer.getOptions()
            self.assertTrue(renderer.enable())
            lua.execute('for i=1,8 do renderer.update(1/60)end')
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uRoughStability"]'), 1)
            self.assertTrue(renderer.setParameter('roughStability', False))
            renderer.update(1/60)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uRoughStability"]'), 0)
            self.assertFalse(renderer.getStatus().cameraHistoryReady)
            for key in ('waterSSR', 'waterColorStrength', 'waterWaveStrength', 'intensity', 'renderScale'):
                self.assertEqual(renderer.getOptions()[key], baseline[key], key)
            self.assertTrue(renderer.setParameter('roughStability', True))
            renderer.update(1/60)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uRoughStability"]'), 1)

    def test_native_conflict_stops_without_automatic_resume(self):
        for lua, renderer in self.runtimes():
            lua.execute('native=true')
            self.assertFalse(renderer.enable()[0])
            lua.execute('native=false')
            self.assertTrue(renderer.enable())
            lua.execute('native=true')
            renderer.update(1/60)
            self.assertFalse(renderer.getStatus().requested)
            lua.execute('native=false')
            renderer.update(1/60)
            self.assertFalse(renderer.getStatus().active)

    def test_heavy_noise_cleanup_is_reversible_and_preserves_appearance(self):
        for lua, renderer in self.runtimes():
            for key, value in [('faceOnReflectance', .04), ('roughnessEnd', .5),
                               ('intensity', .8), ('temporalDenoising', False), ('temporalStrength', 0)]:
                self.assertTrue(renderer.setParameter(key, value))
            before = dict(renderer.getOptions().items())
            self.assertTrue(renderer.applyNoiseQuality())
            self.assertFalse(renderer.getStatus().requested)
            self.assertTrue(renderer.getStatus().noiseRestoreAvailable)
            expected={'renderScale':1,'stochasticRayCount':16,'temporalStrength':.98,
                      'temporalDenoising':True,'nativeTemporal':True,'adaptiveResolution':False}
            for key, value in expected.items():
                self.assertEqual(renderer.getOptions()[key], value, key)
            for key in ('intensity','faceOnReflectance','roughnessEnd','surfaceDetail',
                        'waterSSR','waterSSRStrength','waterColorStrength','waterWaveStrength',
                        'skyReflection','overhangFill','puddleStrength'):
                self.assertEqual(renderer.getOptions()[key], before[key], key)
            self.assertTrue(renderer.enable())
            lua.execute('for i=1,12 do renderer.update(1/60)end')
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uStochasticRayCount"]'),16)
            self.assertFalse(lua.eval('string.find(objects.BeamRTCoherentPostEffectTracePass:getField("shader",0),"OneRay")~=nil'))
            self.assertTrue(renderer.getStatus().accumulationReady)
            self.assertTrue(renderer.applyNoiseQuality()) # repeated click must not overwrite undo
            self.assertTrue(renderer.restoreNoiseQuality())
            self.assertEqual(dict(renderer.getOptions().items()), before)
            self.assertFalse(renderer.getStatus().noiseRestoreAvailable)
            for value in (0, 17, 4.5):
                self.assertFalse(renderer.setParameter('stochasticRayCount',value)[0])

    def test_accumulation_status_distinguishes_disabled_frozen_warming_and_scheduled(self):
        for lua, renderer in self.runtimes():
            self.assertFalse(renderer.getStatus().accumulationScheduled)
            self.assertTrue(renderer.enable())
            self.assertFalse(renderer.getStatus().accumulationReady)
            lua.execute('for i=1,12 do renderer.update(1/60)end')
            self.assertTrue(renderer.getStatus().accumulationReady)
            self.assertFalse(renderer.getStatus().gpuExecutionVerified)
            self.assertTrue(renderer.setParameter('temporalDenoising',False))
            renderer.update(1/60)
            self.assertFalse(renderer.getStatus().accumulationConfigured)
            self.assertFalse(renderer.getStatus().accumulationScheduled)
            self.assertTrue(renderer.setParameter('temporalDenoising',True))
            self.assertTrue(renderer.setParameter('temporalStrength',0))
            self.assertFalse(renderer.getStatus().accumulationConfigured)
            self.assertTrue(renderer.setParameter('temporalStrength',.98))
            self.assertTrue(renderer.setParameter('stochasticTemporalRate',0))
            self.assertTrue(renderer.getStatus().accumulationConfigured)
            self.assertFalse(renderer.getStatus().freshSampling)
            renderer.disable()
            self.assertFalse(renderer.getStatus().accumulationScheduled)

    def test_partial_startup_and_missing_required_pass_fail_closed(self):
        for lua, renderer in self.runtimes():
            lua.execute('objects.PFX_DefaultStateBlock=nil')
            self.assertFalse(renderer.enable()[0])
            lua.execute("objects.PFX_DefaultStateBlock=createObject('GFXStateBlockData')")
            self.assertTrue(renderer.enable())
            lua.execute('objects.BeamRTCoherentPostEffectApplyPass:delete()')
            renderer.update(1/60)
            self.assertFalse(renderer.getStatus().active)

    def test_validation_and_snapshots_cannot_mutate_controls(self):
        for lua, renderer in self.runtimes():
            for key, value in [('skyReflection', 1), ('renderScale', float('nan')), ('renderScale', -1),
                               ('debugView', 0.5), ('debugView', 54), ('bogus', 1), ('fillEngineVelocityHole', True)]:
                self.assertFalse(renderer.setParameter(key, value)[0])
            options = renderer.getOptions()
            options.skyReflection = True
            self.assertFalse(renderer.getOptions().skyReflection)

    def test_cleanup_retains_failed_ownership_for_retry(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.enable())
            lua.execute('failDelete=true')
            self.assertFalse(renderer.disable()[0])
            self.assertFalse(renderer.enable()[0])
            lua.execute('failDelete=false')
            self.assertTrue(renderer.disable())
            self.assertTrue(renderer.enable())

    def test_source_contains_no_external_runtime_or_stock_shader_repair(self):
        text = (MODULES / 'coherentPipeline.lua').read_text()
        for token in ('core_modmanager', 'DXPixelShaderFile = stock', 'motionBlurPlayerVehiclesEnabled =', 'EffectModule.author ='):
            self.assertNotIn(token, text)

    def test_lost_camera_and_render_gap_do_not_keep_history_valid(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.enable())
            lua.execute('for i=1,8 do renderer.update(1/60)end')
            renderer.update(1)
            self.assertFalse(renderer.getStatus().cameraHistoryReady)
            lua.execute('getCameraPosition=nil;getCameraQuat=nil')
            renderer.update(1/60)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass._const["$uProjectionValid"]'), 0)


class CoherentVehicleMotion(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51, LuaJIT):
            lua = cls(unpack_returned_tuples=True)
            lua.execute(r'''
            x=0;identity=1;extent=2;axis=1;present=true
            box={getCenter=function()return {x=x,y=0,z=1}end,
              getAxis=function(self,i)return {x=i==0 and axis or 0,y=i==1 and 1 or 0,z=i==2 and 1 or 0}end,
              getHalfExtents=function()return {x=extent,y=1,z=1}end}
            vehicle={getID=function()return identity end,getSpawnWorldOOBB=function()return box end}
            be={getPlayerVehicle=function()if present then return vehicle end end}
            ''')
            module = lua.execute((MODULES / 'coherentVehicleMotion.lua').read_text())
            yield lua, module

    def test_rigid_motion_has_a_real_previous_pose(self):
        for lua, motion in self.runtimes():
            self.assertFalse(motion.capture(1/60).valid)
            lua.execute('x=2')
            capture = motion.capture(1/60)
            self.assertTrue(capture.valid)
            self.assertEqual(capture.previous.center[1], 0)
            self.assertEqual(capture.current.center[1], 2)

    def test_reset_switch_teleport_gap_and_bad_geometry_invalidate_motion(self):
        for command in ('identity=2', 'x=100', 'present=false', 'extent=0', 'axis=2', 'x=0/0'):
            for lua, motion in self.runtimes():
                motion.capture(1/60)
                lua.execute(command)
                self.assertFalse(motion.capture(1/60).valid, command)
        for lua, motion in self.runtimes():
            motion.capture(1/60)
            self.assertFalse(motion.capture(1).valid)
            motion.clear()
            self.assertFalse(motion.capture(1/60).valid)


if __name__ == '__main__':
    unittest.main()
