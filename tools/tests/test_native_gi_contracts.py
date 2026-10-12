"""Offline source contracts; GPU behavior is exercised by native/gi/self_test.cpp.

These guards do not prove BeamNG resource capture, injection, or lighting.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeGIContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / name).read_text(encoding="utf-8")

    def test_native_worker_not_loaded_and_buffer_backend_opt_in(self):
        lua = self.source("lua/ge/extensions/beamrt/main.lua")
        for entry in ("beamrtGITraceP_v084", "beamrtGIReceiverExport", "beamrt_native_gi"):
            self.assertNotIn(entry, lua)
        self.assertIn("beamrtGITraceP_v083.hlsl", lua)
        self.assertIn("backend='inline',source='guardhouse'", lua)
        buffer = self.source("lua/ge/extensions/beamrt/giVisibilityBuffer.lua")
        self.assertIn("state={active=false", buffer)
        self.assertNotIn("ffi.load", buffer)

    def test_matched_receiver_origin_is_shared_not_reimplemented(self):
        core = self.source("shaders/beamrt/beamrtGITraceP_v067_core.hlsl")
        export = self.source("shaders/beamrt/beamrtGIReceiverExportP_v001.hlsl")
        self.assertIn("float3 beamrtGIReceiverOrigin(", core)
        self.assertIn("float3 rayOrigin = beamrtGIReceiverOrigin(", core)
        self.assertIn("float3 origin=beamrtGIReceiverOrigin(", export)
        self.assertNotIn("beamrtGeometricSurfaceNormal(", export)

    def test_visibility_only_changes_world_surfel_branch(self):
        core = self.source("shaders/beamrt/beamrtGITraceP_v067_core.hlsl")
        self.assertEqual(core.count("beamrtNativeGIBlocked("), 1)
        branch = core[core.index("if (allowWorldSurfels && worldGIStrength > 0.0)"):]
        self.assertIn("beamrtNativeGIBlocked(currentUv,surfelIndex)", branch)
        self.assertIn("sampleRadiance=0.0;sampleConfidence=0.0;return;", branch)

    def test_reuses_existing_traversal_and_exact_consumer(self):
        producer = self.source("native/gi/visibility.cs.hlsl")
        fixture = self.source("native/gi/consumer_test.hlsl")
        header = self.source("shaders/beamrt/beamrtGITrace_v065.h.hlsl")
        common = self.source("shaders/beamrt/beamrtGIVisibilityProducer_v001.h.hlsl")
        self.assertIn('beamrtGIVisibilityProducer_v001.h.hlsl', producer)
        self.assertIn('#include "beamrtMeshBVHCommon.h.hlsl"', common)
        self.assertIn("if(hit==2) blocked|=1u<<i;", common)
        self.assertIn("if(hit<0)", common)
        self.assertIn("beamrtNativeGIVisibility_v001.h.hlsl", fixture)
        self.assertIn("beamrtNativeGIVisibility_v001.h.hlsl", header)
        self.assertIn("uniform_sampler2D(nativeGIVisibilityTex, 5);", header)

    def test_native_adapter_records_without_submission_or_readback(self):
        adapter = self.source("native/gi/beamrt_gi.cpp")
        for forbidden in ("ExecuteCommandLists", "CreateCommandQueue", "WaitForSingleObject",
                          "D3D12CreateDevice", "D3D12_HEAP_TYPE_READBACK", "DllMain"):
            self.assertNotIn(forbidden, adapter)
        self.assertIn("foreign-device interface rejected", adapter)
        self.assertIn("GPU frame still in flight; retained", adapter)
        self.assertIn("unmarked recorded work retained", adapter)


if __name__ == "__main__":
    unittest.main()
