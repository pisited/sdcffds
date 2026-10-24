"""Static guards for the fixture-only independent-owner native participant.

These source checks do not create a process, load a DLL, exercise Windows handle
permissions, or establish game startup safety. Disposable native fixtures must
verify the corresponding runtime protocol and ownership behavior separately.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
STARTUP = ROOT / "native/startup"


def body(source, anchor):
    """Extract a balanced C++ block while ignoring literal/comment braces."""
    start = source.index(anchor)
    masked = re.sub(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
        lambda match: " " * len(match.group()), source, flags=re.DOTALL,
    )
    opening = masked.index("{", start)
    depth = 0
    for index in range(opening, len(masked)):
        depth += (masked[index] == "{") - (masked[index] == "}")
        if not depth:
            return source[opening + 1:index]
    raise AssertionError("unclosed C++ block for " + anchor)


def compact(source):
    return re.sub(r"\s+", "", source)


class OuterChildSessionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (STARTUP / "unattended/outer_child_session.h").read_text(encoding="utf-8")
        cls.host = (STARTUP / "launcher.cpp").read_text(encoding="utf-8")
        cls.channel = (STARTUP / "unattended/startup_stop_channel.h").read_text(encoding="utf-8")
        cls.fixture = (STARTUP / "unattended/startup_stop_channel_fixture.cpp").read_text(encoding="utf-8")

    def test_fixed_x64_protocol_offsets_and_storage_are_compile_asserted(self):
        expected = {
            "magic": 0, "bytes": 8, "abi": 12, "token": 16, "configDigest": 32,
            "childPid": 64, "childTid": 68, "creationTick": 72,
            "overallMilliseconds": 80, "graceMilliseconds": 84,
            "terminationWaitMilliseconds": 88, "expectedIPCcount": 92,
            "setupProcess": 96, "setupThread": 104, "hostToOuterEvent": 112,
            "outerToHostEvent": 120, "state": 128, "resumeResult": 132,
            "coreResult": 136, "error": 140, "sourceHandles": 144,
            "childHandles": 256, "reserved": 368,
        }
        actual = dict((field, int(offset)) for field, offset in re.findall(
            r"offsetof\(OuterChildChannelV1,\s*(\w+)\)\s*==\s*(\d+)", self.header))
        self.assertEqual(actual, expected)
        for text in ("sizeof(void*) == 8", "sizeof(LONG) == 4", "sizeof(OuterChildChannelV1) == 512",
                     "volatile LONG state", "sourceHandles[14]", "childHandles[14]", "reserved[144]",
                     "std::is_standard_layout", "std::is_trivially_copyable"):
            self.assertIn(text, self.header)
        self.assertIn("{'B', 'R', 'T', 'E', 'X', 'T', '1', 0}", self.header)

    def test_constructor_requires_explicit_config_join_and_initial_zero_state(self):
        constructor = body(self.header, "OuterChildSession(HANDLE mapping")
        for text in ("const std::wstring& expectedDigest", "const std::wstring& expectedExe",
                     "DWORD overallSeconds", "DWORD graceSeconds", "unsigned expectedIPCcount"):
            self.assertIn(text, self.header)
        for text in ("FILE_MAP_READ | FILE_MAP_WRITE", "ParseHex<16>(token)", "ParseHex<32>(expectedDigest)",
                     "view_->abi != 1", "view_->terminationWaitMilliseconds != 5000",
                     "!Zero(view_->reserved", "ReadState() != 0", "view_->resumeResult != Unset",
                     "view_->coreResult != Unset", "view_->error != ERROR_SUCCESS",
                     "!Zero(view_->sourceHandles", "!Zero(view_->childHandles",
                     "std::memcpy(immutable_.data()", "AdoptInheritedCapabilities()"):
            self.assertIn(text, constructor)
        parse = body(self.header, "ParseHex(const std::wstring& text)")
        self.assertIn("text.size() != Bytes * 2", parse)
        self.assertIn("value >= L'a' && value <= L'f'", parse)
        self.assertIn("nibble > 15", parse)

    def test_retained_capability_identity_is_checked_without_pid_lookup(self):
        constructor = body(self.header, "OuterChildSession(HANDLE mapping")
        for text in ("GetProcessId(handles_[1]) != view_->childPid",
                     "GetThreadId(handles_[2]) != view_->childTid",
                     "GetProcessIdOfThread(handles_[2]) != view_->childPid",
                     "QueryFullProcessImageNameW(handles_[1]", "expectedExe.c_str()",
                     "WaitForSingleObject(handles_[1], 0)", "processId_ = view_->childPid"):
            self.assertIn(text, constructor)
        inherited = body(self.header, "void AdoptInheritedCapabilities()")
        for text in ("view_->setupProcess", "view_->setupThread", "view_->hostToOuterEvent",
                     "view_->outerToHostEvent", "ValidValue(value)", "GetHandleInformation",
                     "HANDLE_FLAG_INHERIT", "repeated", "handleCount_ != handles_.size()"):
            self.assertIn(text, inherited)
        self.assertIn("DWORD ProcessId() const noexcept { return processId_; }", self.header)

    def test_setup_duplicates_only_reduced_handles_into_current_host(self):
        setup = body(self.header, "PROCESS_INFORMATION Setup()")
        for text in ("setupAttempted_", "PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE",
                     "PROCESS_QUERY_INFORMATION | SYNCHRONIZE", "THREAD_QUERY_INFORMATION | SYNCHRONIZE",
                     "DuplicateHandle(GetCurrentProcess(), handles_[1], GetCurrentProcess()",
                     "DuplicateHandle(GetCurrentProcess(), handles_[2], GetCurrentProcess()",
                     "processRights, FALSE, 0", "threadRights, FALSE, 0", "CloseHandle(result.hProcess)"):
            self.assertIn(text, setup)
        for forbidden in ("DUPLICATE_SAME_ACCESS", "DUPLICATE_CLOSE_SOURCE", "PROCESS_ALL_ACCESS",
                          "THREAD_ALL_ACCESS", "PROCESS_DUP_HANDLE", "PROCESS_TERMINATE",
                          "THREAD_SUSPEND_RESUME"):
            self.assertNotIn(forbidden, self.header)
        self.assertEqual(self.header.count("DuplicateHandle("), 2)

    def test_native_participant_has_no_child_lifecycle_or_discovery_apis(self):
        for forbidden in ("CreateProcessW(", "CreateProcessA(", "ResumeThread(", "TerminateProcess(",
                          "TerminateJobObject(", "OpenProcess(", "OpenThread(", "EnumProcesses(",
                          "CreateToolhelp32Snapshot(", "GetProcessById("):
            self.assertNotIn(forbidden, self.header)
        destructor = body(self.header, "~OuterChildSession()")
        self.assertEqual(compact(destructor), "Close();")
        close = body(self.header, "void Close() noexcept")
        for text in ("UnmapViewOfFile(view_)", "CloseHandle(handles_[handleCount_])"):
            self.assertIn(text, close)
        for forbidden in ("Fail(", "Complete(", "WaitFor", "SetEvent", "Finish("):
            self.assertNotIn(forbidden, close)

    def test_relay_validates_local_and_remote_tables_and_unused_slots(self):
        relay = body(self.header, "void RelayIPC(HANDLE* local, unsigned count)")
        for text in ("relayAttempted_", "count != view_->expectedIPCcount", "GetHandleInformation(local[index]",
                     "value == Value(owned)", "source_[before] == value", "PublishState(1)", "WaitForState(1, 2)",
                     "std::memcmp(view_->sourceHandles, source_.data()", "!ValidValue(value)",
                     "child_[before] == value", "else if (value)", "relayed_ = true", "CheckTables()"):
            self.assertIn(text, relay)
        self.assertNotIn("DuplicateHandle(", relay)
        values = body(self.header, "std::uint64_t ChildValue(HANDLE local) const")
        for text in ("if (!relayed_)", "CheckStable()", "CheckTables()", "source_[index] == Value(local)",
                     "return child_[index]", "unknown local handle"):
            self.assertIn(text, values)
        count = body(self.header, "static bool ValidIPCcount(")
        self.assertEqual(re.findall(r"count == (\d+)", count), ["1", "3", "5", "9", "12", "14"])

    def test_waits_use_creation_origin_deadline_and_child_retained_handle(self):
        remaining = body(self.header, "DWORD Remaining() const noexcept")
        for text in ("GetTickCount64()", "now < view_->creationTick", "now - view_->creationTick",
                     "view_->overallMilliseconds - elapsed"):
            self.assertIn(text, remaining)
        wait = body(self.header, "void WaitForState(LONG request, LONG granted)")
        for text in ("{handles_[4], handles_[1]}", "CheckStable()", "const DWORD remaining = Remaining()",
                     "if (!remaining)", "ERROR_TIMEOUT", "state == granted", "state == 6",
                     "state != request", "WaitForMultipleObjects(2, waits, FALSE, remaining)",
                     "ERROR_PROCESS_ABORTED", "WAIT_FAILED"):
            self.assertIn(text, wait)
        self.assertLess(wait.index("if (!remaining)"), wait.index("state == granted"))
        stable = body(self.header, "void CheckStable() const")
        self.assertIn("std::memcmp(view_, immutable_.data(), immutable_.size())", stable)
        self.assertIn("!Zero(view_->reserved", stable)

    def test_resume_completion_and_failure_are_only_channel_messages(self):
        resume = body(self.header, "DWORD Resume()")
        for text in ("resumeAttempted_", "RequireBudget()", "CheckTables()", "ReadState() != 2",
                     "PublishState(3)", "WaitForState(3, 4)", "view_->resumeResult == Unset",
                     "resumedResult_ = view_->resumeResult", "return resumedResult_"):
            self.assertIn(text, resume)
        complete = body(self.header, "void Complete(int coreResult)")
        for text in ("completed_", "!resumeGranted_", "ReadState() != 4",
                     "view_->coreResult = static_cast<std::uint32_t>(coreResult)", "PublishState(5)"):
            self.assertIn(text, complete)
        failure = body(self.header, "void Fail(DWORD error) noexcept")
        for text in ("if (!view_ || !maySignal_)", "view_->error", "InterlockedExchange(&view_->state, 6)",
                     "SetEvent(handles_[3])"):
            self.assertIn(text, failure)
        for forbidden in ("WaitFor", "DuplicateHandle", "CreateFile", "Publish("):
            self.assertNotIn(forbidden, failure)

    def test_launcher_outer_mode_requires_owned_flags_digest_and_fixture_target(self):
        parse = body(self.host, "static Options parse(")
        for text in ('L"--outer-owned-channel"', 'L"--outer-config-sha256"',
                     "(out.outerChannel!=0)==!out.outerDigest.empty()"):
            self.assertIn(text, parse)
        gate = body(parse, "if(out.outerChannel)")
        for text in ("out.owned && !out.ownedReceiptWait", "std::filesystem::path(out.target).filename().wstring()",
                     'leaf==L"beamrt_startup_fixture.exe"', 'leaf==L"beamrt_binding_startup_fixture.exe"',
                     "game execution is unavailable"):
            self.assertIn(text, gate)
        self.assertNotIn("BeamNG.drive.x64.exe", gate)
        self.assertIn("if(!options.owned)return launchReviewedCore", self.host)

    def test_launcher_payloads_use_relayed_child_handle_values(self):
        core = body(self.host, "static int launchReviewedCore(")
        for text in ("if(outerSession)process=outerSession->Setup()", "outerSession->RelayIPC(events,",
                     "outerSession?outerSession->ChildValue(local)", "outerSession?outerSession->Resume()"):
            self.assertIn(text, core)
        payload = core[core.index("BeamRTStartupPayload payload{"):core.index('fixtureFault(options,exe.path,L"before-resume")')]
        translated = re.findall(r"childHandle\((\w+)\.value\)", payload)
        self.assertCountEqual(translated, (
            "event", "entryEvent", "mapping", "importEvent", "importMapping", "pipelineInput",
            "pipelineOutput", "pipelineStart", "pipelineMatch", "bindingOutput", "bindingStart",
            "bindingRecord", "resourceOutput", "resourceStart",
        ))
        self.assertNotIn("reinterpret_cast", payload)
        self.assertLess(core.index("outerSession->RelayIPC(events,"), core.index("DetourUpdateProcessWithDll"))

    def test_launcher_outer_failure_does_not_enter_host_termination_branch(self):
        core = body(self.host, "static int launchReviewedCore(")
        catch = core[core.rindex("}catch(...){"):]
        outer_fail = body(catch, "if(outerSession)")
        self.assertIn("outerSession->Fail(ERROR_GEN_FAILURE)", outer_fail)
        for forbidden in ("TerminateProcess", "ResumeThread", "CreateProcess", "WaitForSingleObject"):
            self.assertNotIn(forbidden, outer_fail)
        self.assertLess(catch.index("if(outerSession)"), catch.index("else if(ownedSession)"))
        self.assertLess(catch.index("else if(ownedSession)"), catch.index("else if(!resumeAttempted)"))
        launch = body(self.host, "static int launchReviewed(")
        outer = body(launch, "if(options.outerChannel)")
        for text in ("OuterChildSession outer(", "options.outerDigest,exe.path", "nullptr,externalChannel.get(),&outer",
                     "outer.Complete(core)", "outer.Fail(ERROR_GEN_FAILURE)"):
            self.assertIn(text, outer)
        for forbidden in ("StartupOwnedSession", "session.Finish()", "saveOwnedExit", "TerminateProcess", "ResumeThread"):
            self.assertNotIn(forbidden, outer)

    def test_directory_lease_has_real_empty_preclaim_run_and_ancestor_guard(self):
        retained = body(self.channel, "static void RetainPhysicalDirectory(")
        self.assertIn("FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE", retained)
        self.assertIn("FILE_SHARE_READ | FILE_SHARE_WRITE", retained)
        retained_code = re.sub(r"//[^\n]*|/\*.*?\*/", "", retained, flags=re.DOTALL)
        self.assertNotIn("FILE_SHARE_DELETE", retained_code)
        self.assertIn("FILE_FLAG_OPEN_REPARSE_POINT", retained)
        self.assertIn("FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT", retained)
        self.assertIn("#if defined(BEAMRT_STARTUP_STOP_CHANNEL_FIXTURE)", self.channel)
        self.assertIn("friend class StartupStopChannelFixtureAccess", self.channel)
        create = body(self.channel, "static std::unique_ptr<StartupStopChannel> Create(")
        self.assertLess(create.index("RetainPhysicalDirectory(*state)"), create.index("CreateClaim(*state"))
        seam = body(self.fixture, "RetainUnclaimedDirectory(const std::wstring& directory")
        self.assertIn("StartupStopChannel::RetainPhysicalDirectory(*state)", seam)
        for forbidden in ("CreateClaim", "CreateEvent", "CreateThread"):
            self.assertNotIn(forbidden, seam)
        probe = body(self.fixture, 'Case("empty-preclaim-run-and-ancestor-retained-against-rename"')
        for text in ("RetainUnclaimedDirectory(directory, Token)", "runMoved", "ancestorMoved", "lease.reset()",
                     "Absent(directory + L\"\\\\host-claim.json\")", "Absent(ancestor + L\"\\\\host-claim.json\")",
                     "MoveFileExW(directory.c_str()", "MoveFileExW(ancestor.c_str()",
                     "MoveFileExW(movedRun.c_str()", "MoveFileExW(movedAncestor.c_str()"):
            self.assertIn(text, probe)
        self.assertLess(probe.index("runMoved"), probe.index("lease.reset()"))
        self.assertLess(probe.index("ancestorMoved"), probe.index("lease.reset()"))
        self.assertNotIn("StartupStopChannel::Create", probe)
        self.assertNotIn("DeleteFile", probe)
        self.assertNotIn("RemoveDirectory", probe)


if __name__ == "__main__":
    unittest.main()
