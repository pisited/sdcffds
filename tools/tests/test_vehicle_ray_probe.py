"""Full-reference incremental CPU controls using the shared visibility kernel."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
MODULES=ROOT/'lua/ge/extensions/beamrt'
FIXTURE=r'''
function record()
 return {buffers={vertices={[0]=-3,-1,1, -3,1,1, -3,0,-1},indices={[0]=0,1,2}},
  flexmeshes={{meshName='body',nativeIndex=0,primitives={{firstIndex=0,indexCount=3,materialName='test_glass'}}}},
  propmeshes={}}
end
records={record(),record()}
previews={{origin={100,0,0},props={},sampledOnly=true,alignmentVerified=false},
 {origin={110,0,0},props={},sampledOnly=true,alignmentVerified=false}}
poses={
 {center={100,0,0},half={3,3,3},axes={{1,0,0},{0,1,0},{0,0,1}}},
 {center={110,0,0},half={3,3,3},axes={{1,0,0},{0,1,0},{0,0,1}}}}
'''


def load_kernel(lua):
    lua.globals().package.loaded['ge/extensions/beamrt/geometryTriangleIntersection']=lua.execute(
        (MODULES/'geometryTriangleIntersection.lua').read_text())
    for name in ('worldMeshCasters','worldBoxCasters','providers/lightProvider',
                 'providers/materialProvider','providers/tsStaticProvider'):
        lua.globals().package.loaded['ge/extensions/beamrt/'+name]=lua.table()
    module=lua.execute((MODULES/'sceneVisibility.lua').read_text())
    lua.globals().package.loaded['ge/extensions/beamrt/sceneVisibility']=module


class VehicleRayProbe(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);load_kernel(lua);lua.execute(FIXTURE)
            module=lua.execute((MODULES/'vehicleRayProbe.lua').read_text());lua.globals().rays=module
            yield lua,module

    def create(self,lua):
        lua.execute('scenes={rays.prepare(records[1],previews[1],41),rays.prepare(records[2],previews[2],42)};'
                    'job=rays.create(scenes,poses)')
        return lua.globals().job

    def finish(self,m,job,budget=1):
        for _ in range(10000):
            m.advance(job,.001,budget)
            if job.phase=='complete':return m.status(job)
        self.fail('bounded test never completed')

    def test_hit_miss_source_exclusion_unknown_opacity_and_buffer_retirement(self):
        for lua,m in self.runtimes():
            job=self.create(lua);status=self.finish(m,job)
            self.assertTrue(status.geometricControlsPassed)
            self.assertEqual(status.trianglesTested,7);self.assertEqual(status.totalTriangleTests,7)
            self.assertEqual(status.results[1].hit.vehicleId,42)
            self.assertEqual(status.results[2].hit.vehicleId,41)
            self.assertAlmostEqual(status.results[1].hit.point[1],107)
            self.assertAlmostEqual(sum(status.results[1].hit.barycentric.values()),1)
            self.assertFalse(status.results[3].geometricHit)
            self.assertFalse(status.results[4].geometricHit)
            self.assertEqual(status.results[4].excludedVehicleId,42)
            self.assertEqual(status.results[4].trianglesTested,1)
            self.assertEqual(status.results[1].hit.materialName,'test_glass')
            self.assertEqual(status.results[1].hit.alphaMode,'unknown')
            self.assertTrue(status.cpuReferenceOnly);self.assertFalse(status.screenInputsUsed)
            for key in ('opaqueVisibilityVerified','sceneComplete','gpuExecutionVerified',
                        'offscreenReflectionTestPassed','materialShadingVerified'):
                self.assertFalse(status[key])
            self.assertIsNone(job.scenes);self.assertIsNone(job.scratch)

    def test_full_primitive_references_not_the_wireframe_samples_and_step_budget(self):
        for lua,m in self.runtimes():
            lua.execute('''
            for _,r in ipairs(records)do
              r.flexmeshes[1].primitives[1].indexCount=257*3
              for i=0,257*3-1 do r.buffers.indices[i]=i%3 end
            end
            ''')
            job=self.create(lua);m.advance(job,.001,3)
            self.assertEqual(job.tests,3);self.assertEqual(job.phase,'running')
            status=self.finish(m,job,17)
            self.assertEqual(status.trianglesTested,257*7)
            self.assertTrue(status.fullPrimitiveReferences)
            self.assertTrue(status.geometricControlsPassed)

    def test_live_prop_matrix_columns_place_full_prop_geometry(self):
        for lua,m in self.runtimes():
            lua.execute('''
            local r=records[2];r.flexmeshes={}
            r.propmeshes={{meshName='wheel',nativeIndex=7,buffers=r.buffers,
              primitives={{firstIndex=0,indexCount=3,materialName='wheel_unknown'}}}}
            previews[2].props={{nativeIndex=7,columns={{1,0,0},{0,1,0},{0,0,1},{0,0,0}}}}
            ''')
            status=self.finish(m,self.create(lua))
            self.assertTrue(status.geometricControlsPassed)
            self.assertEqual(status.results[1].hit.kind,'prop')
            self.assertEqual(status.results[1].hit.nativeIndex,7)
            self.assertEqual(status.results[1].hit.materialName,'wheel_unknown')

    def test_wrong_candidate_geometry_reports_failed_controls_not_a_pass(self):
        for lua,m in self.runtimes():
            lua.execute('for i=0,8,3 do records[2].buffers.vertices[i]=50 end')
            status=self.finish(m,self.create(lua))
            self.assertFalse(status.results[1].controlPassed)
            self.assertFalse(status.geometricControlsPassed)
            self.assertEqual(status.phase,'complete')

    def test_proximity_timeout_and_invalid_step_budgets_refused(self):
        for lua,m in self.runtimes():
            job=self.create(lua)
            for limit in (0,8193,1.5,float('nan')):
                with self.assertRaises(Exception):m.advance(job,.001,limit)
            with self.assertRaises(Exception):m.advance(job,60,1)
            lua.execute('poses[2].center={105,0,0}')
            with self.assertRaises(Exception):self.create(lua)


if __name__=='__main__':
    unittest.main()
