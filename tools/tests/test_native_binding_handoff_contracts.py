"""Startup binding-receipt guards; no native/game loading by Python."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class BindingHandoffContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_separate_opt_in_and_new_output_preflight(self):
        host = self.source("launcher.cpp")
        for guard in ("bool bindings=false", "--observe-gi-bindings", "out.pipeline && !out.bindingOutput.empty()",
                      "binding and root output paths must differ", "binding output already exists", "options.bindings?12:options.pipeline?9",
                      "beamrtBindingGuid", "binding wait must be 1-300 seconds"):
            self.assertIn(guard, host)
        self.assertIn("CREATE_NEW", host)
        self.assertNotIn("BindingsStart(", self.source("bootstrap.cpp"))

    def test_same_audit_session_and_dynamic_existing_runtime_only(self):
        code = self.source("gi_bindings.cpp")
        for guard in ("BEAMRT_BINDING_EMBEDDED", "#define BEAMRT_PIPELINE_AUDIT_BUILD", "GetModuleHandleExW(0,L\"d3d12.dll\"",
                      "GetProcAddress(c.decoderLease.module", "targetFromAudit(false)"):
            self.assertIn(guard, code)
        root = self.source("gi_root_layout.h")
        self.assertIn("#ifdef BEAMRT_BINDING_EMBEDDED", root)
        self.assertIn("if(!function)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND)", root)
        build = self.source("build.ps1")
        for guard in ("gi_bindings.cpp", "binding_handoff.cpp", "binding_slots.c", "/DBEAMRT_BINDING_EMBEDDED"):
            self.assertIn(guard, build)
        self.assertNotIn("beamrt_pipeline_audit.lib", build)

    def test_verified_match_setup_is_outside_audit_and_bridge_locks(self):
        audit = self.source("pipeline_audit.cpp")
        creation = audit[audit.index("static HRESULT STDMETHODCALLTYPE graphicsCall"):audit.index("static HRESULT STDMETHODCALLTYPE streamCall")]
        self.assertLess(creation.index("});"), creation.index("BeamRT_BindingBridgeAuditMatch"))
        bridge = self.source("binding_handoff.cpp")
        target = bridge[bridge.index("void BeamRT_BindingBridgeAuditMatch"):bridge.index("HRESULT BeamRT_BindingStartFromPayload")]
        self.assertLess(target.index("ReleaseSRWLockExclusive"), target.index("BeamRT_BindingsVerifiedAuditMatch"))
        self.assertIn("if(!setup)return", target)
        self.assertIn("if(controlThread && c->status.ownerThread!=GetCurrentThreadId())", self.source("gi_bindings.cpp"))

    def test_versioned_bounded_payload_and_fail_closed_recording_shape(self):
        header = self.source("binding_handoff.h")
        for guard in ("sizeof(BeamRTBindingPayload)==56", "p->processId==pid", "p->initialThread==thread", "p->abi==beamrtBindingHandoffABI", "beamrtBindingHandoffABI=2",
                      "p->startEvent!=p->recordEvent", "s.viewportCount>16", "s.renderTargetCount>8", "s.cbv%256", "sampler[i]!=s.samplerCpu[i]"):
            self.assertIn(guard, header)
        for flag in ("descriptorProvenanceVerified", "cbvContentsVerified", "cameraVerified", "gpuOrderingVerified", "lightingConsumed"):
            self.assertIn("s." + flag, header)
        host = self.source("launcher.cpp")
        self.assertIn("field<37", host)
        self.assertIn("invalid CPU recording shape accepted", host)

    def test_first_immutable_cpu_receipt_no_renderer_or_gpu_work(self):
        code = self.source("binding_handoff.cpp")
        for guard in ("!recorded", "SetEvent(recordEvent)", "reply->start", "FILE_MAP_WRITE", "targetAttempted", "InterlockedExchange64"):
            self.assertIn(guard, code)
        for forbidden in ("CreateThread", "CreateRemoteThread", "LoadLibrary", "ExecuteCommandLists", "CreateCommandQueue", "BeamRT_GIRecord", "BeamRT_CaptureStart"):
            self.assertNotIn(forbidden, code)
        host = self.source("launcher.cpp")
        self.assertIn("state.serial!=record.snapshot.serial", host)
        self.assertIn("CPU recording only", host)

    def test_production_fixture_automatic_setup_and_native_output_comparison(self):
        fixture = self.source("binding_startup_fixture.cpp")
        self.assertNotIn("BeamRT_BindingsStart(", fixture)
        self.assertNotIn("BeamRT_BindingsTargetFromAudit(", fixture)
        for guard in ("D3D12CreateDevice", "std::thread worker", "targetWorkerThread", "automatic observer changed GPU output", "report.snapshot.cbv==constants->GetGPUVirtualAddress()"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("binding-startup-hardware", "binding-startup-warp", "binding-target-worker-thread", "binding-installed-no-draw", "binding-unsupported-root",
                      "binding-default-off", "binding-output-preserved", "receipt.snapshot,&data.snapshot", "all private jobs drained"):
            self.assertIn(guard, harness)


if __name__ == "__main__":
    unittest.main()
