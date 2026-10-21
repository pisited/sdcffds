#include "owned_watchdog.h"
#include <objbase.h>

#include <iostream>
#include <stdexcept>
#include <string>

using beamrt::unattended::OwnedProcess;
using beamrt::unattended::OwnedProcessReport;
using beamrt::unattended::WatchdogConfig;

namespace {
unsigned cases = 0;
unsigned assertions = 0;
void Check(bool condition, const char* message) {
    ++assertions;
    if (!condition) throw std::runtime_error(message);
}
template<class Body> void Case(const char* name, Body body) {
    try { body(); ++cases; std::cout << "PASS owned-watchdog " << name << '\n'; }
    catch (const std::exception& error) { throw std::runtime_error(std::string(name) + ": " + error.what()); }
}
struct Events final {
    HANDLE quit = nullptr;
    HANDLE ready = nullptr;
    std::wstring quitName;
    std::wstring readyName;
    Events() {
        GUID value{};
        if (FAILED(CoCreateGuid(&value))) throw std::runtime_error("fixture GUID unavailable");
        wchar_t guid[40]{};
        if (!StringFromGUID2(value, guid, 40)) throw std::runtime_error("fixture GUID formatting failed");
        quitName = std::wstring(L"Local\\BeamRTOwnedWatchdogQuit-") + guid;
        readyName = std::wstring(L"Local\\BeamRTOwnedWatchdogReady-") + guid;
        quit = CreateEventW(nullptr, TRUE, FALSE, quitName.c_str());
        if (!quit || GetLastError() == ERROR_ALREADY_EXISTS) {
            if (quit) CloseHandle(quit);
            quit = nullptr;
            throw std::runtime_error("fresh quit event unavailable");
        }
        ready = CreateEventW(nullptr, TRUE, FALSE, readyName.c_str());
        if (!ready || GetLastError() == ERROR_ALREADY_EXISTS) {
            if (ready) CloseHandle(ready);
            ready = nullptr; CloseHandle(quit); quit = nullptr;
            throw std::runtime_error("fresh ready event unavailable");
        }
    }
    ~Events() { if (ready) CloseHandle(ready); if (quit) CloseHandle(quit); }
    Events(const Events&) = delete;
    Events& operator=(const Events&) = delete;
};
WatchdogConfig Config() { return {100, 80, 1000, true}; }
std::vector<std::wstring> Args(const wchar_t* mode, const Events& events) {
    return {mode, events.quitName, events.readyName};
}
std::wstring FixedChildPath() {
    wchar_t path[32768]{};
    const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
    if (!length || length >= 32768) throw std::runtime_error("fixture module path unavailable");
    const std::wstring module(path, length);
    const auto slash = module.find_last_of(L"\\/");
    if (slash == std::wstring::npos) throw std::runtime_error("fixture module path is not absolute");
    const auto leaf = module.substr(slash + 1);
    if (leaf != L"owned_watchdog_fixture.exe") throw std::runtime_error("unexpected fixture executable name");
    return module.substr(0, slash + 1) + L"owned_watchdog_child.exe";
}
void Ready(const Events& events) {
    Check(WaitForSingleObject(events.ready, 2000) == WAIT_OBJECT_0, "disposable child did not become ready");
}
void Forced(const OwnedProcessReport& report, const WatchdogConfig& config) {
    Check(report.normalRequested, "force without prior normal request");
    Check(report.forceAttempted && report.forceCallSucceeded, "exact-owned force missing or failed");
    Check(report.forceAttemptMilliseconds >= report.normalRequestMilliseconds + config.normalGraceMilliseconds,
        "force skipped full normal grace");
    Check(report.processExitVerified && report.exitCode == OwnedProcess::ForcedExitCode,
        "force call substituted for signaled exit proof");
}
}

int main(int count, char**) {
    try {
        // No arbitrary path or process arguments are accepted by this fixture.
        Check(count == 1, "fixture accepts no command-line arguments");
        const auto child = FixedChildPath();
        Case("normal-cooperative", [&] {
            Events events; unsigned calls = 0;
            auto process = OwnedProcess::Create(child, Args(L"cooperative", events), Config(),
                [&](DWORD pid) { ++calls; Check(pid != 0, "normal callback missing diagnostic PID"); return SetEvent(events.quit) != FALSE; });
            Ready(events); const auto report = process->Run();
            Check(calls == 1 && report.normalCallReturned && report.normalCallSucceeded, "normal request not exactly once");
            Check(report.processExitVerified && report.exitCode == 0 && !report.forceAttempted, "normal exit not proved");
            process->Finish(); Check(calls == 1, "finish retried normal after exit");
        });
        Case("hung-owned-only", [&] {
            Events untouched; Events hung; unsigned untouchedCalls = 0; unsigned calls = 0;
            auto untouchedConfig = Config(); untouchedConfig.overallMilliseconds = 5000;
            auto control = OwnedProcess::Create(child, Args(L"cooperative", untouched), untouchedConfig,
                [&](DWORD) { ++untouchedCalls; return SetEvent(untouched.quit) != FALSE; });
            auto process = OwnedProcess::Create(child, Args(L"ignore", hung), Config(),
                [&](DWORD) { ++calls; return SetEvent(hung.quit) != FALSE; });
            Ready(untouched); Ready(hung);
            const auto report = process->Run(); Forced(report, Config());
            Check(calls == 1, "normal request retried for ignored request");
            Check(!control->Poll().processExitVerified && untouchedCalls == 0, "unrelated owned control was targeted");
            const auto clean = control->Finish();
            Check(clean.processExitVerified && clean.exitCode == 0 && !clean.forceAttempted, "control cleanup failed");
        });
        Case("false-normal-full-grace", [&] {
            Events events; unsigned calls = 0;
            auto process = OwnedProcess::Create(child, Args(L"ignore", events), Config(),
                [&](DWORD) { ++calls; return false; });
            Ready(events); const auto report = process->Run(); Forced(report, Config());
            Check(calls == 1 && report.normalCallReturned && !report.normalCallSucceeded && !report.normalCallThrew,
                "false callback status lost or retried");
        });
        Case("throw-normal-full-grace", [&] {
            Events events; unsigned calls = 0;
            auto process = OwnedProcess::Create(child, Args(L"ignore", events), Config(),
                [&](DWORD) -> bool { ++calls; throw std::runtime_error("fixture normal failure"); });
            Ready(events); const auto report = process->Run(); Forced(report, Config());
            Check(calls == 1 && report.normalCallThrew && !report.normalCallReturned, "callback throw status lost");
        });
        Case("exit259-is-real-exit", [&] {
            Events events; unsigned calls = 0;
            auto config = Config(); config.overallMilliseconds = 2000;
            auto process = OwnedProcess::Create(child, Args(L"exit259", events), config,
                [&](DWORD) { ++calls; return SetEvent(events.quit) != FALSE; });
            Ready(events); const auto report = process->Run();
            Check(report.processExitVerified && report.exitCode == 259, "259 confused with a running process");
            Check(!report.forceAttempted && calls == 0, "already exiting child was stopped");
        });
        Case("explicit-stop-once", [&] {
            Events events; unsigned calls = 0;
            auto config = Config(); config.overallMilliseconds = 5000;
            auto process = OwnedProcess::Create(child, Args(L"cooperative", events), config,
                [&](DWORD) { ++calls; return SetEvent(events.quit) != FALSE; });
            Ready(events); const auto report = process->Finish();
            Check(calls == 1 && report.processExitVerified && report.exitCode == 0, "explicit stop failed");
            Check(report.normalRequestMilliseconds < config.overallMilliseconds && !report.forceAttempted, "explicit stop waited for overall deadline");
        });
        Case("destructor-exception-cleanup", [&] {
            Events events; unsigned calls = 0; OwnedProcessReport final; bool finalCalled = false; bool intendedThrow = false;
            try {
                auto process = OwnedProcess::Create(child, Args(L"ignore", events), Config(),
                    [&](DWORD) { ++calls; return SetEvent(events.quit) != FALSE; }, OwnedProcess::BeforeResume(),
                    [&](const OwnedProcessReport& report) { final = report; finalCalled = true; });
                Ready(events); throw std::runtime_error("fixture stack unwinding");
            } catch (const std::runtime_error& error) { intendedThrow = std::string(error.what()) == "fixture stack unwinding"; }
            Check(intendedThrow && finalCalled && calls == 1, "exception cleanup lacked intended throw/single normal/final report");
            Forced(final, Config());
        });
        Case("pre-resume-refusal-never-executed", [&] {
            Events events; unsigned calls = 0; OwnedProcessReport final; bool rejected = false;
            try {
                auto process = OwnedProcess::Create(child, Args(L"cooperative", events), Config(),
                    [&](DWORD) { ++calls; return SetEvent(events.quit) != FALSE; },
                    [](DWORD) { return false; }, [&](const OwnedProcessReport& report) { final = report; });
            } catch (const std::runtime_error& error) { rejected = std::string(error.what()) == "pre-resume setup refused"; }
            Check(rejected && calls == 0 && !final.resumeAttempted && !final.resumed, "pre-resume refusal became a live run");
            Check(WaitForSingleObject(events.ready, 0) == WAIT_TIMEOUT, "refused child executed application instructions");
            Check(final.neverExecutedCleanupAttempted && final.neverExecutedCleanupCallSucceeded &&
                final.processExitVerified && final.exitCode == OwnedProcess::ForcedExitCode,
                "never-executed child cleanup result/exit proof unverified");
        });
        Case("pre-resume-throw-never-executed", [&] {
            Events events; unsigned calls = 0; OwnedProcessReport final; bool rejected = false;
            try {
                auto process = OwnedProcess::Create(child, Args(L"cooperative", events), Config(),
                    [&](DWORD) { ++calls; return SetEvent(events.quit) != FALSE; },
                    [](DWORD) -> bool { throw std::runtime_error("fixture setup failure"); },
                    [&](const OwnedProcessReport& report) { final = report; });
            } catch (const std::runtime_error& error) { rejected = std::string(error.what()) == "fixture setup failure"; }
            Check(rejected && calls == 0 && !final.resumeAttempted, "throwing setup became live");
            Check(final.neverExecutedCleanupAttempted && final.neverExecutedCleanupCallSucceeded &&
                final.processExitVerified && WaitForSingleObject(events.ready, 0) == WAIT_TIMEOUT,
                "throwing setup leaked or executed a child");
        });
        Case("force-disallowed-normal-only", [&] {
            Events events; unsigned calls = 0;
            auto config = Config(); config.forceCloseAuthorized = false;
            auto process = OwnedProcess::Create(child, Args(L"cooperative", events), config,
                [&](DWORD) { ++calls; return SetEvent(events.quit) != FALSE; });
            Ready(events); const auto report = process->Run();
            Check(calls == 1 && report.processExitVerified && report.exitCode == 0 && !report.forceAttempted,
                "force-disallowed cooperative cleanup failed");
        });
        Case("force-disallowed-unconfirmed-then-fixture-release", [&] {
            Events events; unsigned calls = 0;
            auto config = Config(); config.forceCloseAuthorized = false;
            auto process = OwnedProcess::Create(child, Args(L"release42", events), config,
                [&](DWORD) { ++calls; return false; });
            Ready(events); const auto refused = process->Run();
            Check(calls == 1 && refused.forceUnauthorizedAfterGrace && !refused.forceAttempted &&
                !refused.processExitVerified, "unauthorized path did not remain explicitly unconfirmed");
            // Independent fixture cleanup, NOT a watchdog retry or force action.
            // Holding the child on this event removes a scheduler-dependent race.
            Check(SetEvent(events.quit) != FALSE, "fixture-only release failed");
            const auto until = GetTickCount64() + 2000;
            auto exited = process->Poll();
            while (!exited.processExitVerified && GetTickCount64() < until) {
                Sleep(1); exited = process->Poll();
            }
            Check(calls == 1 && exited.processExitVerified && exited.exitCode == 42 && !exited.forceAttempted,
                "native unconfirmed path retried stop/force or lost natural exit proof");
        });
        std::cout << "PASS owned-watchdog native cases=" << cases << " assertions=" << assertions
            << " (disposable hidden children only; no game launch)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL owned-watchdog: " << error.what() << '\n';
        return 1;
    }
}
