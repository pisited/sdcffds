"""Reuse the existing BVH packer for offline native GPU tests, not game opacity.

Real private asset by default; --synthetic uses the existing packing-test fixture
for CI. Explicit opaque/unknown test policies do not certify live materials.
"""
import argparse
import json
import math
from pathlib import Path
import struct
import sys
import beamrt_bvh_pack as pack

sys.path.insert(0, str(Path(__file__).resolve().parent / 'tests'))
from test_bvh_pack import cross, dot, fixture, sub, tri_hit


def prepare(package, output):
    pixels, meta = pack.pack(package)
    if meta['nodeCount'] > 4096 or len(meta['materialNames']) > 16:
        raise ValueError('native worker scene budget exceeded')
    def point(index):
        return pack.decode_vector(pixels[index:index+2], meta['quantMin'], meta['quantExtent'])
    faces = [[point(meta['triangleOffset']+i*7+j) for j in (0,2,4)]
             for i in range(meta['triangleCount'])]
    rays = []
    for face in faces:
        normal = cross(sub(face[1], face[0]), sub(face[2], face[0]))
        length = math.sqrt(dot(normal, normal))
        if length < 1e-5:
            continue
        direction = [-x/length for x in normal]
        centre = [sum(v[i] for v in face)/3 for i in range(3)]
        origin = [centre[i]-direction[i]*2 for i in range(3)]
        rays.append((*origin, 4., *direction, .05))
        if len(rays) == 96:
            break
    for i in range(32):
        rays.append((meta['quantMin'][0]-10, meta['quantMin'][1]+i*.1,
                     meta['quantMin'][2], 4., -1., 0., 0., .05))
    # Compare float32 upload coordinates against every decoded triangle; this is
    # independent of BVH escape-link traversal and uses the existing CPU test.
    rays = [struct.unpack('<8f', struct.pack('<8f', *ray)) for ray in rays]
    expected = [2 if any(tri_hit(ray[:3], ray[4:7], face, reach=ray[3])
                         for face in faces) else 0 for ray in rays]
    if not (0 in expected and 2 in expected):
        raise ValueError('fixture must exercise both hits and misses')
    vectors = (0,0,0,0, 1,0,0,0, 0,1,0,0, 0,0,1,0,
               *meta['quantMin'],0, *meta['quantExtent'],0)
    integers = (meta['nodeCount'], meta['triangleCount'], meta['triangleOffset'],0,
                meta['width'], meta['height'],0,0, *([1]*16))
    params = struct.pack('<24f24I', *vectors, *integers)
    data = (struct.pack('<4I', 0x42525431, len(pixels)*4, len(rays),0) + params
            + bytes(c for pixel in pixels for c in pixel)
            + b''.join(struct.pack('<8f', *ray) for ray in rays)
            + struct.pack('<'+'i'*len(expected), *expected))
    Path(output).parent.mkdir(parents=True, exist_ok=True)
    Path(output).write_bytes(data)
    return {'triangles':len(faces), 'nodes':meta['nodeCount'], 'rays':len(rays),
            'expectedOpaqueHits':expected.count(2), 'expectedMisses':expected.count(0),
            'materialPolicy':'controlled fixture only; not live opacity proof'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--synthetic', action='store_true')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.input and args.synthetic:
        parser.error('choose real input or synthetic fixture, not both')
    path = args.input or Path(__file__).resolve().parents[1]/'art/beamrt/alignment/wcu_guardhouse.beamrt.json'
    package = fixture() if args.synthetic else json.loads(path.read_text(encoding='utf-8'))
    result = prepare(package, args.output)
    result['geometrySource'] = 'synthetic CI fixture' if args.synthetic else str(path)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
