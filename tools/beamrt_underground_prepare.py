"""Prepare private WCU underground GPU assets and native local-light hooks.

Read-only game input; reuses the existing node importer and BVH packer.
One exact highest-detail visual node per asset, no collision/LOD union.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import beamrt_scene_align as align
import beamrt_scene_import as mesh
import beamrt_bvh_pack as packer

ASSETS=['s_steel_factory_sewer_%02d'%i for i in range(1,7)]+['s_steel_factory_underground_%02d'%i for i in (1,2)]
LOCAL_SOURCES={
 'Point':('pointLightP.hlsl','   float Sat_NL_Att = saturate( nDotL * atten * shadowed ) * (cb.lightBrightness * cb.lastFrameExposure);'),
 'Spot':('spotLightP.hlsl','    float Sat_NL_Att = saturate(nDotL * atten * shadowed) * (cb.lightBrightness * cb.lastFrameExposure);')}

def select_visual(root):
    candidates=[]
    for node,_,_ in align.walk(align.active_scene(root)):
        name=node.get('id')or node.get('name')or''
        if mesh.children(node,'instance_geometry') and not re.search(r'collision|colmesh|nulldetail',name,re.I):
            detail=re.search(r'_a(\d+)$',name)
            if not detail:raise ValueError('unrecognized visual detail node: '+name)
            candidates.append((int(detail[1]),name))
    if not candidates:raise ValueError('no visual geometry')
    best=max(x[0]for x in candidates)
    choices=[name for detail,name in candidates if detail==best]
    if len(choices)!=1:raise ValueError('ambiguous highest-detail visual node')
    return choices[0]

def generate_local(source,kind):
    source=source.replace('\r\n','\n')
    _,insertion=LOCAL_SOURCES[kind]
    for token in ('#include "convexGeometry.h.hlsl"',insertion,
                  'const float3 worldPos = perspectiveDiv(mul(cb.screenToWorld, float4(posNdc, 1))).xyz;'):
        if source.count(token)!=1:raise ValueError('unsupported native local-light contract: '+token)
    if 'beamrtLocal' in source or re.search(r'register\s*\(\s*[ts]14\s*\)',source):
        raise ValueError('native local-light slot/name conflict')
    source=source.replace('#include "convexGeometry.h.hlsl"',
      '#include "shaders/common/lighting/advanced/convexGeometry.h.hlsl"\n'
      '#include "shaders/beamrt/beamrtMeshLocalLight.h.hlsl"')
    return source.replace(insertion,
      '    // Keep native attenuation/BRDF/emission. Add only definite world-mesh visibility.\n'
      '    if (gbuffer.target0.w <= 0.0 && cb.lightMapParams.a >= 0.0)\n'
      '        shadowed = beamrtLocalShadowFactor(worldPos, material.normal, cb.lightPosition, shadowed);\n'+insertion)

def prepare(game_root,mod_root):
    game_root,mod_root=Path(game_root).resolve(),Path(mod_root).resolve()
    if game_root==mod_root or game_root in mod_root.parents or mod_root in game_root.parents:
        raise ValueError('game and mod roots must not overlap')
    archive=game_root/'content/levels/west_coast_usa.zip'
    shared=game_root/'content/art_shapes.zip'
    folder=mod_root/'art/beamrt/alignment';folder.mkdir(parents=True,exist_ok=True)
    registry={'schema':'beamrt.underground.registry.v1','assets':[],'runtimeVerified':False}
    for name in ASSETS:
        asset='levels/west_coast_usa/art/shapes/buildings/steel_factory/'+name+'.dae'
        root,_=align.read_asset(archive,asset);node=select_visual(root)
        output=folder/(name+'.beamrt.json')
        package=align.prepare(archive,asset,node,output,material_archives=(shared,),allow_non_surface_lines=True)
        pixels,gpu=packer.pack(package)
        if len(gpu['materialNames'])>16:raise ValueError('too many material identities: '+name)
        digest=hashlib.sha256(bytes(c for p in pixels for c in p)).hexdigest()[:16]
        texture=name+'_'+digest+'.data.png'
        packer.png(folder/texture,pixels,gpu['width'],gpu['height'])
        gpu['texture']='/art/beamrt/alignment/'+texture
        package['gpuData']=gpu;mesh.save_json(output,package)
        # Runtime reads only descriptors, not full CPU triangles/edges.
        registry['assets'].append({'shapePath':package['shapePath'],'selectedNode':node,
          'sourceSha256':package['sourceSha256'],'space':package['space'],
          'sceneNodeTransformsBaked':True,'gpuData':gpu})
        print(name+': '+str(gpu['triangleCount'])+' triangles, '+node,flush=True)
    mesh.save_json(folder/'wcu_underground_registry.json',registry)
    dependencies={}
    for rel in ('shaders/common/lighting/advanced/convexGeometry.h.hlsl',
                'shaders/beamrt/beamrtMeshLocalLight.h.hlsl','shaders/beamrt/beamrtMeshBVHCommon.h.hlsl'):
        base=mod_root if rel.startswith('shaders/beamrt/')else game_root
        dependencies[rel]=(base/rel).read_text(encoding='utf-8').replace('\r\n','\n')
    generated=mod_root/'shaders/beamrt/generated';generated.mkdir(parents=True,exist_ok=True)
    hooks={'schema':'beamrt.native.local.hooks.v1','dependencies':dependencies,'lights':{},'gpuExecutionVerified':False}
    for kind,(filename,_)in LOCAL_SOURCES.items():
        native='shaders/common/lighting/advanced/'+filename
        source=(game_root/native).read_text(encoding='utf-8').replace('\r\n','\n')
        text=generate_local(source,kind)
        digest=hashlib.sha256((text+json.dumps(dependencies,sort_keys=True)).encode()).hexdigest()[:16]
        output=generated/('beamrtLocal'+kind+'_'+digest+'.hlsl');output.write_text(text,encoding='utf-8')
        hooks['lights'][kind]={'nativePath':native,'nativeSource':source,
          'shaderPath':'shaders/beamrt/generated/'+output.name,'generatedSource':text}
    mesh.save_json(generated/'nativeLocalHooks.json',hooks)
    return registry,hooks

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root',required=True)
    parser.add_argument('--mod-root',default=str(Path(__file__).resolve().parents[1]))
    args=parser.parse_args();registry,_=prepare(args.game_root,args.mod_root)
    print('Prepared '+str(len(registry['assets']))+' private candidate meshes; no runtime activation.')

if __name__=='__main__':main()
