"""Differential CPU BVH tests against the independent full-reference scan."""
import random
import unittest
from lupa.luajit21 import LuaRuntime
from test_vehicle_ray_probe import FIXTURE,load_kernel,MODULES


def runtime():
    lua=LuaRuntime(unpack_returned_tuples=True);load_kernel(lua);lua.execute(FIXTURE)
    for stem in ('vehicleRayProbe','vehicleGeometryBVH','vehicleRayImage'):
        module=lua.execute((MODULES/(stem+'.lua')).read_text())
        lua.globals().package.loaded['ge/extensions/beamrt/'+stem]=module
        lua.globals()[{'vehicleRayProbe':'rays','vehicleGeometryBVH':'bvh','vehicleRayImage':'image'}[stem]]=module
    lua.execute('scenes={rays.prepare(records[1],previews[1],41),rays.prepare(records[2],previews[2],42)}')
    return lua


class VehicleGeometryBVH(unittest.TestCase):
    def test_linear_reference_does_not_consult_corrupted_bvh_boxes(self):
        lua=runtime();lua.execute('''
        local db=bvh.build(scenes)
        for i=0,2 do db.bounds[i]=1000000;db.bounds[i+3]=1000001 end
        assert(bvh.trace(db,{104,0,0},{1,0,0},10)==nil)
        local slow=bvh.traceReference(db,{104,0,0},{1,0,0},10)
        assert(slow.vehicleId==42 and math.abs(slow.distance-3)<1e-9)
        assert(bvh.traceReference(db,{104,0,0},{1,0,0},10,42)==nil)
        ''')

    def test_geometric_world_normal_is_unit_and_not_flipped_for_back_faces(self):
        lua=runtime();lua.execute('''
        local db=bvh.build(scenes)
        local a=bvh.trace(db,{104,0,0},{1,0,0},10)
        local b=bvh.trace(db,{108,0,0},{-1,0,0},10)
        assert(a.vehicleId==42 and b.vehicleId==42)
        assert(a.normal[1]==-1 and a.normal[2]==0 and a.normal[3]==0)
        assert(b.normal[1]==-1 and b.normal[2]==0 and b.normal[3]==0)
        assert(a.frontFacing and not b.frontFacing)
        assert(db.carBounds[1].lo[1]==97 and db.carBounds[2].lo[1]==107)
        ''')

    def test_geometric_normal_comes_from_transformed_prop_vertices(self):
        lua=runtime();lua.execute('''
        local r=records[2];r.flexmeshes={};r.propmeshes={{meshName='rotated_door',nativeIndex=7,buffers=r.buffers,
          primitives={{firstIndex=0,indexCount=3,materialName='unknown'}}}}
        previews[2].props={{nativeIndex=7,columns={{0,1,0},{-1,0,0},{0,0,1},{0,0,0}}}}
        scenes[2]=rays.prepare(r,previews[2],42)
        local db=bvh.build(scenes)
        local hit=bvh.trace(db,{110,-6,0},{0,1,0},10)
        assert(hit.vehicleId==42 and hit.kind=='prop')
        assert(hit.normal[1]==0 and hit.normal[2]==-1 and hit.normal[3]==0)
        assert(db.carBounds[2].lo[2]==-3 and db.carBounds[2].hi[2]==-3)
        ''')

    def test_four_full_reference_controls_match_hit_primitive_distance_and_misses(self):
        lua=runtime();lua.execute('''
        stats={};db=bvh.build(scenes,nil,stats);linear=rays.create(scenes,poses)
        while linear.phase=='running'do rays.advance(linear,.001)end
        for i,ray in ipairs(linear.rays)do
          local hit=bvh.trace(db,ray.origin,ray.direction,ray.length,ray.excludedVehicleId)
          local expected=linear.results[i].hit
          assert((hit~=nil)==(expected~=nil))
          if hit then
            assert(hit.vehicleId==expected.vehicleId and hit.primitive==expected.primitive)
            assert(hit.triangleInPrimitive==expected.triangleInPrimitive and math.abs(hit.distance-expected.distance)<1e-9)
          end
        end
        ''')
        self.assertEqual(lua.globals().stats.copied,2)
        self.assertEqual(lua.globals().db.bytes,424)

    def test_randomized_rays_match_brute_force_and_use_fewer_triangle_tests(self):
        lua=runtime();rng=random.Random(39181)
        positions=[]
        # Separated triangles on multiple depth layers; no coplanar tie assumption.
        for _ in range(600):
            x,y,z=(rng.uniform(-20,20) for _ in range(3))
            positions.extend((x,y,z,x+rng.uniform(.1,2),y,z,x,y+rng.uniform(.1,2),z))
        lua.globals().source=lua.table_from(positions)
        lua.execute('''
        scenes={}
        for car=1,2 do
          local v,indices={},{}
          for i,value in ipairs(source)do v[i-1]=value end
          for i=0,#source/3-1 do indices[i]=i end
          scenes[car]={id=40+car,origin={car*50,0,0},triangles=#source/9,
            ranges={{first=0,count=#source/3,buffers={vertices=v,indices=indices},kind='flex',nativeIndex=0,primitive=1}}}
        end
        db=bvh.build(scenes)
        function compare(o,d,exclude)
          local job=rays.create(scenes,poses)
          job.rays={{name='independent random',origin=o,direction=d,target={0,0,0},length=200,tests=0,excludedVehicleId=exclude}}
          job.total=exclude and 600 or 1200
          while job.phase=='running'do rays.advance(job,0)end
          local stats={nodeTests=0,triangleTests=0}
          local actual=bvh.trace(db,o,d,200,exclude,nil,stats)
          local expected=job.results[1].hit
          assert((actual~=nil)==(expected~=nil),'hit mismatch')
          if actual then
            assert(actual.vehicleId==expected.vehicleId,'identity mismatch')
            assert(math.abs(actual.distance-expected.distance)<1e-8,'depth mismatch')
            assert(actual.triangleInPrimitive==expected.triangleInPrimitive,'primitive mismatch')
          end
          return stats.triangleTests
        end
        ''')
        tested=0
        for i in range(250):
            o=[rng.uniform(20,120),rng.uniform(-30,30),rng.uniform(-30,30)]
            d=[rng.uniform(-1,1) for _ in range(3)];norm=sum(v*v for v in d)**.5;d=[v/norm for v in d]
            tested+=lua.globals().compare(lua.table_from(o),lua.table_from(d),41 if i%3==0 else None)
        self.assertLess(tested,250*1200//5)

    def test_shared_native_prop_basis_and_origin_used_without_second_vehicle_rotation(self):
        lua=runtime();lua.execute('''
        local r=records[2];r.flexmeshes={};r.propmeshes={{meshName='door',nativeIndex=7,buffers=r.buffers,
          primitives={{firstIndex=0,indexCount=3,materialName='unknown'}}}}
        previews[2].props={{nativeIndex=7,columns={{1,0,0},{0,1,0},{0,0,1},{0,0,0}}}}
        scenes[2]=rays.prepare(r,previews[2],42)
        local db=bvh.build(scenes)
        local hit=bvh.trace(db,{104,0,0},{1,0,0},10)
        assert(hit.vehicleId==42 and hit.kind=='prop' and hit.nativeIndex==7 and math.abs(hit.distance-3)<1e-9)
        ''')

    def test_flat_centroids_degenerate_triangles_axis_parallel_and_endpoint_rules(self):
        lua=runtime();lua.execute('''
        for _,scene in ipairs(scenes)do
          local r=scene.ranges[1];r.count=300;scene.triangles=100
          for i=0,299 do r.buffers.indices[i]=i%3 end
        end
        local db=bvh.build(scenes)
        assert(db.nodeCount>1 and db.nodeCount<=400)
        local hit=bvh.trace(db,{104,0,0},{1,0,0},10)
        assert(hit.vehicleId==42 and hit.triangleInPrimitive==0)
        assert(bvh.trace(db,{107,0,0},{0,0,1},10)==nil)
        assert(bvh.trace(db,{106.95,0,0},{1,0,0},1)==nil)
        assert(bvh.trace(db,{104,0,0},{1,0,0},3.05)==nil)
        ''')

    def test_nearby_surfaces_do_not_reapply_endpoint_margin_to_nearest_distance(self):
        lua=runtime();lua.execute('''
        -- Right subtree is visited after left. A second hit only 2cm closer
        -- must still replace the first, despite the kernel's 8cm end margin.
        local db=bvh.build(scenes)
        db.vertices[0]=5;db.vertices[3]=5;db.vertices[6]=5
        db.vertices[9]=4.98;db.vertices[12]=4.98;db.vertices[15]=4.98
        db.bounds[0]=4.98;db.bounds[3]=5
        local hit=bvh.trace(db,{0,0,0},{1,0,0},10)
        assert(hit.vehicleId==42 and math.abs(hit.distance-4.98)<1e-9)
        ''')

    def test_budget_malformed_ranges_nonfinite_geometry_and_bad_rays_rejected(self):
        for mutation in ("scenes[1].ranges[1].count=4",'scenes[1].triangles=2',
                         'scenes[1].ranges[1].buffers.indices[0]=-1',
                         'scenes[1].ranges[1].buffers.vertices[0]=0/0',
                         'bvh.maxBytes=1','bvh.maxTriangles=1'):
            lua=runtime();lua.execute(mutation)
            with self.assertRaises(Exception):lua.execute('bvh.build(scenes)')
        for direction,far in (([0,0,0],10),([2,0,0],10),([1,0,0],.1),([1,0,0],1001)):
            lua=runtime();db=lua.globals().bvh.build(lua.globals().scenes)
            with self.assertRaises(Exception):lua.globals().bvh.trace(db,lua.table_from([0,0,0]),lua.table_from(direction),far)

    def test_actual_ffi_buffers_are_copied_and_index_overrun_rejected(self):
        lua=runtime();lua.execute('''
        local ffi=require('ffi')
        local r=scenes[1].ranges[1]
        r.buffers={vertices=ffi.new('float[9]',{-3,-1,1,-3,1,1,-3,0,-1}),indices=ffi.new('uint32_t[3]',{0,1,2})}
        db=bvh.build(scenes)
        r.buffers.vertices[0]=999
        assert(db.vertices[0]==97)
        r.buffers.indices[0]=3
        ''')
        with self.assertRaises(Exception):lua.execute('bvh.build(scenes)')

    def test_ffi_pointers_and_wrong_element_types_never_enter_geometry_copy(self):
        for mutation in ("vertices=ffi.new('double[9]')","indices=ffi.new('int32_t[3]')",
                         "vertices=ffi.cast('float *',keep)","indices=ffi.cast('uint32_t *',keep)"):
            lua=runtime();target,expression=mutation.split('=',1)
            lua.execute("local ffi=require('ffi');keep=ffi.new('float[9]');scenes[1].ranges[1].buffers."+target+'='+expression)
            with self.assertRaises(Exception):lua.execute('bvh.build(scenes)')


if __name__=='__main__':unittest.main()
