#!/usr/bin/env python3
"""Single-asset alignment milestone. Reads installed ZIPs without extracting them.

Select ONE visual mesh node, not every LOD/collision mesh in a DAE. Bake its
ancestor/node transforms before asset unit/up-axis conversion. Material fields
remain evidence/candidates, never automatic opacity certification. Outputs are
private user data; this tool neither changes the installation nor uploads GPU data.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

import beamrt_scene_import as mesh

MAX_BYTES = 64 * 1024 * 1024


def identity():
    return [1.,0.,0.,0., 0.,1.,0.,0., 0.,0.,1.,0., 0.,0.,0.,1.]


def multiply(a, b):
    return [sum(a[r*4+k]*b[k*4+c] for k in range(4))
            for r in range(4) for c in range(4)]


def point(matrix, value):
    v = list(value) + [1.]
    q = [sum(matrix[r*4+k]*v[k] for k in range(4)) for r in range(4)]
    if not all(math.isfinite(x) for x in q) or abs(q[3]-1.) > 1e-6:
        raise ValueError('only finite affine transforms are supported')
    return q[:3]


def numbers(element, count):
    vals = [float(x) for x in mesh.tokens(element)]
    if len(vals) != count or not all(math.isfinite(x) for x in vals):
        raise ValueError('invalid ' + mesh.tag(element) + ' transform')
    return vals


def local_matrix(node):
    # COLLADA column-vector transforms, serialized row-major, postmultiplied
    # in XML order. Khronos COLLADA 1.5 specification, matrix/node sections.
    result = identity()
    for child in node:
        kind = mesh.tag(child)
        step = identity()
        if kind == 'matrix':
            step = numbers(child, 16)
            if any(abs(step[i]) > 1e-8 for i in (12,13,14)) or abs(step[15]-1.) > 1e-8:
                raise ValueError('non-affine COLLADA matrix')
        elif kind == 'translate':
            step[3],step[7],step[11] = numbers(child, 3)
        elif kind == 'scale':
            step[0],step[5],step[10] = numbers(child, 3)
        elif kind == 'rotate':
            x,y,z,degrees = numbers(child, 4)
            length = math.sqrt(x*x+y*y+z*z)
            if length < 1e-12:
                raise ValueError('zero rotation axis')
            x,y,z = x/length,y/length,z/length
            c,s = math.cos(math.radians(degrees)),math.sin(math.radians(degrees))
            t=1-c
            step=[t*x*x+c,t*x*y-s*z,t*x*z+s*y,0.,
                  t*x*y+s*z,t*y*y+c,t*y*z-s*x,0.,
                  t*x*z-s*y,t*y*z+s*x,t*z*z+c,0.,0.,0.,0.,1.]
        elif kind in ('lookat','skew','instance_node','instance_controller'):
            raise ValueError('unsupported node element: ' + kind)
        else:
            continue
        result = multiply(result, step)
    return result


def active_scene(root):
    scene_ref = mesh.first(mesh.first(root,'scene'),'instance_visual_scene')
    scene_id = mesh.strip_ref(scene_ref.get('url')) if scene_ref is not None else None
    scenes = list(mesh.descendants(root,'visual_scene'))
    selected = [s for s in scenes if s.get('id') == scene_id]
    if len(selected) != 1:
        raise ValueError('one explicit active visual_scene is required')
    return selected[0]


def walk(scene):
    records=[]
    def visit(node, parent, ancestry, depth):
        if depth > 128:
            raise ValueError('node hierarchy exceeds limit')
        matrix = multiply(parent, local_matrix(node))
        name=node.get('id') or node.get('name') or '<unnamed>'
        path=ancestry+[name]
        records.append((node,matrix,path))
        for child in mesh.children(node,'node'):
            visit(child,matrix,path,depth+1)
    for node in mesh.children(scene,'node'):
        visit(node,identity(),[],0)
    return records


def asset_name(name):
    name=str(name).replace('\\','/').lstrip('/')
    if not name or '..' in name.split('/') or not name.lower().endswith('.dae'):
        raise ValueError('supply a relative DAE asset path without traversal')
    return name


def read_asset(archive, name):
    with zipfile.ZipFile(archive) as z:
        info=z.getinfo(asset_name(name))
        if info.file_size > MAX_BYTES:
            raise ValueError('asset exceeds 64 MiB safety limit')
        data=z.read(info)
    root=ET.fromstring(data)
    if mesh.tag(root) != 'COLLADA':
        raise ValueError('not a COLLADA document')
    return root,data


def material_bindings(root, instance):
    names={m.get('id'):m.get('name') or m.get('id') for m in mesh.descendants(root,'material')}
    result={}
    for binding in mesh.descendants(instance,'instance_material'):
        symbol=binding.get('symbol')
        target=mesh.strip_ref(binding.get('target'))
        if symbol and target:
            if symbol in result and result[symbol] != names.get(target,target):
                raise ValueError('conflicting selected-node material binding')
            result[symbol]=names.get(target,target)
    return result


def material_evidence(archives, candidates):
    # Resolve engine Material mapTo/name without interpreting missing opacity
    # as opaque. Only metadata is retained; referenced textures are NOT read.
    found={name:[] for name in candidates}
    examined=0
    for archive in archives:
      with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            if not info.filename.lower().endswith('.materials.json') or info.file_size > 8*1024*1024:
                continue
            text=z.read(info).decode('utf-8-sig')
            if not any(name in text for name in candidates):
                continue
            examined+=1
            try:
                data=json.loads(text)
            except ValueError:
                continue  # Unsupported JSON syntax is reported as unresolved.
            if not isinstance(data,dict):
                continue
            for key,record in data.items():
                if not isinstance(record,dict) or record.get('class') != 'Material':
                    continue
                aliases={key,record.get('name'),record.get('mapTo')}
                for name in aliases.intersection(candidates):
                    stages=record.get('Stages',[])
                    opacity=any(isinstance(s,dict) and s.get('opacityMap') for s in stages)
                    candidate=('needs-alpha-test' if record.get('alphaTest') or opacity else
                               'potentially-transparent' if record.get('translucent') else 'unknown-opacity')
                    fields={k:record[k] for k in ('name','mapTo','version','alphaTest','alphaRef',
                            'translucent','doubleSided','Stages') if k in record}
                    found[name].append({'archive':Path(archive).name,'file':info.filename,'key':key,'fields':fields,
                                        'alphaCandidate':candidate,'opaqueVerified':False})
    return {name:{'candidates':hits,'resolvedUnique':len(hits)==1,'alphaMode':'unknown'}
            for name,hits in found.items()},examined


def extract_selected(root, node_name, limit=200000, allow_non_surface_lines=False):
    records=walk(active_scene(root))
    matches=[r for r in records if r[0].get('id') == node_name or r[0].get('name') == node_name]
    if len(matches) != 1:
        raise ValueError('node selection must match exactly one active-scene node')
    selected=matches[0]
    prefix=selected[2]
    selected_records=[r for r in records if r[2][:len(prefix)] == prefix]
    asset=mesh.first(root,'asset')
    unit=mesh.first(asset,'unit')
    scale=float(unit.get('meter','1')) if unit is not None else 1.
    up_node=mesh.first(asset,'up_axis')
    up=(up_node.text or 'Y_UP').strip() if up_node is not None else 'Y_UP'
    if not math.isfinite(scale) or scale<=0 or scale>100000 or up not in ('X_UP','Y_UP','Z_UP'):
        raise ValueError('invalid unit/up-axis')
    geometries={g.get('id'):g for g in mesh.descendants(root,'geometry')}
    faces=[]
    skipped={}
    for node,matrix,path in selected_records:
        for instance in mesh.children(node,'instance_geometry'):
            gid=mesh.strip_ref(instance.get('url'))
            geometry=geometries.get(gid)
            geometry_mesh=mesh.first(geometry,'mesh')
            if geometry_mesh is None:
                raise ValueError('selected geometry is unavailable: '+gid)
            # Parse raw coordinates first; transform nodes in their source axes.
            new,warnings=mesh.parse_geometry(geometry_mesh,gid,material_bindings(root,instance),
                                            1.,'Z_UP',limit-len(faces))
            for warning,count in warnings.items():
                if allow_non_surface_lines and warning in ('unsupported primitive lines','unsupported primitive linestrips'):
                    # Lines have no surface area in the triangle-visibility model.
                    # Record this explicit scope; never ignore unsupported surfaces.
                    key='non-surface '+warning.removeprefix('unsupported primitive ')
                    skipped[key]=skipped.get(key,0)+count
                    continue
                if warning != 'degenerate triangle':
                    raise ValueError('refusing partial selected geometry: '+warning)
                skipped[warning]=skipped.get(warning,0)+count
            for face in new:
                face['v']=[mesh.orient(point(matrix,v),scale,up) for v in face['v']]
                if mesh.face_area_sq(face['v']) <= 1e-14:
                    raise ValueError('node transform collapsed a triangle')
                face['geometryId']=gid
                face['nodePath']=path
                face['alphaMode']='unknown'
            faces.extend(new)
    if not faces:
        raise ValueError('selected node has no supported geometry')
    return faces,{'selectedNode':node_name,'ancestry':prefix,'originalUpAxis':up,
                  'unitMetres':scale,'sceneNodeTransformsBaked':True,'skipped':skipped}


def bake_basis(faces, basis):
    # Exported by MatrixF.mulP3F on scaled unit points, not raw string parsing.
    vectors=[basis[k] for k in ('origin','x','y','z')]
    if any(len(v)!=3 or not all(math.isfinite(float(x)) for x in v) for v in vectors):
        raise ValueError('invalid exported native point basis')
    origin,x,y,z=vectors
    result=[]
    for face in faces:
        out=dict(face)
        out['v']=[[origin[i]+v[0]*x[i]+v[1]*y[i]+v[2]*z[i] for i in range(3)] for v in face['v']]
        result.append(out)
    return result


def prepare(archive, asset, node, output, limit=200000, material_archives=(), allow_non_surface_lines=False):
    if not 1<=limit<=200000:
        raise ValueError('triangle limit must be 1..200000')
    name=asset_name(asset)
    root,data=read_asset(archive,name)
    faces,meta=extract_selected(root,node,limit,allow_non_surface_lines)
    names={f['materialNameCandidate'] for f in faces if f['materialNameCandidate']}
    materials,examined=material_evidence([archive]+list(material_archives),names)
    bounds=mesh.build_bvh(faces)
    package={'schema':'beamrt.mesh.alignment.v1','shapePath':'/'+name,
             'sourceSha256':hashlib.sha256(data).hexdigest(),'space':'engine-model metres, Z-up',
             'nodeSelection':meta,'triangles':faces,'bvh':bounds,'materials':materials,
             'instanceTransformsBaked':False,'gpuUploaded':False,'alignmentVerified':False,
             'opaqueFacesVerified':False,'stats':{'triangles':len(faces),'bvhNodes':len(bounds['nodes']),
             'uvTriangles':sum(f['uv'] is not None for f in faces),'materialNames':sorted(names),
             'materialFilesExamined':examined}}
    mesh.save_json(output,package)
    return package


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive',required=True,help='installed level ZIP (read-only)')
    parser.add_argument('--asset',required=True,help='DAE path inside archive')
    parser.add_argument('--node',help='one exact visual node; no LOD/collision union')
    parser.add_argument('--list-nodes',action='store_true')
    parser.add_argument('--output')
    parser.add_argument('--max-triangles',type=int,default=200000)
    parser.add_argument('--materials-archive',action='append',default=[],help='optional shared material ZIP (read-only)')
    args=parser.parse_args()
    try:
        if args.list_nodes:
            root,_=read_asset(args.archive,args.asset)
            print(json.dumps([{'id':n.get('id'),'name':n.get('name'),'path':p,
                              'geometries':[i.get('url') for i in mesh.children(n,'instance_geometry')]}
                             for n,_,p in walk(active_scene(root))],indent=2))
        else:
            if not args.node or not args.output:
                parser.error('--node and --output are required')
            package=prepare(args.archive,args.asset,args.node,args.output,args.max_triangles,args.materials_archive)
            print(json.dumps({'output':args.output,'stats':package['stats'],
                              'gpuUploaded':False,'alignmentVerified':False},indent=2))
    except (ValueError,OSError,KeyError,ET.ParseError,zipfile.BadZipFile) as exc:
        print('BeamRT alignment preparation error: '+str(exc),file=sys.stderr)
        return 1
    return 0


if __name__=='__main__':
    sys.exit(main())
