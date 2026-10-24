// Disposable integration child only. Reuse the actual GPU/observer fixture,
// then keep THIS process alive until its fixed CPU-receipt ACK is consumed.
// This file cannot create, inspect, attach to or terminate another process.
#define wWinMain BeamRTRecordedFixtureMain
#include "../binding_startup_fixture.cpp"
#undef wWinMain

namespace {
constexpr char handoffToken[] = "0123456789abcdef0123456789abcdef";

enum class HandoffRead { Absent, Complete, Failed };

std::wstring HandoffPhysical(const std::filesystem::path& path) {
    const auto value = std::filesystem::absolute(path).lexically_normal().wstring();
    return value.rfind(L"\\\\?\\", 0) == 0 ? value : std::wstring(L"\\\\?\\") + value;
}

HandoffRead HandoffReadBounded(const std::filesystem::path& path, std::string& bytes) {
    const HANDLE input = CreateFileW(HandoffPhysical(path).c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (input == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_SHARING_VIOLATION ||
            error == ERROR_LOCK_VIOLATION ? HandoffRead::Absent : HandoffRead::Failed;
    }
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    LARGE_INTEGER length{};
    if (!GetFileInformationByHandleEx(input, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
        attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) ||
        !GetFileSizeEx(input, &length) || length.QuadPart <= 0 || length.QuadPart > 4096) {
        CloseHandle(input); return HandoffRead::Failed;
    }
    bytes.assign(static_cast<std::size_t>(length.QuadPart), '\0');
    DWORD read = 0;
    const BOOL complete = ReadFile(input, &bytes[0], static_cast<DWORD>(bytes.size()), &read, nullptr);
    CloseHandle(input);
    return complete && read == bytes.size() ? HandoffRead::Complete : HandoffRead::Failed;
}

bool HandoffWriteNew(const std::filesystem::path& path, const std::string& bytes) {
    const HANDLE output = CreateFileW(HandoffPhysical(path).c_str(), GENERIC_WRITE,
        FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const BOOL complete = WriteFile(output, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr);
    const BOOL flushed = complete && written == bytes.size() ? FlushFileBuffers(output) : FALSE;
    CloseHandle(output);
    return flushed != FALSE;
}

bool HandoffAbsent(const std::filesystem::path& path) {
    return GetFileAttributesW(HandoffPhysical(path).c_str()) == INVALID_FILE_ATTRIBUTES &&
        GetLastError() == ERROR_FILE_NOT_FOUND;
}

bool HandoffAck(const std::string& image, DWORD pid, std::string& digest) {
    // Exact fixed compact format emitted by the existing receipt_ack publisher.
    // This intentionally is NOT a general JSON parser or validator replacement.
    const auto prefix = std::string("{\"token\":\"") + handoffToken +
        "\",\"kind\":\"receipt_validated\",\"expectedPid\":" + std::to_string(pid) +
        ",\"resourceABI\":7,\"profile\":2,\"mode\":1,\"cbvProbeBytes\":0,\"digest\":\"";
    const std::string suffix = "\"}\n";
    if (image.size() != prefix.size() + 64 + suffix.size() ||
        image.compare(0, prefix.size(), prefix) || image.compare(prefix.size() + 64, suffix.size(), suffix))
        return false;
    digest = image.substr(prefix.size(), 64);
    return digest.find_first_not_of("0123456789abcdef") == std::string::npos;
}
} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR command, int show) {
    try {
        int count = 0;
        wchar_t** raw = CommandLineToArgvW(GetCommandLineW(), &count);
        if (!raw) return 96;
        const std::vector<std::wstring> args(raw, raw + count);
        LocalFree(raw);
        if (args.size() != 24 || args[1] != L"--device-backend" ||
            (args[2] != L"warp" && args[2] != L"hardware") || args[3] != L"--vs" ||
            args[5] != L"--ps" || args[7] != L"--binding-case" || args[8] != L"resource-interned" ||
            args[9] != L"--report" || args[11] != L"--module" || args[12] != L"beamrt_startup_bootstrap.dll" ||
            args[13] != L"--hold-ms" || args[14] != L"0" || args[15] != L"--exit-code" ||
            args[16] != L"0" || args[17] != L"--") return 96;
        const std::filesystem::path report(args[10]);
        const auto directory = report.parent_path();
        if (!report.is_absolute() || report.filename() != L"fixture-report.bin" ||
            std::filesystem::path(args[4]).filename() != L"binding.vs.cso" ||
            std::filesystem::path(args[6]).filename() != L"binding.ps.cso") return 96;
        const DWORD pid = GetCurrentProcessId();
        const auto identity = std::string("\"token\":\"") + handoffToken +
            "\",\"expectedPid\":" + std::to_string(pid);
        std::string context;
        if (HandoffReadBounded(directory / L"process-context.json", context) != HandoffRead::Complete ||
            context != "{" + identity + "}\n" || !HandoffAbsent(directory / L"driver-ack.json") ||
            !HandoffAbsent(directory / L"owner-stop.json") ||
            !HandoffAbsent(directory / L"fixture-ack-consumed.json")) return 97;

        const int recorded = BeamRTRecordedFixtureMain(instance, previous, command, show);
        if (recorded != 0) return recorded;

        // No retry, fallback, game operation or process lookup. The outer host's
        // retained-child watchdog is independent of this fixture-only deadline.
        const ULONGLONG until = GetTickCount64() + 10000;
        while (GetTickCount64() < until) {
            if (!HandoffAbsent(directory / L"owner-stop.json")) return 98;
            std::string image;
            const auto result = HandoffReadBounded(directory / L"driver-ack.json", image);
            if (result == HandoffRead::Failed) return 99;
            if (result == HandoffRead::Complete) {
                std::string digest;
                if (!HandoffAck(image, pid, digest)) return 99;
                if (!HandoffAbsent(directory / L"owner-stop.json")) return 98;
                const auto consumed = "{" + identity +
                    ",\"kind\":\"fixture_ack_consumed\",\"digest\":\"" + digest + "\"}\n";
                return HandoffWriteNew(directory / L"fixture-ack-consumed.json", consumed) ? 0 : 101;
            }
            Sleep(2);
        }
        return 100;
    } catch (const std::exception& error) {
        std::cerr << "receipt handoff fixture: " << error.what() << '\n';
        return 102;
    }
}
