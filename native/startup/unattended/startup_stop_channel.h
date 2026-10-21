#pragma once

// Inactive host-side file channel. No process creation, PID discovery, receipt
// validation, game operation or forced-close capability exists in this helper.
// Only an exact-owned process factory may supply PublishContext's PID.
// RequestNormal is a one-shot queue operation, NOT publication/delivery proof.
// Its detached worker owns its file/directory handles while filesystem I/O runs;
// neither Report nor destruction waits for that I/O. An external exact-owned
// watchdog must retain independent attempt-origin grace and process-exit checks.

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace beamrt { namespace unattended {

#if defined(BEAMRT_STARTUP_STOP_CHANNEL_FIXTURE)
class StartupStopChannelFixtureAccess;
#endif

struct StartupStopChannelReport {
    DWORD expectedPid = 0; // Diagnostics/JSON join only; never used to open a process.
    bool contextAttempted = false;
    bool contextPublished = false;
    DWORD contextError = ERROR_SUCCESS;
    bool requestAccepted = false;
    bool workerStarted = false;
    bool publicationCompleted = false;
    bool publicationSucceeded = false;
    DWORD publicationError = ERROR_SUCCESS;
    std::uint64_t requestedAtMilliseconds = 0;
    std::uint64_t workerStartedAtMilliseconds = 0;
    std::uint64_t completedAtMilliseconds = 0;
};

class StartupStopChannel final {
public:
    static_assert(std::atomic<bool>::is_always_lock_free && std::atomic<DWORD>::is_always_lock_free &&
        std::atomic<std::uint64_t>::is_always_lock_free, "nonblocking stop channel requires lock-free target atomics");
    // The directory must already exist on a fixed local drive. Reviewed immutable
    // inputs may be present, but every known runtime output must be absent.
    // Directory components are retained without delete sharing and reparse
    // points are rejected. A CREATE_NEW host-claim.json consumes this attempt.
    static std::unique_ptr<StartupStopChannel> Create(
        const std::wstring& absoluteDirectory, const std::string& token) {
        auto state = std::make_shared<State>();
        state->directory = ValidateDirectory(absoluteDirectory);
        state->token = ValidateToken(token);
        RetainPhysicalDirectory(*state);
        RequireFreshOutputs(*state);
        state->wake = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!state->wake) throw std::runtime_error("stop-channel event creation failed");
        const auto claim = std::string("{\"token\":\"") + state->token +
            "\",\"scope\":\"beamrt-unattended-observation-v1\"}\n";
        const DWORD claimed = CreateClaim(*state, claim);
        if (claimed != ERROR_SUCCESS) throw std::runtime_error("fresh stop-channel host claim refused");
        // All callback publication data is allocated before the child exists.
        auto result = std::unique_ptr<StartupStopChannel>(new StartupStopChannel(state));
        auto context = std::unique_ptr<std::shared_ptr<State>>(new std::shared_ptr<State>(state));
        const HANDLE worker = CreateThread(nullptr, 0, &WorkerMain, context.get(), 0, nullptr);
        if (!worker) throw std::runtime_error("stop-channel worker creation failed");
        context.release();
        CloseHandle(worker); // State is retained by the worker, never a blocking join.
        return result;
    }

    ~StartupStopChannel() noexcept {
        SetEvent(state_->wake);
    }
    StartupStopChannel(const StartupStopChannel&) = delete;
    StartupStopChannel& operator=(const StartupStopChannel&) = delete;
    StartupStopChannel(StartupStopChannel&&) = delete;
    StartupStopChannel& operator=(StartupStopChannel&&) = delete;

    // Synchronous pre-resume setup, called once by the exact-owned process factory.
    // Approval is a machine configuration join, never a source of human authority.
    // Partial/failed setup consumes the attempt; it is never repaired or retried.
    bool PublishContext(DWORD actualOwnedPid) noexcept {
        bool expected = false;
        if (!actualOwnedPid || !state_->contextAttempted.compare_exchange_strong(expected, true))
            return false;
        state_->pid.store(actualOwnedPid, std::memory_order_relaxed);
        try {
            const auto pid = std::to_string(actualOwnedPid);
            const auto context = std::string("{\"token\":\"") + state_->token +
                "\",\"expectedPid\":" + pid + "}\n";
            state_->normalJson = std::string("{\"token\":\"") + state_->token +
                "\",\"expectedPid\":" + pid + ",\"kind\":\"normal_quit_requested\"}\n";
            const auto approval = std::string("{\"token\":\"") + state_->token +
                "\",\"scope\":\"beamrt-unattended-observation-v1\",\"allow\":true}\n";
            DWORD error = Publish(*state_, L"process-context.json", context, state_->contextFile);
            if (error == ERROR_SUCCESS)
                error = Publish(*state_, L"launch-approval.json", approval, state_->approvalFile);
            state_->contextError.store(error, std::memory_order_relaxed);
            if (error != ERROR_SUCCESS) return false;
            state_->contextPublished.store(true, std::memory_order_release);
            return true;
        } catch (...) {
            state_->contextError.store(ERROR_NOT_ENOUGH_MEMORY, std::memory_order_relaxed);
            return false;
        }
    }

    // Main-host only, after all three closed CPU receipt files exist. This is a
    // machine rendezvous, not validation, ownership, GPU or engine-exit proof.
    bool PublishReceiptReady(DWORD actualOwnedPid) noexcept {
        if (!state_->contextPublished.load(std::memory_order_acquire) || !actualOwnedPid ||
            state_->pid.load(std::memory_order_relaxed) != actualOwnedPid) return false;
        bool expected = false;
        if (!state_->receiptAttempted.compare_exchange_strong(expected, true)) return false;
        try {
            const auto ready = std::string("{\"token\":\"") + state_->token +
                "\",\"expectedPid\":" + std::to_string(actualOwnedPid) +
                ",\"kind\":\"cpu_receipt_ready\",\"resourceABI\":7,\"drawABI\":5,"
                "\"profile\":2,\"mode\":1,\"cbvProbeBytes\":0,\"record\":\"recorded-draw.bin\"}\n";
            return Publish(*state_, L"receipt-ready.json", ready, state_->receiptFile) == ERROR_SUCCESS;
        } catch (...) { return false; }
    }

    // No filesystem operations, allocations, mutexes or waits on this path.
    // True means only that this one request was accepted for worker publication.
    // A duplicate/mismatched PID refuses without changing any file or retrying.
    bool RequestNormal(DWORD actualOwnedPid) noexcept {
        if (!state_->contextPublished.load(std::memory_order_acquire) ||
            !actualOwnedPid || state_->pid.load(std::memory_order_relaxed) != actualOwnedPid)
            return false;
        bool expected = false;
        if (!state_->requestAccepted.compare_exchange_strong(expected, true)) return false;
        state_->requestedAt.store(GetTickCount64(), std::memory_order_relaxed);
        if (SetEvent(state_->wake)) return true;
        state_->publicationError.store(GetLastError(), std::memory_order_relaxed);
        state_->completedAt.store(GetTickCount64(), std::memory_order_relaxed);
        state_->publicationCompleted.store(true, std::memory_order_release);
        return false;
    }

    // A coherent completed result is guaranteed once publicationCompleted is true.
    // While pending, diagnostic timestamps may reflect adjacent worker instants.
    StartupStopChannelReport Report() const noexcept {
        StartupStopChannelReport report;
        report.publicationCompleted = state_->publicationCompleted.load(std::memory_order_acquire);
        report.contextPublished = state_->contextPublished.load(std::memory_order_acquire);
        report.expectedPid = state_->pid.load(std::memory_order_relaxed);
        report.contextAttempted = state_->contextAttempted.load(std::memory_order_relaxed);
        report.contextError = state_->contextError.load(std::memory_order_relaxed);
        report.requestAccepted = state_->requestAccepted.load(std::memory_order_relaxed);
        report.workerStarted = state_->workerStarted.load(std::memory_order_relaxed);
        report.publicationSucceeded = state_->publicationSucceeded.load(std::memory_order_relaxed);
        report.publicationError = state_->publicationError.load(std::memory_order_relaxed);
        report.requestedAtMilliseconds = state_->requestedAt.load(std::memory_order_relaxed);
        report.workerStartedAtMilliseconds = state_->workerStartedAt.load(std::memory_order_relaxed);
        report.completedAtMilliseconds = state_->completedAt.load(std::memory_order_relaxed);
        return report;
    }

private:
#if defined(BEAMRT_STARTUP_STOP_CHANNEL_FIXTURE)
    // File-only fixture seam: exercise the retained, still-empty preclaim
    // directory state without creating a claim, event or publication worker.
    friend class StartupStopChannelFixtureAccess;
#endif
    struct State final {
        std::wstring directory;
        std::string token;
        std::string normalJson;
        std::vector<HANDLE> directories;
        HANDLE wake = nullptr;
        HANDLE claimFile = INVALID_HANDLE_VALUE;
        HANDLE contextFile = INVALID_HANDLE_VALUE;
        HANDLE approvalFile = INVALID_HANDLE_VALUE;
        HANDLE stopFile = INVALID_HANDLE_VALUE;
        HANDLE receiptFile = INVALID_HANDLE_VALUE;
        std::atomic<DWORD> pid{0}, contextError{0}, publicationError{0};
        std::atomic<bool> contextAttempted{false}, contextPublished{false}, requestAccepted{false};
        std::atomic<bool> workerStarted{false}, publicationCompleted{false};
        std::atomic<bool> publicationSucceeded{false};
        std::atomic<bool> receiptAttempted{false};
        std::atomic<std::uint64_t> requestedAt{0}, workerStartedAt{0}, completedAt{0};
        ~State() noexcept {
            for (HANDLE file : {claimFile, contextFile, approvalFile, stopFile, receiptFile})
                if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
            if (wake) CloseHandle(wake);
            for (HANDLE directoryHandle : directories) CloseHandle(directoryHandle);
        }
    };

    explicit StartupStopChannel(std::shared_ptr<State> state) : state_(std::move(state)) {}
    static std::string ValidateToken(const std::string& token) {
        if (token.size() != 32) throw std::invalid_argument("token must be exactly 32 lowercase hex characters");
        for (const char value : token)
            if (!((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')))
                throw std::invalid_argument("token must be exactly 32 lowercase hex characters");
        return token;
    }
    static std::wstring ValidateDirectory(const std::wstring& input) {
        if (input.size() < 4 || input.size() > 900 ||
            !((input[0] >= L'A' && input[0] <= L'Z') || (input[0] >= L'a' && input[0] <= L'z')) ||
            input[1] != L':' || (input[2] != L'\\' && input[2] != L'/'))
            throw std::invalid_argument("physical absolute local directory required");
        std::wstring path(input);
        for (auto& value : path) {
            if (value == L'/') value = L'\\';
            if (value < 32 || value == L'<' || value == L'>' || value == L'\"' || value == L'|' ||
                value == L'?' || value == L'*')
                throw std::invalid_argument("invalid directory character");
        }
        if (path.back() == L'\\') path.pop_back();
        if (path.back() == L'\\') throw std::invalid_argument("duplicate trailing directory separator");
        std::size_t start = 3;
        while (start < path.size()) {
            const auto end = path.find(L'\\', start);
            const auto component = path.substr(start, end == std::wstring::npos ? end : end - start);
            if (component.empty() || component == L"." || component == L".." ||
                component.back() == L' ' || component.back() == L'.' || component.find(L':') != std::wstring::npos)
                throw std::invalid_argument("noncanonical directory component");
            auto stem = component.substr(0, component.find(L'.'));
            for (auto& value : stem) if (value >= L'a' && value <= L'z') value -= L'a' - L'A';
            if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL" ||
                (stem.size() == 4 && (stem.substr(0, 3) == L"COM" || stem.substr(0, 3) == L"LPT") &&
                    stem[3] >= L'1' && stem[3] <= L'9'))
                throw std::invalid_argument("reserved directory component");
            if (end == std::wstring::npos) break;
            start = end + 1;
        }
        if (path.size() < 4) throw std::invalid_argument("drive root is not a run directory");
        const auto root = path.substr(0, 3);
        if (GetDriveTypeW(root.c_str()) != DRIVE_FIXED)
            throw std::invalid_argument("run directory must use a fixed local drive");
        return path;
    }
    static void RetainPhysicalDirectory(State& state) {
        for (std::size_t end = 3;;) {
            const auto component = state.directory.substr(0, end);
            const auto physicalComponent = std::wstring(L"\\\\?\\") + component;
            // An attributes-only directory handle does not enforce the intended
            // delete-sharing protection on an empty directory. LIST_DIRECTORY
            // makes the no-FILE_SHARE_DELETE lease cover the preclaim window and
            // every retained ancestor, not just a run directory containing files.
            HANDLE handle = CreateFileW(physicalComponent.c_str(), FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (handle == INVALID_HANDLE_VALUE) throw std::runtime_error("physical directory could not be retained");
            FILE_ATTRIBUTE_TAG_INFO info{};
            if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &info, sizeof(info)) ||
                !(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                CloseHandle(handle);
                throw std::runtime_error("reparse or non-directory component refused");
            }
            // The retained handle also rejects DOS drive substitutions whose final
            // path differs from the explicit physical path supplied by the owner.
            wchar_t finalPath[1024]{};
            const DWORD length = GetFinalPathNameByHandleW(handle, finalPath, 1024, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
            const auto expected = std::wstring(L"\\\\?\\") + component;
            std::wstring actual;
            if (length && length < 1024) actual.assign(finalPath, length);
            if (actual.size() > 7 && actual.back() == L'\\') actual.pop_back();
            auto normalizedExpected = expected;
            if (normalizedExpected.size() > 7 && normalizedExpected.back() == L'\\') normalizedExpected.pop_back();
            if (_wcsicmp(actual.c_str(), normalizedExpected.c_str()) != 0) {
                CloseHandle(handle);
                throw std::runtime_error("directory is not the explicitly named physical location");
            }
            try { state.directories.push_back(handle); }
            catch (...) { CloseHandle(handle); throw; }
            if (end == state.directory.size()) break;
            const auto next = state.directory.find(L'\\', end + 1);
            end = next == std::wstring::npos ? state.directory.size() : next;
        }
    }
    static std::wstring Path(const State& state, const wchar_t* leaf) {
        return std::wstring(L"\\\\?\\") + state.directory + L"\\" + leaf;
    }
    static void RequireFreshOutputs(const State& state) {
        const wchar_t* names[] = {L"host-claim.json", L"process-context.json", L"launch-approval.json",
            L"started.json", L"driver-ack.json", L"unattended-events.jsonl", L"owner-stop.json", L"owned-exit.json", L"receipt-ready.json"};
        for (const auto* leaf : names) {
            const auto path = Path(state, leaf);
            for (const auto& check : {path, path + L".pending"}) {
                if (GetFileAttributesW(check.c_str()) != INVALID_FILE_ATTRIBUTES || GetLastError() != ERROR_FILE_NOT_FOUND)
                    throw std::runtime_error("existing or unverifiable runtime output refused");
            }
        }
    }
    static DWORD WriteAndFlush(HANDLE file, const std::string& bytes) noexcept {
        DWORD written = 0;
        if (bytes.size() > 4096) return ERROR_BUFFER_OVERFLOW;
        if (!WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr)) return GetLastError();
        if (written != bytes.size()) return ERROR_WRITE_FAULT;
        if (!FlushFileBuffers(file)) return GetLastError();
        return ERROR_SUCCESS;
    }
    static DWORD CreateClaim(State& state, const std::string& bytes) {
        state.claimFile = CreateFileW(Path(state, L"host-claim.json").c_str(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (state.claimFile == INVALID_HANDLE_VALUE) return GetLastError();
        return WriteAndFlush(state.claimFile, bytes);
    }
    // Flush then rename BY THE STILL-LOCKED HANDLE, without replacement. Reopen
    // read-only so ordinary CRT readers need not share DELETE access. Identity
    // and content are verified across that reopen before success is reported;
    // then the retained read handle denies write/delete access. A race refuses.
    // Failed attempt files are preserved, never silently repaired or removed.
    static DWORD Publish(State& state, const wchar_t* leaf, const std::string& bytes, HANDLE& retained) {
        const auto finalPath = Path(state, leaf);
        const auto pendingPath = finalPath + L".pending";
        retained = CreateFileW(pendingPath.c_str(), GENERIC_READ | GENERIC_WRITE | DELETE,
            FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (retained == INVALID_HANDLE_VALUE) return GetLastError();
        DWORD error = WriteAndFlush(retained, bytes);
        if (error != ERROR_SUCCESS) return error;
        const auto nameBytes = finalPath.size() * sizeof(wchar_t);
        // Keep the documented terminating NUL in the allocated buffer even though
        // FileNameLength counts only the UTF-16 path bytes, not that terminator.
        std::vector<unsigned char> buffer(offsetof(FILE_RENAME_INFO, FileName) + nameBytes + sizeof(wchar_t));
        auto* rename = reinterpret_cast<FILE_RENAME_INFO*>(buffer.data());
        rename->ReplaceIfExists = FALSE;
        rename->RootDirectory = nullptr;
        rename->FileNameLength = static_cast<DWORD>(nameBytes);
        std::memcpy(rename->FileName, finalPath.c_str(), nameBytes + sizeof(wchar_t));
        if (!SetFileInformationByHandle(retained, FileRenameInfo, rename, static_cast<DWORD>(buffer.size()))) return GetLastError();
        BY_HANDLE_FILE_INFORMATION original{};
        if (!GetFileInformationByHandle(retained, &original)) return GetLastError();
        CloseHandle(retained);
        retained = CreateFileW(finalPath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (retained == INVALID_HANDLE_VALUE) return GetLastError();
        BY_HANDLE_FILE_INFORMATION reopened{};
        if (!GetFileInformationByHandle(retained, &reopened)) return GetLastError();
        if (reopened.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) ||
            original.dwVolumeSerialNumber != reopened.dwVolumeSerialNumber ||
            original.nFileIndexHigh != reopened.nFileIndexHigh || original.nFileIndexLow != reopened.nFileIndexLow)
            return ERROR_INVALID_DATA;
        char content[4097]{};
        DWORD read = 0;
        if (!ReadFile(retained, content, sizeof(content), &read, nullptr)) return GetLastError();
        if (read != bytes.size() || std::memcmp(content, bytes.data(), bytes.size()) != 0) return ERROR_INVALID_DATA;
        return ERROR_SUCCESS;
    }
    static DWORD WINAPI WorkerMain(void* opaque) noexcept {
        std::unique_ptr<std::shared_ptr<State>> context(static_cast<std::shared_ptr<State>*>(opaque));
        const auto state = *context;
        context.reset();
        const DWORD waited = WaitForSingleObject(state->wake, INFINITE);
        if (waited != WAIT_OBJECT_0) {
            state->publicationError.store(waited == WAIT_FAILED ? GetLastError() : ERROR_GEN_FAILURE, std::memory_order_relaxed);
            state->completedAt.store(GetTickCount64(), std::memory_order_relaxed);
            state->publicationCompleted.store(true, std::memory_order_release);
            return 0;
        }
        if (!state->requestAccepted.load(std::memory_order_acquire) ||
            state->publicationCompleted.load(std::memory_order_acquire)) return 0;
        state->workerStartedAt.store(GetTickCount64(), std::memory_order_relaxed);
        state->workerStarted.store(true, std::memory_order_relaxed);
        DWORD error = ERROR_NOT_ENOUGH_MEMORY;
        try { error = Publish(*state, L"owner-stop.json", state->normalJson, state->stopFile); }
        catch (...) { }
        state->publicationError.store(error, std::memory_order_relaxed);
        state->publicationSucceeded.store(error == ERROR_SUCCESS, std::memory_order_relaxed);
        state->completedAt.store(GetTickCount64(), std::memory_order_relaxed);
        state->publicationCompleted.store(true, std::memory_order_release);
        return 0;
    }

    std::shared_ptr<State> state_;
};

} } // namespace beamrt::unattended
