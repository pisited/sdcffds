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
        validator = self.source("native/gi/handoff_validation.h")
        self.assertIn("evidence.sidecar=sidecar", handoff)
        self.assertIn("beamrt_fixture::validateInputs(info,evidence,frameInputs", handoff)
        for field in ("out=e.sidecar", "out.receivers=info.resources[0]", "out.mesh=info.resources[1]",
                      "out.receiverState=states[0]", "out.meshState=states[1]"):
            self.assertIn(field, validator)
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

    def test_handoff_validator_rejects_missing_evidence_without_gpu_writes(self):
        validator = "\n".join(self.source("native/gi/" + name) for name in
                              ("handoff_validation.h", "shader_contract.h", "contract_common.h"))
        for guard in ("foreign-device resource/queue/fence", "incomplete/unsupported producer context",
                      "stale or unexpected producer snapshot", "unresolved root constant/CBV/UAV semantics",
                      "viewport/output coverage mismatch", "missing/unsupported explicit starting state",
                      "broken/unsupported transition chain", "sidecar generation does not match current fixture"):
            self.assertIn(guard, validator)
        self.assertIn("out={};reason.clear()", validator)
        self.assertIn("const BeamRTCaptureInfo& info", validator)
        for forbidden in ("D3D12CreateDevice", "CreateCommandQueue", "ExecuteCommandLists", "ResourceBarrier",
                          "BeamRT_GICreateFrame", "BeamRT_GIDestroyFrame", "WaitForSingleObject"):
            self.assertNotIn(forbidden, validator)
        self.assertNotRegex(validator, r"->\s*(Map|Signal|Wait)\s*\(")

    def test_shader_manifest_checks_reflected_names_types_and_root_registers(self):
        contract = self.source("native/gi/shader_contract.h")
        for check in ("D3DReflect", "GetResourceBindingDescByName", "GetConstantBufferByName",
                      "GetVariableByName", "GetType()->GetDesc", "D3D12CreateRootSignatureDeserializer",
                      "c.Descriptor.ShaderRegister==0", "c.Descriptor.RegisterSpace==0",
                      "range.OffsetInDescriptorsFromTableStart==0", "only the owned SM5.0 pixel fixtures",
                      "constant field name/type/extent mismatch"):
            self.assertIn(check, contract)
        support = self.source("native/gi/test_support.h")
        self.assertIn("PassRole::Consumer", support)
        for field in ("nativeGIVisibilityKey", "nativeGIVisibilitySize", "nativeGIVisibilityEnabled",
                      "surfelIndex", "rtParams0"):
            self.assertIn('layout.put(bytes,"' + field + '"', support)
        self.assertNotIn("fill(cb.Get(),&constants,sizeof(constants))", support)
        self.assertIn("testShaderContracts(producerLayout,handoffVS,consumerPS)", support)

    def test_cbv_resolution_requires_owned_actual_range_current_contents_and_lifetime(self):
        contract = self.source("native/gi/shader_contract.h")
        for check in ("owned(device,entry.resource.Get())", "GetGPUVirtualAddress", "GetDesc()",
                      "c.address-base>=d.Width", "layout.cbvSpan()<=d.Width-offset",
                      "D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT", "heap.Type==D3D12_HEAP_TYPE_UPLOAD",
                      "entry.contentsCurrent==1", "entry.unchangedThroughConsumer==1",
                      "entry.key[i]==expectedKey[i]", "matches==1", "out={};reason.clear()"):
            self.assertIn(check, contract)
        support = self.source("native/gi/test_support.h")
        for case in ("CBV outside actual allocation", "CBV padded span exceeds actual allocation",
                     "GPU-only CBV contents unavailable", "ambiguous buffer ownership",
                     "truncated upload contents", "constant content mismatch", "nonfinite constant content",
                     "failed CBV resolution leaked stale ownership/contents"):
            self.assertIn(case, support)
        self.assertIn("constantOffset=256", support)
        self.assertIn("verifyProducerConstants(handoffHost,producerOutput.Get(),expectedOutput)", support)
        self.assertIn("nonzero-offset CBV contents did not reach GPU producer output", support)
        handoff = self.source("native/gi/handoff_validation.h")
        self.assertIn("resolveConstants(e.device,info,*e.layout", handoff)
        self.assertIn('e.layout->field("fixtureControl")', handoff)

    def test_handoff_validator_requires_real_final_consumer_completion(self):
        validator = self.source("native/gi/handoff_validation.h")
        for guard in ("receipt.finalConsumerSubmitted==1", "receipt.consumerValue>receipt.computeValue",
                      "sameObject(receipt.queue,e.queue)", "sameObject(receipt.fence,e.fence)",
                      "done!=UINT64_MAX && done>=receipt.consumerValue", "exclusiveSerializedQueue==1",
                      "unchangedAfterProducerDraw==1"):
            self.assertIn(guard, validator)
        support = self.source("native/gi/test_support.h")
        for check in ("uncompleted producer fence", "unserialized queue context", "stale positive generation key",
                      "failed handoff leaked stale inputs", "validator accepted an incomplete final-consumer fence",
                      "split barriers incorrectly certified as full transitions"):
            self.assertIn(check, support)
        self.assertIn("beamrt_fixture::validateConsumerCompletion(evidence,receipt", support)


if __name__ == "__main__":
    unittest.main()
