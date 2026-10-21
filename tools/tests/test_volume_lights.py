"""Read-only two-tier haze discovery, actual Lua code in Lua51 and LuaJIT.

No test here establishes GPU visibility or native shadow-map execution.
"""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT
import test_nearby_lamp_shadows as lamps

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/volumeLights.lua').read_text()
EXTRA=r'''
forward={x=1,y=0,z=0}
core_camera.getForward=function()return forward end
function spot(id,distance)
 local o=lamp(id,distance)
 for k,v in pairs({color='1 .8 .5',brightness='2',range='20',innerAngle='20',outerAngle='50'})do
  o.advertised[k]=true;o.fields[k]=v
 end
 function o:getTransform()return {getColumn=function(_,n)assert(n==1);return {x=-1,y=0,z=0}end}end
 function o:setField()error('Read-only discovery attempted a lamp write')end
 return o
end
queryCount=0;SOTLight=64
function vec3(x,y,z)return {x=x,y=y,z=z}end
function Box3F()
 local b={};function b:setExtents(v)self.extents=v end;function b:setCenter(v)self.center=v end;return b
end
function findObjectList(b,flag,detail)
 assert(flag==64 and detail==0 and b.extents.x==360)
 queryCount=queryCount+1;local hits={}
 for id=1,10000 do local o=objects[id]
  if o and math.abs(o.p.x-b.center.x)<=180 then hits[#hits+1]=o end
 end
 return hits
end
'''

class VolumeLights(unittest.TestCase):
    def runtimes(self,spatial=True):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(lamps.MOCK);lua.execute(EXTRA)
            if not spatial:lua.execute('findObjectList=nil')
            api=lua.execute(SOURCE);lua.globals().sources=api
            yield lua,api

    def test_idle_and_status_are_non_mutating_and_haze_needs_no_shadow_fields(self):
        for lua,api in self.runtimes():
            lua.execute("spot(1,140).advertised.castShadows=nil;objects[1].fields.castShadows='0'")
            api.update(.016);api.getStatus()
            self.assertEqual(lua.globals().queryCount,0)
            self.assertEqual(len(api.getVolumetricLights()),0)
            api.enable();api.update(.016)
            self.assertEqual(len(api.getVolumetricLights()),1)
            self.assertEqual(api.getVolumetricLights()[1].id,1)
            self.assertFalse(api.getStatus().shadowWrites)
            self.assertEqual(lua.globals().objects[1].fields.castShadows,'0')
            self.assertEqual(len(lua.globals().writes),0)
            api.disable();self.assertEqual(len(api.getVolumetricLights()),0)
            self.assertEqual(api.getStatus().pendingJobs,0)

    def test_influence_ranking_bounds_range_behind_camera_and_invalid_inputs(self):
        for lua,api in self.runtimes():
            lua.execute('''
            for i=1,12 do spot(i,i*3)end
            spot(13,-100);spot(14,181);spot(15,150).fields.isEnabled='0'
            spot(16,140).fields.brightness='nan';spot(17,130).class='PointLight'
            spot(18,130).fields.range='-1';spot(19,130).fields.outerAngle='180'
            spot(20,130).fields.color='0 0 0';spot(21,125).fields.brightness='100'
            ''')
            api.enable();api.update(.016)
            result=api.getVolumetricLights()
            self.assertEqual(len(result),8)
            ids={result[i].id for i in range(1,9)}
            self.assertTrue(ids.isdisjoint({13,14,15,16,17,18,19,20}))
            for i in range(1,9):self.assertLessEqual(result[i].range,80)
            self.assertEqual(api.getStatus().maxDistance,160)
            self.assertEqual(api.getStatus().radius,180)

    def test_native_query_not_blocked_by_thousands_and_moving_refreshes_next_frame(self):
        for lua,api in self.runtimes():
            lua.execute('for i=1,5000 do spot(i,10000+i)end;spot(6000,140);spot(6001,640)')
            api.enable();api.update(1/15)
            self.assertEqual(api.getVolumetricLights()[1].id,6000)
            self.assertEqual(api.getStatus().pendingJobs,0)
            before=lua.globals().queryCount;api.update(.016)
            self.assertEqual(lua.globals().queryCount,before)
            lua.execute('camera.x=500');api.update(1/15)
            self.assertEqual(api.getVolumetricLights()[1].id,6001)
            self.assertEqual(lua.globals().queryCount,before+1)

    def test_turn_disabled_deleted_recycled_and_missing_camera_are_safe(self):
        for lua,api in self.runtimes():
            lua.execute('spot(1,140);spot(2,-140)')
            api.enable();api.update(.016)
            self.assertEqual(api.getVolumetricLights()[1].id,1)
            lua.execute('forward.x=-1');api.update(.016)
            self.assertEqual(api.getVolumetricLights()[1].id,2)
            lua.execute("objects[2].fields.isEnabled='0'");api.update(.25)
            self.assertEqual(len(api.getVolumetricLights()),0)
            lua.execute('spot(2,-130)');api.update(.25)
            self.assertEqual(api.getVolumetricLights()[1].position[1],-130)
            lua.execute('objects[2]=nil');api.update(.25)
            self.assertEqual(len(api.getVolumetricLights()),0)
            lua.execute('core_camera.getPosition=function()return {x=0/0,y=0,z=0}end');api.update(.25)
            self.assertIn('camera unavailable',api.getStatus().reason)

    def test_fallback_incremental_scan_is_bounded_and_recovers_from_bad_spatial_query(self):
        for lua,api in self.runtimes(spatial=False):
            lua.execute('''
            for i=1,200 do spot(i,10000+i)end;spot(300,140)
            scenetree.findClassObjects=function()local ids={};for i=1,200 do ids[#ids+1]=i end;ids[#ids+1]=300;return ids end
            ''')
            api.enable();api.update(.016)
            self.assertGreater(api.getStatus().pendingJobs,0)
            self.assertLessEqual(api.getStatus().inspected,24)
            for _ in range(10):api.update(.016)
            self.assertEqual(api.getVolumetricLights()[1].id,300)
            self.assertEqual(api.getStatus().cachedCandidates,1)
            lua.execute("findObjectList=function()error('query unavailable')end")
            api.update(.25)
            self.assertTrue(api.getStatus().requested)
            self.assertIn('fallback',api.getStatus().lookup)

    def test_identity_and_no_shadow_or_material_mutations_are_explicit(self):
        for forbidden in ('setField(', 'createObject(', 'settings.setValue', 'setPosition(', 'jsonWriteFile('):
            self.assertNotIn(forbidden,SOURCE)
        for lua,api in self.runtimes():
            lua.execute('for i=1,600 do spot(i,20)end')
            api.enable();api.update(.016)
            self.assertLessEqual(api.getStatus().cachedCandidates,512)
            self.assertEqual(len(api.getVolumetricLights()),8)

if __name__=='__main__':unittest.main()
