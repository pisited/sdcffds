"""Execute actual native-lamp lease with mocked scene fields, Lua51/JIT.

Proves request/restore safety only; no native GPU shadow execution claim.
"""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/nearbyLampShadows.lua').read_text()
MAIN=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text()
MOCK=r'''
objects={};writes={};camera={x=0,y=0,z=0}
core_camera={getPosition=function()return camera end}
function lamp(id,distance,cast,size,class)
 local o={id=id,class=class or 'SpotLight',fields={castShadows=cast or '0',texSize=size or '256',isEnabled='1'},
   advertised={castShadows=true,texSize=true},p={x=distance,y=0,z=0}}
 function o:getID()return self.id end
 function o:getName()return 'lamp'..self.id end
 function o:getClassName()return self.class end
 function o:getPosition()return self.p end
 function o:getFields()return self.advertised end
 function o:getField(k,i)assert(i==0);if self.readFail then error('read failed')end;return self.fields[k] end
 function o:setField(k,i,v)
  assert(i==0);assert(k=='castShadows' or k=='texSize' or k=='priority');table.insert(writes,{id=self.id,key=k,value=v})
  if self.restoreFail and v~='1' and v~='1024' then error('restore blocked')end
  if k=='texSize' and v=='1024' and self.clamp then self.fields[k]='512' else self.fields[k]=v end
  if self.throwAfter and v=='1' then self.throwAfter=false;error('throw after write')end
 end
 objects[id]=o;return o
end
scenetree={findObject=function(id)return objects[id]end,findClassObjects=function(class)
 local result={};for id,o in pairs(objects)do if o.class==class then table.insert(result,id)end end;return result
end}
'''

SPATIAL_MOCK=r'''
queryCount=0;SOTLight=64
function vec3(x,y,z)return {x=x,y=y,z=z}end
function Box3F()
 local b={}
 function b:setExtents(v)self.extents=v end
 function b:setCenter(v)self.center=v end
 return b
end
function findObjectList(box,flags,detail)
 assert(flags==64 and detail==0 and box.extents.x==160)
 queryCount=queryCount+1
 local hits={}
 for _,o in pairs(objects)do
   if math.abs(o.p.x-box.center.x)<=80 then hits[#hits+1]=o end
 end
 return hits
end
'''


class NearbyLampShadows(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51,LuaJIT):
            lua=runtime(unpack_returned_tuples=True);lua.execute(MOCK)
            api=lua.execute(SOURCE);lua.globals().lamps=api
            yield lua,api

    def test_idle_reads_do_not_mutate_and_only_nearest_four_are_changed(self):
        for lua,api in self.runtimes():
            lua.execute('for i=1,8 do lamp(i,i)end;lamp(99,31);lamp(98,.5).fields.isEnabled="0"')
            api.getStatus();api.update()
            self.assertEqual(len(lua.globals().writes),0)
            self.assertTrue(api.enable()[0])
            self.assertEqual(api.getStatus().selectedCount,4)
            self.assertEqual(api.getStatus().changedFields,8)
            for i in range(1,5):
                self.assertEqual(lua.globals().objects[i].fields.castShadows,'1')
                self.assertEqual(lua.globals().objects[i].fields.texSize,'1024')
            self.assertEqual(lua.globals().objects[5].fields.castShadows,'0')
            self.assertEqual(lua.globals().objects[99].fields.castShadows,'0')
            before=len(lua.globals().writes);api.enable();api.update()
            self.assertEqual(len(lua.globals().writes),before)
            self.assertTrue(api.disable())
            for i in range(1,5):
                self.assertEqual(lua.globals().objects[i].fields.castShadows,'0')
                self.assertEqual(lua.globals().objects[i].fields.texSize,'256')

    def test_native_shadow_flags_and_higher_resolution_are_not_downgraded(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1,"true","2048")')
            self.assertTrue(api.enable()[0])
            self.assertEqual(len(lua.globals().writes),0)
            self.assertIn('already request',api.getStatus().reason)
            self.assertTrue(api.disable())

    def test_no_advertised_field_and_disabled_lights_are_not_dynamic_write_targets(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1).advertised={};lamp(2,2).fields.isEnabled="0"')
            self.assertFalse(api.enable()[0])
            self.assertEqual(len(lua.globals().writes),0)

    def test_mid_write_failure_rolls_back_and_native_clamping_is_restored(self):
        for mode in ('throwAfter','clamp'):
            for lua,api in self.runtimes():
                lua.execute('lamp(1,1).'+mode+'=true')
                self.assertFalse(api.enable()[0])
                self.assertEqual(lua.globals().objects[1].fields.castShadows,'0')
                self.assertEqual(lua.globals().objects[1].fields.texSize,'256')
                self.assertFalse(api.getStatus().pendingRestore)

    def test_failed_restoration_keeps_lease_and_can_be_retried(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1)');self.assertTrue(api.enable()[0])
            lua.execute('objects[1].restoreFail=true')
            self.assertFalse(api.disable()[0])
            self.assertTrue(api.getStatus().pendingRestore)
            self.assertFalse(api.enable()[0])
            lua.execute('objects[1].restoreFail=false')
            self.assertTrue(api.disable())
            self.assertFalse(api.getStatus().pendingRestore)

    def test_foreign_fields_and_replacement_objects_are_never_restored_over(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1)');api.enable()
            lua.execute('objects[1].fields.texSize="2048"')
            api.update()
            self.assertFalse(api.getStatus().requested)
            self.assertEqual(lua.globals().objects[1].fields.texSize,'2048')
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'0')
            api.enable();lua.execute('lamp(1,1,"false","4096")')
            count=len(lua.globals().writes);api.update()
            self.assertEqual(len(lua.globals().writes),count)
            self.assertEqual(lua.globals().objects[1].fields.texSize,'4096')

    def test_no_dynamic_cohort_reselection_after_camera_movement(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1);lamp(2,50)');api.enable()
            lua.execute('camera.x=50');api.update()
            self.assertEqual(api.getStatus().selected[1].id,1)
            self.assertEqual(lua.globals().objects[2].fields.castShadows,'0')

    def test_main_capture_interlock_and_history_invalidation_use_actual_methods(self):
        for lua,api in self.runtimes():
            lua.execute('''
            lamp(1,1);M={_nearbyLampShadows=lamps,_coherentRenderer={resetHistory=function()ssr=ssr+1 end}}
            audit=false;ssr=0;gi=0;CLEAN_RADIANCE={}
            PROGRESSIVE={lightingAudit={getStatus=function()return {active=audit}end}}
            function resetTemporalHistory()gi=gi+1 end
            ''')
            lua.execute(re.search(r'^function M.setNearbyLampShadowsEnabled.*?\nend',MAIN,re.M|re.S).group())
            lua.execute('audit=true');self.assertFalse(lua.globals().M.setNearbyLampShadowsEnabled(True)[0])
            self.assertEqual(len(lua.globals().writes),0)
            lua.execute('audit=false');self.assertTrue(lua.globals().M.setNearbyLampShadowsEnabled(True)[0])
            self.assertEqual(lua.globals().ssr,1);self.assertEqual(lua.globals().gi,1)
            self.assertTrue(lua.globals().M.setNearbyLampShadowsEnabled(False)[0])
            self.assertEqual(lua.globals().ssr,2)

    def test_lifecycle_cleanup_is_wired_and_no_shader_or_setting_replacements(self):
        for name in ('disable','onSettingsChanged','onClientStartMission','onClientEndMission','onExtensionUnloaded'):
            body=re.search(r'^function M\.'+name+r'\(.*?\nend',MAIN,re.M|re.S).group()
            self.assertIn('_nearbyLampShadows.disable(',body)
        self.assertIn('_nearbyLampShadows.update(dtReal)',MAIN)
        for forbidden in ('createObject(', 'settings.setValue', 'setLightArgs(', 'material:reload', 'jsonWriteFile(', 'setPosition('):
            self.assertNotIn(forbidden,SOURCE)

    def test_automatic_mode_covers_all_distances_and_disabled_lights_incrementally(self):
        for lua,api in self.runtimes():
            lua.execute('for i=1,80 do lamp(i,i*100)end;objects[80].fields.isEnabled="0"')
            self.assertTrue(api.enableAutomatic())
            self.assertEqual(len(lua.globals().writes),0)
            self.assertTrue(api.update(.016))
            self.assertEqual(len(lua.globals().writes),24) # distant maps retain native resolution
            self.assertEqual(api.getStatus().pendingJobs,56)
            for _ in range(3):api.update(.016)
            self.assertEqual(api.getStatus().processedLights,80)
            self.assertEqual(api.getStatus().pendingJobs,0)
            self.assertTrue(api.getStatus().automatic)
            self.assertIsNone(api.getStatus().radius)
            self.assertIsNone(api.getStatus().maximumLights)
            self.assertEqual(lua.globals().objects[80].fields.castShadows,'1')
            self.assertEqual(lua.globals().objects[80].fields.isEnabled,'0')
            self.assertLessEqual(len(api.getStatus().selected),8)
            before=len(lua.globals().writes)
            for _ in range(400):api.update(.016)
            self.assertEqual(len(lua.globals().writes),before)
            self.assertTrue(api.disable())
            for i in range(1,81):
                self.assertEqual(lua.globals().objects[i].fields.castShadows,'0')
                self.assertEqual(lua.globals().objects[i].fields.texSize,'256')

    def test_automatic_discovers_new_and_recycled_lights_and_yields_conflicting_owner(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,100)');api.enableAutomatic();api.update(.016)
            lua.execute('lamp(2,200);objects[1].fields.texSize="4096";objects[1].fields.castShadows="false"')
            api.update(.016)
            self.assertTrue(api.getStatus().requested)
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'false')
            self.assertEqual(lua.globals().objects[1].fields.texSize,'4096')
            for _ in range(400):api.update(.016)
            self.assertEqual(lua.globals().objects[2].fields.castShadows,'1')
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'false')
            lua.execute('lamp(2,300,"false","512")')
            for _ in range(400):api.update(.016)
            self.assertEqual(lua.globals().objects[2].fields.castShadows,'1')
            self.assertTrue(api.disable())
            self.assertEqual(lua.globals().objects[2].fields.castShadows,'false')
            self.assertEqual(lua.globals().objects[2].fields.texSize,'512')

    def test_automatic_empty_scene_waits_for_new_lights_and_failure_rolls_back(self):
        for lua,api in self.runtimes():
            self.assertTrue(api.enableAutomatic());api.update(.016)
            self.assertTrue(api.getStatus().requested)
            lua.execute('lamp(1,100).throwAfter=true')
            for _ in range(400):api.update(.016)
            self.assertFalse(api.getStatus().requested)
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'0')
            self.assertFalse(api.getStatus().pendingRestore)

    def test_renderer_start_hooks_auto_enable_and_disable_all_does_not_restart_itself(self):
        for name in ('enable','_enableCoherentBackend'):
            body=re.search(r'^function M\.'+name+r'\(.*?\nend',MAIN,re.M|re.S).group()
            self.assertIn('M._startAutomaticLampShadows()',body)
        self.assertNotIn('M._startAutomaticLampShadows()',
                         re.search(r'^function M.onPreRender.*?\nend',MAIN,re.M|re.S).group())
        for lua,api in self.runtimes():
            lua.execute('''
            lamp(1,1);M={_nearbyLampShadows=lamps,_automaticLampShadows=true}
            PROGRESSIVE={lightingAudit={getStatus=function()return {active=audit}end}}
            CLEAN_RADIANCE={};audit=true;function beamrtLog()end
            ''')
            lua.execute(re.search(r'^function M\._startAutomaticLampShadows.*?\nend',MAIN,re.M|re.S).group())
            self.assertTrue(lua.globals().M._startAutomaticLampShadows())
            self.assertFalse(api.getStatus().requested)
            lua.execute('audit=false;M._automaticLampShadows=false')
            lua.globals().M._startAutomaticLampShadows()
            self.assertFalse(api.getStatus().requested)
            lua.execute('M._automaticLampShadows=true')
            self.assertTrue(lua.globals().M._startAutomaticLampShadows()[0])
            self.assertTrue(api.getStatus().automatic)

    def test_priority_is_bounded_camera_relevant_and_restores_when_moving_or_disabled(self):
        for lua,api in self.runtimes():
            lua.execute('''
            for i=1,12 do local o=lamp(i,i);o.advertised.priority=true;o.fields.priority='1' end
            lamp(99,200).fields.isEnabled='0'
            ''')
            api.enableAutomatic();api.update(.016)
            self.assertEqual(len(api.getStatus().prioritizedLights),8)
            for i in range(1,9):
                self.assertEqual(lua.globals().objects[i].fields.priority,'5')
                self.assertEqual(lua.globals().objects[i].fields.texSize,'1024')
            self.assertEqual(lua.globals().objects[9].fields.priority,'1')
            self.assertEqual(lua.globals().objects[9].fields.texSize,'256')
            self.assertEqual(lua.globals().objects[99].fields.castShadows,'1')
            self.assertEqual(lua.globals().objects[99].fields.isEnabled,'0')
            lua.execute('camera.x=200')
            for _ in range(65):api.update(.016)
            self.assertEqual(len(api.getStatus().prioritizedLights),0)
            for i in range(1,13):
                self.assertEqual(lua.globals().objects[i].fields.priority,'1')
                self.assertEqual(lua.globals().objects[i].fields.texSize,'256')
                self.assertEqual(lua.globals().objects[i].fields.castShadows,'1')
            lua.execute('camera.x=0')
            for _ in range(65):api.update(.016)
            self.assertTrue(api.setPriorityAssist(False))
            api.update(.016)
            self.assertEqual(len(api.getStatus().prioritizedLights),0)
            for i in range(1,13):
                self.assertEqual(lua.globals().objects[i].fields.priority,'1')
                self.assertEqual(lua.globals().objects[i].fields.texSize,'256')
            self.assertTrue(api.disable())

    def test_point_map_pressure_is_bounded_and_larger_native_maps_are_preserved(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1,"0","256","PointLight");lamp(2,2,"0","2048")')
            api.enableAutomatic();api.update(.016)
            self.assertEqual(lua.globals().objects[1].fields.texSize,'512')
            self.assertEqual(lua.globals().objects[2].fields.texSize,'2048')
            api.disable()
            self.assertEqual(lua.globals().objects[1].fields.texSize,'256')

    def test_rejected_priority_is_rolled_back_without_disabling_native_shadows(self):
        for lua,api in self.runtimes():
            lua.execute('''
            local o=lamp(1,1);o.advertised.priority=true;o.fields.priority='1'
            local native=o.setField
            function o:setField(k,i,v)
              if k=='priority' and v=='5' then self.fields[k]='2';return false end
              return native(self,k,i,v)
            end
            ''')
            api.enableAutomatic();api.update(.016)
            self.assertTrue(api.getStatus().requested)
            self.assertEqual(api.getStatus().priorityRejected,1)
            self.assertEqual(lua.globals().objects[1].fields.priority,'1')
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'1')
            self.assertEqual(lua.globals().objects[1].fields.texSize,'1024')
            for _ in range(65):api.update(.016)
            self.assertEqual(api.getStatus().priorityRejected,1)
            self.assertTrue(api.disable())

    def test_periodic_checks_are_distinguished_from_new_lights_and_report_is_read_only(self):
        for lua,api in self.runtimes():
            lua.execute('lamp(1,1)');api.enableAutomatic();api.update(.016)
            self.assertEqual(api.getStatus().newLightsThisScan,1)
            before=len(lua.globals().writes)
            report=api.getNearbyReport()
            self.assertEqual(len(report.lights),1)
            self.assertEqual(report.lights[1].fields.castShadows,'1')
            self.assertEqual(len(lua.globals().writes),before)
            for _ in range(400):api.update(.016)
            self.assertGreaterEqual(api.getStatus().scanCycles,2)
            self.assertEqual(api.getStatus().newLightsThisScan,0)
            self.assertIn('not new shadow maps',api.getStatus().reason)

    def test_native_nearby_query_bypasses_thousands_at_low_fps_and_refreshes_next_moving_frame(self):
        for lua,api in self.runtimes():
            lua.execute(SPATIAL_MOCK)
            lua.execute('''
            for i=1,5000 do lamp(i,10000+i)end
            lamp(6000,10);lamp(6001,510)
            -- Deterministic worst case: nearby lamps are last in discovery.
            scenetree.findClassObjects=function(class)
              local ids={};if class~='SpotLight' then return ids end
              for i=1,5000 do ids[#ids+1]=i end
              ids[#ids+1]=6000;ids[#ids+1]=6001;return ids
            end
            ''')
            api.enableAutomatic()
            self.assertEqual(len(lua.globals().writes),0)
            api.update(1/15)
            self.assertEqual(lua.globals().objects[6000].fields.castShadows,'1')
            self.assertEqual(lua.globals().objects[6000].fields.texSize,'1024')
            self.assertEqual(lua.globals().objects[6001].fields.castShadows,'0')
            self.assertGreater(api.getStatus().pendingJobs,4000)
            self.assertIn('Native nearby query active',api.getStatus().nearbyLookup)
            self.assertEqual(api.getStatus().newLightsThisScan,api.getStatus().processedLights)
            lua.execute('camera.x=500')
            api.update(1/15)  # no one-second wait, no queue completion required
            self.assertEqual(lua.globals().objects[6001].fields.castShadows,'1')
            self.assertEqual(lua.globals().objects[6001].fields.texSize,'1024')
            self.assertEqual(lua.globals().objects[6000].fields.texSize,'256')
            self.assertEqual(lua.globals().queryCount,2)
            self.assertTrue(api.disable())
            self.assertEqual(lua.globals().objects[6001].fields.castShadows,'0')
            self.assertEqual(lua.globals().objects[6001].fields.texSize,'256')

    def test_nearby_query_is_throttled_stationary_and_accepts_ids(self):
        for lua,api in self.runtimes():
            lua.execute(SPATIAL_MOCK)
            lua.execute('''
            lamp(1,1)
            local query=findObjectList
            findObjectList=function(...)local hits=query(...);return {hits[1]:getID()}end
            ''')
            api.enableAutomatic();api.update(1/60)
            self.assertEqual(lua.globals().queryCount,1)
            before=len(lua.globals().writes)
            for _ in range(10):api.update(1/60)
            self.assertEqual(lua.globals().queryCount,1)
            for _ in range(10):api.update(1/60)
            self.assertEqual(lua.globals().queryCount,2)
            self.assertEqual(len(lua.globals().writes),before)
            api.setPriorityAssist(False);api.update(1/60)
            self.assertEqual(lua.globals().objects[1].fields.texSize,'256')

    def test_native_query_failure_uses_safe_background_and_query_write_failure_rolls_back(self):
        for lua,api in self.runtimes():
            lua.execute(SPATIAL_MOCK)
            lua.execute('lamp(1,1);findObjectList=function()error("unsupported")end')
            api.enableAutomatic();api.update(1/15)
            self.assertTrue(api.getStatus().requested)
            self.assertIn('Background fallback',api.getStatus().nearbyLookup)
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'1')
            self.assertTrue(api.disable())
            lua.execute(SPATIAL_MOCK)
            lua.execute('objects[1].throwAfter=true')
            api.enableAutomatic();api.update(1/15)
            self.assertFalse(api.getStatus().requested)
            self.assertFalse(api.getStatus().pendingRestore)
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'0')

    def test_native_nearby_selection_uses_live_enabled_state_not_stale_background_cache(self):
        for lua,api in self.runtimes():
            lua.execute(SPATIAL_MOCK)
            lua.execute('lamp(1,1)')
            api.enableAutomatic();api.update(1/60)
            self.assertEqual(len(api.getStatus().prioritizedLights),1)
            lua.execute('objects[1].fields.isEnabled="0"')
            api.update(.25)
            self.assertEqual(len(api.getStatus().prioritizedLights),0)
            self.assertEqual(lua.globals().objects[1].fields.texSize,'256')
            self.assertEqual(lua.globals().objects[1].fields.isEnabled,'0')
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'1')

    def test_background_throughput_scales_with_real_dt_and_respects_soft_budget_and_caps(self):
        for lua,api in self.runtimes():
            lua.execute('for i=1,500 do lamp(i,10000+i)end;os.clock=function()return 0 end')
            api.enableAutomatic();api.update(1/15)
            self.assertEqual(api.getStatus().processedLights,96)
            api.disable();api.enableAutomatic();api.update(1/60)
            self.assertEqual(api.getStatus().processedLights,24)
            api.disable();api.enableAutomatic();api.update(10)
            self.assertEqual(api.getStatus().processedLights,192)
            api.disable();api.enableAutomatic()
            lua.execute('clock=0;os.clock=function()clock=clock+.003;return clock end')
            api.update(1/15)
            self.assertEqual(api.getStatus().processedLights,24)

    def test_nearby_native_hit_inspection_and_writes_are_bounded_and_filter_disabled_lights(self):
        for lua,api in self.runtimes():
            lua.execute(SPATIAL_MOCK)
            lua.execute('''
            for i=1,300 do lamp(i,i/100)end
            objects[1].fields.isEnabled='0'
            for i=1,300 do objects[i].positionReads=0
              local o=objects[i]
              function o:getPosition()self.positionReads=self.positionReads+1;return self.p end
            end
            -- Hide the background queue to measure the nearby path in isolation.
            scenetree.findClassObjects=function()return {}end
            findObjectList=function()
              local hits={};for i=1,300 do hits[#hits+1]=objects[i]end;return hits
            end
            ''')
            api.enableAutomatic();api.update(1/15)
            self.assertEqual(api.getStatus().processedLights,16)
            self.assertEqual(len(api.getStatus().prioritizedLights),8)
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'0')
            self.assertEqual(lua.globals().objects[257].positionReads,0)
            self.assertEqual(lua.globals().objects[300].fields.castShadows,'0')


if __name__=='__main__':unittest.main()
