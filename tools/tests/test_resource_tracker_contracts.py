"""Offline resource provenance contracts; no game or DLL loading by Python."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class ResourceTrackerContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_default_off_startup_and_isolated_standalone_build(self):
        self.assertNotIn("BeamRT_Resources", self.source("bootstrap.cpp"))
        bridge = self.source("binding_handoff.cpp")
        self.assertIn("#ifdef BEAMRT_RESOURCE_EMBEDDED", bridge)
        self.assertIn("BeamRT_ResourceStartFromPayload(device)", bridge)
        self.assertIn("if(!p)return S_FALSE", self.source("resource_handoff.cpp"))
        self.assertIn("bool resources=false", self.source("launcher.cpp"))
        build = self.source("build_resource_tracker.ps1")
        for forbidden in ("native/capture/build.ps1", "native/worker/build.ps1",
                          "--launch-reviewed", "beamrt_startup_bootstrap.dll", "Invoke-WebRequest"):
            self.assertNotIn(forbidden, build)
        self.assertIn("Guid]::NewGuid", build)
        self.assertIn("/W4 /WX", build)

    def test_sdk_slots_original_forward_and_process_lifetime_off(self):
        slots = self.source("resource_slots.c")
        for method in ("CreateDescriptorHeap", "CreateShaderResourceView",
                       "CreateRenderTargetView", "CreateConstantBufferView",
                       "CreateUnorderedAccessView", "CopyDescriptorsSimple", "CopyDescriptors",
                       "CreateCommittedResource", "CreatePlacedResource", "CreateReservedResource"):
            self.assertIn("SLOT(" + method + ")", slots)
        code = self.source("resource_tracker.cpp")
        for forbidden in ("DetourAttach", "ReadProcessMemory", "CreateRemoteThread",
                          "BeamRT_GIRecord", "LoadLibrary", "CreateCommandQueue"):
            self.assertNotIn(forbidden, code)
        self.assertIn("InterlockedCompareExchangePointer(s.address,value,expected)", code)
        self.assertIn("m.AllocationBase!=s.table", code)
        self.assertIn("LastError e{GetLastError()}", code)
        off = code[code.index('extern "C" HRESULT WINAPI BeamRT_ResourcesDisable'):]
        for forbidden in ("delete", "FreeLibrary", "published=nullptr"):
            self.assertNotIn(forbidden, off)

    def test_lifetime_tokens_no_gpu_child_retention(self):
        code = self.source("resource_tracker.cpp")
        self.assertIn("~LifeTag(){life->alive.store(false);}", code)
        self.assertIn("SetPrivateDataInterface(guid,tag.Get())", code)
        self.assertIn("h.life && !live(h.life))c.views.reapDeadHeap(h.life->id)", code)
        self.assertIn("o.life && !live(o.life))c.views.reapDeadResource(o.life->id)", code)
        context = code[code.index("struct Context {"):code.index("static PVOID")]
        self.assertNotIn("ComPtr<ID3D12Resource>", context)
        self.assertNotIn("ComPtr<ID3D12DescriptorHeap>", context)
        self.assertIn("std::array<Object,beamrtResourceObjectLimit>", context)
        self.assertIn("viewStore::Store views;", context)
        self.assertIn("uint32_t profile=beamrtResourceStorageLegacy", context)
        self.assertIn("explicit Context(uint32_t selectedProfile):profile(selectedProfile),views(selectedProfile)", context)

    def test_copy_unknown_clearing_and_bounded_arithmetic(self):
        code = self.source("resource_tracker.cpp")
        for guard in ("h && !h->visible", "clear(c,cpu,type)",
                      "if(!c.status.healthy || !value.resourceId)return", "n>beamrtResourceCopyLimit-count",
                      "offset>UINT64_MAX-starts[i].ptr", "dc!=sc", "dst[i]==src[j]"):
            self.assertIn(guard, code)
        self.assertNotIn("reinterpret_cast<const uint8_t*>", code)

    def test_cbv_candidate_not_content_or_gpu_proof(self):
        code = self.source("resource_tracker.cpp")
        for guard in ("span>UINT64_MAX-address", "address%D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT",
                      "span<=o.desc.Width-(address-o.address)", "if(match)return", "out.candidateOnly=1"):
            self.assertIn(guard, code)
        self.assertNotIn("->Map(", code)
        self.assertNotIn("descriptorProvenanceVerified=1", code)
        self.assertNotIn("cbvContentsVerified=1", code)
        self.assertIn("c->inFlight.load()==0", code)
        self.assertIn("if(active)", code)

    def test_copy_snapshots_then_clears_whole_batch_before_inserting(self):
        code = self.source("resource_tracker.cpp")
        copy = code[code.index("static void copied("):code.index("using CreateHeap=")]
        snapshot = copy.index("find(c,h->life->id,index,values[i])")
        clear = copy.index("clear(c,dst[i],type)")
        write = copy.index("write(c,dst[i],type,values[i])")
        self.assertLess(snapshot, clear)
        self.assertLess(clear, write)
        self.assertIn("dst[i]==src[j]", copy)
        self.assertIn("i!=j && dst[i]==dst[j]", copy)
        self.assertIn("if(!c.status.healthy)return;", copy[copy.index("auto h=locate("):snapshot])
        self.assertIn("if(!c.status.healthy)return;", copy[clear:write])
        self.assertIn("if(!c.status.healthy){freezeCopyFailure(c,pending,i);return;}", copy[write:])
        self.assertNotIn("std::vector", copy)

    def test_copy_regressions_exercise_full_table_and_real_gpu_snapshots(self):
        fixture = self.source("resource_fixture.cpp")
        for guard in ("mixed copy falsely exhausted capacity despite net-zero final occupancy",
                      "for(bool nullFirst:{false,true})", "--copy-pressure",
                      "BeamRTResourceMethodCopyRanges", "status.serial==failure.serial",
                      "source overwrite changed previously copied view metadata",
                      "destination overwrite changed independent source view metadata",
                      "copy conflated distinct views of one resource", "pixel(24)", "pixel(25)"):
            self.assertIn(guard, fixture)
        build = self.source("build_resource_tracker.ps1")
        self.assertIn("@('heap','resource','view','draw','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')", build)
        self.assertIn("@('normal','resource','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')", build)

    def test_colinked_copy_regression_retains_exact_gi_baseline_and_versioned_abi(self):
        fixture = self.source("binding_startup_fixture.cpp")
        for guard in ("ordering<2", "observed.status.views==beamrtResourceViewLimit",
                      "mixed descriptor known-first copy falsely exhausted full view table",
                      "mixed descriptor null-first copy falsely exhausted full view table",
                      "mixed descriptor copy temporary heap did not retire to seven-view GI baseline"):
            self.assertIn(guard, fixture)
        self.assertIn("beamrtResourceHandoffABI=7", self.source("resource_handoff.h"))
        self.assertIn("beamrtResourceDrawABI=5", self.source("resource_record.h"))

    def test_real_gpu_join_lifetime_pressure_and_off_fixture(self):
        fixture = self.source("resource_fixture.cpp")
        for guard in ("snapshot.srvCpu[i]", "snapshot.renderTargets[0]", "snapshot.cbv",
                      "resource tracker changed native pixel 23", "transient.Reset()",
                      "temporaryHeap.Reset()", "transientBuffer.Reset()", "candidate.offset==256",
                      "known aliased address not refused", "status.restoredSlots==10",
                      "cached(device.Get()", "status.callbacks==frozen",
                      "--resource-pressure", "--view-pressure", "CreateConstantBufferView"):
            self.assertIn(guard, fixture)


if __name__ == "__main__":
    unittest.main()
