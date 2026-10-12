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

    def test_offline_capture_to_gi_handoff_uses_explicit_sidecar_and_final_fence(self):
        fixture = self.source("native/gi/self_test.cpp")
        handoff = self.source("native/gi/test_support.h")
        build = self.source("native/gi/build.ps1")
        self.assertIn('#include "test_support.h"', fixture)
        self.assertIn('../capture/beamrt_capture.h', handoff)
        self.assertIn("BeamRT_CaptureGetSnapshotForQueue", handoff)
        self.assertIn("info.resources[0]==sidecar.receivers && info.resources[1]==sidecar.mesh", handoff)
        for field in ("frameInputs.meshState=", "frameInputs.receiverState=", "frameInputs.scene=sidecar.scene",
                      "frameInputs.width=sidecar.width", "frameInputs.surfelCount=sidecar.surfelCount",
                      "std::memcpy(frameInputs.key", "std::memcpy(frameInputs.surfels"):
            self.assertIn(field, handoff)
        for step in ("capture.stop()", "BeamRT_GICreateFrame", "BeamRT_GIRecord",
                     "BeamRT_GIMarkSubmitted", "handoffHost.execute();handoffHost.wait();",
                     "draw(handoffHost,frame.value", "GI frame retired before the consumer completion fence"):
            self.assertIn(step, handoff)
        self.assertIn("native/capture/build.ps1", build)
        self.assertIn("beamrt_capture.lib", build)
        self.assertIn("handoff_producer.hlsl", build)
        self.assertIn("config.offsets[0]=0;config.offsets[1]=1", handoff)
        self.assertIn("!info.cameraVerified && !info.gpuOrderingVerified && !info.lightingConsumed", handoff)

    def test_output_descriptor_copy_uses_cpu_staging_heap(self):
        adapter = self.source("native/gi/beamrt_gi.cpp")
        self.assertIn("heap.NumDescriptors=1;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE", adapter)
        self.assertIn("f->outputSrv->GetCPUDescriptorHandleForHeapStart()", adapter)
        self.assertNotIn("cpuSrv=f->descriptors->GetCPUDescriptorHandleForHeapStart()", adapter)
        self.assertIn("descriptors,outputSrv", adapter)

    def test_handoff_reads_error_text_only_after_api_returns(self):
        import re
        support = self.source("native/gi/test_support.h")
        self.assertIn("static void captureSuccess(int result)", support)
        self.assertIn("captureSuccess(BeamRT_CaptureStart", support)
        self.assertNotRegex(support, r"require\(\s*BeamRT_\w+\([^;]*?BeamRT_\w*LastError\(\)\)")


if __name__ == "__main__":
    unittest.main()
