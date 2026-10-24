"""Compile instrumented native PS permutations; no live game activation."""
import argparse
import json
from pathlib import Path
import subprocess
import uuid
ROOT=Path(__file__).resolve().parents[2]
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--game-root',required=True);p.add_argument('--compiler',required=True)
    a=p.parse_args();m=json.loads((ROOT/'shaders/beamrt/generated/nativeVisibility.json').read_text())
    out=ROOT/'.beamrt-validation'/('native-shadow-compile-'+uuid.uuid4().hex);out.mkdir(parents=True)
    count=0
    for kind,hook in m['lights'].items():
      for probe in range(3):
        for bits in range(32 if kind=='Point'else 16):
            macros=['BEAMRT_NATIVE_POSITION=float3(1,2,3)','BEAMRT_NATIVE_DIRECTION=float3(0,0,-1)',
                    'BEAMRT_NATIVE_RANGE=45','BEAMRT_NATIVE_OUTER=0.2588190451','BEAMRT_NATIVE_PROBE='+str(probe)]
            for flag,name in ((1,'NO_SHADOW'),(2,'USE_COOKIE_TEX'),(4,'BNG_USE_REVERSED_DEPTH_BUFFER'),(8,'BNG_LIGHTING_1_5')):
                if bits&flag:macros.append(name+'=1')
            if kind=='Point'and bits&16:macros.append('SHADOW_CUBE=1')
            cmd=[a.compiler,'/nologo','/Ges','/WX','/O3','/T','ps_5_0','/E','main','/I',str(ROOT),'/I',a.game_root,
                 '/I',str(Path(a.game_root)/'shaders/common/lighting/advanced'),'/Fo',str(out/(kind+'p'+str(probe)+'b'+str(bits)+'.cso'))]
            for macro in macros:cmd+=['/D',macro]
            r=subprocess.run(cmd+[str(ROOT/hook['shaderPath'])],capture_output=True,text=True,timeout=60)
            if r.returncode:raise RuntimeError(kind+str(bits)+'\n'+r.stdout+r.stderr)
            count+=1
    print('PASS: '+str(count)+' native PS permutations; no game execution. Artifacts: '+str(out))
