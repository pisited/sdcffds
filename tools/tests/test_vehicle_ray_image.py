"""Synthetic geometry image checks; never a live vehicle/rendering claim."""
import struct
import unittest
import test_vehicle_geometry_bvh as bvh_test
import test_vehicle_pair_probe as pair_test

BOXES=r'''
function boxRecord()
 local v={};for z=-1,1,2 do for y=-1,1,2 do for x=-1,1,2 do
  -- Encode engine local (x,2y,.6z) in the shipped exporter's axes.
  v[#v+1]=x;v[#v+1]=z*.6;v[#v+1]=-y*2
 end end end
 local ids={0,2,3,0,3,1,4,5,7,4,7,6,0,1,5,0,5,4,2,6,7,2,7,3,0,4,6,0,6,2,1,3,7,1,7,5}
 local vertices,indices={},{}
 for i,value in ipairs(v)do vertices[i-1]=value end
 for i,value in ipairs(ids)do indices[i-1]=value end
 return {buffers={vertices=vertices,indices=indices},flexmeshes={{meshName='synthetic_box',nativeIndex=0,
  primitives={{firstIndex=0,indexCount=36,materialName='unknown'}}}},propmeshes={}}
end
records={boxRecord(),boxRecord()}
poses[1].half={1,2,.6};poses[2].half={1,2,.6}
scenes={rays.prepare(records[1],previews[1],41),rays.prepare(records[2],previews[2],42)}
'''


def runtime():
    lua=bvh_test.runtime();lua.execute(BOXES);return lua


def finish(lua,job):
    for _ in range(10000):
        lua.globals().image.advance(job,.001)
        if job.phase=='complete':return job
    raise AssertionError('Image did not complete')


class VehicleRayImage(unittest.TestCase):
    def test_curved_fixture_produces_many_geometric_normal_directions(self):
        lua=runtime();lua.execute('''
        local vertices,indices={},{}
        local lat,lon=12,20
        for i=0,lat do for j=0,lon-1 do
          local theta=math.pi*i/lat;local phi=2*math.pi*j/lon
          local n=i*lon+j
          vertices[n*3]=math.sin(theta)*math.cos(phi)
          vertices[n*3+1]=math.cos(theta)
          vertices[n*3+2]=-math.sin(theta)*math.sin(phi)
        end end
        local k=0
        for i=0,lat-1 do for j=0,lon-1 do
          local a=i*lon+j;local b=i*lon+(j+1)%lon
          local c=(i+1)*lon+j;local d=(i+1)*lon+(j+1)%lon
          for _,v in ipairs({a,c,b,b,c,d})do indices[k]=v;k=k+1 end
        end end
        for i=1,2 do
          records[i].buffers={vertices=vertices,indices=indices}
          records[i].flexmeshes[1].primitives[1].indexCount=k
          poses[i].half={1,1,1}
          scenes[i]=rays.prepare(records[i],previews[i],40+i)
        end
        ''')
        job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'normals'))
        colors={tuple(p[i]for i in (1,2,3)) for p in job.pixels.values()if p.vehicleId is not None}
        self.assertGreater(len(colors),100)
        self.assertTrue(job.acceleratorMatchesReference)

    def test_normal_closeups_have_fixed_two_panel_budget_and_signed_world_colors(self):
        lua=runtime();job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'normals'))
        status=lua.globals().image.status(job)
        self.assertEqual((status.width,status.height,status.panelWidth),(256,96,128))
        self.assertEqual(status.pixelsRendered,24576);self.assertEqual(status.viewCount,2)
        self.assertTrue(status.isolatedCars);self.assertTrue(status.geometricNormals)
        self.assertFalse(status.authoredNormalsCaptured);self.assertFalse(status.windingVerified)
        self.assertEqual(status.normalFrame,'world');self.assertTrue(status.acceleratorMatchesReference)
        self.assertEqual(status.frontFacePixels+status.backFacePixels,status.hitsA+status.hitsB)
        colors=set()
        for y in range(96):
            for x in range(256):
                p=job.pixels[y*256+x+1]
                if p.vehicleId is not None:
                    self.assertEqual(p.vehicleId,41 if x<128 else 42)
                    rgb=tuple(p[i]for i in (1,2,3));colors.add(rgb)
                    n=[value/127.5-1 for value in rgb]
                    self.assertAlmostEqual(sum(value*value for value in n),1,delta=.02)
        self.assertGreaterEqual(len(colors),3) # three visible flat box faces, not an ID tint
        self.assertGreater(status.hitsA,2000);self.assertGreater(status.hitsB,2000)

    def test_isolated_framing_is_independent_of_gap_and_baseline_remains_available(self):
        outputs=[]
        for gap in (10,60):
            lua=runtime();lua.execute('previews[2].origin[1]='+str(100+gap)+';poses[2].center[1]='+str(100+gap))
            lua.execute('scenes[2]=rays.prepare(records[2],previews[2],42)')
            job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'normals'))
            outputs.append((job.hits[1],job.hits[2]))
        self.assertEqual(outputs[0],outputs[1])
        lua=runtime()
        for profile in ('identity',None):
            job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,profile))
            self.assertEqual((job.width,job.height),(64,40));self.assertEqual(len(job.pixels),2560)
            self.assertEqual(job.profile,'identity')
        with self.assertRaisesRegex(Exception,'Unsupported'):lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'full-shading')

    def test_normals_bitmap_is_actual_256_by_96_not_scaled_baseline(self):
        lua=runtime();job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'normals'))
        lua.globals().job=job
        # Chunk byte extraction to avoid Lua's multi-return stack limit.
        data=bytearray()
        get=lua.eval('function(a,b)local s=image.bitmap(job);return {string.byte(s,a,b)}end')
        size=54+256*96*3
        for start in range(1,size+1,4096):data.extend(get(start,min(size,start+4095)).values())
        self.assertEqual(len(data),73782);self.assertEqual(struct.unpack_from('<ii',data,18),(256,96))
        self.assertEqual(struct.unpack_from('<I',data,2)[0],len(data))
        for x,y in ((64,48),(192,48),(0,0),(255,95)):
            offset=54+(95-y)*768+x*3;b,g,r=data[offset:offset+3]
            self.assertEqual((r,g,b),tuple(job.pixels[y*256+x+1][i]for i in (1,2,3)))

    def test_complete_image_checks_reference_then_has_both_ids_and_background(self):
        lua=runtime();job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses))
        status=lua.globals().image.status(job)
        self.assertEqual(status.phase,'complete');self.assertEqual(status.pixelsRendered,2560)
        self.assertEqual(status.totalTriangles,24);self.assertTrue(status.acceleratorMatchesReference)
        self.assertGreater(status.hitsA,0);self.assertGreater(status.hitsB,0)
        self.assertLess(status.hitsA+status.hitsB,2560)
        self.assertIsNone(job.co);self.assertIsNone(job.controls.scenes);self.assertIsNone(job.controls.scratch)
        self.assertTrue(status.fixedOrthographicView);self.assertFalse(status.gameplayCameraUsed)
        for key in ('alphaTexturesSampled','opaqueVisibilityVerified','sceneComplete',
                    'gpuExecutionVerified','materialShadingVerified','offscreenReflectionTestPassed'):
            self.assertFalse(status[key])

    def test_work_is_incremental_and_cancel_drops_coroutine_and_source_buffers(self):
        lua=runtime();lua.execute('image.operationsPerUpdate=3')
        job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses)
        lua.globals().image.advance(job,.001)
        self.assertEqual(job.phase,'building');self.assertEqual(job.workOperations,3)
        self.assertEqual(job.build.copied,3)
        lua.globals().image.cancel(job)
        self.assertEqual(job.phase,'cancelled');self.assertIsNone(job.co);self.assertIsNone(job.controls.scenes)
        self.assertEqual(len(job.pixels),0)
        lua.globals().image.advance(job,.1);self.assertEqual(job.phase,'cancelled')

    def test_bvh_mismatch_stops_before_publishing_any_pixel(self):
        lua=runtime();lua.execute('bvh.trace=function()return nil end')
        job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses)
        with self.assertRaisesRegex(Exception,'mismatch'):finish(lua,job)
        self.assertFalse(job.acceleratorMatchesReference);self.assertEqual(job.pixelsRendered,0)
        lua.globals().image.cancel(job)

    def test_bad_delta_timeout_and_invalid_geometry_fail_without_ready_image(self):
        for delta in (-1,float('nan'),180):
            lua=runtime();job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses)
            with self.assertRaises(Exception):lua.globals().image.advance(job,delta)
            self.assertNotEqual(job.phase,'complete');lua.globals().image.cancel(job)

    def test_blank_fixed_view_is_not_published_as_success(self):
        lua=bvh_test.runtime() # two infinitely thin test planes, edge-on to this view
        job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses)
        with self.assertRaisesRegex(Exception,'did not sample both cars'):finish(lua,job)
        self.assertNotEqual(job.phase,'complete');lua.globals().image.cancel(job)

    def test_bitmap_header_size_rows_palette_and_decoder(self):
        # Bytes cannot be auto-decoded as UTF-8 by lupa; return octets through
        # Lua's table boundary instead of weakening the Lua source behavior.
        lua=runtime();job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses))
        lua.globals().job=job
        octets=lua.eval('function() local s=image.bitmap(job);return {string.byte(s,1,#s)}end')()
        data=bytes(octets.values())
        self.assertEqual(data[:2],b'BM');self.assertEqual(len(data),7734)
        self.assertEqual(struct.unpack_from('<I',data,2)[0],len(data))
        self.assertEqual(struct.unpack_from('<ii',data,18),(64,40))
        self.assertEqual(struct.unpack_from('<H',data,28)[0],24)
        for x,y in ((0,0),(63,39),(32,20),(11,21)):
            expected=job.pixels[y*64+x+1]
            offset=54+(39-y)*192+x*3
            b,g,r=data[offset:offset+3]
            self.assertEqual((r,g,b),tuple(expected[i]for i in (1,2,3)))

    def test_ui_uses_native_pixel_rectangles_and_pairs_begin_end_even_on_error(self):
        lua=runtime();job=finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses))
        lua.execute('''
        begins=0;ends=0;rects=0
        ui_imgui={Cond_FirstUseEver=1,ImVec2=function(x,y)return {x=x,y=y}end,SetNextWindowSize=function()end,
          Begin=function()begins=begins+1;return true end,End=function()ends=ends+1 end,
          TextUnformatted=function()end,GetCursorScreenPos=function()return {x=0,y=0}end,
          GetWindowDrawList=function()return {}end,GetContentRegionAvailWidth=function()return 512 end,
          ImDrawList_AddRectFilled=function(_,a,b,c)assert(c>=0 and c<4294967296);rects=rects+1 end,
          Dummy=function()end}
        ''')
        lua.globals().image.draw(job);self.assertEqual(lua.globals().begins,1);self.assertEqual(lua.globals().ends,1)
        self.assertGreater(lua.globals().rects,40);self.assertLessEqual(lua.globals().rects,2560)
        lua.execute("ui_imgui.ImDrawList_AddRectFilled=function()error('draw failure')end")
        with self.assertRaisesRegex(Exception,'draw failure'):lua.globals().image.draw(job)
        self.assertEqual(lua.globals().begins,2);self.assertEqual(lua.globals().ends,2)

    def pair_runtime(self):
        lua,probe=pair_test.VehiclePairProbe().runtime()
        # Replace only Lua-owned fake geometry with the synthetic boxes. The
        # real provider still performs its FFI copies and native-profile checks.
        lua.execute('''
        local function cube(mesh)
          local p={};for z=-1,1,2 do for y=-1,1,2 do for x=-1,1,2 do
            p[#p+1]=x;p[#p+1]=z*.6;p[#p+1]=-y*2
          end end end
          mesh.positions=p;mesh.verticesCount=8;mesh.indicesCount=36;mesh.primitiveCount=36
          mesh.ids={0,2,3,0,3,1,4,5,7,4,7,6,0,1,5,0,5,4,2,6,7,2,7,3,0,4,6,0,6,2,1,3,7,1,7,5}
        end
        for _,mesh in pairs(meshes)do cube(mesh)end
        for _,car in pairs(cars)do
          function car:getSpawnWorldOOBB()return {
            getCenter=function()return {self.x,0,0}end,getHalfExtents=function()return {1,2,.6}end,
            getAxis=function(_,i)local a={0,0,0};a[i+1]=1;return a end}end
        end
        local originalOpen=io.open
        bitmapWrites=0;bitmapCloses=0;failBitmap=false
        io.open=function(path,mode)
          if mode=='wb'then
            assert(path:match('^/settings/beamrtVehicleRayImage%-.*%.bmp$'))
            if failBitmap then return nil,'bitmap unavailable'end
            return {write=function(self,data)assert(data:sub(1,2)=='BM');bitmapWrites=bitmapWrites+1;return self end,
              flush=function()return true end,close=function()bitmapCloses=bitmapCloses+1;return true end}
          end
          return originalOpen(path,mode)
        end
        ''')
        return lua,probe

    def test_pair_controller_image_mode_sequential_cleanup_status_export_and_invalidation(self):
        lua,probe=self.pair_runtime();self.assertTrue(probe.startImageTest()[0])
        self.assertEqual(probe.getImageStatus().phase,'acquiring')
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(1000):
            probe.update(.001)
            if probe.getImageStatus().phase in ('complete','cancelled'):break
        status=probe.getImageStatus();self.assertEqual(status.phase,'complete',status.reason)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
        self.assertEqual(lua.globals().bitmapWrites,1);self.assertEqual(lua.globals().bitmapCloses,1)
        self.assertTrue(status.acceleratorMatchesReference);self.assertTrue(status.file.endswith('.bmp'))
        self.assertEqual(lua.globals().journal[len(lua.globals().journal)].operation,'cpuImageComplete')
        probe.update(.1);self.assertEqual(lua.globals().bitmapWrites,1)
        self.assertTrue(probe.showImage(30)[0]);probe.hideImage();self.assertEqual(probe.getImageStatus().uiSecondsRemaining,0)
        lua.execute('paused=false');self.assertEqual(probe.getImageStatus().phase,'cancelled')
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)

    def test_pair_normal_mode_profiles_filename_guards_and_no_extra_native_streams(self):
        lua,probe=self.pair_runtime()
        lua.execute('''
        optionalTouched=0
        for _,mesh in pairs(meshes)do
          local forbidden={}
          for _,stem in ipairs({'normals','tangents','uv1','uv2','vertColors'})do
            for _,suffix in ipairs({'Count','Get'})do local name=stem..suffix;mesh[name]=nil;forbidden[name]=true end
          end
          setmetatable(mesh,{__index=function(_,key)
            if forbidden[key]then optionalTouched=optionalTouched+1;error('Forbidden stream access')end
          end})
        end
        ''')
        self.assertTrue(probe.startNormalImageTest()[0])
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(1000):
            probe.update(.001)
            if probe.getImageStatus().phase in ('complete','cancelled'):break
        status=probe.getImageStatus();self.assertEqual(status.phase,'complete',status.reason)
        self.assertEqual(status.profile,'normals');self.assertIn('normals-',status.file)
        self.assertEqual(status.totalPixels,24576);self.assertTrue(status.acceleratorMatchesReference)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
        self.assertEqual(lua.globals().optionalTouched,0)
        lua.execute('cars[42].x=999');self.assertEqual(probe.getImageStatus().phase,'cancelled')
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)

    def test_pair_cancellation_and_export_failure_do_not_leak_or_recapture(self):
        for failure in ('cancel-build','pose-change','export'):
            lua,probe=self.pair_runtime();self.assertTrue(probe.startImageTest()[0])
            lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true');probe.update(.001)
            if failure=='cancel-build':probe.stop()
            elif failure=='pose-change':lua.execute('cars[42].x=999');probe.update(.001)
            else:
                lua.execute('failBitmap=true')
                for _ in range(1000):
                    probe.update(.001)
                    if probe.getImageStatus().phase=='cancelled':break
            self.assertEqual(probe.getImageStatus().phase,'cancelled')
            self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
            probe.onExtensionUnloaded();self.assertEqual(lua.globals().freed,2)


if __name__=='__main__':unittest.main()
