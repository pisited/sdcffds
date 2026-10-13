"""Strict FXC integration build using actual imported descriptor layouts.

Generates ignored compiler fixtures, never enables rendering or declares real
materials opaque. Identity instance/mode constants are compile-only fixtures.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[2]

def fixture_defines(gpu):
    values={'meshOrigin':'float3(0,0,0)','meshInvX':'float3(1,0,0)',
      'meshInvY':'float3(0,1,0)','meshInvZ':'float3(0,0,1)',
      'meshVisibilityEnabled':'1','meshMaterialPolicyEnabled':'1'}
    for name,key in (('meshQuantMin','quantMin'),('meshQuantExtent','quantExtent')):
        values[name]='float3('+','.join(str(x)for x in gpu[key])+')'
    values['meshAtlasSize']='float2('+str(gpu['width'])+','+str(gpu['height'])+')'
    for name,key in (('meshNodeCount','nodeCount'),('meshTriangleCount','triangleCount'),('meshTriangleOffset','triangleOffset')):
        values[name]=str(gpu[key])
    for bank in range(4):values['meshMaterialModes'+str(bank)]='float4(1,1,1,1)'
    return values

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root',required=True);parser.add_argument('--compiler',required=True)
    args=parser.parse_args()
    registry=json.loads((ROOT/'art/beamrt/alignment/wcu_underground_registry.json').read_text())
    manifest=json.loads((ROOT/'shaders/beamrt/generated/nativeLocalHooks.json').read_text())
    output=ROOT/'.beamrt-validation/local-mesh/compiled';output.mkdir(parents=True,exist_ok=True)
    defines=fixture_defines(max(registry['assets'],key=lambda a:a['gpuData']['triangleCount'])['gpuData'])
    count=0
    for kind,hook in manifest['lights'].items():
        fixture=output/(kind+'.fixture.hlsl')
        fixture.write_text('\n'.join('#define '+name+' '+value for name,value in defines.items())+
                           '\n#include "'+hook['shaderPath']+'"\n')
        # Point cube/paraboloid, cookie and native no-shadow permutations;
        # Spot uses a 2D shadow map and includes forward/reversed depth.
        for bits in range(16 if kind=='Point'else 8):
            macros=[]
            if bits&1:macros.append('NO_SHADOW=1')
            if bits&2:macros.append('USE_COOKIE_TEX=1')
            if bits&4:macros.append('BNG_USE_REVERSED_DEPTH_BUFFER=1')
            if kind=='Point'and bits&8:macros.append('SHADOW_CUBE=1')
            cmd=[args.compiler,'/nologo','/Ges','/WX','/O3','/T','ps_5_0','/E','main',
              '/I',str(ROOT),'/I',args.game_root,'/I',str(Path(args.game_root)/'shaders/common/lighting/advanced'),
              '/Fo',str(output/(kind+str(bits)+'.ps.bin'))]
            for macro in macros:cmd+=['/D',macro]
            result=subprocess.run(cmd+[str(fixture)],capture_output=True,text=True)
            if result.returncode:raise RuntimeError(result.stdout+result.stderr)
            count+=1
    print('PASS: '+str(count)+' native local-light pixel permutations with real descriptor sizes')

if __name__=='__main__':main()
