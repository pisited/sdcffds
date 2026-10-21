"""Explicit water geometry discovery with mocked scene APIs, not game proof."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "lua/ge/extensions/beamrt/waterReceivers.lua").read_text()
MOCK = r'''
objects={}; classes={WaterPlane={},WaterBlock={}}; queryCount=0
core_camera={getPosition=function()return {x=0,y=0,z=5}end}
scenetree={findClassObjects=function(class)queryCount=queryCount+1;return classes[class]end,
  findObject=function(name)return objects[name]end}
function makeWater(class,name,x,y,z)
  local o={class=class,name=name,position={x=x,y=y,z=z},hidden=false,
    columns={{x=1,y=0,z=0},{x=0,y=1,z=0},{x=0,y=0,z=1}},
    box={minExtents={x=x-10,y=y-10,z=z-5},maxExtents={x=x+10,y=y+10,z=z}}}
  function o:getClassName()return self.class end
  function o:getName()return self.name end
  function o:getID()return self.name end
  function o:getPosition()return self.position end
  function o:getTransform()return {getColumn=function(_,i)return self.columns[i+1]end}end
  function o:getWorldBox()return self.box end
  objects[name]=o;table.insert(classes[class],name);return o
end
'''


class WaterReceivers(unittest.TestCase):
    runtime = LuaRuntime

    def setUp(self):
        self.lua = self.runtime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        self.module = self.lua.execute(SOURCE)
        self.lua.globals().water = self.module

    def refresh(self):
        result = self.module.refresh()
        return result[0] if isinstance(result, tuple) else result

    def test_import_is_inert_and_marks_unverified_ownership(self):
        status = self.module.getStatus()
        self.assertEqual(self.lua.globals().queryCount, 0)
        self.assertFalse(status.available)
        self.assertFalse(status.ownershipVerified)
        self.assertFalse(status.waveNormalsVerified)
        self.assertFalse(status.normalLightingAffected)
        self.assertEqual(self.module.getShaderConstants().waterReceiverPlane, "0 0 0 0")

    def test_one_horizontal_plane_and_block_publish_finite_metadata(self):
        self.lua.execute("makeWater('WaterPlane','ocean',0,0,1);makeWater('WaterBlock','pool',0,0,2)")
        self.assertTrue(self.refresh())
        status = self.module.getStatus()
        self.assertEqual((status.planeCount, status.blockCount), (1, 1))
        constants = self.module.getShaderConstants()
        self.assertEqual(constants.waterReceiverPlane, "1 1 0 0")
        self.assertEqual(constants.waterReceiverBlockMin, "-10 -10 2 1")
        self.assertEqual(constants.waterReceiverBlockMax, "10 10 0 0")
        self.assertEqual(constants.waterReceiverMaxDistance, 250)

    def test_nearest_selection_deterministic_and_capped_to_one_of_each(self):
        self.lua.execute("makeWater('WaterPlane','z',0,0,2);makeWater('WaterPlane','a',0,0,2);makeWater('WaterPlane','near',0,0,4);makeWater('WaterBlock','far',100,0,0);makeWater('WaterBlock','nearblock',0,0,0)")
        self.assertTrue(self.refresh())
        self.assertEqual(self.module.getStatus().plane.name, "near")
        self.assertEqual(self.module.getStatus().block.name, "nearblock")
        self.lua.execute("objects.near=nil")
        self.assertTrue(self.refresh())
        self.assertEqual(self.module.getStatus().plane.name, "a")

    def test_no_per_frame_queries_and_status_is_a_copy(self):
        self.lua.execute("makeWater('WaterPlane','ocean',0,0,0)")
        self.refresh()
        self.lua.execute("local s=water.getStatus();s.plane.height=999;s.available=false;for i=1,10 do water.getShaderConstants();water.getStatus()end")
        self.assertEqual(self.lua.globals().queryCount, 2)
        self.assertTrue(self.module.getStatus().available)
        self.assertEqual(self.module.getStatus().plane.height, 0)

    def test_hidden_tilted_and_unavailable_transform_are_rejected(self):
        for change in ("o.hidden=true", "o.columns[3]={x=.1,y=0,z=1}", "o.getTransform=nil"):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute("local o=makeWater('WaterPlane','water',0,0,0);" + change)
                self.assertFalse(self.refresh())
                self.assertEqual(self.module.getStatus().rejected, 1)

    def test_rotated_block_rejected_instead_of_aabb_expansion(self):
        self.lua.execute("local o=makeWater('WaterBlock','water',0,0,0);o.columns[1]={x=.707,y=.707,z=0};o.columns[2]={x=-.707,y=.707,z=0}")
        self.assertFalse(self.refresh())
        self.assertEqual(self.module.getStatus().rejected, 1)

    def test_axis_aligned_quarter_turn_block_is_accepted(self):
        self.lua.execute("local o=makeWater('WaterBlock','water',0,0,0);o.columns[1]={x=0,y=1,z=0};o.columns[2]={x=-1,y=0,z=0}")
        self.assertTrue(self.refresh())

    def test_invalid_bounds_and_nonfinite_height_fail_closed(self):
        for change in ("o.box.minExtents.x=100", "o.position.z=0/0", "o.box=nil", "o.position.z=100", "o.box.maxExtents.y=o.box.minExtents.y"):
            with self.subTest(change=change):
                self.setUp()
                self.lua.execute("local o=makeWater('WaterBlock','water',0,0,0);" + change)
                self.assertFalse(self.refresh())

    def test_query_failure_clears_previous_snapshot(self):
        self.lua.execute("makeWater('WaterPlane','water',0,0,0)")
        self.assertTrue(self.refresh())
        self.lua.execute("scenetree.findClassObjects=function()error('not ready')end")
        self.assertFalse(self.refresh())
        self.assertFalse(self.module.getStatus().available)
        self.assertEqual(self.module.getShaderConstants().waterReceiverPlane, "0 0 0 0")

    def test_camera_and_range_validation(self):
        self.lua.execute("makeWater('WaterPlane','water',0,0,0)")
        for value in (0, -1, 1001, float("nan"), float("inf")):
            self.assertFalse(self.module.refresh(self.lua.table_from({"maxDistance": value}))[0])
        self.lua.execute("core_camera=nil")
        self.assertFalse(self.refresh())

    def test_far_water_and_over_limit_scene_not_selected(self):
        self.lua.execute("makeWater('WaterPlane','far',0,0,1000)")
        self.assertFalse(self.refresh())
        self.lua.execute("for i=1,129 do makeWater('WaterBlock',tostring(i),0,0,0)end")
        self.assertFalse(self.refresh())
        self.assertIn("bounded limit", self.module.getStatus().reason)

    def test_clear_invalidates_without_mutating_game_objects(self):
        self.lua.execute("makeWater('WaterPlane','water',0,0,0)")
        self.refresh()
        self.module.clear("mission changed")
        self.assertFalse(self.module.getStatus().available)
        self.assertEqual(self.module.getStatus().reason, "mission changed")
        self.assertEqual(self.lua.globals().objects.water.position.z, 0)


class WaterReceiversLuaJIT(WaterReceivers):
    runtime = LuaJITRuntime


if __name__ == "__main__":
    unittest.main()
