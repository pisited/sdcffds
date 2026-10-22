"""Prepare private native PS instrumentation. Never edit or activate game files.

Preserves native visibility/BRDF math. Diagnostic ONLY uses lightinfo RT1 alpha,
which the pinned installed 1.5 conditioner writes zero and consumer ignores.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

BASE='shaders/common/lighting/advanced/'
HELPER='shaders/beamrt/beamrtNativeShadowRelay.h.hlsl'
DEPENDENCIES=(BASE+'convexGeometry.h.hlsl',BASE+'softShadow.hlsl',BASE+'lightingUtils.hlsl',
              BASE+'farFrustumQuad.hlsl','shaders/common/lightingStruct.h.hlsl',
              'shaders/common/lighting.hlsl','shaders/common/bng.hlsl')

def generate(source,kind):
    if kind not in ('Point','Spot'):raise ValueError('Unsupported native light kind')
    source=source.replace('\r\n','\n')
    tokens=['#include "convexGeometry.h.hlsl"','float4 lightColorMod = cb.lightColor;',
            'float shadowed = 1.0;', 'return outData;',
            'lightinfoCondition(outData, lightColorOut * irradiance * retroMul, irradiance, specular, 0);']
    for token in tokens:
        if source.count(token)!=1:raise ValueError('Native light contract changed: '+token)
    if 'cb.worldToLightProj'not in source:raise ValueError('Native light projection missing')
    if re.search(r'beamrtNative|register\s*\(\s*[ts]14\s*\)',source):raise ValueError('Hook already occupied')
    # Capture the actual filtered native visibility before optional lightmap logic.
    source=source.replace('float4 lightColorMod = cb.lightColor;',
        'float beamrtNativeVisibility = shadowed;\n    float4 lightColorMod = cb.lightColor;')
    source=source.replace('#include "convexGeometry.h.hlsl"',
        '#include "'+BASE+'convexGeometry.h.hlsl"\n#include "'+HELPER+'"')
    code='''#ifdef BNG_LIGHTING_1_5
    // RGB and native attenuation stay EXACTLY as the original shader computed.
    if (beamrtNativeSelected(cb)) {
        bool available = false;
#ifndef NO_SHADOW
        uint mapWidth, mapHeight;
        shadowMapTex.GetDimensions(mapWidth, mapHeight);
        available = mapWidth > 0 && mapHeight > 0 && isfinite(cb.shadowMapTexelSize)
            && cb.shadowMapTexelSize > 0
            && beamrtNativeVisibility >= 0 && beamrtNativeVisibility <= 1;
#endif
        outData.outB.a = beamrtNativePacket(beamrtNativeVisibility, available);
    }
#endif
    return outData;'''
    return ('#define BEAMRT_NATIVE_SPOT '+('1'if kind=='Spot'else'0')+'\n'+
            source.replace('return outData;',code))

def prepare(game_root,mod_root):
    game,mod=Path(game_root).resolve(),Path(mod_root).resolve()
    if game==mod or game in mod.parents or mod in game.parents:raise ValueError('Game/mod overlap')
    dependencies={p:(game/p).read_text(encoding='utf8').replace('\r\n','\n')for p in DEPENDENCIES}
    condition=dependencies['shaders/common/lighting.hlsl']
    if 'output.outB = float4(specular.rgb, 0);'not in condition or 'specular = bufferSample1.rgb;'not in condition:
        raise ValueError('Native 1.5 alpha producer/consumer contract changed')
    # The full dependency texts are pinned locally, not redistributed.
    for path,text in dependencies.items():
        if re.search(r'(?m)^\s*uniform_sampler\w*\([^\n]*,\s*14\s*\)',text):
            raise ValueError('Native dependency occupies sampler14: '+path)
    dependencies[HELPER]=(mod/HELPER).read_text(encoding='utf8').replace('\r\n','\n')
    lights={};folder=mod/'shaders/beamrt/generated';folder.mkdir(parents=True,exist_ok=True)
    for kind in ('Point','Spot'):
        native=BASE+kind.lower()+'LightP.hlsl';source=(game/native).read_text(encoding='utf8').replace('\r\n','\n')
        generated=generate(source,kind)
        digest=hashlib.sha256((generated+json.dumps(dependencies,sort_keys=True)).encode()).hexdigest()[:16]
        path='shaders/beamrt/generated/beamrtNativeVisibility'+kind+'_'+digest+'.hlsl'
        (mod/path).write_text(generated,encoding='utf8')
        lights[kind]=dict(nativePath=native,nativeSource=source,shaderPath=path,generatedSource=generated)
    manifest=dict(schema='beamrt.native.visibility.v1',lights=lights,dependencies=dependencies,
                  gpuExecutionVerified=False,beautyRGBChanged=False)
    (folder/'nativeVisibility.json').write_text(json.dumps(manifest),encoding='utf8')
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--game-root',required=True)
    p.add_argument('--mod-root',default=str(Path(__file__).resolve().parents[1]));a=p.parse_args()
    m=prepare(a.game_root,a.mod_root)
    print(json.dumps({k:v['shaderPath']for k,v in m['lights'].items()},indent=2))
