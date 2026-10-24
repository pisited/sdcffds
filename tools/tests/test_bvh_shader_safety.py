"""Shared traversal guards and GPU regressions; no game loading here."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT / "tools"))
import beamrt_bvh_pack as pack
import beamrt_scene_import as mesh


class BVHShaderSafety(unittest.TestCase):
    def test_leaf_range_uses_checked_subtraction(self):
        shader = (ROOT / "shaders/beamrt/beamrtMeshBVHCommon.h.hlsl").read_text()
        self.assertIn("start>(uint)meshTriangleCount || count>(uint)meshTriangleCount-start", shader)
        self.assertNotIn("start+count>(uint)meshTriangleCount", shader)
        guard = shader.index("start>(uint)meshTriangleCount")
        self.assertLess(guard, shader.index("uint p=(uint)meshTriangleOffset+(start+i)*7"))

    def test_preorder_subtree_shape_refuses_before_box_hit(self):
        shader = (ROOT / "shaders/beamrt/beamrtMeshBVHCommon.h.hlsl").read_text()
        guard = shader.index("escape!=node+1")
        self.assertIn("count==0 && escape<=node+2", shader)
        self.assertLess(guard, shader.index("if(!beamrtMeshBox"))
        self.assertIn("return -1;", shader[guard:shader.index("if(!beamrtMeshBox")])

    def test_native_gpu_fixture_corrupts_indices_and_links_then_recovers(self):
        fixture = (ROOT / "native/worker/self_test.cpp").read_text()
        for guard in ("overflowed leaf range certified a hit/miss", "invalid internal subtree certified a hit/miss",
                      "invalid leaf escape certified a hit/miss", "worker did not recover", "GPU result differs from CPU brute force"):
            self.assertIn(guard, fixture)
        for path in ("native/worker/trace.cs.hlsl", "shaders/beamrt/beamrtGIVisibilityProducer_v001.h.hlsl"):
            self.assertIn("beamrtMeshBVHCommon.h.hlsl", (ROOT / path).read_text())

    def test_gi_fixture_checks_unknown_texels_and_baseline_consumer(self):
        helper = (ROOT / "native/gi/test_support.h").read_text()
        fixture = (ROOT / "native/gi/self_test.cpp").read_text()
        self.assertIn("result[channel]==-1.0f", helper)
        self.assertIn("corrupt BVH produced a certified clear/blocked GI mask", helper)
        self.assertIn("expectInvalidVisibility(host,frame)", fixture)
        self.assertIn("fallback(true)", fixture)
        self.assertIn("expectInvalidVisibilityTexture(host,invalidPixel.resource.Get())", fixture)
        self.assertIn("invalidPixel.copySource->GetCPUDescriptorHandleForHeapStart().ptr", fixture)

    def test_valid_source_face_can_collapse_in_existing_packing(self):
        triangles = [
            {"v": [[0,0,0],[0.0001,0,0],[0,1,0]], "alphaMode": "opaque"},
            {"v": [[100000,0,0],[100001,0,0],[100000,1,0]], "alphaMode": "opaque"},
        ]
        package={"schema":"beamrt.mesh.alignment.v1", "triangles":triangles,"bvh":mesh.build_bvh(triangles)}
        pixels,meta=pack.pack(package)
        vertices=[pack.decode_vector(pixels[meta["triangleOffset"]+offset:meta["triangleOffset"]+offset+2],meta["quantMin"],meta["quantExtent"])
                  for offset in (0,2,4)]
        self.assertNotEqual(triangles[0]["v"][0],triangles[0]["v"][1])
        self.assertEqual(vertices[0],vertices[1])
        # The original is genuinely non-collinear; this is precision loss,
        # not merely an originally empty face with distinct points.
        source=triangles[0]["v"]
        self.assertNotEqual((source[1][0]-source[0][0])*(source[2][1]-source[0][1])
                            -(source[1][1]-source[0][1])*(source[2][0]-source[0][0]),0)

    def test_unusable_face_is_unknown_not_parallel_ray_miss(self):
        shader=(ROOT / "shaders/beamrt/beamrtMeshBVHCommon.h.hlsl").read_text()
        check=shader.index("all(area==0.0)")
        self.assertIn("!all(isfinite(area))",shader)
        self.assertLess(check,shader.index("if(beamrtMeshTriangle(o,d,a,b,c"))
        self.assertIn("return -1;",shader[check:shader.index("if(beamrtMeshTriangle(o,d,a,b,c")])
        self.assertIn("collapsed geometry certified as a clean miss/hit",(ROOT / "native/worker/self_test.cpp").read_text())
        self.assertIn("corruption<4",(ROOT / "native/gi/self_test.cpp").read_text())

    def test_gpu_control_keeps_valid_parallel_faces_as_misses(self):
        fixture=(ROOT / "native/worker/self_test.cpp").read_text()
        self.assertIn("planeHits[0].category==2 && planeHits[1].category==0",fixture)
        self.assertIn("valid parallel face was confused with unusable geometry",fixture)


if __name__ == "__main__":
    unittest.main()
