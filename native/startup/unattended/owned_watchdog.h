#pragma once

// Inactive, Windows-only building block. This header never opens an existing
// process, installs a game hook, discovers a PID, or launches anything on import.
// The caller must obtain fresh launch authority separately. The normal request
// callback MUST be bounded/nonblocking (for example, publish a small stop marker).
// A synchronous callback, process creation, and the Windows scheduler are not
// hard-real-time operations. A hung callback requires an independent coordinator.

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include "watchdog_policy.h"

#include <algorithm>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace beamrt { namespace unattended {

struct OwnedProcessReport {
    DWORD processId = 0; // Diagnostics only: NEVER used to open/kill a process.
    bool resumeAttempted = false;
    bool resumed = false;
    bool normalRequested = false;
    bool normalCallReturned = false;
    bool normalCallSucceeded = false;
    bool normalCallThrew = false;
    bool forceAttempted = false;
    bool forceCallSucceeded = false;
    DWORD forceError = ERROR_SUCCESS;
    bool neverExecutedCleanupAttempted = false;
    bool neverExecutedCleanupCallSucceeded = false;
    DWORD neverExecutedCleanupError = ERROR_SUCCESS;
    bool processExitVerified = false;
    DWORD exitCode = 0; // Valid only when processExitVerified is true, even 259.
    DWORD observationError = ERROR_SUCCESS;
    std::uint64_t elapsedMilliseconds = 0;
    std::uint64_t normalRequestMilliseconds = 0;
    std::uint64_t forceAttemptMilliseconds = 0;
    bool forceUnauthorizedAfterGrace = false;
};

// Exact-owned process capability. No constructor, adopt, attach, OpenProcess,
// PID/name matching, process-tree operation, or public native HANDLE exists.
// The private retained HANDLE comes only from this factory's CreateProcessW.
// Instances are not thread-safe. Keep one owner; do not destroy from callbacks.
class OwnedProcess final {
public:
    using NormalRequest = std::function<bool(DWORD)>;
    // Optional setup before ResumeThread (e.g. publish retained-child PID).
    // Throwing/refusing setup cleans up only the never-executed suspended child.
    using BeforeResume = std::function<bool(DWORD)>;
    using FinalReport = std::function<void(const OwnedProcessReport&)>;
    static constexpr DWORD ForcedExitCode = 0x42525446U;

    static std::unique_ptr<OwnedProcess> Create(
        const std::wstring& absoluteExecutable,
        const std::vector<std::wstring>& arguments,
        const WatchdogConfig& config,
        NormalRequest normalRequest,
        BeforeResume beforeResume = BeforeResume(),
        FinalReport finalReport = FinalReport()) {
        ValidateWatchdogConfig(config);
        if (!normalRequest) throw std::invalid_argument("an explicit normal request callback is required");
        if (!IsAbsoluteExecutable(absoluteExecutable))
            throw std::invalid_argument("an explicit absolute .exe path is required");
        auto result = std::unique_ptr<OwnedProcess>(new OwnedProcess(config,
            std::move(normalRequest), std::move(finalReport)));
        std::wstring commandLine = QuoteArgument(absoluteExecutable);
        for (const auto& argument : arguments) {
            if (argument.find(L'\0') != std::wstring::npos)
                throw std::invalid_argument("embedded NUL in process argument");
            commandLine += L" " + QuoteArgument(argument);
        }
        if (commandLine.size() >= 32767) throw std::invalid_argument("process command line exceeds Windows limit");
        // All allocations and callback capture happen before the child exists.
        std::vector<wchar_t> writable(commandLine.begin(), commandLine.end());
        writable.push_back(L'\0');
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process{};
        result->creationTick_ = GetTickCount64();
        if (!CreateProcessW(absoluteExecutable.c_str(), writable.data(), nullptr, nullptr,
                FALSE, CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
            throw std::runtime_error("CreateProcessW failed (no existing process was attached)");
        }
        result->process_ = process.hProcess;
        result->thread_ = process.hThread;
        result->report_.processId = process.dwProcessId;
        // Any exception from this point unwinds through the exact-owned object.
        if (beforeResume && !beforeResume(process.dwProcessId))
            throw std::runtime_error("pre-resume setup refused");
        result->report_.resumeAttempted = true;
        const DWORD previousSuspendCount = ResumeThread(result->thread_);
        result->report_.resumed = previousSuspendCount != static_cast<DWORD>(-1);
        if (previousSuspendCount == static_cast<DWORD>(-1))
            throw std::runtime_error("ResumeThread failed");
        // Never classify a successful-but-unexpected resume as never executed.
        if (previousSuspendCount != 1)
            throw std::runtime_error("unexpected previous suspend count");
        CloseHandle(result->thread_);
        result->thread_ = nullptr;
        return result;
    }

    ~OwnedProcess() noexcept {
        if (process_) {
            if (!report_.resumeAttempted) CleanupNeverExecutedChild();
            else { try { Finish(); } catch (...) { /* Keep destructor noexcept. */ } }
            CloseHandle(process_);
        }
        if (thread_) CloseHandle(thread_);
        if (finalReport_) { try { finalReport_(report_); } catch (...) { } }
    }
    OwnedProcess(const OwnedProcess&) = delete;
    OwnedProcess& operator=(const OwnedProcess&) = delete;
    OwnedProcess(OwnedProcess&&) = delete;
    OwnedProcess& operator=(OwnedProcess&&) = delete;

    OwnedProcessReport Poll(bool stopRequested = false) noexcept {
        if (!process_ || !report_.resumeAttempted) return report_;
        report_.elapsedMilliseconds = GetTickCount64() - creationTick_;
        ObserveExit();
        const WatchdogAction action = policy_.Step(report_.elapsedMilliseconds,
            report_.processExitVerified, stopRequested);
        if (action == WatchdogAction::RequestNormal) {
            // Record before invoking user code: false/throw cannot cause retry.
            report_.normalRequested = true;
            report_.normalRequestMilliseconds = report_.elapsedMilliseconds;
            try {
                report_.normalCallSucceeded = normalRequest_(report_.processId);
                report_.normalCallReturned = true;
            } catch (...) { report_.normalCallThrew = true; }
        } else if (action == WatchdogAction::ForceClose) {
            // A late natural exit between polls must not become a force call.
            ObserveExit();
            if (!report_.processExitVerified && report_.observationError == ERROR_SUCCESS) {
                report_.forceAttempted = true;
                report_.forceAttemptMilliseconds = GetTickCount64() - creationTick_;
                report_.forceCallSucceeded = TerminateProcess(process_, ForcedExitCode) != FALSE;
                if (!report_.forceCallSucceeded) report_.forceError = GetLastError();
                // TerminateProcess success is NOT exit proof. Wait first; even
                // a genuine exit code STILL_ACTIVE (259) is valid once signaled.
                const DWORD waited = WaitForSingleObject(process_, config_.terminationWaitMilliseconds);
                if (waited == WAIT_FAILED) report_.observationError = GetLastError();
                ObserveExit();
            }
        }
        report_.forceUnauthorizedAfterGrace = policy_.GraceExpired() && !policy_.ForceAuthorized();
        return report_;
    }

    // Normal run loop: overall deadline cannot be reset by readiness or activity.
    // On callback false/throw, the FULL normal grace still elapses before force.
    OwnedProcessReport Run() noexcept { return RunUntilStopped(false); }
    // Explicit stop / exception cleanup: normal once, full grace, force if allowed.
    OwnedProcessReport Finish() noexcept { return RunUntilStopped(true); }
    OwnedProcessReport Report() const noexcept { return report_; }

private:
    friend class StartupOwnedSession;
    OwnedProcess(const WatchdogConfig& config, NormalRequest callback, FinalReport finalReport)
        : config_(config), policy_(config), normalRequest_(std::move(callback)),
          finalReport_(std::move(finalReport)) {}

    static bool IsAbsoluteExecutable(const std::wstring& path) noexcept {
        if (path.size() < 7 || path.find(L'\0') != std::wstring::npos) return false;
        const bool driveAbsolute = ((path[0] >= L'A' && path[0] <= L'Z') ||
            (path[0] >= L'a' && path[0] <= L'z')) && path[1] == L':' &&
            (path[2] == L'\\' || path[2] == L'/');
        if (!driveAbsolute) return false; // No UNC, device, relative, or shell paths.
        const std::size_t offset = path.size() - 4;
        return path[offset] == L'.' && (path[offset + 1] == L'e' || path[offset + 1] == L'E') &&
            (path[offset + 2] == L'x' || path[offset + 2] == L'X') &&
            (path[offset + 3] == L'e' || path[offset + 3] == L'E');
    }
    static std::wstring QuoteArgument(const std::wstring& argument) {
        std::wstring result = L"\"";
        std::size_t slashes = 0;
        for (const wchar_t character : argument) {
            if (character == L'\\') { ++slashes; continue; }
            if (character == L'\"') {
                result.append(slashes * 2 + 1, L'\\');
                result += character;
            } else {
                result.append(slashes, L'\\');
                result += character;
            }
            slashes = 0;
        }
        result.append(slashes * 2, L'\\');
        result += L'\"';
        return result;
    }
    void ObserveExit() noexcept {
        if (report_.processExitVerified) return;
        const DWORD waited = WaitForSingleObject(process_, 0);
        if (waited == WAIT_OBJECT_0) {
            DWORD code = 0;
            if (GetExitCodeProcess(process_, &code)) {
                report_.processExitVerified = true;
                report_.exitCode = code;
                report_.observationError = ERROR_SUCCESS;
            } else report_.observationError = GetLastError();
        } else if (waited == WAIT_FAILED) report_.observationError = GetLastError();
    }
    OwnedProcessReport RunUntilStopped(bool stopRequested) noexcept {
        for (;;) {
            const auto report = Poll(stopRequested);
            if (report.processExitVerified || report.forceAttempted ||
                report.forceUnauthorizedAfterGrace || report.observationError != ERROR_SUCCESS)
                return report;
            Sleep(1);
        }
    }
    void CleanupNeverExecutedChild() noexcept {
        // This exception path is limited to our own CREATE_SUSPENDED child,
        // before any application instruction ran; it is not the live fallback.
        ObserveExit();
        if (report_.neverExecutedCleanupAttempted) return;
        if (!report_.processExitVerified) {
            report_.neverExecutedCleanupAttempted = true;
            report_.neverExecutedCleanupCallSucceeded = TerminateProcess(process_, ForcedExitCode) != FALSE;
            if (report_.neverExecutedCleanupCallSucceeded) {
                const DWORD waited = WaitForSingleObject(process_, config_.terminationWaitMilliseconds);
                if (waited == WAIT_FAILED) report_.observationError = GetLastError();
                ObserveExit();
            } else report_.neverExecutedCleanupError = GetLastError();
        }
    }

    WatchdogConfig config_;
    WatchdogPolicy policy_;
    NormalRequest normalRequest_;
    FinalReport finalReport_;
    HANDLE process_ = nullptr;
    HANDLE thread_ = nullptr;
    ULONGLONG creationTick_ = 0;
    OwnedProcessReport report_;
};

} } // namespace beamrt::unattended
