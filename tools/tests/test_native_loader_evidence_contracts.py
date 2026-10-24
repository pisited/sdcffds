"""Fixture evidence source guards only; no process or DLL is started here."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeLoaderEvidenceContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_original_paths_have_verified_copies_before_first_case(self):
        harness = self.source("process_test.cpp")
        for guard in ("inputs.sha256.tsv", "fs::copy_options::none",
                      "hash(destination)==before && hash(source)==before",
                      "capture-", "preserveInputs(root,directory)"):
            self.assertIn(guard, harness)
        self.assertLess(harness.index("preserveInputs(root,directory)"),
                        harness.index('Case baseline{"loader-normal-import-control"}'))
        self.assertIn('root/(test.faultHost?L"beamrt_startup_fault_host.exe":L"beamrt_startup_host.exe")', harness)
        self.assertIn("hash(target)", harness)
        self.assertNotIn("test.faultHost=true", harness[harness.index("if(loader){\n            Case baseline"):])

    def test_host_log_inheritance_is_explicit_and_separate_from_game_transport(self):
        harness = self.source("process_test.cpp")
        for guard in (".command.utf16", ".host.log", ".host-exit.txt",
                      "PROC_THREAD_ATTRIBUTE_HANDLE_LIST,inherited,sizeof(inherited)",
                      "STARTF_USESHOWWINDOW|STARTF_USESTDHANDLES", "CREATE_NEW",
                      "FlushFileBuffers(output.value)", "log.replay()"):
            self.assertIn(guard, harness)
        self.assertNotIn("CREATE_NEW_CONSOLE", harness)
        host = self.source("launcher.cpp")
        self.assertIn("options.bindings?12:options.pipeline?9:options.imports?5:options.entry?3:1", host)
        self.assertNotIn("FixtureLog", host)

    def test_known_loader_refusal_is_fixture_only_and_checks_real_exit_diagnostic(self):
        harness = self.source("process_test.cpp")
        for guard in ("loader-known-missing-dependency", "missing.hostExit=2",
                      "missing.expectEntry=false", "Observed child exit/status: 0xc0000135.",
                      "!fs::exists(report)", "waitEmpty(job.value)"):
            self.assertIn(guard, harness)
        build = self.source("build.ps1")
        self.assertIn("if($RunLoaderTests)", build)
        self.assertIn("beamrt_missing_loader_fixture.lib", build)
        fixture = self.source("loader_missing_fixture.cpp")
        self.assertIn("__declspec(dllimport)", fixture)
        self.assertIn("BeamRT_MissingFixtureDependency();", fixture)
        self.assertIn("beamrt_deliberately_absent_fixture_dependency.dll",
                      self.source("loader_missing_fixture.def"))
        for forbidden in ("LoadLibrary", "CreateProcess", "D3D12", "BeamNG.drive.x64.exe"):
            self.assertNotIn(forbidden, fixture)
        self.assertNotIn("loader_missing_fixture", self.source("bootstrap.cpp"))


if __name__ == "__main__":
    unittest.main()
