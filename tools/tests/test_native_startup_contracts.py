"""Review-only startup source guards; no process launch or DLL loading."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeStartupContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text(encoding="utf-8")

    def test_review_is_default_and_launch_requires_explicit_identity(self):
        host = self.source("launcher.cpp")
        for guard in ("bool launch=false", "if(!options.launch)return 0", "--launch-reviewed",
                      "--expected-target-sha256", "--expected-dll-sha256",
                      "--acknowledge-native-insertion", "startup-observation-only",
                      "options.targetHash==targetHash", "options.dllHash==dllHash",
                      "review and launch modes are mutually exclusive"):
            self.assertIn(guard, host)
        self.assertIn("FILE_SHARE_READ,nullptr,OPEN_EXISTING", host)
        self.assertIn("GetFinalPathNameByHandleW", host)
        self.assertIn("IMAGE_FILE_MACHINE_AMD64", host)

    def test_only_owned_suspended_child_can_receive_bootstrap(self):
        host = self.source("launcher.cpp")
        for guard in ("CreateProcessW(exe.path.c_str()", "CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT",
                      "PROC_THREAD_ATTRIBUTE_HANDLE_LIST", "DetourUpdateProcessWithDll(process.hProcess",
                      "DetourCopyPayloadToProcess(process.hProcess", "if(!resumeAttempted)",
                      "no forced live-game termination", "WaitForMultipleObjects(2,waits,FALSE,15000)"):
            self.assertIn(guard, host)
        for forbidden in ("OpenProcess(", "CreateRemoteThread", "SuspendThread", "DetourCreateProcessWithDllEx",
                          "ShellExecute", "system(", "FreeLibrary", "BeamRT_CaptureStart", "BeamRT_GIRecord"):
            self.assertNotIn(forbidden, host)

    def test_descriptor_admission_stays_review_only_and_explicitly_selected(self):
        host = self.source("launcher.cpp")
        for guard in ("resourceMode=beamrtResourceAllAllocations", '--resource-descriptors-only',
                      "out.resources || out.resourceMode==beamrtResourceAllAllocations",
                      "out.resourceMode!=beamrtResourceDescriptorTextures || !out.resourceProbeBytes",
                      "descriptor-only resource mode activated by default", "explicit descriptor-only resource mode refused"):
            self.assertIn(guard, host)
        self.assertLess(host.index("if(!options.launch)return 0"), host.index("return launchReviewed(options"))

    def test_bootstrap_only_reports_presence_without_renderer_or_unload_work(self):
        bootstrap = self.source("bootstrap.cpp")
        for guard in ("reason!=DLL_PROCESS_ATTACH", "beamrtStartupPayloadValid", "DetourRestoreAfterWith",
                      "SetEvent(receipt)", "CloseHandle(receipt)", "attachThread,0,0,0"):
            self.assertIn(guard, bootstrap)
        for forbidden in ("DetourAttach", "DetourDetach", "LoadLibrary", "CreateThread", "WaitFor",
                          "CreateFile", "D3D12", "BeamRT_CaptureStart", "BeamRT_GI", "std::"):
            self.assertNotIn(forbidden, bootstrap)
        contract = self.source("startup_contract.h")
        for guard in ("p->processId==processId", "p->mode==beamrtStartupObservationOnly",
                      "p->receiptEvent!=UINT64_MAX", "!p->reserved[0] && !p->reserved[1]",
                      "static_assert(sizeof(void*)==8"):
            self.assertIn(guard, contract)

    def test_build_contract_tests_never_launch_or_load(self):
        build = self.source("build.ps1")
        self.assertIn("/W4 /WX", build)
        self.assertIn("--self-test", build)
        self.assertNotIn("--launch-reviewed", build[build.index("if($RunContractTests)"):].split("& (Join-Path", 1)[-1])
        self.assertNotIn("beamrt_capture.lib", build)
        self.assertNotIn("beamrt_native_gi.lib", build)
        host = self.source("launcher.cpp")
        test = host[host.index("static void selfTest()"):host.index("int wmain(")]
        self.assertIn("CommandLineToArgvW", test)
        self.assertIn("beamrtStartupPayloadValid", test)
        self.assertNotIn("launchReviewed(", test)
        self.assertNotIn("CreateProcess", test)

    def test_fault_variants_are_separate_and_absent_from_production_builds(self):
        build = self.source("build.ps1")
        self.assertIn("if($RunProcessTests)", build)
        self.assertIn("/DBEAMRT_STARTUP_TEST_FAULTS", build)
        self.assertIn("/DBEAMRT_STARTUP_TEST_NO_RECEIPT", build)
        for line in build.splitlines():
            if "& cl.exe" in line and ("/Febeamrt_startup_host.exe" in line or "/Febeamrt_startup_bootstrap.dll" in line):
                self.assertNotIn("/DBEAMRT_STARTUP_TEST_", line)
        host = self.source("launcher.cpp")
        self.assertIn("#ifdef BEAMRT_STARTUP_TEST_FAULTS", host)
        self.assertIn('filename()==L"beamrt_startup_fixture.exe"', host)
        self.assertIn("#ifdef BEAMRT_STARTUP_TEST_NO_RECEIPT", self.source("bootstrap.cpp"))
        self.assertIn("printable(commandLine(options,exe.path))", host)
        self.assertIn("auto command=commandLine(options,exe.path)", host)

    def test_process_harness_owns_fixed_fixture_tree_and_checks_loaded_status(self):
        harness = self.source("process_test.cpp")
        for guard in ("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", "AssignProcessToJobObject",
                      "IsProcessInJob(process.value,job,&member)", "JobObjectBasicAccountingInformation",
                      "waitEmpty(job.value)", "!stats.ActiveProcesses", "read<BeamRTStartupFixtureReport>",
                      "GetExitCodeProcess(targetProcess.value,&childExit)", "result.processId==GetProcessId(targetProcess.value)",
                      "result.status.captureInstalled", "result.status.gpuWorkSubmitted", "result.status.lightingConsumed",
                      "missing-receipt-real-timeout", "cleanup-before-payload", "failure-after-resume-retains-child",
                      'root/L"beamrt_startup_fixture.exe"'):
            self.assertIn(guard, harness)
        for forbidden in ("BeamNG.drive.x64.exe", "EnumProcesses", "CreateToolhelp32Snapshot", "CREATE_BREAKAWAY_FROM_JOB"):
            self.assertNotIn(forbidden, harness)
        fixture = self.source("fixture_target.cpp")
        self.assertIn('GetProcAddress(module,"BeamRT_StartupQuery")', fixture)
        self.assertIn("CREATE_NEW", fixture)
        for forbidden in ("LoadLibrary", "BeamRT_CaptureStart", "D3D12", "CreateProcess"):
            self.assertNotIn(forbidden, fixture)


if __name__ == "__main__":
    unittest.main()
