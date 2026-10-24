"""Image-scoped import source guards; these checks never load a DLL or game."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ImportObserverContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_separate_payload_defaults_off_and_requires_entry(self):
        host = self.source("launcher.cpp")
        for guard in ("bool imports=false", "--observe-device-import", "!out.imports || out.entry",
                      "options.imports?5:options.entry?3:1", "beamrtImportGuid", "process.dwThreadId",
                      "observed.processId!=process.dwProcessId", "observed.ownerThread!=process.dwThreadId",
                      "!observed.candidateReady", "observed.ambiguous", "FILE_MAP_READ"):
            self.assertIn(guard, host)
        header = self.source("import_observer.h")
        for guard in ("sizeof(BeamRTImportPayload)==48", "p->abi==1", "p->processId==pid", "p->initialThread==tid",
                      "!p->reserved[0]", "!p->reserved[1]", "p->statusMapping!=UINT64_MAX"):
            self.assertIn(guard, header)
        entry = self.source("entry_rendezvous.cpp")
        self.assertLess(entry.index("entryTransaction(false)"), entry.index("BeamRT_ImportStartFromPayload()"))
        self.assertNotIn("BeamRT_ImportStartFromPayload", self.source("bootstrap.cpp"))

    def test_import_identity_alignment_and_atomic_conflict_guard(self):
        observer = self.source("import_observer.cpp")
        for guard in ("DetourEnumerateImportsEx", '_stricmp(name,"d3d12.dll")==0', "module==search.runtime",
                      'GetProcAddress(c->runtime,"D3D12CreateDevice")', "MAKEINTRESOURCEA(ordinal)", "search.matches==1",
                      "!search.conflict", "alignof(PVOID)==0", "memory.AllocationBase!=GetModuleHandleW(nullptr)",
                      "memory.Type!=MEM_IMAGE", "VirtualProtect", "InterlockedCompareExchangePointer(c.slot,replacement,expected)"):
            self.assertIn(guard, observer)
        for forbidden in ("DetourAttach", "SuspendThread", "OpenThread", "CreateThread", "LoadLibrary",
                          "DetourUpdateThread", "CreateCommandQueue", "ExecuteCommandLists", "BeamRT_GIRecord"):
            self.assertNotIn(forbidden, observer)

    def test_callback_preserves_original_and_retains_after_disable(self):
        observer = self.source("import_observer.cpp")
        for guard in ("c->original(adapter,minimum,iid,output)", "LastErrorRestore error{GetLastError()}",
                      "SetLastError(value)", "if(info.disabled)return result", "info.ambiguous=1;info.complete=0",
                      "if(!c->info.complete || c->info.disabled", "(*out)->AddRef()", "*out=nullptr",
                      "GetCurrentThreadId()!=c->info.ownerThread", "c->info.slotRestored=1", "c->info.disabled=1"):
            self.assertIn(guard, observer)
        disable = observer[observer.index('extern "C" HRESULT WINAPI BeamRT_ImportObserveDisable'):]
        for forbidden in ("delete", "FreeLibrary", "currentImport=nullptr", "device.Reset", "original=nullptr"):
            self.assertNotIn(forbidden, disable)
        self.assertIn("if(context()!=c)", observer)
        for field in ("cameraVerified", "resourceStateChainVerified", "gpuOrderingVerified", "lightingConsumed"):
            self.assertIn(field, self.source("import_observer.h"))
            self.assertNotIn("." + field + "=1", observer)

    def test_receipt_is_immutable_first_candidate_not_live_or_gpu_evidence(self):
        observer = self.source("import_observer.cpp")
        for guard in ("if(!c.receipt)return", "FILE_MAP_WRITE", "SetEvent(c.receipt)", "closeReceipt(c)",
                      "if(info.candidateReady || !info.complete)publishOnce", "Process-lifetime publication"):
            self.assertIn(guard, observer)
        fixture = self.source("import_fixture.cpp")
        for guard in ("static BeforeMain fixture", "resource->GetDevice", "same(owner.Get(),observed.Get())",
                      "std::thread concurrent", "const auto cached", "cached(f.adapter.Get()", "initial.calls!=report.afterDisable.calls",
                      "initial.ambiguous", "wrongStop!=HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED)"):
            self.assertIn(guard, fixture)
        self.assertNotIn("BeamRT_ImportStartFromPayload", fixture)
        runner = self.source("process_test.cpp")
        for guard in ("import-hardware", "import-warp", "import-ordinal-warp", "import-absent-fails-closed", "imported.testsMask==2047",
                      "GetExitCodeProcess(targetProcess.value", "waitEmpty(job.value)"):
            self.assertIn(guard, runner)
        self.assertIn("if($RunImportTests)", self.source("build.ps1"))


if __name__ == "__main__":
    unittest.main()
