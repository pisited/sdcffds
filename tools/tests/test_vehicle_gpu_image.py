"""Image wire contract, publication and lifecycle; mock sockets are not GPU proof."""
import struct
import unittest
import test_vehicle_gpu_probe as probe_fixture
import test_vehicle_camera_reflection as camera_fixture
import test_vehicle_ray_image as image_fixture

NETWORK=r'''
cfg.schema='beamrt.gpu-image.v2';cfg.expires=os.time()+1800
jsonReadFile=function(path)assert(path=='/settings/beamrtGpuImageEndpoint.json');return cfg end
imageSocketsClosed=0;imageConnects=0;imageFailure=false;corruptImage=false
local ffi=require('ffi')
local function le(n)local t={};for j=1,4 do t[j]=string.char(n%256);n=math.floor(n/256)end;return table.concat(t)end
local function u(s,p)local a,b,c,d=s:byte(p,p+3);return a+b*256+c*65536+d*16777216 end
local function answer(data)
 local nt,nn,w,h=u(data,13),u(data,17),u(data,21),u(data,25)
 local tris=ffi.new('beamrt_gpu_triangle_v1[?]',nt);ffi.copy(tris,data:sub(65,64+nt*48),nt*48)
 local c=ffi.new('float[16]');ffi.copy(c,data:sub(65+nt*52+nn*16),64)
 local camera={right={},forward={},up={},position={0,0,0},near=tonumber(c[3]),far=tonumber(c[7]),
  left=tonumber(c[12]),rightEdge=tonumber(c[13]),top=tonumber(c[14]),bottom=tonumber(c[15])}
 for j=1,3 do camera.right[j]=tonumber(c[j-1]);camera.forward[j]=tonumber(c[j+3]);camera.up[j]=tonumber(c[j+7])end
 local pixels=ffi.new('beamrt_gpu_image_pixel_v1[?]',w*h)
 local kernel=require('ge/extensions/beamrt/geometryTriangleIntersection')
 local mirror=require('ge/extensions/beamrt/vehicleReflectionMask')
 local cam=require('ge/extensions/beamrt/vehicleCameraSnapshot')
 local function trace(origin,dir,far,excluded,out)
  out.owner=4294967295;out.reference=4294967295;out.distance=0;out.state=0
  local best,index,who,normal
  for i=0,nt-1 do
   local t=tris[i]
   if t.owner~=excluded then
    local tri={a={},b={},c={}};for j=1,3 do tri.a[j]=tonumber(t.a[j-1]);tri.b[j]=tonumber(t.b[j-1]);tri.c[j]=tonumber(t.c[j-1])end
    local d=kernel.segment(origin,dir,far,tri)
    if d and (not best or d<best)then
     best=d;index=i;who=tonumber(t.owner)
     local ax,ay,az=tri.b[1]-tri.a[1],tri.b[2]-tri.a[2],tri.b[3]-tri.a[3]
     local bx,by,bz=tri.c[1]-tri.a[1],tri.c[2]-tri.a[2],tri.c[3]-tri.a[3]
     normal={ay*bz-az*by,az*bx-ax*bz,ax*by-ay*bx};local n=0;for j=1,3 do n=n+normal[j]^2 end
     n=math.sqrt(n);for j=1,3 do normal[j]=normal[j]/n end
    end
   end
  end
  if best then out.owner=who;out.reference=index;out.distance=best;out.state=1 end
  return best,normal,who
 end
 for y=0,h-1 do for x=0,w-1 do
  local out=pixels[y*w+x];local origin,dir,far=cam.ray(camera,(x+.5)/w,(y+.5)/h)
  local d,n,who=trace(origin,dir,far,0,out.primary)
  local start={0,0,0};local reflected={1,0,0}
  if d then reflected=mirror.reflect(dir,n);for j=1,3 do start[j]=origin[j]+dir[j]*d+reflected[j]*.01 end end
  trace(start,reflected,.2,0,out.full);trace(start,reflected,.2,0,out.excluded)
  if d then trace(start,reflected,tonumber(c[11]),0,out.full);trace(start,reflected,tonumber(c[11]),3-who,out.excluded)end
 end end
 local linear=ffi.string(pixels,w*h*48)
 if corruptImage then pixels[0].primary.state=corruptImageState or 2 end
 return 'BRGIMO1\0'..le(2)..le(0)..le(w)..le(h)..le(1)..le(48)..cfg.token..ffi.string(pixels,w*h*48),linear
end
package.loaded.socket={gettime=function()return fakeNow end,tcp=function()
 local s={sent='',reply='',offset=1,closed=false,stage='image'}
 function s:settimeout(n)assert(n==0);return 1 end
 function s:connect(host,port)assert(host=='127.0.0.1'and port==cfg.port);imageConnects=imageConnects+1;return 1 end
 function s:getpeername()return '127.0.0.1'end
 function s:send(data,pos)
  if imageFailure then return nil,'closed',pos-1 end
  if self.stage=='image-replied'then self.stage='check';self.sent='';self.reply='';self.offset=1 end
  self.sent=self.sent..data:sub(pos)
  if self.stage=='image' and #self.sent>=64 and #self.sent==64+u(self.sent,29)then
   self.reply,self.linear=answer(self.sent);self.stage='image-replied'
  elseif self.stage=='check' and #self.sent>=64 and #self.sent==64+u(self.sent,13)*4 then
   local count,w,h=u(self.sent,13),u(self.sent,17),u(self.sent,21)
   local parts={'BRGCKO1\0'..le(2)..le(count)..le(w)..le(h)..le(1)..le(52)..cfg.token}
   for i=0,count-1 do local index=u(self.sent,65+i*4);parts[#parts+1]=le(index)..self.linear:sub(index*48+1,index*48+48)end
   self.reply=table.concat(parts);self.stage='done'
  end
  return #data
 end
 function s:receive(n)
  local last=math.min(#self.reply,self.offset+math.min(n,65536)-1)
  local data=self.reply:sub(self.offset,last);self.offset=last+1
  if #data==n then return data end;return nil,'timeout',data
 end
 function s:close()assert(not self.closed);self.closed=true;imageSocketsClosed=imageSocketsClosed+1;return 1 end
 return s
end}
'''


def load_image(lua):
    module=lua.execute((camera_fixture.bounce_fixture.bvh_fixture.MODULES/'vehicleGpuImage.lua').read_text())
    lua.globals().package.loaded['ge/extensions/beamrt/vehicleGpuImage']=module
    lua.globals().gpu_image=module
    return module


def runtime():
    lua=probe_fixture.runtime();load_image(lua);lua.execute(NETWORK);return lua


class VehicleGpuImage(unittest.TestCase):
    def test_full_image_publication_uses_corresponding_gpu_records_and_no_cpu_rays_on_wire(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        status=lua.globals().image.status(job);g=status.gpuImage
        self.assertEqual((status.width,status.height,status.viewCount),(256,128,4));self.assertEqual(status.pixelsRendered,32768)
        self.assertTrue(g.passed);self.assertEqual(g.pixelsMatched,8192)
        self.assertTrue(g.offscreenGeometryControlsPassed);self.assertGreater(g.offscreenHits,0)
        self.assertEqual(g.invalidPixels,0);self.assertTrue(g.gpuGeneratedPrimaryRays);self.assertTrue(g.gpuGeneratedReflectedRays)
        self.assertFalse(g.cpuRayInputsUploaded);self.assertFalse(g.gameIntegrationVerified);self.assertFalse(g.dxrUsed)
        self.assertEqual(lua.globals().imageSocketsClosed,1);self.assertIsNone(job.gpuImageExpected)
        for y in range(128):
            for x in range(128):
                cpu,gpu=job.pixels[y*256+x+1],job.pixels[y*256+x+129]
                self.assertEqual(tuple(cpu[j]for j in (1,2,3)),tuple(gpu[j]for j in (1,2,3)))
        g.mismatches[1]='tamper';self.assertEqual(len(lua.globals().image.status(job).gpuImage.mismatches),0)

    def test_invalid_gpu_pixel_is_visible_and_cannot_pass(self):
        lua=runtime();lua.execute('corruptImage=true');s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        self.assertEqual(job.gpuImage.phase,'mismatch');self.assertFalse(job.gpuImage.passed)
        self.assertEqual(job.gpuImage.invalidPixels,1);self.assertEqual(job.gpuImage.ownerDisagreements,1)
        self.assertEqual(tuple(job.pixels[129][j]for j in (1,2,3)),(175,85,220))

    def test_query_budget_exhaustion_is_explicit_incomplete_not_a_miss(self):
        lua=runtime();lua.execute('corruptImage=true;corruptImageState=3');s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        self.assertFalse(job.gpuImage.passed);self.assertEqual(job.gpuImage.incompletePixels,1)
        self.assertEqual(tuple(job.pixels[129][j]for j in (1,2,3)),(175,85,220))

    def test_packing_keeps_full_permutation_topology_and_camera_without_expected_data(self):
        lua=runtime();lua.execute('''
        db=bvh.build(scenes);snapshot=vehicleCameraSnapshot.capture()
        packet=gpu_image.pack(db,{41,42},snapshot,function()end,{},20)
        ''')
        p=lua.globals().packet
        self.assertEqual(p.triangleCount,2);self.assertEqual(p.nodeCount,1)
        self.assertEqual(p.topology[0].left,4294967295);self.assertEqual(p.topology[0].count,2)
        self.assertEqual({p.order[i]for i in range(2)},{0,1})
        self.assertAlmostEqual(p.camera[3],.1);self.assertEqual(p.camera[7],50);self.assertEqual(p.camera[11],20)
        data=probe_fixture.octets(lua,'gpu_image.header(packet,cfg)')
        self.assertEqual(data[:8],b'BRGIMG1\0');self.assertEqual(struct.unpack_from('<6I',data,8),(2,2,1,128,64,184))
        self.assertIsNone(p.comparisons);self.assertIsNone(p.expected)

    def test_image_endpoint_capability_is_distinct_from_ray_probe(self):
        lua=runtime();lua.execute("cfg.schema='beamrt.gpu-ray-probe.v1'")
        with self.assertRaisesRegex(Exception,'helper first'):lua.globals().gpu_image.preflight()
        self.assertEqual(lua.globals().imageConnects,0)

    def test_bad_image_reply_is_rejected_before_publication(self):
        lua=runtime();lua.execute('''
        cpu= gpu_image.expected(128*32)
        p={width=128,height=32,triangleCount=2};job={width=256,height=64}
        bad=string.rep('x',64+128*32*48)
        ''')
        with self.assertRaisesRegex(Exception,'reply identity'):
            lua.eval('gpu_image.publish(p,cfg,bad,cpu,job,{},function()end)')

    def test_missed_or_occluded_source_is_not_certified_offscreen_from_zero_primary_pixels(self):
        lua=runtime();lua.execute('cam.position={90,0,0};cam.forward={1,0,0};cam.right={0,-1,0}')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        self.assertTrue(job.gpuImage.passed);self.assertEqual(job.gpuImage.offscreenHits,0)
        self.assertFalse(job.gpuImage.offscreenGeometryControlsPassed)

    def test_missing_image_helper_refuses_before_request_and_camera_motion_closes_owned_socket(self):
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime()
        lua.globals().jsonReadFile=lua.eval('function()return nil end')
        self.assertFalse(p.startGpuImageTest()[0]);self.assertEqual(lua.globals().requests,0)
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime()
        lua.execute(probe_fixture.NETWORK);load_image(lua);lua.execute(NETWORK)
        self.assertTrue(p.startGpuImageTest()[0]);lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(4000):
            p.update(.001)
            if p.getImageStatus().phase=='gpu-sending':break
        self.assertEqual(p.getImageStatus().phase,'gpu-sending')
        lua.execute('cam.position[1]=104');p.update(.001)
        self.assertEqual(p.getGpuImageStatus().phase,'cancelled')
        self.assertEqual(lua.globals().freed,2);self.assertEqual(lua.globals().imageSocketsClosed,1)

    def test_gpu_linear_audit_supports_primitive_only_difference_without_changing_strict_cpu_failure(self):
        lua=runtime();lua.execute('''
        local record=gpu_image.record;injected=false
        gpu_image.record=function(e,index,...)
          record(e,index,...)
          if not injected and e[index].full.owner>0 then e[index].full.reference=(e[index].full.reference+1)%2;injected=true end
        end
        ''')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        g=job.gpuImage
        self.assertFalse(g.passed);self.assertEqual(g.phase,'mismatch');self.assertEqual(g.primitiveDisagreements,1)
        self.assertTrue(g.gpuLinearRecheckPassed);self.assertEqual(g.gpuLinearRecheckMatched,1)
        self.assertTrue(g.primitiveOnlyCpuDisagreement);self.assertTrue(g.gpuLinearRecheckCoversAllDisagreements)
        self.assertIsNone(job.gpuImageWitnesses);self.assertIsNone(job.gpuSocket)

    def test_gpu_linear_recheck_rejects_a_corrupt_accelerated_result(self):
        lua=runtime();lua.execute('corruptImage=true');s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        self.assertFalse(job.gpuImage.gpuLinearRecheckPassed);self.assertEqual(job.gpuImage.gpuLinearRecheckSamples,1)
        self.assertFalse(job.gpuImage.primitiveOnlyCpuDisagreement);self.assertFalse(job.gpuImage.passed)

    def test_bounded_audit_cannot_certify_disagreements_beyond_its_eight_pixel_budget(self):
        lua=runtime();lua.execute('''
        local record=gpu_image.record;injected=0
        gpu_image.record=function(e,index,...)
          record(e,index,...)
          if injected<9 and e[index].primary.owner>0 then
            e[index].primary.reference=(e[index].primary.reference+1)%2;injected=injected+1
          end
        end
        ''')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        g=job.gpuImage
        self.assertEqual(lua.globals().injected,9);self.assertEqual(g.primitiveDisagreements,9)
        self.assertEqual(g.gpuLinearRecheckSamples,8);self.assertTrue(g.gpuLinearRecheckPassed)
        self.assertFalse(g.gpuLinearRecheckCoversAllDisagreements);self.assertFalse(g.primitiveOnlyCpuDisagreement)
        self.assertFalse(g.passed);self.assertIsNone(job.gpuImageWitnesses)

    def test_recheck_reply_requires_session_identity_and_corresponding_pixel_index(self):
        lua=runtime();lua.execute('''
        p={width=128,height=32};auditJob={gpuImageWitnesses={{index=3,bytes=string.rep('x',48)}}}
        local le=require('ge/extensions/beamrt/vehicleGpuProbe').encodeU32
        check='BRGCKO1\\0'..le(2)..le(1)..le(128)..le(32)..le(1)..le(52)..cfg.token..le(4)..string.rep('x',48)
        wrongSession=check:sub(1,32)..string.rep('z',32)..check:sub(65)
        ''')
        with self.assertRaisesRegex(Exception,'identity/size'):
            lua.eval('gpu_image.acceptRecheck(p,cfg,wrongSession,auditJob,{})')
        with self.assertRaisesRegex(Exception,'pixel mismatch'):
            lua.eval('gpu_image.acceptRecheck(p,cfg,check,auditJob,{})')

    def test_publication_clears_expected_buffers_and_quad_bitmap_uses_actual_right_column(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',s,lua.globals().gpu_image.preflight()))
        self.assertIsNone(job.gpuImageExpected)
        lua.globals().job=job
        get=lua.eval('function(a,b)local s=image.bitmap(job);return {string.byte(s,a,b)}end')
        size=54+job.width*job.height*3;data=bytearray()
        for start in range(1,size+1,4096):data.extend(get(start,min(size,start+4095)).values())
        self.assertEqual(struct.unpack_from('<ii',data,18),(256,128))
        for x,y in ((64,32),(192,32),(64,96),(192,96)):
            offset=54+(127-y)*768+x*3;b,g,r=data[offset:offset+3]
            self.assertEqual((r,g,b),tuple(job.pixels[y*256+x+1][j]for j in (1,2,3)))

    def test_controller_completion_native_ownership_and_failed_readback_summary(self):
        for fail in (False,True):
            lua,p=camera_fixture.VehicleCameraReflection().pair_runtime()
            lua.execute(probe_fixture.NETWORK)
            # Preload factories refresh this stateless module on start.
            load_image(lua);lua.execute(NETWORK);lua.globals().imageFailure=fail
            self.assertTrue(p.startGpuImageTest()[0])
            lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
            for _ in range(4000):
                p.update(.001)
                if p.getImageStatus().phase in ('complete','cancelled'):break
            s=p.getGpuImageStatus()
            if fail:
                self.assertEqual(s.phase,'cancelled');self.assertEqual(s.gpu.phase,'cancelled')
                self.assertFalse(s.gpu.passed);self.assertIn('disconnected',s.reason)
            else:
                self.assertEqual(s.phase,'complete',s.reason);self.assertTrue(s.gpu.passed)
                self.assertIn('camera-gpu-image-',s.file)
            self.assertEqual(lua.globals().freed,2);self.assertEqual(lua.globals().imageSocketsClosed,1)


if __name__=='__main__':unittest.main()
