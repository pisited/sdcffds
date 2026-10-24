"""Actual Lua light-acquisition policy; no native rendering/shadow proof."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[2]
MOCK=r'''
package.path='lua/?.lua;'..package.path
local vector={}
function vector.__add(a,b)return vec(a.x+b.x,a.y+b.y,a.z+b.z)end
function vec(x,y,z)return setmetatable({x=x,y=y,z=z},vector)end
camera=vec(0,0,0);core_camera={getPosition=function()return camera end}
objects={};vehicles={};vehicleData={};controlledId=42
be={getPlayerVehicleID=function()return controlledId end,getObjectByID=function(self,id)return vehicles[id]end}
function getAllVehicles()local all={};for _,v in pairs(vehicles)do all[#all+1]=v end;return all end
core_vehicle_manager={getVehicleData=function(id)return vehicleData[id]end}
function vehicle(id,x,props)
  local v={id=id,x=x}
  function v:getID()return id end
  function v:getPosition()return vec(self.x,0,0)end
  function v:getProp(pid)
    local p={};function p:getLiveTransformWorld()
      local m={};function m:getColumn(index)return index==3 and vec(1,2,3)or vec(0,1,0)end;return m
    end
    function p:getLight()error('read-only acquisition must not mutate native lights')end
    return p
  end
  vehicles[id]=v;vehicleData[id]={vdata={props=props or{}}};return v
end
vehicle(42,10,{
  {pid=0,mesh='SPOTLIGHT',func='lowbeam',lightCastShadows=true,lightBrightness=2},
  {pid=1,mesh='POINTLIGHT',func='signal_R',lightColor={r=255,g=90,b=0,a=255}}})
vehicle(99,2,{}) -- walk-mode avatar; no headlight props
vehicle(100,200,{{pid=0,mesh='POINTLIGHT'}})
local point={___type='class<PointLight>',color='1 1 1 1',brightness=3,radius=10}
function point:getID()return 1 end
function point:getName()return 'roomLight'end
function point:getPosition()return vec(3,0,0)end
function point:getField(key)return self[key]or''end
objects.roomLight=point
scenetree={findObject=function(name)return objects[name]end,
  findClassObjects=function(class)return class=='PointLight'and{'roomLight'}or{}end}
function findObjectListFrustum()return{'roomLight'}end
'''

class Lights(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True);self.lua.execute(MOCK)
        self.module=self.lua.eval("require('ge/extensions/beamrt/providers/lightProvider')")
    def rebuild(self,**options):
        result=self.module.rebuild(self.lua.table_from({'all':True,**options}))
        self.assertTrue(result[0]);return self.module.getStats()
    def vehicle_records(self):return [r for r in self.module.getRecords().values()if r.source=='vehicleProp']
    def test_car_lights_retained_when_control_switches_to_walk_avatar(self):
        self.rebuild();first={r.id for r in self.vehicle_records()}
        self.lua.globals().controlledId=99;stats=self.rebuild()
        self.assertEqual(first,{r.id for r in self.vehicle_records()})
        self.assertEqual(len(first),2);self.assertTrue(stats.vehicleSelection.selectionIndependentOfControlledVehicle)
        self.assertFalse(stats.feedsRayTracer);self.assertFalse(stats.vehicleEnabledStateVerified)
    def test_explicit_vehicle_and_disable_keep_existing_query_scope(self):
        stats=self.rebuild(vehicleId=99);self.assertEqual(stats.vehicleLights,0)
        self.assertEqual(stats.vehicleSelection.mode,'explicit')
        stats=self.rebuild(includeVehicleLights=False);self.assertEqual(stats.vehicleLights,0)
        self.assertEqual(stats.lights,1)
    def test_constructor_shadow_defaults_are_not_live_intensity_claims(self):
        self.rebuild();records={r.name:r for r in self.vehicle_records()}
        self.assertTrue(records['lowbeam'].castShadows)
        orange=records['signal_R'];self.assertFalse(orange.castShadows)
        self.assertIn('no shadows',orange.shadowPolicySource)
        self.assertEqual((orange.range,orange.innerAngle,orange.outerAngle,orange.brightness),(10,40,45,1))
        self.assertIsNone(orange.enabled);self.assertFalse(orange.enabledStateVerified)
    def test_nearby_radius_and_cap_are_explicit_not_hidden_complete_scene(self):
        self.lua.eval('vehicle')(120,30,self.lua.table_from([self.lua.table_from({'pid':0,'mesh':'POINTLIGHT'})]))
        stats=self.rebuild(maxVehicleLightVehicles=2)
        self.assertTrue(stats.vehicleSelection.capped)
        self.assertTrue(all(r.vehicleId==42 for r in self.vehicle_records()))
        stats=self.rebuild(vehicleLightRadius=5);self.assertEqual(stats.vehicleLights,0)
    def test_missing_enumeration_reports_player_fallback(self):
        self.lua.globals().getAllVehicles=None;self.lua.globals().controlledId=99
        stats=self.rebuild();self.assertEqual(stats.vehicleSelection.mode,'player fallback')
        self.assertFalse(stats.vehicleSelection.selectionIndependentOfControlledVehicle)
        self.assertIn('unavailable',stats.vehicleLightWarning)
    def test_native_light_wrapper_without_class_method_is_recorded(self):
        stats=self.rebuild();self.assertEqual(stats.unresolvedOrRejected,0)
        record=self.module.getById(1);self.assertEqual(record.type,'point')
    def test_invalid_budget_and_vehicle_removal_are_safe(self):
        stats=self.rebuild(maxVehicleLightVehicles=0);self.assertEqual(stats.vehicleLights,0)
        self.assertIn('invalid',stats.vehicleLightWarning)
        self.lua.globals().vehicles[42]=None;self.lua.globals().vehicleData[42]=None
        stats=self.rebuild();self.assertEqual(stats.vehicleLights,0)
    def test_actual_light_position_still_uses_prop_transform_plus_vehicle_origin(self):
        self.rebuild();position=self.vehicle_records()[0].position
        self.assertEqual((position.x,position.y,position.z),(11,2,3))

if __name__=='__main__':unittest.main(verbosity=2)
