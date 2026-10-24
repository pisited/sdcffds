"""Explicit hardware test of Lua wire packing -> real separate-process GPU host.

Uses synthetic planes only. No BeamNG launch, hooks or proprietary mesh export.
"""
import json
import socket
import subprocess
import time
from pathlib import Path
import test_vehicle_gpu_probe as fixture

ROOT=Path(__file__).resolve().parents[2]


def main():
    folder=ROOT/'.beamrt-validation/vehicle-gpu-probe'
    config=folder/'transport-test-endpoint.json'
    # A fresh unique filename avoids interpreting a prior helper's endpoint.
    config=folder/('transport-test-endpoint-'+str(time.time_ns())+'.json')
    process=subprocess.Popen([str(folder/'beamrt_vehicle_gpu_probe.exe'),str(folder/'trace.cso'),str(config)],
                             stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                             creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        deadline=time.monotonic()+15
        while not config.exists():
            if process.poll() is not None:raise RuntimeError(process.communicate())
            if time.monotonic()>deadline:raise TimeoutError('Helper startup timed out')
            time.sleep(.05)
        endpoint=json.loads(config.read_text())
        lua=fixture.runtime();lua.globals().cfg.token=endpoint['token']
        lua.execute('''
        ffi=require('ffi');db=bvh.build(scenes);control=rays.create(scenes,poses);snap=vehicleCameraSnapshot.capture()
        local origin={103,0,0};local direction={-1,0,0}
        local hit=bvh.trace(db,origin,direction,50)
        casts={bounce.cast(db,hit,origin,direction,20,42)}
        packet=gpu.pack(db,{41,42},snap,casts,control,function()end,{},vehicleOffscreenGeometry.capture(db,{41,42},snap))
        ''')
        packet=(fixture.octets(lua,'gpu.header(packet,cfg)')+
                fixture.octets(lua,'ffi.string(packet.triangles,packet.triangleCount*48)')+
                fixture.octets(lua,'ffi.string(packet.rays,packet.rayCount*32)'))
        # An unauthenticated client must not consume the one valid job.
        with socket.create_connection(('127.0.0.1',endpoint['port']),5)as wrong:
            wrong.sendall(packet[:32]+b'0'*32)
        with socket.create_connection(('127.0.0.1',endpoint['port']),5)as peer:
            peer.settimeout(15)
            for i in range(0,len(packet),17):peer.sendall(packet[i:i+17])
            response=b'';needed=64+lua.globals().packet.rayCount*16
            while len(response)<needed:
                chunk=peer.recv(needed-len(response))
                if not chunk:raise EOFError('Incomplete hardware reply')
                response+=chunk
        result=lua.globals().gpu.compare(lua.globals().packet,lua.globals().cfg,response)
        assert result.passed and result.hardwareExecutionVerified
        assert result.offscreenGeometryComparisonPassed and result.offscreenRaysMatched>0
        out,err=process.communicate(timeout=15)
        assert process.returncode==0,(out,err)
        print(out.strip())
        summary={'scope':'synthetic Lua-to-isolated-GPU transport only','raysMatched':result.matched,
                 'offscreenRaysMatched':result.offscreenRaysMatched,'hardwareExecutionVerified':True,
                 'invalidSessionRejected':True,'gameIntegrationVerified':False}
        (folder/'transport-test-result.json').write_text(json.dumps(summary,indent=2))
        print(json.dumps(summary))
    finally:
        if process.poll()is None:
            process.terminate();process.communicate(timeout=10)


if __name__=='__main__':main()
