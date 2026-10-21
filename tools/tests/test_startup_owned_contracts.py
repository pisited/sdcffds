"""Static host ownership guards; real disposable Windows fixtures test behavior.

These checks neither launch a process nor establish live-game safety.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
STARTUP = ROOT / "native/startup"


class StartupOwnedContracts(unittest.TestCase):
    def read(self, name):
        return (STARTUP / name).read_text(encoding="utf-8")

    def test_manual_path_stays_default_and_owned_options_are_complete(self):
        host = self.read("launcher.cpp")
        for text in ("bool owned=false", "ownedFields==5", "exact-created-child-after-normal-quit",
                     "if(!options.owned)return launchReviewedCore", "owned session requires a lowercase 32-hex token",
                     "owned shutdown activated by default", "owned review did not remain inert"):
            self.assertIn(text, host)
        for flag in ("--owned-run-directory", "--owned-run-token", "--owned-overall-seconds",
                     "--owned-normal-grace-seconds", "--acknowledge-owned-force-close"):
            self.assertIn(flag, host)

    def test_actual_creator_keeps_master_handles_and_setup_is_reduced_rights(self):
        session = self.read("unattended/startup_owned_session.h")
        for text in ("CreateProcessW(absoluteExecutable.c_str()", "DuplicateHandle(",
                     "PROCESS_VM_OPERATION | PROCESS_VM_READ", "THREAD_QUERY_INFORMATION | SYNCHRONIZE",
                     "ResumeThread(owned_->thread_)", "pending->creationTick_ = GetTickCount64()"):
            self.assertIn(text, session)
        for forbidden in ("OpenProcess(", "PROCESS_TERMINATE", "THREAD_SUSPEND_RESUME",
                          "EnumProcesses", "GetProcessById", "TerminateJobObject"):
            self.assertNotIn(forbidden, session)

    def test_host_uses_creator_resume_and_requires_context_before_resuming(self):
        host = self.read("launcher.cpp")
        for text in ("ownedSession->Create(exe.path", "ownedSession?ownedSession->Resume()",
                     "demand(stopChannel->PublishContext(process.dwProcessId)",
                     "session.Finish()", "channel->RequestNormal(pid)",
                     "if(ownedSession){std::wcerr"):
            self.assertIn(text, host)
        self.assertLess(host.index("demand(stopChannel->PublishContext"),
                        host.index("ownedSession?ownedSession->Resume()"))
        for forbidden in ("OpenProcess(", "GetProcessById", "CreateToolhelp32Snapshot"):
            self.assertNotIn(forbidden, host)

    def test_watcher_lifetime_is_independent_of_core_receipt_waits(self):
        session = self.read("unattended/startup_owned_session.h")
        for text in ("watcher_ = std::thread", "watcher_.join()", "owned_->Poll(stopRequested_)",
                     "CleanupNeverExecutedChild()", "owned_->report_.resumeAttempted = true",
                     "std::lock_guard<std::mutex>"):
            self.assertIn(text, session)
        self.assertNotIn("TerminateThread", session)
        owner = self.read("unattended/owned_watchdog.h")
        self.assertIn("friend class StartupOwnedSession", owner)
        self.assertIn("if (report_.neverExecutedCleanupAttempted) return", owner)

    def test_normal_request_does_not_block_on_publication_or_infer_delivery(self):
        channel = self.read("unattended/startup_stop_channel.h")
        callback = channel[channel.index("bool RequestNormal("):channel.index("StartupStopChannelReport Report()")]
        for text in ("compare_exchange_strong", "SetEvent(", "contextPublished.load"):
            self.assertIn(text, callback)
        for forbidden in ("CreateFile", "WriteFile", "FlushFileBuffers", "WaitFor", "new ", "std::mutex"):
            self.assertNotIn(forbidden, callback)
        for text in ("FILE_FLAG_OPEN_REPARSE_POINT", "ReplaceIfExists = FALSE", "publicationCompleted",
                     "publicationSucceeded", "host-claim.json", "owned-exit.json"):
            self.assertIn(text, channel)

    def test_exit_receipt_keeps_force_and_os_completion_separate(self):
        host = self.read("launcher.cpp")
        for text in ("saveOwnedExit", "physicalReportPath", "CREATE_NEW", "FlushFileBuffers(file.value)",
                     "processExitVerified", "neverExecutedCleanupAttempted", "stopCompleted",
                     "if(!report.processExitVerified)return 14", "if(report.forceAttempted)return 15",
                     "if(report.exitCode)return 16"):
            self.assertIn(text, host)

    def test_fixture_only_builders_do_not_accept_a_game_target(self):
        fixture = self.read("unattended/startup_owned_fixture.cpp")
        for forbidden in ("BeamNG.drive.x64.exe", "OpenProcess(", "GetProcessById", "EnumProcesses"):
            self.assertNotIn(forbidden, fixture)
        for text in ("watcher-across-main-receipt-wait", "after-resume-exception-force", "manual-review-unchanged"):
            self.assertIn(text, fixture)


    def test_receipt_rendezvous_is_opt_in_and_does_not_stop_on_ack(self):
        host = self.read("launcher.cpp")
        for text in ("ownedReceiptWait=0", "--owned-receipt-wait-seconds",
                     "receipt wait requires exact-owned interned descriptor observation",
                     "receipt wait requires recorded-draw.bin inside the owned directory",
                     "if(!result && options.ownedReceiptWait)", "channel->PublishReceiptReady",
                     "if(state.processExitVerified)break", "result=17;break"):
            self.assertIn(text, host)
        begin = host.index("if(!result && options.ownedReceiptWait)")
        end = host.index("catch(...){const auto report=session.Finish()", begin)
        wait = host[begin:end]
        for forbidden in ("session.Finish()", "driver-ack.json", "OpenProcess", "TerminateProcess"):
            self.assertNotIn(forbidden, wait)
        channel = self.read("unattended/startup_stop_channel.h")
        for text in ("PublishReceiptReady", "receiptAttempted.compare_exchange_strong",
                     "receipt-ready.json", "receiptFile", "cpu_receipt_ready"):
            self.assertIn(text, channel)


if __name__ == "__main__":
    unittest.main()
