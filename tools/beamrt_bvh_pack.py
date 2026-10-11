"""Pack one model-space BVH into lossless RGBA8 data, not a rendered image.

Vertices use 16-bit positions relative to asset bounds. Node bounds round
outward. Preorder escape links allow stackless traversal. No triangle reduction,
no guessed opacity, no textureCube assumption, and no GPU verification claim.
"""
import argparse
import json
import math
from pathlib import Path
import struct
import zlib

HEADERS = [(64,128,192,255),(23,101,211,37)]

def word(n):
    if not 0<=n<2**32:raise ValueError('integer exceeds packed range')
    return tuple((n>>(8*i))&255 for i in range(4))

def vector(v,lo,extent,rounding=round):
    q=[int(max(0,min(65535,rounding((v[i]-lo[i])/extent[i]*65535)))) for i in range(3)]
    return [(q[0]&255,q[0]>>8,q[1]&255,q[1]>>8),(q[2]&255,q[2]>>8,0,255)]

def decode_vector(pixels,lo,extent):
    a,b=pixels
    q=[a[0]+256*a[1],a[2]+256*a[3],b[0]+256*b[1]]
    return [lo[i]+extent[i]*q[i]/65535 for i in range(3)]

def escapes(nodes):
    result={}
    def visit(index):
        n=nodes[index]
        if n['count']:
            end=index+1
        else:
            if n['left']!=index+1:raise ValueError('BVH is not preorder')
            left_end=visit(n['left'])
            if n['right']!=left_end:raise ValueError('BVH subtrees are not contiguous')
            end=visit(n['right'])
        result[index]=end
        return end
    if visit(0)!=len(nodes):raise ValueError('unreachable BVH nodes')
    return result

def pack(package):
    if package.get('schema')!='beamrt.mesh.alignment.v1':raise ValueError('alignment package required')
    faces=package['triangles'];bvh=package['bvh'];nodes=bvh['nodes'];order=bvh['triangleIndices']
    if not faces or len(faces)>200000 or sorted(order)!=list(range(len(faces))):raise ValueError('incomplete triangle order')
    lo=nodes[0]['min'];extent=[max(nodes[0]['max'][i]-lo[i],1e-6) for i in range(3)]
    end=escapes(nodes)
    pixels=list(HEADERS)
    for i,n in enumerate(nodes):
        pixels+=vector(n['min'],lo,extent,math.floor)
        pixels+=vector(n['max'],lo,extent,math.ceil)
        start=n['start'] if n['count'] else 0
        if not 0<=n['count']<=8 or end[i]>=2**24:raise ValueError('node payload exceeds budget')
        pixels+=[word(start),word(n['count']|(end[i]<<8))]
    triangle_offset=len(pixels)
    material_names=sorted({f.get('materialNameCandidate') or '<unresolved>' for f in faces})
    max_error=0.
    for index in order:
        face=faces[index]
        for v in face['v']:
            encoded=vector(v,lo,extent);pixels+=encoded
            decoded=decode_vector(encoded,lo,extent)
            max_error=max(max_error,max(abs(v[i]-decoded[i]) for i in range(3)))
        # Unknown material cannot become a certified opaque blocker.
        alpha={'unknown':0,'opaque':1,'mask':2,'blend':3}.get(face.get('alphaMode','unknown'),0)
        material=material_names.index(face.get('materialNameCandidate') or '<unresolved>')
        pixels.append((alpha,material&255,material>>8,255))
    width=256;height=math.ceil(len(pixels)/width)
    pixels += [(0,0,0,255)]*(width*height-len(pixels))
    return pixels,{'schema':'beamrt.bvh.rgba8.v1','width':width,'height':height,
      'nodeCount':len(nodes),'triangleCount':len(faces),'nodeOffset':2,'nodeStride':6,
      'triangleOffset':triangle_offset,'triangleStride':7,'quantMin':lo,'quantExtent':extent,
      'maximumMeasuredQuantizationErrorMetres':max_error,'materialNames':material_names,
      'gpuUploadVerified':False,'opacityTexturesSampled':False,'maximumTraversalNodes':4096}

def png(path,pixels,width,height):
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    rows=b''.join(b'\0'+bytes(c for p in pixels[y*width:(y+1)*width] for c in p) for y in range(height))
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows,9))+chunk(b'IEND',b'')
    Path(path).write_bytes(data)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',required=True);parser.add_argument('--output',required=True)
    args=parser.parse_args()
    package=json.loads(Path(args.input).read_text(encoding='utf-8'))
    pixels,meta=pack(package)
    output=Path(args.output);output.parent.mkdir(parents=True,exist_ok=True)
    name=output.stem+'.data.png'
    png(output.parent/name,pixels,meta['width'],meta['height'])
    meta['texture']='/art/beamrt/alignment/'+name
    package['gpuData']=meta
    output.write_text(json.dumps(package,separators=(',',':')),encoding='utf-8')
    print(json.dumps(meta,indent=2))

if __name__=='__main__':main()
