"""Camera/projection contract + geometric perspective mask. No game claim."""
import unittest
import test_vehicle_reflection_mask as bounce_fixture
import test_vehicle_ray_image as image_fixture

CAMERA=r'''
cam={position={103,0,0},right={0,1,0},forward={-1,0,0},up={0,0,1},
 left=-.2,rightEdge=.2,top=.1,bottom=-.1,near=.1,far=50,width=1280,height=640}
nativeWrong=false;nativeOrtho=false;nativeFailed=false;nativeCalls=0
core_camera={getPosition=function()return cam.position end,getRight=function()return cam.right end,
 getForward=function()return cam.forward end,getUp=function()return cam.up end}
local frustum={getNearLeft=function()return cam.left end,getNearRight=function()return cam.rightEdge end,
 getNearTop=function()return cam.top end,getNearBottom=function()return cam.bottom end,
 getNearDist=function()return cam.near end,getFarDist=function()return cam.far end}
view={frustum=frustum,viewPort={extent={x=1280,y=640}}}
function view:getUnprojectedRayPosDir(x,y)
 nativeCalls=nativeCalls+1
 if nativeFailed then return false end
 local h=cam.left+(cam.rightEdge-cam.left)*x/cam.width
 local v=cam.top+(cam.bottom-cam.top)*y/cam.height
 local d={};local length=0
 for j=1,3 do
  d[j]=cam.forward[j]*cam.near+cam.right[j]*h+cam.up[j]*v
  if nativeOrtho then d[j]=cam.forward[j]end
  length=length+d[j]^2
 end
 length=math.sqrt(length);for j=1,3 do d[j]=d[j]/length end
 if nativeWrong then d[1]=-d[1];d[2]=-d[2]end
 return true,cam.position,d
end
RenderViewManagerInstance={getView=function(_,name)assert(name=='main');return view end}
'''


def runtime():
    lua=bounce_fixture.runtime();lua.execute(CAMERA)
    for stem in ('vehicleCameraSnapshot','vehicleOffscreenGeometry','vehicleCameraReflectionMask'):
        module=lua.execute((bounce_fixture.bvh_fixture.MODULES/(stem+'.lua')).read_text())
        lua.globals().package.loaded['ge/extensions/beamrt/'+stem]=module
        lua.globals()[stem]=module
    return lua


class VehicleCameraReflection(unittest.TestCase):
    def test_optional_checks_do_not_touch_autoloading_global_or_extension_metatables(self):
        lua=runtime();lua.execute('''
        optionalLoads=0
        extensions=setmetatable({},{__index=function(_,key)
          optionalLoads=optionalLoads+1;error('Unexpected extension autoload: '..key)
        end})
        local original=getmetatable(_G)
        setmetatable(_G,{__index=function(_,key)
          if key=='render_openxr' or key=='render_splitScreen'then
            optionalLoads=optionalLoads+1;error('Unexpected global optional lookup')
          end
          return nil
        end})
        ''')
        m=lua.globals().vehicleCameraSnapshot;s=m.capture()
        self.assertTrue(s.projectionValidated);self.assertTrue(m.matches(s))
        self.assertEqual(lua.globals().optionalLoads,0)

    def test_native_nine_point_validation_detached_camera_and_center_ray(self):
        lua=runtime();m=lua.globals().vehicleCameraSnapshot;s=m.capture()
        self.assertTrue(s.projectionValidated);self.assertEqual(s.nativeRayChecks,9)
        self.assertLess(s.maxNativeDirectionError,1e-12);self.assertEqual(lua.globals().nativeCalls,9)
        self.assertEqual((s.sampleWidth,s.sampleHeight),(128,64))
        start,direction,far=m.ray(s,.5,.5)
        self.assertAlmostEqual(start[1],102.9);self.assertEqual(direction[1],-1)
        self.assertEqual(direction[2],0);self.assertEqual(direction[3],0);self.assertAlmostEqual(far,49.9)
        s.position[1]=999;self.assertEqual(lua.globals().cam.position[1],103)

    def test_projection_round_trip_off_axis_roll_and_asymmetric_frustum(self):
        lua=runtime();lua.execute('''
        cam.right={0,0,1};cam.up={0,-1,0};cam.left=-.08;cam.rightEdge=.15
        ''');m=lua.globals().vehicleCameraSnapshot;s=m.capture()
        for u,v in ((.05,.1),(.5,.5),(.9,.8)):
            start,d,far=m.ray(s,u,v)
            p=lua.table_from([start[j]+d[j]*3 for j in (1,2,3)])
            actual_u,actual_v,inside=m.project(s,p)
            self.assertAlmostEqual(actual_u,u);self.assertAlmostEqual(actual_v,v);self.assertTrue(inside)
        _,_,inside=m.project(s,lua.table_from([110,0,0]));self.assertFalse(inside)

    def test_wrong_unprojection_orthographic_and_bad_native_return_rejected(self):
        for mutation in ('nativeWrong=true','nativeOrtho=true','nativeFailed=true'):
            lua=runtime();lua.execute(mutation)
            with self.assertRaises(Exception):lua.globals().vehicleCameraSnapshot.capture()

    def test_invalid_camera_basis_frustum_viewport_vr_and_split_screen_rejected(self):
        for mutation in ('cam.near=0','cam.far=.1','cam.left=.2','cam.up={1,0,0}',
                         'view.viewPort.extent.x=0','view.viewPort.extent.x=100',
                         "render_openxr={isSessionRunning=function()return true end}",
                         "extensions={render_splitScreen={getCurrentConfiguration=function()return true,2 end}}",
                         "extensions={render_splitScreen={getCurrentConfiguration=function()return true,1 end}}"):
            lua=runtime();lua.execute(mutation)
            with self.assertRaises(Exception):lua.globals().vehicleCameraSnapshot.capture()

    def test_matches_rejects_motion_rotation_fov_resize_but_tolerates_small_jitter(self):
        for mutation in ('cam.position[1]=cam.position[1]+.01','cam.forward={-.999,0,.0447}',
                         'cam.left=cam.left-.02','view.viewPort.extent.x=1000','cam.near=.11'):
            lua=runtime();m=lua.globals().vehicleCameraSnapshot;s=m.capture();lua.execute(mutation)
            ok,why=m.matches(s);self.assertFalse(ok,mutation)
        lua=runtime();m=lua.globals().vehicleCameraSnapshot;s=m.capture()
        lua.execute('cam.left=cam.left+.0001;cam.rightEdge=cam.rightEdge+.0001')
        self.assertTrue(m.matches(s))

    def test_camera_gap_view_can_bounce_to_source_behind_camera_and_keeps_full_primary_scene(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-bounce',s))
        status=lua.globals().image.status(job)
        self.assertEqual((status.width,status.height,status.viewCount),(128,128,2))
        self.assertTrue(status.gameplayCameraUsed);self.assertFalse(status.fixedOrthographicView)
        self.assertTrue(status.primaryFullPair);self.assertFalse(status.primaryReceiverIsolated)
        self.assertTrue(status.cameraProjectionValidated);self.assertTrue(status.cameraPrimaryMatched)
        self.assertGreater(status.hitsA,0);self.assertEqual(status.hitsB,0)
        self.assertGreater(status.otherHitsA,0);self.assertEqual(status.otherHitsB,0)
        self.assertTrue(status.cameraBounceGeometricControlsPassed);self.assertFalse(status.bothDirectionsRequired)
        self.assertEqual(status.reflectedHitPointsOutsideFrustum,status.otherHitsA)
        self.assertTrue(status.wholeSourceOutsideFrustumVerified);self.assertTrue(status.offscreenGeometryControlsPassed)
        self.assertEqual(status.offscreenSourceHitsA,status.otherHitsA)
        self.assertEqual(status.offscreenSourceHitsB,0)
        self.assertTrue(status.offscreenSourceBounds[2].outside)
        self.assertEqual(status.offscreenSourceBounds[2].plane,'near')
        self.assertFalse(status.offscreenReflectionTestPassed)
        for p in job.pixels.values():
            if p.vehicleId is not None:self.assertEqual(p.vehicleId,41)

    def test_front_car_occludes_rear_car_in_primary_queries(self):
        lua=runtime();lua.execute('cam.position={90,0,0};cam.forward={1,0,0};cam.right={0,-1,0}')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-bounce',s))
        self.assertGreater(job.hits[1],0);self.assertEqual(job.hits[2],0)
        self.assertEqual(job.bounce.otherHitsA,0);self.assertFalse(job.bounce.cameraBounceGeometricControlsPassed)
        self.assertFalse(job.bounce.offscreenGeometryControlsPassed)

    def pair_runtime(self):
        lua,probe=image_fixture.VehicleRayImage().pair_runtime();lua.execute(CAMERA)
        # cube A is centered at100, B110, camera103 in their gap facing A.
        return lua,probe

    def test_controller_camera_preflight_before_native_request_and_filename(self):
        lua,p=self.pair_runtime();self.assertTrue(p.startCameraReflectionMaskTest()[0])
        entries=list(lua.globals().journal.values())
        camera_after=next(e.sequence for e in entries if e.operation=='captureMainCamera' and e.boundary=='after')
        request_before=next(e.sequence for e in entries if e.operation=='request' and e.boundary=='before')
        self.assertLess(camera_after,request_before)
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(3000):
            p.update(.001)
            if p.getImageStatus().phase in ('complete','cancelled'):break
        status=p.getImageStatus();self.assertEqual(status.phase,'complete',status.reason)
        self.assertEqual(status.profile,'camera-bounce');self.assertIn('camera-bounce-',status.file)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
        self.assertTrue(status.cameraProjectionValidated);self.assertTrue(status.cameraPrimaryMatched)
        status.frozenCamera.position[1]=999;self.assertEqual(p.getImageStatus().frozenCamera.position[1],103)
        lua.execute('cam.position[1]=103.01');self.assertEqual(p.getImageStatus().phase,'cancelled')
        self.assertEqual(lua.globals().freed,2)

    def test_failed_projection_makes_no_gpu_request_and_camera_move_releases_pending_once(self):
        lua,p=self.pair_runtime();lua.execute('nativeWrong=true')
        self.assertFalse(p.startCameraReflectionMaskTest()[0]);self.assertEqual(lua.globals().requests,0)
        self.assertEqual(lua.globals().freed,0)
        lua,p=self.pair_runtime();self.assertTrue(p.startCameraReflectionMaskTest()[0])
        lua.execute('cam.position[1]=103.01');p.update(.1)
        self.assertEqual(p.getImageStatus().phase,'cancelled');self.assertEqual(lua.globals().requests,1)
        self.assertEqual(lua.globals().freed,1);p.onExtensionUnloaded();self.assertEqual(lua.globals().freed,1)

    def test_one_player_multiseat_preflight_refuses_before_any_gpu_request(self):
        lua,p=self.pair_runtime()
        lua.execute('extensions={render_splitScreen={getCurrentConfiguration=function()return true,1 end}}')
        ok,why=p.startCameraReflectionMaskTest();self.assertFalse(ok);self.assertIn('multiseat',why)
        self.assertEqual(lua.globals().requests,0);self.assertEqual(lua.globals().freed,0)


if __name__=='__main__':unittest.main()
