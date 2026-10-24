#include "../startup_contract.h"
#include <shellapi.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
static std::wstring PhysicalPath(const fs::path& path) {
    const auto value = fs::absolute(path).lexically_normal().wstring();
    return value.rfind(L"\\\\?\\", 0) == 0 ? value : std::wstring(L"\\\\?\\") + value;
}

// Disposable hidden GUI process, deliberately named beamrt_startup_fixture.exe
// in its isolated build directory. No graphics, networking, existing-process
// inspection, engine loading, or process creation is present in this fixture.
static bool WriteNew(const fs::path& path, const std::string& text) {
    HANDLE file = CreateFileW(PhysicalPath(path).c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const BOOL result = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
    CloseHandle(file);
    return result && written == text.size();
}

static bool EqualBoundedFile(const fs::path& path, const std::string& expected) {
    const HANDLE file = CreateFileW(PhysicalPath(path).c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER length{};
    if (!GetFileSizeEx(file, &length) || length.QuadPart != static_cast<LONGLONG>(expected.size())) {
        CloseHandle(file); return false;
    }
    std::string text(expected.size(), '\0');
    DWORD count = 0;
    const BOOL read = ReadFile(file, text.data(), static_cast<DWORD>(text.size()), &count, nullptr);
    CloseHandle(file);
    return read && count == expected.size() && text == expected;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    int count = 0;
    wchar_t** raw = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!raw) return 60;
    const std::vector<std::wstring> args(raw, raw + count);
    LocalFree(raw);
    std::size_t offset = 1;
    if (args.size() >= 3 && args[1] == L"--fixture-host-fault") offset = 3;
    if (args.size() != offset + 10 || args[offset] != L"--owned-fixture-mode" ||
        args[offset + 2] != L"--owned-fixture-run-dir" || args[offset + 4] != L"--owned-fixture-token" ||
        args[offset + 6] != L"--owned-fixture-module" || args[offset + 8] != L"--owned-fixture-report") return 61;
    const auto& mode = args[offset + 1];
    if (mode != L"cooperative" && mode != L"ignore" && mode != L"exit17") return 62;
    const fs::path directory(args[offset + 3]);
    const auto& wideToken = args[offset + 5];
    if (!directory.is_absolute() || wideToken.size() != 32 ||
        wideToken.find_first_not_of(L"0123456789abcdef") != std::wstring::npos) return 63;
    std::string token;
    for (const wchar_t character : wideToken) token += static_cast<char>(character);
    const DWORD pid = GetCurrentProcessId();
    const auto identity = "\"token\":\"" + token + "\",\"expectedPid\":" + std::to_string(pid);
    const auto context = "{" + identity + "}\n";
    if (!EqualBoundedFile(directory / L"process-context.json", context)) return 64;
    using Query = BOOL(WINAPI*)(BeamRTStartupStatus*, DWORD);
    const auto module = GetModuleHandleW(args[offset + 7].c_str());
    const auto query = module ? reinterpret_cast<Query>(GetProcAddress(module, "BeamRT_StartupQuery")) : nullptr;
    BeamRTStartupStatus status{};
    if (!query || !query(&status, sizeof(status)) || status.bytes != sizeof(status) || status.abi != 1 ||
        status.processId != pid || status.attachThread != GetCurrentThreadId() || status.attached != 1 ||
        status.captureInstalled || status.gpuWorkSubmitted || status.lightingConsumed) return 65;
    const fs::path report(args[offset + 9]);
    if (report.parent_path() != directory) return 66;
    if (!WriteNew(report, "{" + identity + ",\"startupQueryValid\":true,\"captureInstalled\":false,"
        "\"gpuWorkSubmitted\":false,\"lightingConsumed\":false}\n")) return 67;
    if (mode == L"exit17") return 17;
    const auto stop = "{" + identity + ",\"kind\":\"normal_quit_requested\"}\n";
    const auto until = GetTickCount64() + 25000;
    while (GetTickCount64() < until) {
        if (mode == L"cooperative" && EqualBoundedFile(directory / L"owner-stop.json", stop)) {
            if (!WriteNew(report.wstring() + L".normal", "normal request accepted\n")) return 68;
            return 0;
        }
        Sleep(2);
    }
    // A fixture guard only. The real owner deadlines are much shorter and the
    // harness requires their exact forced exit code, never this self-timeout.
    return 69;
}
