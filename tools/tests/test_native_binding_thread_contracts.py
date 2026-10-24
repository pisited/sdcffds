"""Bounded CPU thread-evidence source guards; no native/game loading here."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BindingThreadContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_bounded_epoch_samples_counts_and_existing_guard(self):
        header = self.source("binding_thread_diagnostics.h")
        for guard in ("beamrtBindingThreadSampleLimit=16", "beamrtBindingMethodCount=24", "==1160",
                      "d.repeatedCalls!=d.threadRejected-d.firstEpochConflicts", "d.droppedEpochSamples",
                      "d.byMethod[i]>UINT64_MAX-sum", "s.expectedThread!=s.callerThread"):
            self.assertIn(guard, header)
        code = self.source("gi_bindings.cpp")
        for guard in ("if(s.threadConflict)", "d.sampleCount==beamrtBindingThreadSampleLimit", "++d.beforeTarget", "++d.afterTarget",
                      "s.resetThread && !s.firstRecordingThread", "c.status.threadRejected==UINT64_MAX",
                      "if(s.thread && s.thread!=tid)", "s.resetThread=s.thread", "s.threadConflict=conflict"):
            self.assertIn(guard, code)
        self.assertNotIn("s.thread=0", code)
        self.assertNotIn("CaptureStackBackTrace", code)
        self.assertNotIn("CreateThread", code)

    def test_versioned_transport_preserves_old_record_and_immutable_prefix(self):
        header = self.source("binding_handoff.h")
        for guard in ("beamrtBindingHandoffABI=2", "p->abi==beamrtBindingHandoffABI", "==1144", "==1184", "==912"):
            self.assertIn(guard, header)
        bridge = self.source("binding_handoff.cpp")
        for guard in ("out.samples[count]=sample", "InterlockedExchange(&out.count,count+1)", "!recorded",
                      "diagnostics.threadRejected==s.threadRejected", "frame.serial,diagnostics"):
            self.assertIn(guard, bridge)
        self.assertLess(bridge.index("frame.serial,diagnostics"), bridge.index("SetEvent(recordEvent)"))
        host = self.source("launcher.cpp")
        for guard in ("legacy binding transport accepted", "field<24", "invalid thread diagnostic evidence accepted",
                      'L".threads.bin"', 'L".thread-samples.bin"', "threads.snapshotSerial!=record.snapshot.serial",
                      "MemoryBarrier()", "thread evidence output already exists", "thread evidence aliases root output"):
            self.assertIn(guard, host)
        prefix = host[host.index("static void saveThreadPrefix"):host.index("static int launchReviewed")]
        self.assertNotIn("Interlocked", prefix)  # Never writes the read-only shared mapping.
        self.assertIn("for(LONG i=0;i<count", prefix)

    def test_actual_fixtures_check_repeats_pressure_off_and_timeout_evidence(self):
        fixture = self.source("binding_fixture.cpp")
        for guard in ("diagnostic.threadRejected==55", "diagnostic.firstEpochConflicts==23", "diagnostic.repeatedCalls==32",
                      "diagnostic.sampleCount==16", "diagnostic.droppedEpochSamples==7", "diagnostic.samples[2].sourceWasSnapshot",
                      "!disabled.enabled", "Reset-pinned pre-target attribution failed"):
            self.assertIn(guard, fixture)
        runner = self.source("process_test.cpp")
        for guard in ("binding-thread-attribution-hardware", "binding-thread-attribution-warp", "binding-thread-evidence-without-draw",
                      "binding-thread-output-preserved", "threads.diagnostics,&data.diagnostics", "prefix.samples[i],&data.diagnostics.samples[i]",
                      "bindings?11"):
            self.assertIn(guard, runner)
        bridge = self.source("binding_handoff.cpp")
        for forbidden in ("LoadLibrary", "CreateThread", "ExecuteCommandLists", "BeamRT_CaptureStart", "BeamRT_GIRecord"):
            self.assertNotIn(forbidden, bridge)


if __name__ == "__main__":
    unittest.main()
