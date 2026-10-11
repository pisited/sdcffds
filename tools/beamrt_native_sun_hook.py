"""Prepare a private, reversible direct-sun hook from the installed shader.

Does not edit the game, activate anything, or redistribute native source.
Changes one direct-light visibility expression; original shadows, clouds,
BRDF, local lights, emissive and cubemap composition remain native.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

NATIVE = 'shaders/common/lighting/advanced/vectorLightP.hlsl'
INSERT = '    float Sat_NL_Att = saturate(dotNL * unshadowed) * lightBrightness * lastFrameExposure;'

def generate(source):
    source = source.replace('\r\n', '\n')
    for token in (INSERT, 'LightBufferOutput main(FarFrustumQuadConnectP IN)',
                  'const float3 worldPos = perspectiveDiv(mul(screenToWorldPos0, float4(posNdc, 1))).xyz;',
                  'unshadowed = sunShadowMaskTex.Load(int3(IN.hpos.xy, 0)).r;'):
        if source.count(token) != 1:
            raise ValueError('Unsupported native vector-light contract: '+token)
    if re.search(r'register\s*\(\s*[ts]14\s*\)|beamrtMeshSun', source):
        raise ValueError('Native shader already uses the hook name or slot14')
    for name in ('farFrustumQuad.h.hlsl', 'farFrustumQuad.hlsl'):
        old = '#include "'+name+'"'
        if source.count(old) != 1:
            raise ValueError('Unsupported include layout')
        source = source.replace(old, '#include "shaders/common/lighting/advanced/'+name+'"')
    source = source.replace('LightBufferOutput main(FarFrustumQuadConnectP IN)',
        '#include "shaders/beamrt/beamrtMeshSunHook.h.hlsl"\n\nLightBufferOutput main(FarFrustumQuadConnectP IN)')
    return source.replace(INSERT,
        '    // BEAMRT: retain native shadows; reject only additional definite mesh blockers.\n'
        '    // Thin/transmitting receiver shading remains native.\n'
        '    if (subsurfaceIntensity <= 0.0)\n'
        '        unshadowed = min(unshadowed, beamrtMeshSunFactor(IN.hpos, worldPos));\n\n'+INSERT)

def prepare(game_root, mod_root):
    game_root,mod_root=Path(game_root).resolve(),Path(mod_root).resolve()
    if game_root==mod_root or game_root in mod_root.parents or mod_root in game_root.parents:
        raise ValueError('Game and mod directories must not overlap')
    source=(game_root/NATIVE).read_text(encoding='utf-8').replace('\r\n','\n')
    generated=generate(source)
    # Includes are part of the compatibility contract; slot14 must stay unused.
    dependencies={}
    for path in ('shaders/common/lighting/advanced/farFrustumQuad.h.hlsl',
                 'shaders/common/lighting/advanced/farFrustumQuad.hlsl'):
        text=(game_root/path).read_text(encoding='utf-8').replace('\r\n','\n')
        if re.search(r'(?:uniform_sampler\w*\([^\n]*,\s*14\s*\)|register\s*\(\s*[ts]14\s*\))',text):
            raise ValueError('Native dependency already occupies slot14')
        dependencies[path]=text
    digest=hashlib.sha256(generated.encode()).hexdigest()[:16]
    folder=mod_root/'shaders/beamrt/generated';folder.mkdir(parents=True,exist_ok=True)
    shader=folder/('beamrtVectorLight_'+digest+'.hlsl')
    shader.write_text(generated,encoding='utf-8')
    manifest={'schema':'beamrt.native.sun.hook.v1','nativePath':NATIVE,
        'nativeSource':source,'dependencies':dependencies,
        'shaderPath':'shaders/beamrt/generated/'+shader.name,
        'generatedSource':generated,'gpuExecutionVerified':False}
    (folder/'nativeSunHook.json').write_text(json.dumps(manifest),encoding='utf-8')
    return manifest

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root',required=True)
    parser.add_argument('--mod-root',default=str(Path(__file__).resolve().parents[1]))
    args=parser.parse_args();result=prepare(args.game_root,args.mod_root)
    print(json.dumps({k:result[k] for k in ('schema','shaderPath','gpuExecutionVerified')},indent=2))

if __name__=='__main__':main()
