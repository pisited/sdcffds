"""Device-creation source guards; neither this module nor CI launches a game."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DeviceObserverContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_explicit_post_loader_hook_preserves_exact_original_call(self):
        observer = self.source("device_observer.cpp")
        for guard in ("PFN_D3D12_CREATE_DEVICE", "originalCreateDevice(adapter,minimum,iid,output)",
                      'GetModuleHandleExW(0,L"d3d12.dll"', 'GetProcAddress(pending->runtime.value,"D3D12CreateDevice")',
                      "DetourUpdateThread(GetCurrentThread())", "DetourTransactionAbort", "return result;"):
            self.assertIn(guard, observer)
        for forbidden in ("DllMain", "LoadLibrary", "CreateThread", "BeamRT_CaptureStart", "ExecuteCommandLists",
                          "CreateCommittedResource", "CreateCommandQueue", "BeamRT_GIRecord"):
            self.assertNotIn(forbidden, observer)
        bootstrap = self.source("bootstrap.cpp")
        self.assertNotIn("BeamRT_DeviceObserveStart", bootstrap)
        self.assertNotIn("device_observer.h", bootstrap)
        self.assertIn("No BeamNG initialization point is provided", self.source("device_observer.h"))

    def test_incomplete_or_stale_observations_do_not_publish_device(self):
        observer = self.source("device_observer.cpp")
        for guard in ("info.lastCallerThread!=info.ownerThread", "h->identity.Get()!=identity.Get()",
                      "generation!=h->info.generation", "!h->info.complete || !h->device", "*out=nullptr",
                      "(*out)->AddRef()", "GetDeviceRemovedReason", "info.probes", "info.failedCalls"):
            self.assertIn(guard, observer)
        header = self.source("device_observer.h")
        for unknown in ("cameraVerified", "resourceStateChainVerified", "gpuOrderingVerified", "lightingConsumed"):
            self.assertIn(unknown, header)
            self.assertNotIn("." + unknown + "=1", observer)
        self.assertIn("pending->info.generation=++nextGeneration", observer)

    def test_stop_retains_until_owner_and_quiescence_contract_succeeds(self):
        observer = self.source("device_observer.cpp")
        for guard in ("quiet!=1", "GetCurrentThreadId()!=h->info.ownerThread", "activeCallbacks,0,0)!=0",
                      "const HRESULT result=transaction(false);if(FAILED(result))return result",
                      "current=nullptr;originalCreateDevice=nullptr;retired=h;*out=nullptr", "delete retired"):
            self.assertIn(guard, observer)
        self.assertIn("ModuleLease runtime; // destroyed AFTER retained COM interfaces", observer)
        self.assertIn("Counters do not prove quiescence", self.source("device_observer.h"))

    def test_loaded_fixture_exercises_device_identity_and_native_restore(self):
        fixture = self.source("device_fixture.cpp")
        for check in ("IID_PPV_ARGS(&created)", "same(created.Get(),observed.Get())", "resource->GetDevice",
                      "baselineFailure", "baselineProbe", "wrongStop==HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)",
                      "oldGeneration", "std::memcmp(before", "!same(first.Get(),foreign.Get())", "observer.stop=stop"):
            self.assertIn(check, fixture)
        build = self.source("build.ps1")
        self.assertIn("if($RunDeviceTests)", build)
        self.assertIn("$beamrtOutput --device", build)
        self.assertNotIn("beamrt_capture.lib", build)
        self.assertNotIn("beamrt_native_gi.lib", build)
        for line in build.splitlines():
            if "& cl.exe" in line and "bootstrap.cpp" in line:
                self.assertNotIn("d3d12.lib", line)


if __name__ == "__main__":
    unittest.main()
