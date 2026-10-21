#pragma once

// Explicit startup-host integration only. The master process/thread handles are
// created here, never accepted from another owner, and never exposed. Setup may
// receive reduced-right duplicates while an independently scheduled owner thread
// services the same exact-child policy. This is not a separate watchdog process
// or a hard real-time guarantee: Win32 calls and callbacks must remain bounded.
#include "owned_watchdog.h"

#include <mutex>
#include <thread>

namespace beamrt { namespace unattended {

class StartupOwnedSession final {
public:
    using NormalRequest = OwnedProcess::NormalRequest;
    using FinalReport = OwnedProcess::FinalReport;

    StartupOwnedSession(const WatchdogConfig& config, NormalRequest normalRequest,
        FinalReport finalReport = FinalReport())
        : config_(config), normalRequest_(std::move(normalRequest)),
          finalReport_(std::move(finalReport)) {
        ValidateWatchdogConfig(config_);
        if (!normalRequest_)
            throw std::invalid_argument("an explicit normal request callback is required");
    }

    ~StartupOwnedSession() noexcept { Finish(); }
    StartupOwnedSession(const StartupOwnedSession&) = delete;
    StartupOwnedSession& operator=(const StartupOwnedSession&) = delete;
    StartupOwnedSession(StartupOwnedSession&&) = delete;
    StartupOwnedSession& operator=(StartupOwnedSession&&) = delete;

    // Returns caller-owned DUPLICATES only. They support the startup host's
    // suspended-child Detours setup and waits, but cannot terminate or resume.
    // The caller must close both duplicate handles, including on exceptions.
    PROCESS_INFORMATION Create(const std::wstring& absoluteExecutable,
        std::vector<wchar_t>& mutableCommand, const std::wstring& workingDirectory,
        STARTUPINFOEXW& startup, BOOL inheritHandles, DWORD creationFlags) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (owned_ || finished_ || createAttempted_)
            throw std::runtime_error("startup session is one-shot");
        if (!OwnedProcess::IsAbsoluteExecutable(absoluteExecutable) ||
            mutableCommand.empty() || mutableCommand.back() != L'\0' ||
            mutableCommand.size() > 32767 ||
            startup.StartupInfo.cb != sizeof(STARTUPINFOEXW) ||
            !(creationFlags & CREATE_SUSPENDED) ||
            !(creationFlags & EXTENDED_STARTUPINFO_PRESENT)) {
            throw std::invalid_argument("explicit suspended extended-startup inputs required");
        }
        createAttempted_ = true;
        auto pending = std::unique_ptr<OwnedProcess>(new OwnedProcess(config_,
            std::move(normalRequest_), std::move(finalReport_)));
        PROCESS_INFORMATION actual{};
        pending->creationTick_ = GetTickCount64();
        if (!CreateProcessW(absoluteExecutable.c_str(), mutableCommand.data(),
                nullptr, nullptr, inheritHandles, creationFlags, nullptr,
                workingDirectory.empty() ? nullptr : workingDirectory.c_str(),
                &startup.StartupInfo, &actual)) {
            throw std::runtime_error("owned startup CreateProcessW failed");
        }
        pending->process_ = actual.hProcess;
        pending->thread_ = actual.hThread;
        pending->report_.processId = actual.dwProcessId;
        // Retain identity and cleanup evidence even when later setup fails.
        owned_ = std::move(pending);

        PROCESS_INFORMATION setup{};
        setup.dwProcessId = actual.dwProcessId;
        setup.dwThreadId = actual.dwThreadId;
        constexpr DWORD processRights = PROCESS_VM_OPERATION | PROCESS_VM_READ |
            PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION | SYNCHRONIZE;
        constexpr DWORD threadRights = THREAD_QUERY_INFORMATION | SYNCHRONIZE;
        try {
            if (!DuplicateHandle(GetCurrentProcess(), actual.hProcess, GetCurrentProcess(),
                    &setup.hProcess, processRights, FALSE, 0)) {
                throw std::runtime_error("startup process setup-handle duplication failed");
            }
            if (!DuplicateHandle(GetCurrentProcess(), actual.hThread, GetCurrentProcess(),
                    &setup.hThread, threadRights, FALSE, 0)) {
                throw std::runtime_error("startup thread setup-handle duplication failed");
            }
            watcher_ = std::thread([this]() noexcept { Watch(); });
        }
        catch (...) {
            if (setup.hThread) CloseHandle(setup.hThread);
            if (setup.hProcess) CloseHandle(setup.hProcess);
            // The only child exists suspended and no resume was attempted.
            owned_->report_.elapsedMilliseconds = GetTickCount64() - owned_->creationTick_;
            owned_->CleanupNeverExecutedChild();
            finished_ = true;
            throw;
        }
        return setup;
    }

    // Only this method can resume the private master thread. An expired or
    // already stopped pre-resume session must never execute application code.
    DWORD Resume() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!owned_ || finished_ || stopRequested_ || owned_->report_.resumeAttempted)
            throw std::runtime_error("owned startup resume is unavailable");
        owned_->report_.elapsedMilliseconds = GetTickCount64() - owned_->creationTick_;
        owned_->ObserveExit();
        if (owned_->report_.elapsedMilliseconds >= config_.overallMilliseconds) {
            beforeResumeTimedOut_ = true;
            owned_->CleanupNeverExecutedChild();
        }
        if (beforeResumeTimedOut_ || owned_->report_.processExitVerified ||
            owned_->report_.observationError != ERROR_SUCCESS)
            throw std::runtime_error("owned startup child stopped before resume");

        owned_->report_.resumeAttempted = true;
        const DWORD previous = ResumeThread(owned_->thread_);
        owned_->report_.resumed = previous != static_cast<DWORD>(-1);
        // Even an unexpected successful resume may have executed application
        // code. It must use the live normal/grace policy from this point on.
        if (previous != static_cast<DWORD>(-1)) {
            CloseHandle(owned_->thread_);
            owned_->thread_ = nullptr;
        }
        return previous;
    }

    // Owner-thread only, never from callbacks. Join happens outside the mutex so
    // the observer can finish its normal-request/full-grace/exit-check sequence.
    OwnedProcessReport Finish() noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopRequested_ = true;
            finished_ = true;
            if (owned_ && !watcher_.joinable() && !owned_->report_.resumeAttempted) {
                owned_->report_.elapsedMilliseconds = GetTickCount64() - owned_->creationTick_;
                owned_->CleanupNeverExecutedChild();
            }
        }
        if (watcher_.joinable()) watcher_.join();
        return Report();
    }

    OwnedProcessReport Report() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return owned_ ? owned_->report_ : OwnedProcessReport{};
    }

    bool BeforeResumeTimedOut() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return beforeResumeTimedOut_;
    }

private:
    void Watch() noexcept {
        for (;;) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!owned_) return;
                if (!owned_->report_.resumeAttempted) {
                    owned_->report_.elapsedMilliseconds = GetTickCount64() - owned_->creationTick_;
                    owned_->ObserveExit();
                    if (owned_->report_.processExitVerified ||
                        owned_->report_.observationError != ERROR_SUCCESS) return;
                    const bool expired = owned_->report_.elapsedMilliseconds >= config_.overallMilliseconds;
                    if (expired) beforeResumeTimedOut_ = true;
                    if (stopRequested_ || expired) {
                        owned_->CleanupNeverExecutedChild();
                        return;
                    }
                } else {
                    const auto report = owned_->Poll(stopRequested_);
                    if (report.processExitVerified || report.forceAttempted ||
                        report.forceUnauthorizedAfterGrace ||
                        report.observationError != ERROR_SUCCESS) return;
                }
            }
            Sleep(1);
        }
    }

    WatchdogConfig config_;
    NormalRequest normalRequest_;
    FinalReport finalReport_;
    mutable std::mutex mutex_;
    std::unique_ptr<OwnedProcess> owned_;
    std::thread watcher_;
    bool stopRequested_ = false;
    bool finished_ = false;
    bool beforeResumeTimedOut_ = false;
    bool createAttempted_ = false;
};

} } // namespace beamrt::unattended
