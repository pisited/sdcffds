"""Catch the previously observed v2-header/v1-implementation rollback early.

These source checks supplement, not replace, the native compile/GPU self-test.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeWorkerContracts(unittest.TestCase):
    def test_implementation_matches_the_tested_v2_abi(self):
        source = (ROOT / "native/worker/beamrt_worker.cpp").read_text(encoding="utf-8")
        test = (ROOT / "native/worker/self_test.cpp").read_text(encoding="utf-8")
        self.assertRegex(source, r"BeamRT_WorkerAbiVersion\(\)\s*\{\s*return\s+2\s*;")
        self.assertIn("BeamRT_WorkerAbiVersion()==2", test)

    def test_every_declared_worker_entry_point_is_implemented(self):
        header = (ROOT / "native/worker/beamrt_worker.h").read_text(encoding="utf-8")
        source = (ROOT / "native/worker/beamrt_worker.cpp").read_text(encoding="utf-8")
        names = re.findall(r"BEAMRT_API\s+[^;]*?\b(BeamRT_Worker\w+)\s*\(", header)
        self.assertGreaterEqual(len(names), 8)
        for name in names:
            self.assertRegex(source, rf'extern "C"\s+[^{{;]*?\b{name}\s*\([^;]*?\)\s*\{{')
        for name in ("BeamRT_WorkerCreateOnAdapter", "BeamRT_WorkerGetDeviceInfo",
                     "BeamRT_WorkerDeviceMatchesResource"):
            self.assertIn(name, names)

    def test_restored_device_acquisition_stays_explicit_and_owner_checked(self):
        source = (ROOT / "native/worker/beamrt_worker.cpp").read_text(encoding="utf-8")
        self.assertIn("candidateCreationAllowed==1", source)
        self.assertIn("EnumAdapterByLuid (no default fallback)", source)
        self.assertIn("ours.Get()==theirs.Get()", source)
        lua = (ROOT / "lua/ge/extensions/beamrt/main.lua").read_text(encoding="utf-8")
        self.assertNotIn("ffi.load", lua)
        self.assertNotIn("beamrt_native_worker", lua)


if __name__ == "__main__":
    unittest.main()
