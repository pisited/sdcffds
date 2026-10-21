"""Prepare small, material-mapped area-emitter quadratures; stdout only.

Reads installed ZIP assets without extracting or modifying the map. Native
instance placement, live material validation and visual alignment remain runtime
requirements. Four samples per mesh/material are a coarse approximation.
"""
import argparse
import hashlib
import json
import math
import xml.etree.ElementTree as ET
import zipfile
import zlib
import beamrt_scene_align as align

DEFAULT_ASSETS=(
 ('levels/polish_roads_v2/SketchUpCK/stacja_benz/owlen_ledy.dae','stacja_ledy_top_a160'),
 ('levels/polish_roads_v2/SketchUpCK/stacja_benz/owlen_led_budynek.dae','budynek_owlen_ledy_a90'),
)

def area(vertices):
    if len(vertices)!=3 or any(len(v)!=3 or any(not math.isfinite(x) for x in v) for v in vertices):
        raise ValueError('invalid emitter triangle')
    a,b,c=vertices
    u=[b[i]-a[i] for i in range(3)];v=[c[i]-a[i] for i in range(3)]
    cross=(u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0])
    return math.sqrt(sum(x*x for x in cross))*.5

def quadrature(faces):
    grouped={}
    for face in faces:
        name=face.get('materialNameCandidate')
        if not name:raise ValueError('unresolved material identity')
        grouped.setdefault(name,[]).append(face['v'])
    result=[]
    for name,triangles in grouped.items():
        weighted=[(v,area(v)) for v in triangles if area(v)>1e-10]
        total=sum(a for _,a in weighted)
        if not total:continue
        samples=[]
        for i in range(4):
            target=total*(i+.5)/4;acc=0
            for vertices,a in weighted:
                acc+=a
                if acc>=target:
                    samples.append({'v':vertices,'triangleArea':a,'weightArea':total/4});break
        result.append({'material':name,'area':total,'samples':samples})
    return result

def prepare(archive,assets=DEFAULT_ASSETS):
    result={'schema':'beamrt.emissive.quadrature.v1','assets':{},'visualAlignmentVerified':False,
            'sourceTextureSampling':False,'note':'Opt-in geometry-derived area approximation; no shadow visibility.'}
    with zipfile.ZipFile(archive) as z:
        for path,node in assets:
            path=align.asset_name(path)
            info=z.getinfo(path)
            if info.file_size>8*1024*1024:raise ValueError('emitter asset exceeds 8 MiB limit')
            data=z.read(info).replace(b'\r\n',b'\n')
            faces,meta=align.extract_selected(ET.fromstring(data),node)
            groups=quadrature(faces)
            # This first catalogue intentionally supports only the separately
            # authored, uniformly emissive LED material, not whole buildings.
            if len(groups)!=1 or groups[0]['material']!='budynek_owlen_led':
                raise ValueError('non-uniform/unverified material in LED asset')
            result['assets']['/'+path.lower()]={'groups':groups,'sourceBytes':len(data),
                'sourceAdler32':zlib.adler32(data)&0xffffffff,'sourceSHA256':hashlib.sha256(data).hexdigest(),
                'placement':meta,'emissiveMap':'/levels/polish_roads_v2/From_east_coast_usa/shapes/buildings/universal_r.data.png'}
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--archive',required=True)
    args=p.parse_args();print(json.dumps(prepare(args.archive),separators=(',',':'),allow_nan=False))
