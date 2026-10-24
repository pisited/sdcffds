"""Parity with the previous visibility segment kernel and unchanged alpha policy."""
import math
from pathlib import Path
import random
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT
from test_vehicle_ray_probe import load_kernel

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/geometryTriangleIntersection.lua').read_text()


def sub(a,b):return [a[i]-b[i] for i in range(3)]
def dot(a,b):return sum(a[i]*b[i] for i in range(3))
def cross(a,b):return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def previous(origin,direction,far,a,b,c):
    e1,e2=sub(b,a),sub(c,a);p=cross(direction,e2);det=dot(e1,p)
    if abs(det)<1e-7:return None
    inv=1/det;t=sub(origin,a);u=dot(t,p)*inv
    if u<0 or u>1:return None
    q=cross(t,e1);v=dot(direction,q)*inv
    if v<0 or u+v>1:return None
    distance=dot(e2,q)*inv
    if distance<=.08 or distance>=far-.08:return None
    return distance,u,v


class GeometryTriangleIntersection(unittest.TestCase):
    def test_extracted_scalar_kernel_parity_with_previous_vector_math(self):
        rng=random.Random(42);cases=[]
        for _ in range(200):
            a,b,c=[[rng.uniform(-10,10) for _ in range(3)] for _ in range(3)]
            n=cross(sub(b,a),sub(c,a));length=math.sqrt(dot(n,n))
            n=[x/length for x in n];distance=rng.uniform(.2,30)
            center=[(a[i]+b[i]+c[i])/3 for i in range(3)]
            origin=[center[i]-distance*n[i] for i in range(3)]
            cases.append((origin,n,distance+5,a,b,c))
            cases.append(([x+50 for x in origin],n,distance+5,a,b,c))
        cases.extend([([0,0,z],[0,0,1],far,[-1,-1,1],[1,-1,1],[0,1,1])
                      for z,far in ((.93,5),(0,1.05),(0,5))])
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);m=lua.execute(SOURCE)
            for origin,direction,far,a,b,c in cases:
                tri=lua.table_from({'a':lua.table_from(a),'b':lua.table_from(b),'c':lua.table_from(c)})
                result=m.segment(lua.table_from(origin),lua.table_from(direction),far,tri)
                expected=previous(origin,direction,far,a,b,c)
                if expected is None:self.assertIsNone(result)
                else:
                    for actual,want in zip(result,expected):self.assertAlmostEqual(actual,want,places=9)

    def test_scene_visibility_alpha_and_unknown_scene_semantics_unchanged(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);load_kernel(lua)
            lua.execute('''
            triangles={{a={-1,-1,1},b={1,-1,1},c={0,1,1},alphaMode='unknown'}}
            package.loaded['ge/extensions/beamrt/worldMeshCasters'].getTriangles=function()return triangles end
            visibility=package.loaded['ge/extensions/beamrt/sceneVisibility']
            ''')
            def trace():return lua.eval('visibility.traceSegment({0,0,0},{0,0,5})')
            self.assertEqual(trace().status,'possible-blocker')
            lua.execute("triangles[1].alphaMode='opaque'")
            self.assertEqual(trace().status,'blocked')
            lua.execute('triangles={}')
            result=trace();self.assertEqual(result.status,'unknown')
            self.assertFalse(result.sceneComplete);self.assertTrue(result.unblockedIsNotVerified)


if __name__=='__main__':unittest.main()
