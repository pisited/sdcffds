"""Native entry source guards; no game launch or DLL loading by these tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EntryContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_separate_payload_and_default_off_native_only_entry(self):
        launcher = self.source("launcher.cpp")
        for guard in ("bool entry=false", "--entry-rendezvous", "exe.nativeEntryRva()", "beamrtEntryGuid",
                      "process.dwThreadId", "entryEvent.value", "options.entry?3:1", "No native-entry receipt",
                      "status.entryBytesRestored", "status.ownerThread!=process.dwThreadId", "FILE_MAP_READ"):
            self.assertIn(guard, launcher)
        entry = self.source("entry_rendezvous.cpp")
        for guard in ("if(!p)return S_FALSE", "DetourGetEntryPoint(exe)", "DetourGetContainingModule(originalAddress)!=exe",
                      "IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR", "VirtualQuery", "memory.AllocationBase!=exe", "PAGE_GUARD|PAGE_NOACCESS"):
            self.assertIn(guard, entry)
        contract = self.source("entry_contract.h")
        for guard in ("p->processId==pid", "p->initialThread==tid", "p->expectedEntryRva", "!p->reserved"):
            self.assertIn(guard, contract)

    def test_tail_forwarding_preserves_stack_flags_and_volatile_entry_state(self):
        assembly = self.source("entry_thunk.asm")
        self.assertLess(assembly.index("pushfq"), assembly.index("sub rsp"))
        self.assertIn(".allocstack 8", assembly)
        self.assertIn(".allocstack 0C0h", assembly)
        self.assertIn("mov rcx,rsp", assembly)
        self.assertIn("call BeamRT_EntryInitialize", assembly)
        self.assertIn("popfq", assembly)
        self.assertIn("jmp QWORD PTR [beamrtOriginalEntry]", assembly)
        self.assertNotIn("call beamrtOriginalEntry", assembly)
        for register in ("rax", "rcx", "rdx", "r8", "r9", "r10", "r11", "xmm0", "xmm5"):
            self.assertIn(register, assembly)

    def test_production_entry_remains_passive_and_does_not_certify_graphics_quiescence(self):
        entry = self.source("entry_rendezvous.cpp")
        activation = entry.index("info.deviceResult=BeamRT_DeviceObserveStart")
        self.assertLess(entry.index("#ifdef BEAMRT_ENTRY_FIXTURE_AUTOSTART"), activation)
        self.assertIn('lstrcmpW(name,L"beamrt_entry_fixture.exe")==0', entry)
        self.assertIn("#ifdef BEAMRT_ENTRY_FIXTURE_INIT_FAIL", entry)
        self.assertIn("entryTransaction(false)", entry)
        self.assertIn("info.hookAttached=0", entry)
        self.assertNotIn(".graphicsQuiescenceVerified=1", entry)
        self.assertNotIn(".lightingConsumed=1", entry)
        bootstrap = self.source("bootstrap.cpp")
        self.assertIn("BeamRT_EntryArmFromPayload()", bootstrap)
        self.assertNotIn("BeamRT_EntryInitialize(", bootstrap)
        self.assertNotIn("BeamRT_DeviceObserveStart(", bootstrap)
        build = self.source("build.ps1")
        self.assertIn("ml64.exe", build)
        self.assertIn("if($RunEntryTests)", build)
        for line in build.splitlines():
            if "/Febeamrt_startup_bootstrap.dll" in line:
                self.assertNotIn("BEAMRT_ENTRY_FIXTURE_AUTOSTART", line)
                self.assertNotIn("$beamrtEntryDefines", line)

    def test_fixture_proves_pre_main_creation_and_actual_entry_forwarding(self):
        fixture = self.source("entry_fixture.cpp")
        for guard in ("static BeforeMain beforeMain", "D3D12CreateDevice", "BeamRT_EntryFixtureRecord",
                      "std::memcmp(&before,&deliveredFrame", "resource->GetDevice", "same(owner.Get(),seen.Get())"):
            self.assertIn(guard, fixture)
        self.assertNotIn("BeamRT_DeviceObserveStart", fixture)
        original = self.source("entry_fixture_thunk.asm")
        self.assertIn("call BeamRT_EntryFixtureRecord", original)
        self.assertIn("jmp wWinMainCRTStartup", original)
        runner = self.source("process_test.cpp")
        for guard in ("entry-passive", "entry-auto-hardware", "entry-auto-warp", "entry-init-failure-fallback",
                      "entryReport.frameMatches==1", "entryReport.preMainReached==1", "!info.graphicsQuiescenceVerified"):
            self.assertIn(guard, runner)


if __name__ == "__main__":
    unittest.main()
