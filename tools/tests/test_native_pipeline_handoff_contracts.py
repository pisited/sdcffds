"""Startup-connected creation receipts; no game or native loading by Python."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class PipelineHandoffContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_independent_opt_in_hashes_roles_and_inherited_handles(self):
        host = self.source("launcher.cpp")
        for guard in ("bool pipeline=false", "--observe-gi-creation", "out.entry && out.imports", "out.vertexHash.empty()",
                      "out.pixelHash.empty()", "options.pipeline?9:options.imports?5:options.entry?3:1", "beamrtPipelineGuid",
                      "vertexFile->sha256()==options.vertexHash", "pixelFile->sha256()==options.pixelHash",
                      "shaderBytes(1)", "shaderBytes(0)", "CREATE_NEW", "pipeline wait must be 1-300 seconds"):
            self.assertIn(guard, host)
        self.assertNotIn("BeamRT_PipelineAuditStart(", host)

    def test_payload_binds_process_and_bounded_shader_input(self):
        header = self.source("pipeline_handoff.h")
        for guard in ("sizeof(BeamRTPipelinePayload)==72", "p->processId==pid", "p->initialThread", "p->abi==beamrtPipelineHandoffABI",
                      "p->vertexBytes<=16*1024*1024", "p->pixelBytes<=16*1024*1024", "!p->reserved[0]", "!p->reserved[1]"):
            self.assertIn(guard, header)
        code = self.source("pipeline_handoff.cpp")
        for guard in ("GetCurrentThreadId()==p->initialThread", "memory.AllocationBase==GetModuleHandleW(nullptr)",
                      "FILE_MAP_READ", "header->vertexBytes==p->vertexBytes", "header->pixelBytes==p->pixelBytes"):
            self.assertIn(guard, code)

    def test_import_handoff_is_outside_import_lock_and_not_dll_attach(self):
        code = self.source("import_observer.cpp")
        self.assertIn("firstCandidate=device", code)
        self.assertIn("if(firstCandidate)BeamRT_PipelineStartFromPayload(firstCandidate.Get(),_ReturnAddress())", code)
        self.assertLess(code.index("publishOnce(*c)"), code.index("BeamRT_PipelineStartFromPayload("))
        self.assertNotIn("PipelineStartFromPayload", self.source("bootstrap.cpp"))
        transport = self.source("pipeline_handoff.cpp")
        for forbidden in ("CreateThread", "ExecuteCommandLists", "BeamRT_GIRecord", "CreateFileW", "LoadLibrary"):
            self.assertNotIn(forbidden, transport)

    def test_installation_does_not_imply_match_and_match_does_not_imply_draw(self):
        code = self.source("pipeline_handoff.cpp")
        for guard in ("reply->start", "reply->match", "!matched", "SetEvent(matchEvent)", "SetEvent(start)"):
            self.assertIn(guard, code)
        host = self.source("launcher.cpp")
        for guard in ("No pipeline start receipt", "No exact pipeline creation receipt", "!info.creationMatchAvailable", "info.drawBindingsVerified",
                      "info.cameraVerified", "info.gpuOrderingVerified", "info.lightingConsumed", "Approximate diagnostics only"):
            self.assertIn(guard, host)
        self.assertIn("InterlockedExchange64", code)
        self.assertNotIn("resourceStateChainVerified=1", code)

    def test_v2_diagnostics_include_failure_and_pressure_without_gpu_proof(self):
        header = self.source("pipeline_handoff.h")
        self.assertIn("beamrtPipelineHandoffABI=2", header)
        self.assertIn("beamrtPipelineAuditInfoABI=2", self.source("pipeline_audit.h"))
        host = self.source("launcher.cpp")
        for guard in ("beamrtPipelineFailureName", "progress.failureResult", "progress.budgetSkipped", "progress.liveRootTags", "progress.metadataBytes"):
            self.assertIn(guard, host)
        self.assertIn("InterlockedExchange(&p.failureReason", self.source("pipeline_handoff.cpp"))

    def test_startup_fixture_reports_exact_conflict_without_root_output(self):
        fixture = self.source("pipeline_startup_fixture.cpp")
        for guard in ("pressure(96)", "--root-conflict", "BeamRTPipelineFailure::rootEvidenceConflict", "report.audit.failureResult!=E_INVALIDARG"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("pipeline-conflict-hardware", "pipeline-conflict-warp", "!fs::exists(rootOutput)", "all private jobs drained"):
            self.assertIn(guard, harness)

    def test_fixture_uses_production_startup_and_independent_root_hash(self):
        fixture = self.source("pipeline_startup_fixture.cpp")
        self.assertNotIn("BeamRT_PipelineAuditStart(", fixture)
        for guard in ("D3D12CreateDevice", "CreateGraphicsPipelineState", "seenPipeline->GetDevice", "BCryptHash", "disable()"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("pipeline-startup-hardware", "pipeline-startup-warp", "pipeline-installed-without-match", "pipeline-shader-hash-refused",
                      "pipeline-output-preserved", "pipeline-wrong-stage-refused", "hash(rootOutput)==digest"):
            self.assertIn(guard, harness)
        build = self.source("build.ps1")
        self.assertIn("pipeline_handoff.cpp", build)
        self.assertIn("/DBEAMRT_PIPELINE_HANDOFF", build)
        self.assertIn("if($RunPipelineStartupTests)", build)


if __name__ == "__main__":
    unittest.main()
