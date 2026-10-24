"""Protocol, float packing and lifecycle; fake sockets are not GPU evidence."""
import struct
import unittest
import test_vehicle_camera_reflection as camera_fixture
import test_vehicle_ray_image as image_fixture

NETWORK=r'''
cfg={schema='beamrt.gpu-ray-probe.v1',host='127.0.0.1',port=43210,
 expires=os.time()+600,hardware=true,token=string.rep('a',32)}
jsonReadFile=function(path)assert(path=='/settings/beamrtGpuProbeEndpoint.json');return cfg end
closedSockets=0;connectedSockets=0;fakeNow=0;socketFailure=false;wrongReply=false;partialLimit=37
local ffi=require('ffi')
local function le(n)local s={};for j=1,4 do s[j]=string.char(n%256);n=math.floor(n/256)end;return table.concat(s)end
local function u(s,p)local a,b,c,d=s:byte(p,p+3);return a+b*256+c*65536+d*16777216 end
local function answer(data)
 local nt,nr=u(data,13),u(data,17)
 local tris=ffi.new('beamrt_gpu_triangle_v1[?]',nt);ffi.copy(tris,data:sub(65,64+nt*48),nt*48)
 local rays=ffi.new('beamrt_gpu_ray_v1[?]',nr);ffi.copy(rays,data:sub(65+nt*48),nr*32)
 local out={'BRGOUT1\0'..le(1)..le(0)..le(nt)..le(nr)..le(1)..le(16)..cfg.token}
 local kernel=require('ge/extensions/beamrt/geometryTriangleIntersection')
 for ri=0,nr-1 do
  local r=rays[ri];local best,index,who
  local origin={tonumber(r.origin[0]),tonumber(r.origin[1]),tonumber(r.origin[2])}
  local direction={tonumber(r.direction[0]),tonumber(r.direction[1]),tonumber(r.direction[2])}
  for ti=0,nt-1 do
   local t=tris[ti]
   if t.owner~=r.excluded then
    local tri={a={},b={},c={}}
    for j=1,3 do tri.a[j]=tonumber(t.a[j-1]);tri.b[j]=tonumber(t.b[j-1]);tri.c[j]=tonumber(t.c[j-1])end
    local d=kernel.segment(origin,direction,tonumber(r.reach),tri)
    if d and (not best or d<best)then best=d;index=ti;who=tonumber(t.owner)end
   end
  end
  local distance=ffi.new('float[1]',best or 0)
  out[#out+1]=le(who or 4294967295)..le(index or 4294967295)..ffi.string(distance,4)..le(best and 1 or 0)
 end
 local response=table.concat(out)
 if wrongReply then response=response:sub(1,64)..le(99)..response:sub(69)end
 return response
end
local function tcp()
 local sock={sent='',reply='',offset=1,closed=false,polls=0}
 function sock:settimeout(n)assert(n==0);return 1 end
 function sock:connect(host,port)assert(host=='127.0.0.1'and port==cfg.port);connectedSockets=connectedSockets+1;return nil,'timeout'end
 function sock:getpeername()self.polls=self.polls+1;if self.polls>=2 then return '127.0.0.1'end end
 function sock:send(data,start)
  if socketFailure then return nil,'closed',start-1 end
  local last=math.min(#data,start+partialLimit-1)
  self.sent=self.sent..data:sub(start,last)
  if #self.sent>=64 and #self.sent==64+u(self.sent,29)then self.reply=answer(self.sent)end
  if last<#data then return nil,'timeout',last end;return last
 end
 function sock:receive(n)
  local last=math.min(#self.reply,self.offset+math.min(n,partialLimit)-1)
  local data=self.reply:sub(self.offset,last);self.offset=last+1
  if #data==n then return data end;return nil,'timeout',data
 end
 function sock:close()assert(not self.closed);self.closed=true;closedSockets=closedSockets+1;return 1 end
 return sock
end
package.loaded.socket={tcp=tcp,gettime=function()return fakeNow end}
'''


def runtime():
    lua=camera_fixture.runtime()
    m=lua.execute((camera_fixture.bounce_fixture.bvh_fixture.MODULES/'vehicleGpuProbe.lua').read_text())
    lua.globals().package.loaded['ge/extensions/beamrt/vehicleGpuProbe']=m;lua.globals().gpu=m
    lua.execute(NETWORK)
    return lua


def octets(lua,expression):
    return bytes(lua.eval('function()local s='+expression+';return {string.byte(s,1,#s)}end')().values())


class VehicleGpuProbe(unittest.TestCase):
    def test_preflight_accepts_only_fresh_hardware_loopback_and_never_connects(self):
        for mutation in ('cfg=nil',"cfg.host='192.168.1.2'",'cfg.port=80','cfg.hardware=false',
                         "cfg.token='bad'",'cfg.expires=os.time()-1','cfg.expires=os.time()+10000'):
            lua=runtime();lua.execute(mutation)
            with self.assertRaises(Exception):lua.globals().gpu.preflight()
            self.assertEqual(lua.globals().connectedSockets,0)
        lua=runtime();endpoint=lua.globals().gpu.preflight()
        self.assertEqual(endpoint.host,'127.0.0.1');self.assertEqual(lua.globals().connectedSockets,0)

    def test_partial_network_full_geometry_comparison_and_independent_scope(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu',s,lua.globals().gpu.preflight()))
        status=lua.globals().image.status(job);g=status.gpuProbe
        self.assertEqual(g.phase,'passed');self.assertTrue(g.passed)
        self.assertTrue(g.hardwareExecutionVerified) # fake protocol flag only
        self.assertEqual(g.triangles,2);self.assertEqual(g.trianglesPacked,2)
        self.assertEqual(g.matched,g.rays);self.assertGreaterEqual(g.rays,8);self.assertLessEqual(g.rays,20)
        self.assertEqual(g.bytesSent,g.packetBytes)
        self.assertFalse(g.gameIntegrationVerified);self.assertFalse(g.dxrUsed)
        self.assertTrue(status.offscreenGeometryControlsPassed)
        self.assertTrue(g.offscreenGeometryComparisonPassed);self.assertGreater(g.offscreenRaysMatched,0)
        self.assertFalse(status.gpuExecutionVerified);self.assertEqual(lua.globals().closedSockets,1)
        self.assertIsNone(job.gpuSocket);self.assertIsNone(job.co)
        g.mismatches[1]='tamper';self.assertEqual(len(lua.globals().image.status(job).gpuProbe.mismatches),0)

    def test_wrong_gpu_nearest_identity_is_reported_as_mismatch_not_success(self):
        lua=runtime();lua.execute('wrongReply=true');s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu',s,lua.globals().gpu.preflight()))
        g=job.gpuProbe
        self.assertEqual(g.phase,'mismatch');self.assertFalse(g.passed)
        self.assertGreater(len(g.mismatches),0);self.assertEqual(g.mismatches[1].ray,1)
        self.assertEqual(lua.globals().closedSockets,1)

    def test_transfer_never_depends_on_cast_pointer_arithmetic(self):
        lua=runtime();lua.execute('''
        local ffi=require('ffi')
        ffi.cast=function()error('BeamNG byte-pointer addition path is unavailable')end
        ''')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu',s,lua.globals().gpu.preflight()))
        self.assertTrue(job.gpuProbe.passed);self.assertEqual(job.gpuProbe.bytesSent,job.gpuProbe.packetBytes)

    def test_multi_chunk_owned_array_transfer_preserves_all_triangle_bytes(self):
        lua=runtime();lua.execute('''
        partialLimit=65536
        for _,s in ipairs(scenes)do
          local r=s.ranges[1];r.count=3300;s.triangles=1100
          local indices={};for i=0,3299 do indices[i]=i%3 end
          r.buffers={vertices=r.buffers.vertices,indices=indices}
        end
        require('ffi').cast=function()error('Pointer arithmetic path must stay unused')end
        ''')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu',s,lua.globals().gpu.preflight()))
        self.assertEqual(job.gpuProbe.triangles,2200);self.assertGreater(job.gpuProbe.packetBytes,65536)
        self.assertTrue(job.gpuProbe.passed);self.assertEqual(job.gpuProbe.bytesSent,job.gpuProbe.packetBytes)

    def test_packet_uses_all_references_rebased_float_arrays_and_exclusion_ids(self):
        lua=runtime();lua.execute('''
        db=bvh.build(scenes);control=rays.create(scenes,poses);snap=vehicleCameraSnapshot.capture()
        local origin={98,0,0};local direction={-1,0,0}
        local hit=bvh.trace(db,origin,direction,2,42)
        casts={bounce.cast(db,hit,origin,direction,20,42)}
        packet=gpu.pack(db,{41,42},snap,casts,control,function()end,{})
        ''')
        packet=lua.globals().packet
        self.assertEqual(packet.triangleCount,2);self.assertEqual(packet.rayCount,6)
        self.assertEqual(packet.triangles[0].owner,1);self.assertEqual(packet.triangles[1].owner,2)
        self.assertEqual(packet.triangles[1].reference,1)
        self.assertAlmostEqual(packet.triangles[0].a[0],-6)
        self.assertEqual(packet.rays[5].excluded,2)
        header=octets(lua,'gpu.header(packet,gpu.preflight())')
        self.assertEqual(len(header),64);self.assertEqual(header[:8],b'BRGIN01\0')
        self.assertEqual(struct.unpack_from('<6I',header,8),(1,2,6,48,32,288))

    def test_bad_reply_session_counts_hardware_and_truncation_are_rejected(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        # Exercise the production reply parser directly with a minimal known
        # packet. No server receives the CPU expected answer in the wire format.
        lua.execute('''
        p={triangleCount=1,rayCount=1,comparisons={{owner=0,distance=0,label='known-miss'}}}
        local function le(n)local t={};for i=1,4 do t[i]=string.char(n%256);n=math.floor(n/256)end;return table.concat(t)end
        reply='BRGOUT1\0'..le(1)..le(0)..le(1)..le(1)..le(1)..le(16)..cfg.token
          ..le(4294967295)..le(4294967295)..le(0)..le(0)
        ''')
        self.assertTrue(lua.eval('gpu.compare(p,cfg,reply).passed'))
        for expression in ('reply:sub(1,79)',"'XXXXXXXX'..reply:sub(9)",
                           "reply:sub(1,24)..string.rep('\\0',4)..reply:sub(29)",
                           "reply:sub(1,32)..string.rep('b',32)..reply:sub(65)"):
            with self.assertRaises(Exception):lua.eval('gpu.compare(p,cfg,'+expression+')')

    def test_controller_refuses_missing_helper_before_any_native_mesh_request(self):
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime()
        lua.globals().jsonReadFile=lua.eval('function()return nil end')
        ok,why=p.startGpuReflectionProbe();self.assertFalse(ok);self.assertIn('helper first',why)
        self.assertEqual(lua.globals().requests,0);self.assertEqual(lua.globals().freed,0)

    def test_controller_frees_both_native_handles_before_socket_and_cancel_closes_once(self):
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime();lua.execute(NETWORK)
        lua.execute('''
        local tcp=package.loaded.socket.tcp
        package.loaded.socket.tcp=function()assert(freed==2);return tcp()end
        ''')
        self.assertTrue(p.startGpuReflectionProbe()[0])
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(4000):
            p.update(.001)
            if p.getImageStatus().phase=='gpu-sending':break
        self.assertEqual(p.getImageStatus().phase,'gpu-sending')
        self.assertEqual(lua.globals().freed,2);self.assertEqual(lua.globals().connectedSockets,1)
        p.stop();self.assertEqual(lua.globals().closedSockets,1)
        p.stop();self.assertEqual(lua.globals().closedSockets,1);self.assertEqual(lua.globals().freed,2)

    def test_controller_saves_completed_gpu_receipt_and_socket_failure_releases_ownership(self):
        for fail in (False,True):
            lua,p=camera_fixture.VehicleCameraReflection().pair_runtime();lua.execute(NETWORK)
            lua.globals().socketFailure=fail
            self.assertTrue(p.startGpuReflectionProbe()[0])
            lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
            for _ in range(4000):
                p.update(.001)
                if p.getImageStatus().phase in ('complete','cancelled'):break
            s=p.getGpuStatus()
            if fail:
                self.assertEqual(s.phase,'cancelled');self.assertIn('disconnected',s.reason)
                self.assertEqual(s.gpu.phase,'cancelled');self.assertFalse(s.gpu.passed)
                self.assertGreater(s.gpu.trianglesPacked,0)
                s.gpu.trianglesPacked=0
                self.assertGreater(p.getGpuStatus().gpu.trianglesPacked,0)
            else:
                self.assertEqual(s.phase,'complete',s.reason);self.assertEqual(s.gpu.phase,'passed')
                self.assertIn('camera-gpu-',s.file);self.assertEqual(s.gpu.matched,s.gpu.rays)
                self.assertTrue(s.gpu.offscreenGeometryComparisonPassed)
                self.assertFalse(s.gameIntegrationVerified)
            self.assertEqual(lua.globals().freed,2);self.assertEqual(lua.globals().closedSockets,1)

    def test_failed_transfer_keeps_a_visible_error_panel_and_hides_on_request(self):
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime();lua.execute(NETWORK)
        lua.execute('''
        socketFailure=true;labels={}
        ui_imgui={Cond_FirstUseEver=1,ImVec2=function(x,y)return {x=x,y=y}end,
          SetNextWindowSize=function()end,Begin=function()return true end,End=function()end,
          TextUnformatted=function(s)labels[#labels+1]=s end}
        ''')
        self.assertTrue(p.startGpuReflectionProbe()[0])
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(4000):
            p.update(.001)
            if p.getImageStatus().phase=='cancelled':break
        p.onUpdate(.001)
        self.assertIn('Diagnostic stopped before completion.',list(lua.globals().labels.values()))
        self.assertTrue(any('disconnected' in s for s in lua.globals().labels.values()))
        lua.execute('labels={}')
        p.hideImage();p.onUpdate(.001)
        self.assertEqual(len(lua.globals().labels),0)


if __name__=='__main__':unittest.main()
