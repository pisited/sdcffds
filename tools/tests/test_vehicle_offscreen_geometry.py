"""Conservative whole-captured-source certificate, never shaded RT acceptance."""
import unittest
import test_vehicle_camera_reflection as camera_fixture
import test_vehicle_ray_image as image_fixture


def runtime():
    return camera_fixture.runtime()


class VehicleOffscreenGeometry(unittest.TestCase):
    def bounds(self,lua,lo,hi):
        return lua.table_from({'lo':lua.table_from(lo),'hi':lua.table_from(hi)})

    def test_all_six_separating_planes_use_whole_bounds_and_world_distance(self):
        cases=(
            ('near',[108,-1,-1],[110,1,1]),
            ('far',[40,-1,-1],[42,1,1]),
            ('left',[92,-102,-1],[94,-100,1]),
            ('right',[92,100,-1],[94,102,1]),
            ('bottom',[92,-1,-102],[94,1,-100]),
            ('top',[92,-1,100],[94,1,102]),
        )
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture();m=lua.globals().vehicleOffscreenGeometry
        for plane,lo,hi in cases:
            r=m.classify(s,self.bounds(lua,lo,hi))
            self.assertTrue(r.outside,plane);self.assertEqual(r.plane,plane)
            self.assertGreater(r.minimumSeparationMetres,.01)
            self.assertEqual((r.planesChecked,r.cornersPerPlane),(6,8));self.assertTrue(r.conservative)
        near=m.classify(s,self.bounds(lua,[108,-1,-1],[110,1,1]))
        self.assertAlmostEqual(near.minimumSeparationMetres,5.1)
        far=m.classify(s,self.bounds(lua,[40,-1,-1],[42,1,1]))
        self.assertAlmostEqual(far.minimumSeparationMetres,11)

    def test_no_corner_visible_does_not_mean_the_box_is_outside(self):
        lua=runtime();m=lua.globals().vehicleOffscreenGeometry;s=lua.globals().vehicleCameraSnapshot.capture()
        lo,hi=[92,-100,-100],[94,100,100]
        for x in (lo[0],hi[0]):
            for y in (lo[1],hi[1]):
                for z in (lo[2],hi[2]):
                    _,_,inside=lua.globals().vehicleCameraSnapshot.project(s,lua.table_from([x,y,z]))
                    self.assertFalse(inside)
        self.assertFalse(m.classify(s,self.bounds(lua,lo,hi)).outside)
        self.assertFalse(m.classify(s,self.bounds(lua,[102,-10,-10],[104,10,10])).outside)

    def test_partial_visibility_pixel_margins_and_primary_distance_cap_are_not_offscreen_proof(self):
        lua=runtime();m=lua.globals().vehicleOffscreenGeometry;s=lua.globals().vehicleCameraSnapshot.capture()
        self.assertFalse(m.classify(s,self.bounds(lua,[92,15,-1],[94,25,1])).outside)
        # A point just beyond the right edge still falls inside the two-pixel
        # expansion. It cannot become a certificate by being missed at 128px.
        self.assertFalse(m.classify(s,self.bounds(lua,[93,20.02,0],[93,20.02,0])).outside)
        # The 1cm plane margin is independent of the near endpoint exclusion.
        self.assertFalse(m.classify(s,self.bounds(lua,[102.905,0,0],[102.905,0,0])).outside)
        lua.execute('cam.far=5000');s=lua.globals().vehicleCameraSnapshot.capture()
        self.assertFalse(m.classify(s,self.bounds(lua,[-1398,-1,-1],[-1397,1,1])).outside)

    def test_rolled_asymmetric_frustum_uses_camera_basis_and_rejects_invalid_bounds(self):
        lua=runtime();lua.execute('cam.right={0,0,1};cam.up={0,-1,0};cam.left=-.08;cam.rightEdge=.15')
        s=lua.globals().vehicleCameraSnapshot.capture();m=lua.globals().vehicleOffscreenGeometry
        r=m.classify(s,self.bounds(lua,[92,-1,100],[94,1,102]))
        self.assertTrue(r.outside);self.assertEqual(r.plane,'right')
        for lo,hi in (([1,0,0],[0,0,0]),([float('nan'),0,0],[1,1,1]),([0,0,0],[float('inf'),1,1])):
            with self.assertRaisesRegex(Exception,'Invalid complete triangle bounds'):
                m.classify(s,self.bounds(lua,lo,hi))

    def test_real_secondary_hits_to_whole_offscreen_source_match_reference_and_exclusion(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-bounce',s))
        status=lua.globals().image.status(job)
        self.assertTrue(status.offscreenGeometryControlsPassed)
        self.assertGreater(status.offscreenSourceHitsA,0);self.assertEqual(status.hitsB,0)
        self.assertEqual(status.offscreenSourceHitsA,status.changedPixels)
        self.assertTrue(status.cameraPrimaryMatched);self.assertTrue(status.reflectedReferenceMatched)
        self.assertTrue(status.sourceExcludedControlPassed);self.assertFalse(status.offscreenReflectionTestPassed)
        self.assertFalse(status.materialShadingVerified);self.assertFalse(status.gpuExecutionVerified)
        status.offscreenSourceBounds[2].outside=False
        self.assertTrue(lua.globals().image.status(job).offscreenSourceBounds[2].outside)

    def test_outside_bounds_with_no_reflected_hits_cannot_pass(self):
        lua=runtime();lua.execute('''
        for _,scene in ipairs(scenes)do scene.ranges[1].buffers.vertices={[0]=-1,-1,-1,1,-1,1,0,1,0}end
        ''')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-bounce',s))
        self.assertTrue(job.bounce.offscreenSourceBounds[2].outside)
        self.assertEqual(job.bounce.offscreenSourceHitsA,0);self.assertFalse(job.bounce.offscreenGeometryControlsPassed)

    def test_controller_compact_report_retains_guards_and_detaches_certificates(self):
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime()
        self.assertTrue(p.startCameraReflectionMaskTest()[0])
        self.assertFalse(p.getOffscreenStatus().offscreenGeometryControlsPassed)
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(4000):
            p.update(.001)
            if p.getImageStatus().phase in ('complete','cancelled'):break
        s=p.getOffscreenStatus();self.assertEqual(s.phase,'complete')
        self.assertEqual(s.diagnosticRevision,16);self.assertTrue(s.offscreenGeometryControlsPassed)
        self.assertTrue(s.sourceBounds[2].outside);self.assertEqual(s.primaryHitsB,0)
        s.sourceBounds[2].outside=False
        self.assertTrue(p.getOffscreenStatus().sourceBounds[2].outside)
        lua.execute('cam.position[1]=104')
        s=p.getOffscreenStatus();self.assertEqual(s.phase,'cancelled')
        self.assertFalse(s.offscreenGeometryControlsPassed);self.assertEqual(lua.globals().freed,2)


if __name__=='__main__':unittest.main()
