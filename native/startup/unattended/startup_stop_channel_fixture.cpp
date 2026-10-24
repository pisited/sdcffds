#define BEAMRT_STARTUP_STOP_CHANNEL_FIXTURE
#include "startup_stop_channel.h"
#include <objbase.h>
#include <winioctl.h>

#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <string>

using beamrt::unattended::StartupStopChannel;
using beamrt::unattended::StartupStopChannelReport;

namespace beamrt { namespace unattended {
class StartupStopChannelFixtureAccess final {
public:
    static std::shared_ptr<void> RetainUnclaimedDirectory(const std::wstring& directory, const std::string& token) {
        auto state = std::make_shared<StartupStopChannel::State>();
        state->directory = StartupStopChannel::ValidateDirectory(directory);
        state->token = StartupStopChannel::ValidateToken(token);
        StartupStopChannel::RetainPhysicalDirectory(*state);
        return state;
    }
};
}}

namespace {
unsigned cases = 0, assertions = 0;
const std::string Token = "0123456789abcdef0123456789abcdef";
void Check(bool condition, const char* message) {
    ++assertions;
    if (!condition) throw std::runtime_error(message);
}
template<class Body> void Case(const char* name, Body body) {
    try { body(); ++cases; std::cout << "PASS startup-stop-channel " << name << '\n'; }
    catch (const std::exception& error) { throw std::runtime_error(std::string(name) + ": " + error.what()); }
}
std::wstring FixedFixtureDirectory() {
    wchar_t module[32768]{};
    const DWORD size = GetModuleFileNameW(nullptr, module, 32768);
    Check(size && size < 32768, "fixture path unavailable");
    const std::wstring path(module, size);
    const auto slash = path.find_last_of(L"\\/");
    Check(slash != std::wstring::npos && path.substr(slash + 1) == L"startup_stop_channel_fixture.exe",
        "unexpected fixed fixture runner");
    return path.substr(0, slash);
}
std::wstring FreshDirectory(const std::wstring& parent) {
    GUID guid{};
    Check(SUCCEEDED(CoCreateGuid(&guid)), "fixture GUID unavailable");
    wchar_t text[40]{};
    Check(StringFromGUID2(guid, text, 40) != 0, "fixture GUID formatting failed");
    const auto path = parent + L"\\file-channel-" + text;
    Check(CreateDirectoryW(path.c_str(), nullptr) != FALSE, "new fixture directory unavailable");
    return path;
}
void CreateSentinel(const std::wstring& path, const std::string& value = "unchanged") {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    Check(file != INVALID_HANDLE_VALUE, "new sentinel unavailable");
    DWORD written = 0;
    const bool good = WriteFile(file, value.data(), static_cast<DWORD>(value.size()), &written, nullptr) &&
        written == value.size() && FlushFileBuffers(file);
    CloseHandle(file);
    Check(good, "sentinel write failed");
}
std::string Read(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    Check(file != INVALID_HANDLE_VALUE, "published file not readable");
    char bytes[4097]{};
    DWORD size = 0;
    const bool good = ReadFile(file, bytes, sizeof(bytes), &size, nullptr) && size <= 4096;
    CloseHandle(file);
    Check(good, "published file read failed");
    return std::string(bytes, size);
}
void CrtReadable(const std::wstring& path) {
    FILE* file = nullptr;
    const int opened = _wfopen_s(&file, path.c_str(), L"rb");
    Check(opened == 0 && file, "ordinary CRT reader blocked by retained publication handle");
    Check(std::fgetc(file) == '{', "CRT reader did not see JSON");
    Check(std::fclose(file) == 0, "CRT reader close failed");
}
bool Absent(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES && GetLastError() == ERROR_FILE_NOT_FOUND;
}
template<class Body> void Refused(Body body) {
    bool refused = false;
    try { body(); } catch (const std::exception&) { refused = true; }
    Check(refused, "invalid channel request accepted");
}
StartupStopChannelReport Completed(StartupStopChannel& channel) {
    const auto started = GetTickCount64();
    for (;;) {
        const auto report = channel.Report();
        if (report.publicationCompleted) return report;
        Check(GetTickCount64() - started < 3000, "worker publication did not complete in fixture bound");
        Sleep(1);
    }
}
void Context(StartupStopChannel& channel) {
    const bool published = channel.PublishContext(1234);
    ++assertions;
    if (!published) throw std::runtime_error("context refused with Win32 error " + std::to_string(channel.Report().contextError));
}
void DenyRewrite(const std::wstring& path) {
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    const DWORD error = handle == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    Check(error == ERROR_SHARING_VIOLATION, "published file allowed rewrite while owned channel remained alive");
}
void MakeJunction(const std::wstring& link, const std::wstring& target) {
    struct MountPointBuffer {
        ULONG tag;
        USHORT length, reserved, substituteOffset, substituteLength, printOffset, printLength;
        wchar_t path[2048];
    } buffer{};
    const auto substitute = std::wstring(L"\\??\\") + target;
    const auto substituteBytes = substitute.size() * sizeof(wchar_t);
    const auto printBytes = target.size() * sizeof(wchar_t);
    Check(substituteBytes + printBytes + 2 * sizeof(wchar_t) <= sizeof(buffer.path), "junction fixture path too long");
    buffer.tag = IO_REPARSE_TAG_MOUNT_POINT;
    buffer.substituteLength = static_cast<USHORT>(substituteBytes);
    buffer.printOffset = static_cast<USHORT>(substituteBytes + sizeof(wchar_t));
    buffer.printLength = static_cast<USHORT>(printBytes);
    buffer.length = static_cast<USHORT>(8 + substituteBytes + printBytes + 2 * sizeof(wchar_t));
    std::memcpy(buffer.path, substitute.c_str(), substituteBytes + sizeof(wchar_t));
    std::memcpy(reinterpret_cast<unsigned char*>(buffer.path) + buffer.printOffset,
        target.c_str(), printBytes + sizeof(wchar_t));
    HANDLE handle = CreateFileW(link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    Check(handle != INVALID_HANDLE_VALUE, "junction fixture directory could not be opened");
    DWORD returned = 0;
    const bool good = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, &buffer, buffer.length + 8,
        nullptr, 0, &returned, nullptr) != FALSE;
    const DWORD error = good ? ERROR_SUCCESS : GetLastError();
    CloseHandle(handle);
    if (!good) throw std::runtime_error("junction fixture creation failed with Win32 error " + std::to_string(error));
}
}

int main(int count, char**) {
    try {
        Check(count == 1, "fixture accepts no arbitrary command-line paths");
        const auto parent = FixedFixtureDirectory();
        Case("empty-preclaim-run-and-ancestor-retained-against-rename", [&] {
            const auto ancestor = FreshDirectory(parent);
            const auto directory = ancestor + L"\\empty-run";
            Check(CreateDirectoryW(directory.c_str(), nullptr) != FALSE, "empty preclaim run directory unavailable");
            const auto movedRun = directory + L"-moved";
            const auto movedAncestor = ancestor + L"-moved";
            auto lease = beamrt::unattended::StartupStopChannelFixtureAccess::RetainUnclaimedDirectory(directory, Token);
            Check(Absent(directory + L"\\host-claim.json") && Absent(ancestor + L"\\host-claim.json"),
                "preclaim fixture unexpectedly created a host claim");
            const bool runMoved = MoveFileExW(directory.c_str(), movedRun.c_str(), 0) != FALSE;
            const DWORD runError = runMoved ? ERROR_SUCCESS : GetLastError();
            Check(!runMoved && (runError == ERROR_SHARING_VIOLATION || runError == ERROR_ACCESS_DENIED) &&
                GetFileAttributesW(directory.c_str()) != INVALID_FILE_ATTRIBUTES && Absent(movedRun),
                "retained empty preclaim run directory could be renamed");
            const bool ancestorMoved = MoveFileExW(ancestor.c_str(), movedAncestor.c_str(), 0) != FALSE;
            const DWORD ancestorError = ancestorMoved ? ERROR_SUCCESS : GetLastError();
            Check(!ancestorMoved && (ancestorError == ERROR_SHARING_VIOLATION || ancestorError == ERROR_ACCESS_DENIED) &&
                GetFileAttributesW(ancestor.c_str()) != INVALID_FILE_ATTRIBUTES && Absent(movedAncestor),
                "retained preclaim ancestor could be renamed");
            Check(Absent(directory + L"\\host-claim.json") && Absent(ancestor + L"\\host-claim.json"),
                "rename probes created a host claim");
            lease.reset();
            // Exact fixture-owned paths only. Restore both original names and
            // retain the empty directories as evidence rather than deleting them.
            Check(MoveFileExW(directory.c_str(), movedRun.c_str(), 0) != FALSE,
                "released empty run directory remained rename-locked");
            Check(Absent(directory) && GetFileAttributesW(movedRun.c_str()) != INVALID_FILE_ATTRIBUTES,
                "released run-directory rename was not observable");
            Check(MoveFileExW(movedRun.c_str(), directory.c_str(), 0) != FALSE,
                "released run directory could not be restored");
            Check(MoveFileExW(ancestor.c_str(), movedAncestor.c_str(), 0) != FALSE,
                "released ancestor remained rename-locked");
            Check(Absent(ancestor) && GetFileAttributesW(movedAncestor.c_str()) != INVALID_FILE_ATTRIBUTES,
                "released ancestor rename was not observable");
            Check(MoveFileExW(movedAncestor.c_str(), ancestor.c_str(), 0) != FALSE,
                "released ancestor could not be restored");
            Check(GetFileAttributesW(directory.c_str()) != INVALID_FILE_ATTRIBUTES &&
                Absent(directory + L"\\host-claim.json") && Absent(ancestor + L"\\host-claim.json"),
                "restored preclaim fixture lost its empty directory or gained a host claim");
        });
        Case("fresh-context-and-asynchronous-stop", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            Check(Absent(directory + L"\\process-context.json") && !channel->Report().contextPublished,
                "create published a PID before the exact-owned factory supplied one");
            Check(!channel->RequestNormal(1234), "stop accepted before context");
            Check(!channel->PublishContext(0), "zero PID accepted");
            Check(channel->PublishContext(1234), "fresh context refused");
            Check(Read(directory + L"\\process-context.json") ==
                "{\"token\":\"" + Token + "\",\"expectedPid\":1234}\n", "context schema mismatch");
            Check(Read(directory + L"\\launch-approval.json") == "{\"token\":\"" + Token +
                "\",\"scope\":\"beamrt-unattended-observation-v1\",\"allow\":true}\n", "configuration schema mismatch");
            CrtReadable(directory + L"\\process-context.json");
            CrtReadable(directory + L"\\launch-approval.json");
            Check(!channel->PublishContext(5678), "PID context was reusable");
            Check(!channel->RequestNormal(5678) && Absent(directory + L"\\owner-stop.json"), "foreign PID changed stop channel");
            Check(channel->RequestNormal(1234), "owned normal request was not enqueued");
            Check(!channel->RequestNormal(1234), "normal request was retried");
            const auto report = Completed(*channel);
            if (!report.publicationSucceeded) throw std::runtime_error("stop publication refused with Win32 error " +
                std::to_string(report.publicationError));
            Check(report.contextPublished && report.expectedPid == 1234 && report.requestAccepted && report.workerStarted &&
                report.publicationSucceeded && report.publicationError == ERROR_SUCCESS, "publication status incomplete");
            Check(report.workerStartedAtMilliseconds >= report.requestedAtMilliseconds &&
                report.completedAtMilliseconds >= report.workerStartedAtMilliseconds, "publication timestamps unordered");
            Check(Read(directory + L"\\owner-stop.json") == "{\"token\":\"" + Token +
                "\",\"expectedPid\":1234,\"kind\":\"normal_quit_requested\"}\n", "stop schema mismatch");
            CrtReadable(directory + L"\\owner-stop.json");
            Check(Absent(directory + L"\\owner-stop.json.pending") && Absent(directory + L"\\process-context.json.pending") &&
                Absent(directory + L"\\launch-approval.json.pending"), "successful rename left a pending file");
            DenyRewrite(directory + L"\\owner-stop.json");
            DenyRewrite(directory + L"\\process-context.json");
            DenyRewrite(directory + L"\\launch-approval.json");
        });
        Case("atomic-host-claim-refuses-second-owner", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            const auto claim = Read(directory + L"\\host-claim.json");
            Refused([&] { StartupStopChannel::Create(directory, Token); });
            Check(Read(directory + L"\\host-claim.json") == claim, "second owner replaced host claim");
        });
        Case("every-known-runtime-output-refused", [&] {
            for (const auto* leaf : {L"host-claim.json", L"process-context.json", L"launch-approval.json", L"started.json",
                    L"driver-ack.json", L"unattended-events.jsonl", L"owner-stop.json", L"owned-exit.json", L"receipt-ready.json"}) {
                for (const bool pending : {false, true}) {
                    const auto directory = FreshDirectory(parent);
                    const auto path = directory + L"\\" + leaf + (pending ? L".pending" : L"");
                    CreateSentinel(path);
                    Refused([&] { StartupStopChannel::Create(directory, Token); });
                    Check(Read(path) == "unchanged", "old runtime output was changed");
                    Check(leaf == std::wstring(L"host-claim.json") && !pending || Absent(directory + L"\\host-claim.json"),
                        "failed preflight consumed a new claim");
                }
            }
        });
        Case("token-validation-before-claim", [&] {
            for (const auto& token : {std::string(), std::string(32, 'A'), std::string(31, '0'), std::string(32, 'g')}) {
                const auto directory = FreshDirectory(parent);
                Refused([&] { StartupStopChannel::Create(directory, token); });
                Check(Absent(directory + L"\\host-claim.json"), "bad token consumed host claim");
            }
        });
        Case("nonphysical-and-noncanonical-paths-refused", [&] {
            const auto directory = FreshDirectory(parent);
            for (const auto& path : {std::wstring(L"relative"), std::wstring(L"\\\\server\\share\\run"),
                    std::wstring(L"C:\\"), directory + L"\\..", directory + L"\\.", directory + L"\\NUL",
                    directory + L"\\CON.txt", directory + L":stream", directory + L" ", directory + L"\\\\"})
                Refused([&] { StartupStopChannel::Create(path, Token); });
            Check(Absent(directory + L"\\host-claim.json"), "invalid path created a claim");
        });
        Case("directory-components-retained-against-rename", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            const bool moved = MoveFileExW(directory.c_str(), (directory + L"-moved").c_str(), 0) != FALSE;
            const DWORD error = moved ? ERROR_SUCCESS : GetLastError();
            Check(!moved && (error == ERROR_SHARING_VIOLATION || error == ERROR_ACCESS_DENIED) &&
                GetFileAttributesW(directory.c_str()) != INVALID_FILE_ATTRIBUTES && Absent(directory + L"-moved"),
                "retained run directory could be renamed");
        });
        Case("actual-reparse-directory-refused", [&] {
            const auto target = FreshDirectory(parent);
            const auto link = FreshDirectory(parent);
            MakeJunction(link, target);
            Check((GetFileAttributesW(link.c_str()) & FILE_ATTRIBUTE_REPARSE_POINT) != 0,
                "junction fixture is not a reparse point");
            Refused([&] { StartupStopChannel::Create(link, Token); });
            Check(Absent(target + L"\\host-claim.json"), "reparse-path attempt wrote through to target");
        });
        Case("context-publication-race-consumes-attempt", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            CreateSentinel(directory + L"\\process-context.json");
            Check(!channel->PublishContext(1234), "context publication overwrote a raced destination");
            Check(channel->Report().contextAttempted && !channel->Report().contextPublished &&
                channel->Report().contextError != ERROR_SUCCESS, "context failure status missing");
            Check(!channel->PublishContext(1234) && !channel->RequestNormal(1234), "failed context was reusable");
            Check(Read(directory + L"\\process-context.json") == "unchanged", "raced destination changed");
            Check(Absent(directory + L"\\launch-approval.json"), "approval published after refused PID context");
        });
        Case("partial-context-refuses-resume-and-stop", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            CreateSentinel(directory + L"\\launch-approval.json");
            Check(!channel->PublishContext(1234) && !channel->Report().contextPublished,
                "partial context was classified ready");
            Check(!channel->RequestNormal(1234), "partial context accepted normal request");
            Check(Read(directory + L"\\launch-approval.json") == "unchanged", "partial setup replaced configuration");
        });
        Case("asynchronous-stop-destination-race-refused", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            Context(*channel);
            CreateSentinel(directory + L"\\owner-stop.json");
            Check(channel->RequestNormal(1234), "request queue rejected before worker attempted output");
            const auto report = Completed(*channel);
            Check(report.requestAccepted && report.publicationCompleted && !report.publicationSucceeded &&
                report.publicationError != ERROR_SUCCESS, "queue acceptance substituted for successful publication");
            Check(Read(directory + L"\\owner-stop.json") == "unchanged", "worker overwrote raced stop output");
        });
        Case("asynchronous-stop-pending-race-refused", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            Context(*channel);
            CreateSentinel(directory + L"\\owner-stop.json.pending");
            Check(channel->RequestNormal(1234), "request queue rejected before worker attempted pending output");
            const auto report = Completed(*channel);
            Check(report.requestAccepted && !report.publicationSucceeded && report.publicationError != ERROR_SUCCESS,
                "pending-file refusal not reported");
            Check(Absent(directory + L"\\owner-stop.json") && Read(directory + L"\\owner-stop.json.pending") == "unchanged",
                "worker changed an existing pending file");
        });
        Case("receipt-ready-requires-owned-context-and-exact-pid", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            Check(!channel->PublishReceiptReady(1234) && !channel->PublishReceiptReady(0),
                "receipt rendezvous accepted before owned context");
            Check(Absent(directory + L"\\receipt-ready.json") && Absent(directory + L"\\receipt-ready.json.pending"),
                "unclaimed rendezvous wrote runtime output");
            Context(*channel);
            Check(!channel->PublishReceiptReady(0) && !channel->PublishReceiptReady(5678),
                "zero or foreign PID published a receipt rendezvous");
            Check(Absent(directory + L"\\receipt-ready.json") && Absent(directory + L"\\receipt-ready.json.pending"),
                "wrong PID changed rendezvous output");
            Check(channel->PublishReceiptReady(1234), "exact owned PID rendezvous refused after invalid PID attempts");
            const auto expected = std::string("{\"token\":\"") + Token +
                "\",\"expectedPid\":1234,\"kind\":\"cpu_receipt_ready\",\"resourceABI\":7,\"drawABI\":5,"
                "\"profile\":2,\"mode\":1,\"cbvProbeBytes\":0,\"record\":\"recorded-draw.bin\"}\n";
            Check(Read(directory + L"\\receipt-ready.json") == expected, "receipt rendezvous exact schema mismatch");
            CrtReadable(directory + L"\\receipt-ready.json");
            Check(Absent(directory + L"\\receipt-ready.json.pending"), "receipt rendezvous left successful pending output");
            Check(!channel->PublishReceiptReady(1234) && !channel->PublishReceiptReady(5678),
                "receipt rendezvous was reused");
            Check(Read(directory + L"\\receipt-ready.json") == expected, "duplicate changed published rendezvous");
            DenyRewrite(directory + L"\\receipt-ready.json");
            Check(!channel->Report().requestAccepted && Absent(directory + L"\\owner-stop.json"),
                "receipt rendezvous unexpectedly requested shutdown");
        });
        Case("receipt-ready-destination-race-is-preserved-and-one-shot", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            Context(*channel);
            CreateSentinel(directory + L"\\receipt-ready.json");
            Check(!channel->PublishReceiptReady(1234), "receipt rendezvous overwrote raced destination");
            Check(Read(directory + L"\\receipt-ready.json") == "unchanged", "receipt rendezvous changed raced destination");
            Check(!channel->PublishReceiptReady(1234), "raced receipt rendezvous was retried");
            Check(Read(directory + L"\\receipt-ready.json") == "unchanged", "repeated rendezvous changed destination");
        });
        Case("receipt-ready-pending-race-is-preserved-and-one-shot", [&] {
            const auto directory = FreshDirectory(parent);
            auto channel = StartupStopChannel::Create(directory, Token);
            Context(*channel);
            CreateSentinel(directory + L"\\receipt-ready.json.pending");
            Check(!channel->PublishReceiptReady(1234), "receipt rendezvous overwrote raced pending output");
            Check(Absent(directory + L"\\receipt-ready.json") &&
                Read(directory + L"\\receipt-ready.json.pending") == "unchanged", "rendezvous changed raced pending output");
            Check(!channel->PublishReceiptReady(1234), "pending-file receipt rendezvous was retried");
            Check(Read(directory + L"\\receipt-ready.json.pending") == "unchanged", "repeated rendezvous changed pending output");
        });
        Case("destruction-without-request-does-not-publish-stop", [&] {
            const auto directory = FreshDirectory(parent);
            {
                auto channel = StartupStopChannel::Create(directory, Token);
                Context(*channel);
            }
            Sleep(20);
            Check(Absent(directory + L"\\owner-stop.json"), "channel destruction issued an unrequested quit");
            Check(Absent(directory + L"\\receipt-ready.json"), "channel destruction published an unrequested receipt rendezvous");
        });
        std::cout << "PASS startup-stop-channel file cases=" << cases << " assertions=" << assertions
            << "; no process, game, startup host or DLL was launched; fixture files retained.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL startup-stop-channel: " << error.what() << '\n';
        return 1;
    }
}
