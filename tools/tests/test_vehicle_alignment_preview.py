"""Bounded wireframe transform/sampling checks. No renderer or GPU proof."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/vehicleAlignmentPreview.lua').read_text()
FIXTURE=r'''
function vec3(x,y,z)return {x=x,y=y,z=z}end
function ColorF(r,g,b,a)return {r=r,g=g,b=b,a=a}end
lines={};debugDrawer={drawLine=function(_,a,b,color)lines[#lines+1]={a,b,color}end}
matrixColumns={{0,1,0},{-1,0,0},{0,0,1},{2,3,4}}
pointCalls=0
matrix={getColumn=function(_,i)return matrixColumns[i+1]end,mulP3F=function(_,p)
 pointCalls=pointCalls+1;return {x=-p.y+2,y=p.x+3,z=p.z+4}
end}
requestedPid=nil
vehicle={getProp=function(_,pid)requestedPid=pid;assert(pid==91);return {
 getLiveTransformWorld=function()return matrix end}end}
buffers={vertices={[0]=1,2,3, 0,1,0, -1,0,1},indices={[0]=0,1,2}}
primitive={firstIndex=0,indexCount=3}
record={buffers=buffers,flexmeshes={{primitives={primitive}}},
 propmeshes={{nativeIndex=7,meshName='steering',buffers=buffers,primitives={primitive}}}}
placement={comparisonAvailable=true,matched=1,orientationAvailable=1,
 originRelativeTranslationMaxErrorMetres=0,directRotationMaxErrorDegrees=0,
 details={{nativeIndex=7,meshName='steering',pid=91,liveRelativePosition={2,3,4}}}}
origin={100,200,300}
'''


class VehicleAlignmentPreview(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(FIXTURE)
            module=lua.execute(SOURCE);lua.globals().alignment=module
            yield lua,module

    def build(self,lua,m,candidate=True):
        g=lua.globals()
        return m.build(g.record,g.placement,g.vehicle,g.origin,candidate)

    def test_inverse_export_axes_native_point_transform_and_origin_exactly_once(self):
        for lua,m in self.runtimes():
            result=self.build(lua,m)
            self.assertEqual(len(result.triangles),2)
            self.assertEqual(list(result.triangles[1][1].values()),[101,197,302])
            self.assertEqual(list(result.triangles[2][1].values()),[105,204,306])
            self.assertEqual(lua.globals().pointCalls,3)
            self.assertEqual(lua.globals().requestedPid,91)
            self.assertEqual(len(result.props),1)
            self.assertFalse(result.alignmentVerified);self.assertFalse(result.feedsRayTracer)
            self.assertTrue(result.sampledOnly)
            self.assertEqual(len(lua.globals().lines),0)
            self.assertIsNone(result.buffers)
            self.assertTrue(m.validate(result,lua.globals().vehicle))

    def test_all_live_prop_matrix_columns_invalidate_on_change(self):
        for column in range(1,5):
            for lua,m in self.runtimes():
                result=self.build(lua,m)
                lua.execute(f'matrixColumns[{column}][1]=matrixColumns[{column}][1]+.01')
                with self.assertRaises(Exception):m.validate(result,lua.globals().vehicle)

    def test_no_transform_selection_on_failed_candidate_partial_match_or_pose_mismatch(self):
        for mutation in ('placement.matched=0','placement.orientationAvailable=0',
                         'placement.directRotationMaxErrorDegrees=1',
                         'placement.originRelativeTranslationMaxErrorMetres=.1',
                         "placement.details[1].meshName='different'",'matrixColumns[4][1]=10'):
            for lua,m in self.runtimes():
                lua.execute(mutation)
                with self.assertRaises(Exception):self.build(lua,m)
                self.assertEqual(len(lua.globals().lines),0)
        for lua,m in self.runtimes():
            with self.assertRaises(Exception):self.build(lua,m,False)

    def test_deterministic_sampling_full_prop_coverage_and_hard_triangle_limit(self):
        for lua,m in self.runtimes():
            lua.execute('''
            record.flexmeshes[1].primitives[1]={firstIndex=0,indexCount=512*3}
            for i=0,512*3-1 do buffers.indices[i]=i%3 end
            record.propmeshes={};placement.details={}
            placement.matched=15;placement.orientationAvailable=15
            for i=0,14 do
              record.propmeshes[i+1]={nativeIndex=i,meshName='prop'..i,buffers=buffers,
                primitives={{firstIndex=0,indexCount=24}}}
              placement.details[i+1]={nativeIndex=i,meshName='prop'..i,pid=91,liveRelativePosition={2,3,4}}
            end
            ''')
            a=self.build(lua,m);b=self.build(lua,m)
            self.assertEqual(len(a.triangles),124);self.assertEqual(len(a.props),15)
            self.assertLessEqual(len(a.triangles),m.maxTriangles)
            self.assertEqual(list(a.triangles[20][1].values()),list(b.triangles[20][1].values()))
            m.draw(a,1);self.assertEqual(len(lua.globals().lines),124*3)
            self.assertEqual(lua.globals().lines[1][3].b,1)
            self.assertEqual(lua.globals().lines[193][3].r,1)

    def test_nonfinite_native_point_output_and_excess_prop_coverage_refused(self):
        for mutation in ('matrix.mulP3F=function()return {0/0,0,0}end',
                         'for i=2,65 do record.propmeshes[i]=record.propmeshes[1]end'):
            for lua,m in self.runtimes():
                lua.execute(mutation)
                with self.assertRaises(Exception):self.build(lua,m)
                self.assertEqual(len(lua.globals().lines),0)


if __name__=='__main__':
    unittest.main()
