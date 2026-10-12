"""Source safety contracts for the isolated public-D3D12 capture prototype.

Actual interception and unchanged GPU results are tested by capture/self_test.cpp.
Neither this file nor that fixture proves BeamNG loading, camera data or lighting.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeCaptureContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / name).read_text(encoding="utf-8")

    def setUp(self):
        self.capture = self.source("native/capture/beamrt_capture.cpp")
        self.header = self.source("native/capture/beamrt_capture.h")

    def test_no_automatic_loader_or_external_process_injection(self):
        for symbol in ("DllMain", "D3D12CreateDevice", "LoadLibrary", "LoadLibraryW",
                       "VirtualAllocEx", "WriteProcessMemory", "CreateRemoteThread",
                       "DetourCreateProcessWithDllEx", "DetourCreateProcessWithDlls"):
            self.assertNotRegex(self.capture, rf"\b{symbol}\s*\(")
        lua = self.source("lua/ge/extensions/beamrt/main.lua")
        self.assertNotIn("beamrt_capture", lua)
        self.assertNotIn("ffi.load", lua)

    def test_sdk_abi_slots_not_private_engine_addresses(self):
        sdk = self.source("native/capture/sdk_methods.c")
        for interface in ("ID3D12DeviceVtbl", "ID3D12GraphicsCommandListVtbl",
                          "ID3D12CommandQueueVtbl"):
            self.assertIn(f"offsetof({interface},", sdk)
        self.assertNotRegex(sdk, r"\[\s*\d+\s*\]")
        self.assertIn("beamrtSDKMethod(device,list.Get(),queue.Get(),i)", self.capture)
        self.assertIn("aliased/missing SDK method implementation unsupported", self.capture)

    def test_actual_hooks_forward_renderer_calls(self):
        methods = ("CreateHeap", "CreateSRV", "CreateCBV", "CreateUAV", "CreateRTV", "CopySimple",
                   "CopyRanges", "CreateRoot", "CreateGraphics", "CreateCompute",
                   "CreateList", "ResetList", "ClearList", "SetHeaps", "SetPipeline",
                   "SetGraphicsRoot", "SetComputeRoot", "SetGraphicsTable",
               "SetComputeTable", "SetGraphicsConstant", "SetComputeConstant",
               "SetGraphicsConstants", "SetComputeConstants", "SetGraphicsCBV", "SetComputeCBV",
               "SetGraphicsUAV", "SetComputeUAV", "SetViewports", "SetScissors",
               "SetRenderTargets", "ResourceBarrier", "Draw", "DrawIndexed", "Dispatch",
               "Bundle", "Indirect", "ExecuteLists", "QueueSignal", "QueueWait")
        for method in methods:
            self.assertRegex(self.capture, rf"STDMETHODCALLTYPE h{method}\(")
            self.assertRegex(self.capture, rf"\bo{method}\(self,")
            self.assertIn(f"reinterpret_cast<PVOID>(h{method})", self.capture)
        self.assertIn("DetourAttach(hook.original,hook.replacement)", self.capture)
        self.assertIn("DetourDetach(hook.original,hook.replacement)", self.capture)

    def test_pass_and_layout_must_both_match_exact_bytes(self):
        self.assertIn("code.BytecodeLength==bytes.size()", self.capture)
        self.assertIn("std::memcmp(code.pShaderBytecode,bytes.data(),bytes.size())==0", self.capture)
        self.assertIn("count!=h.root.size() || std::memcmp(bytes,h.root.data(),count)", self.capture)
        for stage in ("PS", "CS"):
            self.assertIn(f"!bytesMatch(desc->{stage},h.shader)", self.capture)
        self.assertIn("D3D12CreateRootSignatureDeserializer", self.capture)
        self.assertIn("SRV offset invalid/duplicate", self.capture)

    def test_metadata_only_no_capture_gpu_work_or_readback(self):
        for method in ("Map", "Unmap", "Dispatch", "DrawInstanced", "DrawIndexedInstanced",
                       "ResourceBarrier", "CopyResource", "CopyBufferRegion",
                       "CopyTextureRegion", "ExecuteCommandLists", "Signal", "Wait"):
            self.assertNotRegex(self.capture, rf"->\s*{method}\s*\(")
        for symbol in ("D3D12_HEAP_TYPE_READBACK", "CreateCommittedResource", "WaitForSingleObject"):
            self.assertNotIn(symbol, self.capture)
        self.assertIn("No new device, GPU submission", self.capture)
        self.assertIn("No loader, renderer replacement", self.header)

    def test_descriptor_provenance_and_submission_time_resolution(self):
        self.assertIn("if(!heap || heap->shaderVisible)continue;", self.capture)
        self.assertIn("views.erase(to[i].ptr)", self.capture)
        self.assertIn("h.copyHandles(from,to)", self.capture)
        self.assertIn("views.find(cpuHandle(state->candidate,config.offsets[n]))", self.capture)
        submit = self.capture[self.capture.index("static void STDMETHODCALLTYPE hExecuteLists"):]
        self.assertLess(submit.index("h.submit(self,count,lists)"), submit.index("oExecuteLists(self,count,lists)"))
        for method in ("hCreateCBV", "hCreateUAV"):
            start = self.capture.index(f"static void STDMETHODCALLTYPE {method}")
            end = self.capture.index("\nstatic ", start + 1)
            self.assertIn("h.views.erase(handle.ptr)", self.capture[start:end])

    def test_reset_heap_changes_and_unsupported_commands_invalidate(self):
        self.assertEqual(self.capture.count("const auto generation=old->generation+1"), 2)
        self.assertIn("sampler.Get()!=state->samplerHeap.Get()", self.capture)
        self.assertIn("state->graphicsTables.clear();state->computeTables.clear();", self.capture)
        self.assertIn("if(state->poisoned || !state->candidate.heap)", self.capture)
        self.assertIn("host->config.threadMode==BEAMRT_CAPTURE_SINGLE_THREAD", self.capture)
        self.assertIn("single-thread capture received another API-calling thread", self.capture)
        self.assertIn("catch(const std::exception& e)", self.capture)
        self.assertIn("noexcept", self.capture)
        self.assertIn("catch(const std::exception& e){host->poison(e.what());}", self.capture)

    def test_bounded_lifetimes_and_no_false_lighting_certification(self):
        self.assertIn("ComPtr<ID3D12Resource> references[8]", self.capture)
        self.assertIn("BeamRTCaptureInfo info{}", self.capture)
        for flag in ("cameraVerified", "gpuOrderingVerified", "lightingConsumed"):
            self.assertIn(flag, self.header)
            self.assertNotRegex(self.capture, rf"\b{flag}\s*=")
        for limit in ("heaps.size()<64", "views.size()<512", "roots.size()<32",
                      "pipelines.size()<64", "commands.size()<64", "queues.size()<32"):
            self.assertIn(limit, self.capture)
        self.assertIn("new BeamRTCaptureSnapshot(*h->latest)", self.capture)
        self.assertIn("transaction(false);current=nullptr;delete h;*out=nullptr", self.capture)
        self.assertIn("GetCurrentThreadId()==h->thread && activeCalls==0", self.capture)
        self.assertIn("Failure retains host/hooks", self.header)

    def test_queue_specific_snapshots_cannot_borrow_global_latest(self):
        method = self.capture[self.capture.index('extern "C" int BeamRT_CaptureGetSnapshotForQueue'):]
        method = method[:method.index('extern "C" int BeamRT_CaptureReadSnapshot')]
        self.assertIn("h->owns(queue)", method)
        self.assertIn("h->queues.find(queue)", method)
        self.assertIn("new BeamRTCaptureSnapshot(*found->second.latest)", method)
        self.assertNotIn("*h->latest", method)
        self.assertIn("queueState.latest.reset()", self.capture)
        self.assertIn("snapshot->queueReference=queue;snapshot->info.queue=queue", self.capture)
        self.assertIn("queues.clear()", self.capture)

    def test_v3_threading_contract_retains_quiescent_owner_detach(self):
        self.assertRegex(self.capture, r"BeamRT_CaptureAbiVersion\(\)\s*\{return 3;")
        self.assertIn("threadMode,reserved2", self.header)
        self.assertIn("cfg->threadMode<=BEAMRT_CAPTURE_MULTITHREAD", self.capture)
        self.assertIn("std::lock_guard<std::mutex> lock(host->mutex)", self.capture)
        self.assertIn("GetCurrentThreadId()==h->thread && activeCalls==0", self.capture)
        self.assertNotIn("SuspendThread", self.capture)
        self.assertNotIn("CreateToolhelp32Snapshot", self.capture)
        fixture = self.source("native/capture/thread_fixture.h")
        for evidence in ("std::launch::async", "BEAMRT_CAPTURE_MULTITHREAD",
                         "queue-specific capture mixed independent resources",
                         "invalid queue retained stale descriptor provenance",
                         "one invalid queue changed the other queue's capture",
                         "another control thread detached the capture hooks",
                         "multithread capture changed normal GPU output"):
            self.assertIn(evidence, fixture)

    def test_draw_context_is_bounded_and_observational(self):
        for field in ("viewports[BEAMRT_CAPTURE_MAX_VIEWPORTS]", "scissors[BEAMRT_CAPTURE_MAX_VIEWPORTS]",
                      "renderTargets[BEAMRT_CAPTURE_MAX_OUTPUTS]", "rootValues[BEAMRT_CAPTURE_MAX_ROOT_VALUES]",
                      "transitions[BEAMRT_CAPTURE_MAX_TRANSITIONS]", "queueSignalFence", "queueWaitFence"):
            self.assertIn(field, self.header)
        self.assertIn("info.resourceStateChainVerified=0", self.capture)
        self.assertIn("gpuOrderingVerified", self.header)
        self.assertIn("queueExecutionSerial", self.capture)
        fixture = self.source("native/capture/self_test.cpp")
        for evidence in ("viewport/scissor context mismatch", "render-target provenance mismatch",
                         "per-draw root constant mismatch", "resource transition evidence missing",
                         "queue signal/wait evidence missing", "compute output binding not captured"):
            self.assertIn(evidence, fixture)

    def test_pinned_dependency_ignored_output_and_independent_ci(self):
        build = self.source("native/capture/build.ps1")
        self.assertIn("e4bfd6b03e50de46b47abfbd1e46b384f0c5f833", build)
        self.assertIn("https://github.com/microsoft/Detours.git", build)
        self.assertIn("status --porcelain --untracked-files=no", build)
        self.assertIn(".beamrt-validation/native-capture", build)
        self.assertIn(".beamrt-validation/", self.source(".gitignore"))
        self.assertIn("/W4 /WX", build)
        self.assertIn("/Ges /WX", build)
        workflow = self.source(".github/workflows/beamrt-native-capture.yml")
        self.assertIn("./native/capture/build.ps1 -RunTest -Warp", workflow)
        self.assertNotIn("native/worker/build.ps1", workflow)
        self.assertNotIn("native/gi/build.ps1", workflow)

    def test_real_fixture_covers_graphics_compute_and_restoration(self):
        fixture = self.source("native/capture/self_test.cpp")
        for entry in ("DrawInstanced", "Dispatch", "CopyDescriptorsSimple", "CopyDescriptors",
                      "ExecuteCommandLists", "BeamRT_CaptureStop", "ExecuteBundle"):
            self.assertIn(entry, fixture)
        for evidence in ("read-only hooks changed normal GPU output",
                         "unknown descriptor reused stale resource provenance",
                         "unsupported bundle certified a capture",
                         "unsupported multi-thread scope certified",
                         "capture budget error did not invalidate metadata",
                         "capture ABI mismatch",
                         "compute interception changed GPU output"):
            self.assertIn(evidence, fixture)
        self.assertEqual(fixture.count("D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE"), 2)
        self.assertEqual(fixture.count("D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE"), 2)
        self.assertNotIn("CaptureObserve", fixture)


if __name__ == "__main__":
    unittest.main()
