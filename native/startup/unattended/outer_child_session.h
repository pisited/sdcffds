#pragma once

// Explicit host-side participant in a fixed inherited outer-owner channel.
// This participant owns only reduced setup capabilities, never the private
// child masters. The independently running outer owner performs IPC relay,
// execution release and all shutdown policy. Destruction only closes handles;
// it is not cleanup or child-exit evidence.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <type_traits>

namespace beamrt { namespace unattended {

struct alignas(8) OuterChildChannelV1 final {
    char magic[8];
    std::uint32_t bytes;
    std::uint32_t abi;
    unsigned char token[16];
    unsigned char configDigest[32];
    std::uint32_t childPid;
    std::uint32_t childTid;
    std::uint64_t creationTick;
    std::uint32_t overallMilliseconds;
    std::uint32_t graceMilliseconds;
    std::uint32_t terminationWaitMilliseconds;
    std::uint32_t expectedIPCcount;
    std::uint64_t setupProcess;
    std::uint64_t setupThread;
    std::uint64_t hostToOuterEvent;
    std::uint64_t outerToHostEvent;
    volatile LONG state;
    std::uint32_t resumeResult;
    std::uint32_t coreResult;
    std::uint32_t error;
    std::uint64_t sourceHandles[14];
    std::uint64_t childHandles[14];
    unsigned char reserved[144];
};

static_assert(sizeof(void*) == 8 && sizeof(LONG) == 4, "outer channel requires Windows x64");
static_assert(std::is_standard_layout<OuterChildChannelV1>::value &&
    std::is_trivially_copyable<OuterChildChannelV1>::value, "outer channel must have a fixed byte layout");
static_assert(offsetof(OuterChildChannelV1, magic) == 0 && offsetof(OuterChildChannelV1, bytes) == 8 &&
    offsetof(OuterChildChannelV1, abi) == 12 && offsetof(OuterChildChannelV1, token) == 16 &&
    offsetof(OuterChildChannelV1, configDigest) == 32, "outer channel identity offsets changed");
static_assert(offsetof(OuterChildChannelV1, childPid) == 64 && offsetof(OuterChildChannelV1, childTid) == 68 &&
    offsetof(OuterChildChannelV1, creationTick) == 72 && offsetof(OuterChildChannelV1, overallMilliseconds) == 80 &&
    offsetof(OuterChildChannelV1, graceMilliseconds) == 84 &&
    offsetof(OuterChildChannelV1, terminationWaitMilliseconds) == 88 &&
    offsetof(OuterChildChannelV1, expectedIPCcount) == 92, "outer channel policy offsets changed");
static_assert(offsetof(OuterChildChannelV1, setupProcess) == 96 &&
    offsetof(OuterChildChannelV1, setupThread) == 104 &&
    offsetof(OuterChildChannelV1, hostToOuterEvent) == 112 &&
    offsetof(OuterChildChannelV1, outerToHostEvent) == 120, "outer channel capability offsets changed");
static_assert(offsetof(OuterChildChannelV1, state) == 128 && offsetof(OuterChildChannelV1, resumeResult) == 132 &&
    offsetof(OuterChildChannelV1, coreResult) == 136 && offsetof(OuterChildChannelV1, error) == 140 &&
    offsetof(OuterChildChannelV1, sourceHandles) == 144 && offsetof(OuterChildChannelV1, childHandles) == 256 &&
    offsetof(OuterChildChannelV1, reserved) == 368 && sizeof(OuterChildChannelV1) == 512,
    "outer channel mutable offsets or size changed");

class OuterChildSession final {
public:
    // Ownership of mapping transfers immediately, including on constructor
    // failure. The other four inherited capabilities are adopted from the
    // validated fixed channel; aliases are closed only once. Numeric identities
    // are joins, not authority to reopen or acquire another process.
    OuterChildSession(HANDLE mapping, const std::wstring& token,
        const std::wstring& expectedDigest, const std::wstring& expectedExe,
        DWORD overallSeconds, DWORD graceSeconds, unsigned expectedIPCcount) {
        try {
            if (!ValidValue(Value(mapping))) throw std::runtime_error("outer mapping capability value refused");
            handles_[handleCount_++] = mapping;
            DWORD mappingFlags = 0;
            if (!GetHandleInformation(mapping, &mappingFlags) || !(mappingFlags & HANDLE_FLAG_INHERIT))
                throw std::runtime_error("outer inherited mapping metadata refused");
            view_ = static_cast<OuterChildChannelV1*>(MapViewOfFile(mapping,
                FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(OuterChildChannelV1)));
            if (!view_) throw std::runtime_error("outer shared-channel mapping failed");
            // Adopt all valid distinct listed capabilities before semantic
            // validation so a refused constructor closes the inherited set.
            // Only the reviewed outer factory may supply this channel.
            AdoptInheritedCapabilities();
            const char magic[8] = {'B', 'R', 'T', 'E', 'X', 'T', '1', 0};
            if (std::memcmp(view_->magic, magic, sizeof(magic)) || view_->bytes != sizeof(OuterChildChannelV1) ||
                view_->abi != 1 || !overallSeconds || overallSeconds > 480 || !graceSeconds || graceSeconds > 30 ||
                !ValidIPCcount(expectedIPCcount) || view_->overallMilliseconds != overallSeconds * 1000 ||
                view_->graceMilliseconds != graceSeconds * 1000 || view_->terminationWaitMilliseconds != 5000 ||
                view_->expectedIPCcount != expectedIPCcount || !view_->childPid || !view_->childTid ||
                view_->creationTick > GetTickCount64()) {
                throw std::runtime_error("outer shared-channel identity or policy refused");
            }
            const auto parsedToken = ParseHex<16>(token);
            const auto parsedDigest = ParseHex<32>(expectedDigest);
            if (std::memcmp(view_->token, parsedToken.data(), parsedToken.size()) ||
                std::memcmp(view_->configDigest, parsedDigest.data(), parsedDigest.size()) ||
                !Zero(view_->reserved, sizeof(view_->reserved)) || ReadState() != 0 ||
                view_->resumeResult != Unset || view_->coreResult != Unset || view_->error != ERROR_SUCCESS ||
                !Zero(view_->sourceHandles, sizeof(view_->sourceHandles)) ||
                !Zero(view_->childHandles, sizeof(view_->childHandles))) {
                throw std::runtime_error("outer shared-channel initial contents refused");
            }
            std::memcpy(immutable_.data(), view_, immutable_.size());
            maySignal_ = true;
            if (GetProcessId(handles_[1]) != view_->childPid || GetThreadId(handles_[2]) != view_->childTid ||
                GetProcessIdOfThread(handles_[2]) != view_->childPid) {
                throw std::runtime_error("outer retained setup capability identity mismatch");
            }
            if (expectedExe.size() < 7 || expectedExe.size() > 32700 ||
                !((expectedExe[0] >= L'A' && expectedExe[0] <= L'Z') ||
                  (expectedExe[0] >= L'a' && expectedExe[0] <= L'z')) ||
                expectedExe[1] != L':' || expectedExe[2] != L'\\' ||
                expectedExe.find(L'\0') != std::wstring::npos) {
                throw std::runtime_error("outer expected executable must be explicitly drive-absolute");
            }
            std::array<wchar_t, 32768> actualExe{};
            DWORD actualLength = static_cast<DWORD>(actualExe.size());
            if (!QueryFullProcessImageNameW(handles_[1], 0, actualExe.data(), &actualLength) ||
                !actualLength || actualLength >= actualExe.size() ||
                _wcsicmp(actualExe.data(), expectedExe.c_str()) != 0) {
                throw std::runtime_error("outer retained child executable mismatch");
            }
            CheckStable();
            RequireBudget();
            if (WaitForSingleObject(handles_[1], 0) != WAIT_TIMEOUT)
                throw std::runtime_error("outer retained child is not waiting for setup");
            processId_ = view_->childPid;
        } catch (...) {
            Fail(ERROR_INVALID_DATA);
            Close();
            throw;
        }
    }

    ~OuterChildSession() noexcept { Close(); }
    OuterChildSession(const OuterChildSession&) = delete;
    OuterChildSession& operator=(const OuterChildSession&) = delete;
    OuterChildSession(OuterChildSession&&) = delete;
    OuterChildSession& operator=(OuterChildSession&&) = delete;

    DWORD ProcessId() const noexcept { return processId_; }

    // Caller-owned duplicates, in the current host only. Neither duplicate has
    // target duplication, execution-release or termination capabilities.
    PROCESS_INFORMATION Setup() {
        if (setupAttempted_) Reject(ERROR_INVALID_STATE, "outer setup handles are one-shot");
        setupAttempted_ = true;
        CheckStable();
        RequireBudget();
        if (ReadState() != 0) Reject(ERROR_INVALID_STATE, "outer setup state refused");
        PROCESS_INFORMATION result{};
        result.dwProcessId = view_->childPid;
        result.dwThreadId = view_->childTid;
        constexpr DWORD processRights = PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE |
            PROCESS_QUERY_INFORMATION | SYNCHRONIZE;
        constexpr DWORD threadRights = THREAD_QUERY_INFORMATION | SYNCHRONIZE;
        if (!DuplicateHandle(GetCurrentProcess(), handles_[1], GetCurrentProcess(), &result.hProcess,
                processRights, FALSE, 0)) Reject(GetLastError(), "outer current-process setup duplication failed");
        if (!DuplicateHandle(GetCurrentProcess(), handles_[2], GetCurrentProcess(), &result.hThread,
                threadRights, FALSE, 0)) {
            const DWORD error = GetLastError();
            CloseHandle(result.hProcess);
            Reject(error, "outer current-thread setup duplication failed");
        }
        setupReturned_ = true;
        return result;
    }

    // Local IPC source handles are published once. Only the outer owner can
    // relay them to the exact retained child, using its fixed per-slot rights.
    void RelayIPC(HANDLE* local, unsigned count) {
        if (relayAttempted_) Reject(ERROR_INVALID_STATE, "outer IPC relay is one-shot");
        relayAttempted_ = true;
        CheckStable();
        RequireBudget();
        if (!setupReturned_ || !local || count != view_->expectedIPCcount || ReadState() != 0 ||
            view_->resumeResult != Unset || view_->coreResult != Unset || view_->error != ERROR_SUCCESS ||
            !Zero(view_->sourceHandles, sizeof(view_->sourceHandles)) ||
            !Zero(view_->childHandles, sizeof(view_->childHandles))) {
            Reject(ERROR_INVALID_DATA, "outer IPC request state refused");
        }
        for (unsigned index = 0; index < count; ++index) {
            const auto value = Value(local[index]);
            DWORD flags = 0;
            if (!ValidValue(value) || !GetHandleInformation(local[index], &flags))
                Reject(ERROR_INVALID_HANDLE, "outer IPC source handle refused");
            for (const HANDLE owned : handles_)
                if (value == Value(owned)) Reject(ERROR_INVALID_HANDLE, "outer IPC source aliases inherited capability");
            for (unsigned before = 0; before < index; ++before)
                if (source_[before] == value) Reject(ERROR_INVALID_HANDLE, "outer IPC source handle repeated");
            source_[index] = value;
        }
        std::memcpy(view_->sourceHandles, source_.data(), sizeof(view_->sourceHandles));
        PublishState(1);
        WaitForState(1, 2);
        if (view_->resumeResult != Unset || view_->coreResult != Unset || view_->error != ERROR_SUCCESS ||
            std::memcmp(view_->sourceHandles, source_.data(), sizeof(view_->sourceHandles))) {
            Reject(ERROR_INVALID_DATA, "outer IPC grant changed request fields");
        }
        for (unsigned index = 0; index < 14; ++index) {
            const auto value = view_->childHandles[index];
            if (index < count) {
                if (!ValidValue(value)) Reject(ERROR_INVALID_HANDLE, "outer IPC remote handle refused");
                for (unsigned before = 0; before < index; ++before)
                    if (child_[before] == value) Reject(ERROR_INVALID_HANDLE, "outer IPC remote handle repeated");
                child_[index] = value;
            } else if (value) Reject(ERROR_INVALID_DATA, "outer IPC unused remote slot was populated");
        }
        relayed_ = true;
        CheckTables();
    }

    std::uint64_t ChildValue(HANDLE local) const {
        if (!relayed_) throw std::runtime_error("outer child IPC value requested before relay grant");
        CheckStable();
        CheckTables();
        const LONG state = ReadState();
        if (state < 2 || state > 5) throw std::runtime_error("outer child IPC value requested after failure");
        for (unsigned index = 0; index < view_->expectedIPCcount; ++index)
            if (source_[index] == Value(local)) return child_[index];
        throw std::runtime_error("outer child IPC value requested for an unknown local handle");
    }

    // Returns only the outer owner's actual release result. No child execution
    // primitive exists in this participant. A successful result other than one
    // remains visible so the caller can reject an unexpected suspend count.
    DWORD Resume() {
        if (resumeAttempted_) Reject(ERROR_INVALID_STATE, "outer execution release is one-shot");
        resumeAttempted_ = true;
        CheckStable();
        RequireBudget();
        CheckTables();
        if (!relayed_ || ReadState() != 2 || view_->resumeResult != Unset || view_->coreResult != Unset ||
            view_->error != ERROR_SUCCESS) Reject(ERROR_INVALID_DATA, "outer execution request state refused");
        PublishState(3);
        WaitForState(3, 4);
        CheckTables();
        if (view_->resumeResult == Unset || view_->coreResult != Unset || view_->error != ERROR_SUCCESS)
            Reject(ERROR_INVALID_DATA, "outer execution grant result refused");
        resumedResult_ = view_->resumeResult;
        resumeGranted_ = true;
        return resumedResult_;
    }

    void Complete(int coreResult) {
        if (completed_) Reject(ERROR_INVALID_STATE, "outer core completion is one-shot");
        CheckStable();
        CheckTables();
        if (!resumeGranted_ || ReadState() != 4 || view_->resumeResult != resumedResult_ ||
            view_->coreResult != Unset || view_->error != ERROR_SUCCESS)
            Reject(ERROR_INVALID_DATA, "outer core completion state refused");
        completed_ = true;
        view_->coreResult = static_cast<std::uint32_t>(coreResult);
        PublishState(5);
    }

    // Best-effort terminal failure notification only. The independent owner
    // retains exact-child policy even when this notification cannot be delivered.
    void Fail(DWORD error) noexcept {
        if (!view_ || !maySignal_) return;
        view_->error = error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error;
        InterlockedExchange(&view_->state, 6);
        SetEvent(handles_[3]);
    }

private:
    static constexpr std::uint32_t Unset = 0xFFFFFFFFU;
    static bool ValidIPCcount(unsigned count) noexcept {
        return count == 1 || count == 3 || count == 5 || count == 9 || count == 12 || count == 14;
    }
    static bool ValidValue(std::uint64_t value) noexcept {
        return value > 0 && value < 0xFFFFFFFFFFFFFFF0ULL;
    }
    static std::uint64_t Value(HANDLE handle) noexcept {
        return static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(handle));
    }
    static HANDLE FromValue(std::uint64_t value) noexcept {
        return reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(value));
    }
    static bool Zero(const void* pointer, std::size_t bytes) noexcept {
        const auto* data = static_cast<const unsigned char*>(pointer);
        for (std::size_t index = 0; index < bytes; ++index) if (data[index]) return false;
        return true;
    }
    template<std::size_t Bytes> static std::array<unsigned char, Bytes> ParseHex(const std::wstring& text) {
        if (text.size() != Bytes * 2) throw std::invalid_argument("outer lowercase hex join has wrong size");
        std::array<unsigned char, Bytes> result{};
        for (std::size_t index = 0; index < text.size(); ++index) {
            const wchar_t value = text[index];
            const unsigned nibble = value >= L'0' && value <= L'9' ? static_cast<unsigned>(value - L'0') :
                value >= L'a' && value <= L'f' ? static_cast<unsigned>(value - L'a' + 10) : 16;
            if (nibble > 15) throw std::invalid_argument("outer join must be lowercase hexadecimal");
            result[index / 2] = static_cast<unsigned char>((result[index / 2] << 4) | nibble);
        }
        return result;
    }
    void AdoptInheritedCapabilities() {
        bool good = true;
        const std::uint64_t values[] = {view_->setupProcess, view_->setupThread,
            view_->hostToOuterEvent, view_->outerToHostEvent};
        for (const auto value : values) {
            if (!ValidValue(value)) { good = false; continue; }
            const HANDLE handle = FromValue(value);
            bool repeated = false;
            for (const HANDLE owned : handles_) if (owned == handle) repeated = true;
            if (repeated) { good = false; continue; }
            DWORD flags = 0;
            if (!GetHandleInformation(handle, &flags)) { good = false; continue; }
            handles_[handleCount_++] = handle;
            if (!(flags & HANDLE_FLAG_INHERIT)) good = false;
        }
        if (!good || handleCount_ != handles_.size())
            throw std::runtime_error("outer inherited capability set refused");
    }
    LONG ReadState() const noexcept { return InterlockedCompareExchange(&view_->state, 0, 0); }
    void CheckStable() const {
        if (!view_ || std::memcmp(view_, immutable_.data(), immutable_.size()) ||
            !Zero(view_->reserved, sizeof(view_->reserved)))
            throw std::runtime_error("outer immutable channel fields changed");
    }
    void CheckTables() const {
        if (std::memcmp(view_->sourceHandles, source_.data(), sizeof(view_->sourceHandles)) ||
            std::memcmp(view_->childHandles, child_.data(), sizeof(view_->childHandles)))
            throw std::runtime_error("outer accepted IPC handle tables changed");
    }
    DWORD Remaining() const noexcept {
        const auto now = GetTickCount64();
        if (now < view_->creationTick) return 0;
        const auto elapsed = now - view_->creationTick;
        return elapsed < view_->overallMilliseconds ? static_cast<DWORD>(view_->overallMilliseconds - elapsed) : 0;
    }
    void RequireBudget() {
        if (!Remaining()) Reject(ERROR_TIMEOUT, "outer creation-origin overall deadline expired");
    }
    [[noreturn]] void Reject(DWORD error, const char* message) {
        Fail(error);
        throw std::runtime_error(message);
    }
    void PublishState(LONG state) {
        InterlockedExchange(&view_->state, state);
        if (!SetEvent(handles_[3])) Reject(GetLastError(), "outer request event signaling failed");
    }
    void WaitForState(LONG request, LONG granted) {
        const HANDLE waits[] = {handles_[4], handles_[1]};
        for (;;) {
            CheckStable();
            const DWORD remaining = Remaining();
            if (!remaining) Reject(ERROR_TIMEOUT, "outer handoff reached creation-origin deadline");
            const LONG state = ReadState();
            if (state == granted) return;
            if (state == 6) throw std::runtime_error("outer owner refused the handoff request");
            if (state != request) Reject(ERROR_INVALID_DATA, "outer handoff state transition refused");
            const DWORD waited = WaitForMultipleObjects(2, waits, FALSE, remaining);
            if (waited == WAIT_OBJECT_0) continue;
            if (waited == WAIT_OBJECT_0 + 1)
                Reject(ERROR_PROCESS_ABORTED, "outer retained child exited before handoff grant");
            if (waited == WAIT_TIMEOUT) Reject(ERROR_TIMEOUT, "outer handoff event wait timed out");
            Reject(waited == WAIT_FAILED ? GetLastError() : ERROR_INVALID_DATA, "outer handoff event wait failed");
        }
    }
    void Close() noexcept {
        if (view_) { UnmapViewOfFile(view_); view_ = nullptr; }
        while (handleCount_) {
            --handleCount_;
            CloseHandle(handles_[handleCount_]);
            handles_[handleCount_] = nullptr;
        }
    }

    OuterChildChannelV1* view_ = nullptr;
    std::array<HANDLE, 5> handles_{};
    std::size_t handleCount_ = 0;
    std::array<unsigned char, 128> immutable_{};
    std::array<std::uint64_t, 14> source_{};
    std::array<std::uint64_t, 14> child_{};
    DWORD processId_ = 0;
    DWORD resumedResult_ = Unset;
    bool maySignal_ = false;
    bool setupAttempted_ = false;
    bool setupReturned_ = false;
    bool relayAttempted_ = false;
    bool relayed_ = false;
    bool resumeAttempted_ = false;
    bool resumeGranted_ = false;
    bool completed_ = false;
};

} } // namespace beamrt::unattended
