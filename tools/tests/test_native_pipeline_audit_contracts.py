"""Creation-only SDK slot audit guards; no native/game loading by these tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class PipelineAuditContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_public_slots_not_instruction_detours_or_truncated_tables(self):
        slots = self.source("pipeline_slots.c")
        for name in ("ID3D12DeviceVtbl,CreateRootSignature", "ID3D12DeviceVtbl,CreateGraphicsPipelineState", "ID3D12Device2Vtbl,CreatePipelineState"):
            self.assertIn("offsetof(" + name, slots)
        code = self.source("pipeline_audit.cpp")
        for guard in ("InterlockedCompareExchangePointer(slot.address,replacement,expected)", "memory.AllocationBase!=slot.tableModule", "GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS"):
            self.assertIn(guard, code)
        for forbidden in ("DetourAttach", "SuspendThread", "OpenThread", "LoadLibrary", "CreateThread", "CreateCommandQueue", "ExecuteCommandLists", "BeamRT_GIRecord"):
            self.assertNotIn(forbidden, code)

    def test_exact_two_shader_contract_and_observed_root_required(self):
        code = self.source("pipeline_audit.cpp")
        for guard in ("same(desc->VS,a->vertex)", "same(desc->PS,a->pixel)", "rootEvidence(a->roots.budget,desc->pRootSignature,root)", "unknownRootMatches",
                      "child(*a,pipeline.Get())", "a->matchedRootBytes.assign", "count>65536"):
            self.assertIn(guard, code)
        self.assertIn("unsupportedStreams", code)
        self.assertNotIn("reinterpret_cast<const D3D12_GRAPHICS_PIPELINE_STATE_DESC*>(desc", code)

    def test_object_owned_metadata_has_weak_cache_and_bounded_pressure(self):
        code = self.source("pipeline_root_metadata.h")
        for guard in ("std::vector<std::weak_ptr<RootRecord>>", "SetPrivateDataInterface", "object.Attach(pointer)",
                      "budget.known.count(pointer)", "beamrtPipelineMetadataBudget-prior", "beamrtPipelineLayoutCacheLimit", "return S_FALSE"):
            self.assertIn(guard, code)
        self.assertNotIn("ComPtr<ID3D12RootSignature>", code)
        self.assertNotIn("ComPtr<ID3D12Device>", code)
        audit = self.source("pipeline_audit.cpp")
        self.assertNotIn("roots.size()>=32", audit)
        self.assertIn("if(attached==S_FALSE)", audit)
        self.assertIn("increment(a->info.budgetSkipped", audit)
        fixture = self.source("pipeline_fixture.cpp")
        for guard in ("pressure(96)", "info.liveLayouts>32", "info.liveLayouts==1", "info.metadataBytes<busyBytes"):
            self.assertIn(guard, fixture)

    def test_first_fatal_reason_and_result_are_not_overwritten(self):
        audit = self.source("pipeline_audit.cpp")
        self.assertIn("if(!a.info.failureReason)", audit)
        self.assertIn("a.info.failureResult=result", audit)
        for guard in ("BeamRTPipelineFailure::allocation", "BeamRTPipelineFailure::rootEvidenceConflict",
                      "BeamRTPipelineFailure::slotInstall", "BeamRTPipelineFailure::slotRestore", "BeamRTPipelineFailure::deviceRemoved"):
            self.assertIn(guard, audit)

    def test_late_callbacks_survive_disable_and_early_failure(self):
        code = self.source("pipeline_audit.cpp")
        self.assertLess(code.index("InterlockedExchangePointer(&published,resident)"), code.index("exchange(slot,slot.original,slot.replacement"))
        disable = code[code.index('extern "C" HRESULT WINAPI BeamRT_PipelineAuditDisable'):]
        for forbidden in ("delete", "FreeLibrary", "published=nullptr", "device.Reset", "roots.clear"):
            self.assertNotIn(forbidden, disable)
        self.assertIn("a->info.ownerThread!=GetCurrentThreadId()", disable)
        self.assertIn("a->info.enabled=0", disable)
        self.assertIn("RestoreError error{GetLastError()}", code)
        self.assertIn("if(actual)*actual=0;if(root)*root=nullptr;if(pipeline)*pipeline=nullptr", code)

    def test_creation_does_not_become_draw_or_resource_proof(self):
        header = self.source("pipeline_audit.h")
        code = self.source("pipeline_audit.cpp")
        for flag in ("drawBindingsVerified", "cameraVerified", "gpuOrderingVerified", "lightingConsumed"):
            self.assertIn(flag, header)
            self.assertNotIn("." + flag + "=1", code)
        for name in ("import_observer.cpp", "entry_rendezvous.cpp", "bootstrap.cpp", "launcher.cpp"):
            self.assertNotIn("BeamRT_PipelineAuditStart", self.source(name))
        fixture = self.source("pipeline_fixture.cpp")
        for guard in ("unknownRootMatches==1", "info.shaderMatches==expectedMatches", "seenPipeline->GetDevice", "cachedRoot(device.Get()", "info.rootsObserved==frozen"):
            self.assertIn(guard, fixture)

    def test_real_budget_and_foreign_tag_rejections_keep_native_api_results(self):
        fixture = self.source("pipeline_fixture.cpp")
        for guard in ("bulkParams[64]", "info.budgetSkipped>before", "info.unknownRootMatches==2", "const ULONG_PTR foreign=1",
                      "BeamRTPipelineFailure::rootEvidenceConflict", "info.failureReason==firstReason", "invalidated match still readable"):
            self.assertIn(guard, fixture)
        self.assertIn("@beamrtFixtureArgs --conflict", self.source("build_pipeline_audit.ps1"))


if __name__ == "__main__":
    unittest.main()
