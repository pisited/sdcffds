import math
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import beamrt_bvh_pack as pack
import beamrt_scene_import as mesh

def dot(a,b):return sum(x*y for x,y in zip(a,b))
def sub(a,b):return [x-y for x,y in zip(a,b)]
def cross(a,b):return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def tri_hit(origin,direction,face,reach=200):
    a,b,c=face
    e1,e2=sub(b,a),sub(c,a);p=cross(direction,e2);det=dot(e1,p)
    if abs(det)<1e-10:return False
    t=sub(origin,a);u=dot(t,p)/det
    if not 0<=u<=1:return False
    q=cross(t,e1);v=dot(direction,q)/det
    return v>=0 and u+v<=1 and .05<dot(e2,q)/det<reach
def box_hit(origin,direction,lo,hi,reach=200):
    near,far=.05,reach
    for i in range(3):
        if abs(direction[i])<1e-10:
            if not lo[i]<=origin[i]<=hi[i]:return False
        else:
            a=(lo[i]-origin[i])/direction[i];b=(hi[i]-origin[i])/direction[i]
            near=max(near,min(a,b));far=min(far,max(a,b))
            if near>far:return False
    return True
def packed_hit(pixels,meta,origin,direction,budget=4096):
    def word(i):return sum(pixels[i][j]<<(8*j) for j in range(4))
    def point(i):return pack.decode_vector(pixels[i:i+2],meta['quantMin'],meta['quantExtent'])
    node=0
    for _ in range(budget):
        if node>=meta['nodeCount']:return False,True
        offset=2+node*6;info=word(offset+5);count=info&255;escape=info>>8
        if not box_hit(origin,direction,point(offset),point(offset+2)):
            node=escape;continue
        if not count:node+=1;continue
        start=word(offset+4)
        for i in range(count):
            p=meta['triangleOffset']+(start+i)*7
            if tri_hit(origin,direction,[point(p),point(p+2),point(p+4)]):return True,True
        node=escape
    return False,node>=meta['nodeCount']
def fixture(n=39):
    faces=[{'v':[[i*2.,0.,0.],[i*2.+1,0.,0.],[i*2.,1.,0.]],'alphaMode':'unknown'} for i in range(n)]
    return {'schema':'beamrt.mesh.alignment.v1','triangles':faces,'bvh':mesh.build_bvh(faces)}

class PackingTests(unittest.TestCase):
    def test_all_triangles_and_escape_links(self):
        data=fixture();pixels,meta=pack.pack(data)
        end=pack.escapes(data['bvh']['nodes'])
        self.assertEqual(end[0],len(end));self.assertEqual(meta['triangleCount'],39)
        for i,node in enumerate(data['bvh']['nodes']):
            b=pixels[2+i*6+5];value=sum(b[j]<<(8*j) for j in range(4))
            self.assertEqual(value&255,node['count']);self.assertEqual(value>>8,end[i])
    def test_outward_bounds_enclose_quantized_vertices(self):
        data=fixture();pixels,meta=pack.pack(data);lo=meta['quantMin'];extent=meta['quantExtent']
        for i,node in enumerate(data['bvh']['nodes']):
            decoded_lo=pack.decode_vector(pixels[2+i*6:4+i*6],lo,extent)
            decoded_hi=pack.decode_vector(pixels[4+i*6:6+i*6],lo,extent)
            for axis in range(3):
                self.assertLessEqual(decoded_lo[axis],node['min'][axis]+1e-10)
                self.assertGreaterEqual(decoded_hi[axis],node['max'][axis]-1e-10)
    def test_stackless_packed_traversal_vs_brute_force(self):
        data=fixture();pixels,meta=pack.pack(data)
        for x in range(-1,82):
            for y in (.1,.4,1.5):
                origin=[x+.21,y,4];direction=[0,0,-1]
                expected=any(tri_hit(origin,direction,f['v']) for f in data['triangles'])
                actual,complete=packed_hit(pixels,meta,origin,direction)
                self.assertTrue(complete);self.assertEqual(actual,expected)
    def test_non_normalized_direction_preserves_world_ray_distance(self):
        data=fixture(1);pixels,meta=pack.pack(data)
        self.assertTrue(packed_hit(pixels,meta,[.2,.2,2],[0,0,-.5])[0])
        self.assertFalse(tri_hit([.2,.2,2],[0,0,-.5],data['triangles'][0]['v'],reach=3))
    def test_budget_exhaustion_stays_unknown(self):
        data=fixture();pixels,meta=pack.pack(data)
        self.assertEqual(packed_hit(pixels,meta,[20,.1,4],[0,0,-1],budget=1),(False,False))
    def test_opacity_not_invented(self):
        data=fixture(1);pixels,meta=pack.pack(data)
        self.assertEqual(pixels[meta['triangleOffset']+6][0],0)
        data['triangles'][0]['alphaMode']='opaque';pixels,meta=pack.pack(data)
        self.assertEqual(pixels[meta['triangleOffset']+6][0],1)
    def test_png_exact_bytes_and_no_gamma_metadata(self):
        pixels,meta=pack.pack(fixture())
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'data.png';pack.png(path,pixels,meta['width'],meta['height'])
            raw=path.read_bytes();at=8;chunks=[];compressed=b''
            while at<len(raw):
                size=struct.unpack('>I',raw[at:at+4])[0];kind=raw[at+4:at+8]
                chunks.append(kind)
                if kind==b'IDAT':compressed+=raw[at+8:at+8+size]
                at+=size+12
            self.assertNotIn(b'gAMA',chunks);self.assertNotIn(b'sRGB',chunks)
            data=zlib.decompress(compressed);width=meta['width']
            actual=[]
            for y in range(meta['height']):
                row=data[y*(1+width*4)+1:(y+1)*(1+width*4)]
                actual.extend(tuple(row[i:i+4]) for i in range(0,len(row),4))
            self.assertEqual(actual,pixels)
    def test_srgb_decode_encode_recovers_all_bytes(self):
        for b in range(256):
            c=b/255.;linear=c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4
            encoded=linear*12.92 if linear<=.0031308 else 1.055*linear**(1/2.4)-.055
            self.assertEqual(round(encoded*255),b)
    def test_corrupt_topology_and_missing_triangle_rejected(self):
        data=fixture();data['bvh']['nodes'][0]['left']=5
        with self.assertRaises(ValueError):pack.pack(data)
        data=fixture();data['bvh']['triangleIndices'].pop()
        with self.assertRaises(ValueError):pack.pack(data)

if __name__=='__main__':unittest.main(verbosity=2)
