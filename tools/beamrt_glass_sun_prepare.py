"""Prepare an opt-in private sunlight shader; never edit installed game files."""
import argparse
import hashlib
import json
from pathlib import Path
import re

NATIVE='shaders/common/lighting/advanced/vectorLightP.hlsl'
HELPER='shaders/beamrt/beamrtGlassSunHook.h.hlsl'
INSERT='    float Sat_NL_Att = saturate(dotNL * unshadowed) * lightBrightness * lastFrameExposure;'

def generate(source):
    source=source.replace('\r\n','\n')
    for token in (INSERT,'LightBufferOutput main(FarFrustumQuadConnectP IN)',
                  'const float3 worldPos = perspectiveDiv(mul(screenToWorldPos0, float4(posNdc, 1))).xyz;',
                  'unshadowed = sunShadowMaskTex.Load(', '    unshadowed *= cloudCookie;'):
        if source.count(token)!=1:raise ValueError('Unsupported native sunlight contract: '+token)
    if re.search(r'register\s*\(\s*[ts]14\s*\)|beamrtGlass|beamrtMeshSun',source):
        raise ValueError('Sunlight shader hook/slot14 already occupied')
    for name in ('farFrustumQuad.h.hlsl','farFrustumQuad.hlsl'):
        old='#include "'+name+'"'
        if source.count(old)!=1:raise ValueError('Unsupported native include layout')
        source=source.replace(old,'#include "shaders/common/lighting/advanced/'+name+'"')
    source=source.replace('LightBufferOutput main(FarFrustumQuadConnectP IN)',
        '#include "'+HELPER+'"\n\nLightBufferOutput main(FarFrustumQuadConnectP IN)')
    return source.replace(INSERT,
        '    // Additional glass extinction only: native body/scene/cloud shadows remain intact.\n'
        '    unshadowed *= beamrtGlassSunTransmission(IN.hpos, worldPos);\n'+INSERT)

def prepare(game_root,mod_root):
    game,mod=Path(game_root).resolve(),Path(mod_root).resolve()
    if game==mod or game in mod.parents or mod in game.parents:raise ValueError('Game/mod directories must not overlap')
    source=(game/NATIVE).read_text(encoding='utf8').replace('\r\n','\n')
    generated=generate(source)
    dependencies={}
    for name in ('farFrustumQuad.h.hlsl','farFrustumQuad.hlsl'):
        path='shaders/common/lighting/advanced/'+name
        text=(game/path).read_text(encoding='utf8').replace('\r\n','\n')
        if re.search(r'(?:uniform_sampler\w*\([^\n]*,\s*14\s*\)|register\s*\(\s*[ts]14\s*\))',text):
            raise ValueError('Native sunlight dependency occupies slot14')
        dependencies[path]=text
    dependencies[HELPER]=(mod/HELPER).read_text(encoding='utf8').replace('\r\n','\n')
    digest=hashlib.sha256((generated+dependencies[HELPER]).encode()).hexdigest()[:16]
    path='shaders/beamrt/generated/beamrtGlassVector_'+digest+'.hlsl'
    manifest=dict(schema='beamrt.glass.sun.v1',nativePath=NATIVE,nativeSource=source,
        shaderPath=path,generatedSource=generated,dependencies=dependencies,gpuExecutionVerified=False)
    folder=mod/'shaders/beamrt/generated';folder.mkdir(parents=True,exist_ok=True)
    (mod/path).write_text(generated,encoding='utf8')
    (folder/'glassSunHook.json').write_text(json.dumps(manifest),encoding='utf8')
    return manifest

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root',required=True)
    parser.add_argument('--mod-root',default=str(Path(__file__).resolve().parents[1]))
    args=parser.parse_args();m=prepare(args.game_root,args.mod_root)
    print(json.dumps({k:m[k]for k in ('schema','shaderPath','gpuExecutionVerified')},indent=2))

if __name__=='__main__':main()
