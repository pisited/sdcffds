"""Analytic geometric mirror tests, not native material or reflection claims."""
import math
import unittest
import test_vehicle_geometry_bvh as bvh_fixture
import test_vehicle_ray_image as image_fixture


def runtime():
    lua=bvh_fixture.runtime()
    mask=lua.execute((bvh_fixture.MODULES/'vehicleReflectionMask.lua').read_text())
    lua.globals().package.loaded['ge/extensions/beamrt/vehicleReflectionMask']=mask
    lua.globals().bounce=mask
    return lua


class VehicleReflectionMask(unittest.TestCase):
    def test_analytic_reflection_is_specular_unit_and_normal_sign_invariant(self):
        lua=runtime();m=lua.globals().bounce
        for direction,normal,expected in (
            ([-1,0,0],[1,0,0],[1,0,0]),
            ([-2**-.5,-2**-.5,0],[1,0,0],[2**-.5,-2**-.5,0]),
            ([0,0,-1],[0,0,1],[0,0,1]),
            ([1,0,0],[0,1,0],[1,0,0]),
        ):
            for sign in (1,-1):
                actual=m.reflect(lua.table_from(direction),lua.table_from([v*sign for v in normal]))
                for i,value in enumerate(expected,1):self.assertAlmostEqual(actual[i],value)
                self.assertAlmostEqual(sum(v*v for v in actual.values()),1)
        for direction,normal in (([2,0,0],[1,0,0]),([1,0,0],[0,0,0]),([math.nan,0,0],[1,0,0])):
            with self.assertRaises(Exception):m.reflect(lua.table_from(direction),lua.table_from(normal))

    def test_planar_pair_bounces_hit_opposite_car_and_disappear_when_source_excluded(self):
        lua=runtime();lua.execute('''
        local db=bvh.build(scenes)
        local start={98,0,0};local d={-1,0,0}
        local primary=bvh.trace(db,start,d,2,42)
        assert(primary.vehicleId==41 and math.abs(primary.distance-1)<1e-9)
        local cast=bounce.cast(db,primary,start,d,20,42)
        assert(cast.full.vehicleId==42 and cast.excluded==nil)
        assert(cast.direction[1]==1 and cast.direction[2]==0 and cast.direction[3]==0)
        assert(math.abs(cast.origin[1]-97.01)<1e-9)
        assert(math.abs(cast.full.distance-9.99)<1e-9)
        local expected=bvh.traceReference(db,cast.origin,cast.direction,20)
        assert(expected.vehicleId==42 and expected.reference==cast.full.reference)
        ''')

    def test_self_hit_is_not_deleted_to_manufacture_other_car_hit(self):
        lua=runtime();lua.execute('''
        local function plane(x,y)
          return {vertices={[0]=x,y-1,-1,x,y+1,-1,x,y,1},indices={[0]=0,1,2}}
        end
        scenes={
          {id=41,origin={0,0,0},triangles=1,ranges={{buffers=plane(2,-2),first=0,count=3,kind='flex'}}},
          {id=42,origin={0,0,0},triangles=1,ranges={{buffers=plane(4,-4),first=0,count=3,kind='flex'}}}}
        -- These input range vertices are in exporter axes: re-encode engine
        -- XYZ deliberately, so the known secondary line is x=-y, z=0.
        for _,s in ipairs(scenes)do local v=s.ranges[1].buffers.vertices
          for i=0,2 do local y,z=v[i*3+1],v[i*3+2];v[i*3+1]=z;v[i*3+2]=-y end
        end
        local db=bvh.build(scenes);local q=math.sqrt(.5)
        local cast=bounce.cast(db,{distance=math.sqrt(2),normal={1,0,0}},
          {1,1,0},{-q,-q,0},20,42)
        assert(cast.full.vehicleId==41 and cast.excluded.vehicleId==41)
        assert(cast.full.reference==cast.excluded.reference)
        ''')

    def test_four_panel_mask_has_real_specular_hits_and_source_excluded_controls(self):
        lua=runtime();job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'bounce'))
        status=lua.globals().image.status(job)
        self.assertEqual((status.width,status.height,status.panelWidth),(192,128,96))
        self.assertEqual(status.totalPixels,24576);self.assertEqual(status.pixelsRendered,24576)
        self.assertEqual(status.primarySamples,12288);self.assertEqual(status.viewCount,4)
        self.assertGreater(status.otherHitsA,0);self.assertGreater(status.otherHitsB,0)
        self.assertEqual(status.otherHitsA,status.hitsA);self.assertEqual(status.otherHitsB,status.hitsB)
        self.assertTrue(status.oneBounceGeometricControlsPassed);self.assertTrue(status.sourceExcludedControlPassed)
        self.assertTrue(status.reflectedReferenceMatched);self.assertEqual(status.reflectedReferenceSamples,8)
        self.assertGreater(status.bounceReferenceTriangleTests,0)
        self.assertEqual(status.changedPixels,status.otherHitsA+status.otherHitsB)
        self.assertEqual(status.secondaryRays,status.hitsA+status.hitsB)
        self.assertEqual(status.sourceExcludedRays,status.secondaryRays)
        self.assertEqual(status.selfHits+status.reflectedMisses+status.otherHitsA+status.otherHitsB,status.secondaryRays)
        self.assertEqual(status.excludedSelfHits+status.excludedMisses,status.sourceExcludedRays)
        self.assertTrue(status.receiverSelfHitsRetained);self.assertTrue(status.secondaryFullPair)
        self.assertFalse(status.offscreenReflectionTestPassed);self.assertFalse(status.gpuExecutionVerified)
        for y in range(128):
            for x in range(192):
                p=job.pixels[y*192+x+1]
                if p.vehicleId is not None:
                    if y<64:
                        self.assertEqual(tuple(p[i]for i in (1,2,3)),(45,240,100))
                        self.assertEqual(p.reflectedVehicleId,42 if x<96 else 41)
                    else:
                        self.assertEqual(tuple(p[i]for i in (1,2,3)),(58,68,82))
                        self.assertIsNone(p.reflectedVehicleId)

    def test_zero_intercar_hits_do_not_become_a_pass_just_because_render_completed(self):
        lua=runtime();lua.execute('''
        -- Each plane is x+y=0 in its own car coordinates. Horizontal primary
        -- rays reflect sideways, not across the gap, while center-to-center
        -- direct reference controls still hit both planes.
        for _,scene in ipairs(scenes)do
          scene.ranges[1].buffers.vertices={[0]=-1,-1,-1,1,-1,1,0,1,0}
        end
        ''')
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'bounce'))
        self.assertEqual(job.phase,'complete');self.assertEqual(job.bounce.otherHitsA+job.bounce.otherHitsB,0)
        self.assertTrue(job.bounce.reflectedReferenceMatched)
        self.assertFalse(job.bounce.sourceExcludedControlPassed);self.assertFalse(job.bounce.oneBounceGeometricControlsPassed)

    def test_false_bounce_answers_are_rejected_by_full_scan_comparison(self):
        lua=runtime();lua.execute('''
        local original=bounce.cast
        bounce.cast=function(...)
          local result=original(...);result.full=nil;result.excluded=nil;return result
        end
        ''')
        # Deliberately force all bounces to miss. The full-scan comparison must
        # reject this rather than publish a false match/pass.
        job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'bounce')
        with self.assertRaisesRegex(Exception,'mismatch'):image_fixture.finish(lua,job)
        self.assertFalse(job.bounce.oneBounceGeometricControlsPassed)
        lua.globals().image.cancel(job)

    def test_cooperative_cancel_during_bounce_render_and_reference_checks(self):
        for target in ('rendering-bounces','checking-bounces'):
            lua=runtime();lua.execute('image.operationsPerUpdate=16')
            job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'bounce')
            for _ in range(10000):
                lua.globals().image.advance(job,.001)
                if job.phase==target:break
            self.assertEqual(job.phase,target)
            lua.globals().image.cancel(job)
            self.assertIsNone(job.co);self.assertIsNone(job.controls.scenes);self.assertEqual(len(job.pixels),0)
            self.assertEqual(job.phase,'cancelled')

    def test_existing_controller_uses_geometry_only_and_saves_bounce_artifact(self):
        lua,probe=image_fixture.VehicleRayImage().pair_runtime()
        self.assertTrue(probe.startReflectionMaskTest()[0])
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(2000):
            probe.update(.001)
            if probe.getImageStatus().phase in ('complete','cancelled'):break
        status=probe.getImageStatus();self.assertEqual(status.phase,'complete',status.reason)
        self.assertEqual(status.profile,'bounce');self.assertIn('bounce-',status.file)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
        self.assertEqual(lua.globals().bitmapWrites,1);self.assertTrue(status.acceleratorMatchesReference)
        self.assertTrue(status.reflectedReferenceMatched)
        lua.execute('paused=false');self.assertEqual(probe.getImageStatus().phase,'cancelled')


if __name__=='__main__':unittest.main()
