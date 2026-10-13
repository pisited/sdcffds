"""Standalone recording-observer guards, never game/native loading by Python."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class BindingContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_target_only_from_actual_creation_audit_and_sdk_layout(self):
        code = self.source("gi_bindings.cpp")
        self.assertIn("BeamRT_PipelineAuditReadMatch", code)
        self.assertIn("beamrtDecodeGIRoot(bytes,size,layout)", code)
        self.assertIn("child(*c,rootObject.Get())", code)
        layout = self.source("gi_root_layout.h")
        for guard in ("D3D12CreateVersionedRootSignatureDeserializer", "root.NumParameters!=3", "root.NumStaticSamplers",
                      "p.Descriptor.ShaderRegister", "r.NumDescriptors!=6", "r.BaseShaderRegister", "r.RegisterSpace", "r.OffsetInDescriptorsFromTableStart"):
            self.assertIn(guard, layout)

    def test_atomic_sdk_slots_no_old_capture_or_instruction_patch(self):
        slots = self.source("binding_slots.c")
        for method in ("CreateCommandList", "CreateCommandList1", "Reset", "DrawInstanced", "DrawIndexedInstanced", "BeginRenderPass", "EndRenderPass", "ExecuteIndirect"):
            self.assertIn("," + method + ")", slots)
        code = self.source("gi_bindings.cpp")
        for guard in ("InterlockedCompareExchangePointer(s.address,value,expected)", "m.AllocationBase!=s.table", "c.slotCount.store(count+1)"):
            self.assertIn(guard, code)
        for forbidden in ("DetourAttach", "SuspendThread", "CreateRemoteThread", "BeamRT_CaptureStart", "BeamRT_GIRecord", "LoadLibrary", "CreateCommandQueue"):
            self.assertNotIn(forbidden, code)

    def test_bounded_object_owned_tags_and_late_off_contract(self):
        code = self.source("gi_bindings.cpp")
        for guard in ("beamrtBindingCommandLimit", "SetPrivateDataInterface", "c.tags.count(raw)", "c->status.pressureSkipped", "c->live.load()"):
            self.assertIn(guard, code)
        self.assertNotIn("ComPtr<ID3D12GraphicsCommandList>", code[:code.index("static void created(ID3D12Device* d")])
        off = code[code.index('extern "C" HRESULT WINAPI BeamRT_BindingsDisable'):]
        for forbidden in ("delete", "FreeLibrary", "published=nullptr", "targetRoot.Reset"):
            self.assertNotIn(forbidden, off)
        self.assertIn("LastError e{GetLastError()}", code)

    def test_invalidations_and_handles_never_certify_resources(self):
        code = self.source("gi_bindings.cpp")
        for guard in ("s.generation+1", "s.thread!=tid", "s.kinds[i]==2", "if(!identical(s.root.Get(),p))", "unsupported(l)", "c.status.snapshotAvailable=0"):
            self.assertIn(guard, code)
        header = self.source("gi_bindings.h")
        for flag in ("descriptorProvenanceVerified", "cbvContentsVerified", "cameraVerified", "gpuOrderingVerified", "lightingConsumed"):
            self.assertIn(flag, header)
            self.assertNotIn("." + flag + "=1", code)
        bounds = self.source("binding_validation.h")
        for guard in ("h.count<6", "index>uint64_t(h.count)-6", "offset>UINT64_MAX-h.cpu", "(address-h.gpu)%h.stride"):
            self.assertIn(guard, bounds)

    def test_fixture_reads_gpu_output_and_restores_native_callbacks(self):
        fixture = self.source("binding_fixture.cpp")
        for guard in ("recordedDraw", "snapshot.cbv==constants->GetGPUVirtualAddress()", "observer changed native GPU output", "pressure(65)",
                      "ordinary command lists retained", "cached(render.list.Get()", "status.serial==frozen", "unavailable()", "differentRoot"):
            self.assertIn(guard, fixture)
        build = self.source("build_bindings.ps1")
        for guard in ("/W4 /WX", "beamrt_gi_bindings.dll", "--fixture-root-out", "beamrt_binding_fixture.exe"):
            self.assertIn(guard, build)
        startup = self.source("build.ps1")
        self.assertNotIn("gi_bindings.cpp", startup)
        self.assertNotIn("BindingsStart", self.source("bootstrap.cpp"))


if __name__ == "__main__":
    unittest.main()
