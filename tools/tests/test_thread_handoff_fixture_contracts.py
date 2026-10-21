"""Source/isolation guards for the CPU-only interval fixture, not game proof."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ThreadHandoffFixtureContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_model_is_fixed_capacity_and_fixture_only(self):
        model = self.source("thread_handoff_fixture_model.h")
        for text in ("namespace beamrt_fixture", "listLimit=4,tokenLimit=8", "std::array<ListStatus,listLimit>",
                     "std::array<Entry,tokenLimit>", "if(slot==tokenLimit)", "if(ticket==limits.tickets)",
                     "if(serial==limits.publications)", "s->generation==limits.generations", "value==limits.counters"):
            self.assertIn(text, model)
        for text in ("d3d12.h", "windows.h", "LoadLibrary", "GetProcAddress", "ExecuteCommandLists",
                     "CreateProcess", "std::vector", "std::unordered_map"):
            self.assertNotIn(text, model)
        for name in ("gi_bindings.cpp", "bootstrap.cpp", "binding_handoff.cpp", "build.ps1", "build_bindings.ps1"):
            production = self.source(name)
            self.assertNotIn("thread_handoff_fixture", production)

    def test_entire_callback_phases_tokens_and_refused_outputs(self):
        model = self.source("thread_handoff_fixture_model.h")
        for text in ("Entered,Forwarding,NativeReturned,MetadataUpdated", "e.token.ticket!=t.ticket",
                     "e.token.generation!=t.generation", "caller!=t.caller", "s->generation!=t.generation",
                     "e->phase!=before", "e->phase==Phase::MetadataUpdated", "s->active || !s->recording",
                     "s->active || s->recording", "out={}", "s->uncertain || s->active",
                     "if(latest.list==id)available=false", "enabled=false;available=false"):
            self.assertIn(text, model)
        # A metadata lock does not stand in for the forwarding span: every phase
        # is a separate model call; the fixture blocks outside those calls.
        fixture = self.source("thread_handoff_fixture.cpp")
        self.assertIn("model.forwarding(a,1)", fixture)
        self.assertIn("inside.open();release.wait()", fixture)
        self.assertIn("s.callbackOverlaps==1 && !s.forwardingSpanOverlaps", fixture)

    def test_deterministic_threading_and_all_scenario_groups(self):
        fixture = self.source("thread_handoff_fixture.cpp")
        for text in ("condition.wait_for", "std::chrono::seconds(5)", "worker.join()", "release.open()",
                     '"same-thread"', '"sequential-A-B-A"', '"overlapping-forwarding"',
                     '"post-native-metadata-gap"', '"different-lists-concurrent"', '"same-thread-reentry"',
                     '"Close-Reset-crossing"', '"stale-generation"', '"forged-token"', '"duplicate-exit"',
                     '"wrong-caller"', '"missing-entry-phase-exit"', '"reordered-phases"', '"OFF-and-late"',
                     '"bounds-and-capacity"', '"counter-ceilings"', '"receipt-source-isolation"',
                     "forwards==2", "argc!=1", '"/17 CPU-only callback interval cases'):
            self.assertIn(text, fixture)
        for text in ("sleep_for", "Start-Sleep", "Sleep(", "D3D12CreateDevice", "BeamRT_BindingsStart"):
            self.assertNotIn(text, fixture)

    def test_build_does_not_rebuild_or_deploy_native_observers(self):
        build = self.source("build_thread_handoff_fixture.ps1")
        for text in ("/W4 /WX", "thread_handoff_fixture.cpp", "[Guid]::NewGuid()", "fixture.log",
                     "artifacts.sha256.csv", "if($RunTest)", "MSVC environment initialization failed"):
            self.assertIn(text, build)
        for text in ("native/capture/build.ps1", "native/worker/build.ps1", "build_bindings.ps1", "/LD",
                     "d3d12.lib", "dxgi.lib", "Detours", "Start-Process", "--launch-reviewed"):
            self.assertNotIn(text, build)

    def test_ci_runs_the_cpu_fixture_and_source_guards(self):
        workflow = (ROOT / ".github/workflows/beamrt-native-worker.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.count("'tools/tests/test_thread_handoff_fixture_contracts.py'"), 2)
        self.assertIn("python -B tools/tests/test_thread_handoff_fixture_contracts.py", workflow)
        self.assertIn("./native/startup/build_thread_handoff_fixture.ps1 -RunTest", workflow)
        observer = self.source("gi_bindings.cpp")
        self.assertIn("if(s.thread && s.thread!=tid)", observer)
        self.assertIn("s.resetThread=s.thread", observer)


if __name__ == "__main__":
    unittest.main()
