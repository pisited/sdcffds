"""Stdlib checks for the existing packer's native-worker fixtures; not GPU proof."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import beamrt_native_fixture as native
import beamrt_bvh_pack as pack
from test_bvh_pack import fixture


class NativeFixture(unittest.TestCase):
    def test_exact_existing_bvh_bytes_and_scene_abi(self):
        package = fixture()
        pixels, meta = pack.pack(package)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'fixture.bin'
            result = native.prepare(package, path)
            data = path.read_bytes()
        magic, byte_count, ray_count, reserved = struct.unpack('<4I', data[:16])
        self.assertEqual((magic,byte_count,reserved),(0x42525431,len(pixels)*4,0))
        self.assertEqual(ray_count,result['rays'])
        params = struct.unpack('<24f24I', data[16:208])
        self.assertEqual(params[24:28],(meta['nodeCount'],meta['triangleCount'],meta['triangleOffset'],0))
        self.assertEqual(params[28:32],(meta['width'],meta['height'],0,0))
        self.assertEqual(params[32:],(1,)*16)
        self.assertEqual(data[208:208+byte_count], bytes(c for p in pixels for c in p))
        self.assertEqual(len(data),208+byte_count+ray_count*(32+4))
        self.assertIn('not live opacity proof',result['materialPolicy'])

    def test_both_hit_and_miss_cpu_reference_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            result = native.prepare(fixture(),Path(directory)/'fixture.bin')
        self.assertGreater(result['expectedOpaqueHits'],0)
        self.assertEqual(result['expectedMisses'],32)
        self.assertEqual(result['rays'],result['expectedOpaqueHits']+result['expectedMisses'])

    def test_source_unknown_opacity_not_rewritten(self):
        package = fixture()
        with tempfile.TemporaryDirectory() as directory:
            native.prepare(package,Path(directory)/'fixture.bin')
        self.assertTrue(all(face['alphaMode']=='unknown' for face in package['triangles']))
        pixels,meta = pack.pack(package)
        self.assertTrue(all(pixels[meta['triangleOffset']+i*7+6][0]==0 for i in range(meta['triangleCount'])))

    def test_material_capacity_rejected_before_output(self):
        package=fixture(17)
        for i,face in enumerate(package['triangles']): face['materialNameCandidate']=f'material_{i}'
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'fixture.bin'
            with self.assertRaises(ValueError): native.prepare(package,path)
            self.assertFalse(path.exists())

    def test_degenerate_data_without_a_valid_hit_is_rejected(self):
        package=fixture(1)
        package['triangles'][0]['v']=[[0.,0.,0.]]*3
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'fixture.bin'
            with self.assertRaises(ValueError): native.prepare(package,path)
            self.assertFalse(path.exists())

    def test_deterministic_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            first,second=(Path(directory)/name for name in ('a.bin','b.bin'))
            native.prepare(fixture(),first); native.prepare(fixture(),second)
            self.assertEqual(first.read_bytes(),second.read_bytes())


if __name__=='__main__':
    unittest.main(verbosity=2)
