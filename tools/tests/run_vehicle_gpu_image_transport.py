"""Explicit hardware test: Lua BVH/camera packet -> GPU-generated image -> CPU comparison."""
import json
import socket
import struct
import subprocess
import time
import zlib
from pathlib import Path
import test_vehicle_gpu_image as fixture
import test_vehicle_gpu_probe as probe_fixture
import test_vehicle_ray_image as image_fixture

ROOT=Path(__file__).resolve().parents[2]


def run_case(synthetic_disagreement=False):
    folder=ROOT/'.beamrt-validation/vehicle-gpu-image'
    config=folder/('transport-'+str(time.time_ns())+'.json')
    process=subprocess.Popen([str(folder/'beamrt_vehicle_gpu_image.exe'),str(folder/'image.cso'),str(config)],
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline=time.monotonic()+15
        while not config.exists():
            if process.poll()is not None:raise RuntimeError(process.communicate())
            if time.monotonic()>deadline:raise TimeoutError('Image helper startup timed out')
            time.sleep(.05)
        endpoint=json.loads(config.read_text())
        lua=fixture.runtime();lua.globals().cfg.token=endpoint['token']
        lua.execute('''
        ffi=require('ffi');cam.height=680;view.viewPort.extent.y=680
        gpu_image.run=function(db,ids,snapshot,work,job,endpoint)
          imageStats={phase='packed',triangles=db.count,trianglesPacked=0,nodes=db.nodeCount,nodesPacked=0,bytesSent=0}
          imagePacket=gpu_image.pack(db,ids,snapshot,work,imageStats,job.bounce.bounceMaxDistance)
        end
        ''')
        snapshot=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-gpu-image',snapshot,lua.globals().cfg))
        p=lua.globals().imagePacket
        lua.globals().transportJob=job
        if synthetic_disagreement:
            # A negative control for the audit path, never live vehicle evidence.
            lua.execute('''
            local e=transportJob.gpuImageExpected
            for i=0,imagePacket.width*imagePacket.height-1 do
              if e[i].full.owner>0 then e[i].full.reference=(e[i].full.reference+1)%imagePacket.triangleCount;break end
            end
            ''')
        packet=(probe_fixture.octets(lua,'gpu_image.header(imagePacket,cfg)')+
                probe_fixture.octets(lua,'ffi.string(imagePacket.triangles,imagePacket.triangleCount*48)')+
                probe_fixture.octets(lua,'ffi.string(imagePacket.topology,imagePacket.nodeCount*16)')+
                probe_fixture.octets(lua,'ffi.string(imagePacket.order,imagePacket.triangleCount*4)')+
                probe_fixture.octets(lua,'ffi.string(imagePacket.camera,64)'))
        with socket.create_connection(('127.0.0.1',endpoint['port']),5)as wrong:wrong.sendall(packet[:32]+b'0'*32)
        with socket.create_connection(('127.0.0.1',endpoint['port']),5)as peer:
            peer.settimeout(30)
            for i in range(0,len(packet),19):peer.sendall(packet[i:i+19])
            response=b'';needed=64+p.width*p.height*48
            while len(response)<needed:
                chunk=peer.recv(needed-len(response))
                if not chunk:raise EOFError('Incomplete GPU image readback')
                response+=chunk
            stats=lua.globals().imageStats
            lua.globals().gpu_image.publish(p,lua.globals().cfg,response,job.gpuImageExpected,job,stats,lua.eval('function()end'))
            lua.execute('checkHeader,checkIndices,checkCount=gpu_image.checkRequest(imagePacket,cfg,transportJob)')
            check_packet=(probe_fixture.octets(lua,'checkHeader')+
                          probe_fixture.octets(lua,'ffi.string(checkIndices,checkCount*4)'))
            peer.sendall(check_packet)
            checked=b'';check_needed=64+int(lua.globals().checkCount)*52
            while len(checked)<check_needed:
                chunk=peer.recv(check_needed-len(checked))
                if not chunk:raise EOFError('Incomplete GPU full-scan recheck')
                checked+=chunk
            lua.globals().gpu_image.acceptRecheck(p,lua.globals().cfg,checked,job,stats)
        assert stats.invalidPixels==0
        if synthetic_disagreement:
            assert not stats.passed and stats.primitiveDisagreements==1 and stats.phase=='mismatch'
            assert stats.gpuLinearRecheckSamples==1 and stats.gpuLinearRecheckMatched==1
            assert stats.gpuLinearRecheckBitExact==1 and stats.primitiveOnlyCpuDisagreement
        else:
            assert stats.passed,{'owners':stats.ownerDisagreements,'references':stats.primitiveDisagreements,'distances':stats.distanceDisagreements}
            assert stats.offscreenGeometryControlsPassed and stats.gpuLinearRecheckSamples==0
        out,err=process.communicate(timeout=15);assert process.returncode==0,(out,err);print(out.strip())
        summary={'scope':'synthetic GPU-generated image compared with independent CPU rays',
                 'pixelsCompared':stats.pixels,'pixelsMatched':stats.pixelsMatched,'offscreenHits':stats.offscreenHits,
                 'invalidPixels':stats.invalidPixels,'hardwareExecutionVerified':True,'gameIntegrationVerified':False,
                 'syntheticExpectedReferenceChanged':synthetic_disagreement,'strictPassed':stats.passed,
                 'gpuLinearRecheckSamples':stats.gpuLinearRecheckSamples,'gpuLinearRecheckBitExact':stats.gpuLinearRecheckBitExact}
        result_name='transport-audit-negative-control.json' if synthetic_disagreement else 'transport-result.json'
        (folder/result_name).write_text(json.dumps(summary,indent=2))
        # Native hardware readback is now the right column; CPU reference is left.
        raw=b''.join(b'\0'+bytes(int(job.pixels[y*job.width+x+1][j])for x in range(job.width)for j in (1,2,3))for y in range(job.height))
        def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
        png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',job.width,job.height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
        if not synthetic_disagreement:(folder/'synthetic-cpu-gpu-image.png').write_bytes(png)
        print(json.dumps(summary))
    finally:
        if process.poll()is None:process.terminate();process.communicate(timeout=10)


if __name__=='__main__':
    run_case()
    run_case(synthetic_disagreement=True)
