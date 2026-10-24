#include "../startup_contract.h"
#include <bcrypt.h>

#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
namespace {
unsigned cases = 0, assertions = 0;
constexpr DWORD forcedExit = 0x42525446U;
constexpr wchar_t token[] = L"0123456789abcdef0123456789abcdef";
void Require(bool condition, const char* message) {
    ++assertions;
    if (!condition) throw std::runtime_error(message);
}
void Win(BOOL condition, const char* message) {
    Require(condition != FALSE, (std::string(message) + " Win32=" + std::to_string(GetLastError())).c_str());
}
struct Handle {
    HANDLE value = nullptr;
    explicit Handle(HANDLE handle = nullptr) : value(handle) {}
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
};
std::wstring Quote(const std::wstring& text) {
    std::wstring out = L"\"";
    std::size_t slashes = 0;
    for (const wchar_t c : text) {
        if (c == L'\\') { ++slashes; continue; }
        out.append(c == L'\"' ? slashes * 2 + 1 : slashes, L'\\'); out += c; slashes = 0;
    }
    out.append(slashes * 2, L'\\'); return out + L'\"';
}
std::string Ascii(const std::wstring& text) {
    std::string out;
    for (const wchar_t character : text) {
        Require(character > 0 && character < 128, "fixture label must be ASCII");
        out += static_cast<char>(character);
    }
    return out;
}
std::string Read(const fs::path& path) {
    const auto normal = fs::absolute(path).lexically_normal().wstring();
    const auto physical = normal.rfind(L"\\\\?\\", 0) == 0 ? normal : std::wstring(L"\\\\?\\") + normal;
    Handle file(CreateFileW(physical.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    Require(file.value != INVALID_HANDLE_VALUE, "fixture evidence missing");
    LARGE_INTEGER size{};Win(GetFileSizeEx(file.value, &size), "fixture evidence size");
    Require(size.QuadPart >= 0 && size.QuadPart < 65536, "fixture evidence exceeds bound");
    std::string out(static_cast<std::size_t>(size.QuadPart), '\0');
    DWORD read = 0;
    Win(ReadFile(file.value, out.data(), static_cast<DWORD>(out.size()), &read, nullptr), "fixture evidence read");
    Require(read == out.size(), "fixture evidence unreadable"); return out;
}
void WriteNew(const fs::path& path, const std::string& text) {
    const auto normal = fs::absolute(path).lexically_normal().wstring();
    const auto physical = normal.rfind(L"\\\\?\\", 0) == 0 ? normal : std::wstring(L"\\\\?\\") + normal;
    Handle file(CreateFileW(physical.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    Require(file.value != INVALID_HANDLE_VALUE, "fixture evidence already exists");
    DWORD written = 0; Win(WriteFile(file.value, text.data(), static_cast<DWORD>(text.size()), &written, nullptr), "fixture evidence write");
    Require(written == text.size(), "fixture evidence incomplete");
}
bool Exists(const fs::path& path) {
    const auto physical = std::wstring(L"\\\\?\\") + fs::absolute(path).lexically_normal().wstring();
    if (GetFileAttributesW(physical.c_str()) != INVALID_FILE_ATTRIBUTES) return true;
    const DWORD error = GetLastError();
    Require(error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND, "fixture existence could not be checked");
    return false;
}
std::wstring Hash(const fs::path& path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    Require(bool(file), "fixture input unavailable"); const auto length = file.tellg();
    Require(length > 0 && length <= 16 * 1024 * 1024, "fixture input hash budget exceeded");
    std::vector<unsigned char> bytes(static_cast<std::size_t>(length)); file.seekg(0);
    file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    Require(bool(file), "fixture input hash read failed");
    BCRYPT_ALG_HANDLE algorithm = nullptr; unsigned char digest[32]{};
    Require(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0, "fixture hash algorithm");
    const auto status = BCryptHash(algorithm, nullptr, 0, bytes.data(), static_cast<ULONG>(bytes.size()), digest, sizeof(digest));
    BCryptCloseAlgorithmProvider(algorithm, 0); Require(status >= 0, "fixture hashing failed");
    std::wstring out; constexpr wchar_t hex[] = L"0123456789abcdef";
    for (const auto byte : digest) { out += hex[byte >> 4]; out += hex[byte & 15]; }
    return out;
}
// Evidence emitted by our fixed reviewed host, not a production JSON parser.
std::size_t Field(const std::string& json, const char* key) {
    const auto needle = std::string("\"") + key + "\":";
    const auto at = json.find(needle); Require(at != std::string::npos, "owned report field missing");
    Require(json.find(needle, at + needle.size()) == std::string::npos, "duplicate owned report field");
    return at + needle.size();
}
unsigned long long Number(const std::string& json, const char* key) {
    auto at = Field(json, key); const auto first = at;
    while (at < json.size() && json[at] >= '0' && json[at] <= '9') ++at;
    Require(at > first && at < json.size() && (json[at] == ',' || json[at] == '}'), "owned report number invalid");
    return std::stoull(json.substr(first, at - first));
}
bool Flag(const std::string& json, const char* key) {
    const auto at = Field(json, key);
    if (json.compare(at, 5, "false") == 0) return false;
    Require(json.compare(at, 4, "true") == 0, "owned report boolean invalid"); return true;
}
fs::path FixedRoot() {
    wchar_t path[32768]{}; const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
    Require(length && length < 32768, "fixture module path unavailable");
    const fs::path self(std::wstring(path, length));
    Require(self.filename() == L"startup_owned_fixture.exe", "unexpected harness executable name");
    const auto root = self.parent_path();
    for (const wchar_t* leaf : {L"beamrt_startup_host.exe", L"beamrt_startup_fault_host.exe", L"beamrt_startup_fixture.exe",
             L"beamrt_startup_bootstrap.dll", L"beamrt_startup_no_receipt.dll"})
        Require(fs::is_regular_file(root / leaf), "fixed sibling fixture input unavailable");
    return root;
}
struct Test {
    const char* name;
    const wchar_t* mode = L"cooperative";
    bool noReceipt = false, faultHost = false, owned = true, launch = true;
    std::wstring fault;
    DWORD expectedHostExit = 0;
    unsigned expectedProcesses = 2;
    bool expectResume = true, expectForce = false;
    int expectNormal = 1;
    bool expectEntry = true;
    bool existingContext = false;
    DWORD expectedChildExit = 0;
    std::function<void(std::vector<std::wstring>&, const fs::path&)> change;
};
std::vector<std::wstring> Owned(const fs::path& directory) {
    return {L"--owned-run-directory", directory.wstring(), L"--owned-run-token", token,
        L"--owned-overall-seconds", L"2", L"--owned-normal-grace-seconds", L"1",
        L"--acknowledge-owned-force-close", L"exact-created-child-after-normal-quit"};
}
void RemoveFlag(std::vector<std::wstring>& args, const std::wstring& flag) {
    for (auto i = args.begin(); i != args.end(); ++i) if (*i == flag) {
        Require(i + 1 != args.end(), "fixture flag value missing"); args.erase(i, i + 2); return;
    }
    Require(false, "fixture flag not found");
}
void SetFlag(std::vector<std::wstring>& args, const std::wstring& flag, const std::wstring& value) {
    for (auto i = args.begin(); i != args.end(); ++i) if (*i == flag) { *(i + 1) = value; return; }
    Require(false, "fixture flag not found");
}
void Run(const fs::path& root, const fs::path& evidence, const Test& test) {
    const auto directory = evidence / test.name;
    const auto physicalDirectory = std::wstring(L"\\\\?\\") + fs::absolute(directory).lexically_normal().wstring();
    Require(CreateDirectoryW(physicalDirectory.c_str(), nullptr) != FALSE, "fresh case directory unavailable");
    const auto host = root / (test.faultHost ? L"beamrt_startup_fault_host.exe" : L"beamrt_startup_host.exe");
    const auto child = root / L"beamrt_startup_fixture.exe";
    const auto dll = root / (test.noReceipt ? L"beamrt_startup_no_receipt.dll" : L"beamrt_startup_bootstrap.dll");
    std::vector<std::wstring> args = {test.launch ? L"--launch-reviewed" : L"--review", L"--target", child.wstring(),
        L"--dll", dll.wstring(), L"--workdir", directory.wstring(), L"--expected-target-sha256", Hash(child),
        L"--expected-dll-sha256", Hash(dll), L"--acknowledge-native-insertion", L"startup-observation-only"};
    if (test.owned) { const auto owned = Owned(directory); args.insert(args.end(), owned.begin(), owned.end()); }
    if (test.change) test.change(args, directory);
    args.push_back(L"--");
    if (!test.fault.empty()) { args.push_back(L"--fixture-host-fault"); args.push_back(test.fault); }
    args.insert(args.end(), {L"--owned-fixture-mode", test.mode, L"--owned-fixture-run-dir", directory.wstring(),
        L"--owned-fixture-token", token, L"--owned-fixture-module", dll.filename().wstring(),
        L"--owned-fixture-report", (directory / L"entered.json").wstring()});
    auto command = Quote(host.wstring()); for (const auto& arg : args) command += L" " + Quote(arg);
    std::vector<wchar_t> mutableCommand(command.begin(), command.end()); mutableCommand.push_back(0);
    WriteNew(directory / L"command.utf16", std::string(reinterpret_cast<const char*>(command.data()), command.size() * sizeof(wchar_t)));
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    const auto physicalLog = physicalDirectory + L"\\host.log";
    Handle output(CreateFileW(physicalLog.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    Handle input(CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr));
    Require(output.value != INVALID_HANDLE_VALUE && input.value != INVALID_HANDLE_VALUE, "fixture log handles unavailable");
    SIZE_T attributeBytes = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
    std::vector<unsigned char> attributeStorage(attributeBytes);
    auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributeStorage.data());
    Win(InitializeProcThreadAttributeList(attributes, 1, 0, &attributeBytes), "fixture attribute list");
    struct AttributeCleanup { LPPROC_THREAD_ATTRIBUTE_LIST value; ~AttributeCleanup() { DeleteProcThreadAttributeList(value); } } cleanup{attributes};
    HANDLE handles[]{output.value, input.value};
    Win(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr), "fixture restricted inheritance");
    Handle job(CreateJobObjectW(nullptr, nullptr)); Require(job.value != nullptr, "private fixture job unavailable");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    Win(SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)), "fixture-only emergency job scope");
    STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.StartupInfo.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
    startup.StartupInfo.wShowWindow = SW_HIDE; startup.StartupInfo.hStdOutput = output.value; startup.StartupInfo.hStdError = output.value;
    startup.StartupInfo.hStdInput = input.value; startup.lpAttributeList = attributes; PROCESS_INFORMATION created{};
    Win(CreateProcessW(host.c_str(), mutableCommand.data(), nullptr, nullptr, TRUE, CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
        nullptr, root.c_str(), &startup.StartupInfo, &created), "fixture host creation");
    Handle process(created.hProcess), thread(created.hThread);
    if (!AssignProcessToJobObject(job.value, created.hProcess)) {
        const DWORD error = GetLastError(); TerminateProcess(created.hProcess, 70); WaitForSingleObject(created.hProcess, 5000);
        SetLastError(error); Win(FALSE, "fixture host private job assignment");
    }
    const auto start = GetTickCount64(); Require(ResumeThread(thread.value) == 1, "fixture host resume failed");
    Require(WaitForSingleObject(process.value, 20000) == WAIT_OBJECT_0, "fixture host exceeded disposable wait bound");
    const auto elapsed = GetTickCount64() - start;
    DWORD hostExit = 0; Win(GetExitCodeProcess(process.value, &hostExit), "fixture host exit query");
    WriteNew(directory / L"host-exit.txt", std::to_string(hostExit) + "\nelapsedMilliseconds=" + std::to_string(elapsed) + "\n");
    Win(FlushFileBuffers(output.value), "fixture host log flush");
    if (hostExit != test.expectedHostExit) std::cerr << Read(directory / L"host.log");
    Require(hostExit == test.expectedHostExit, "unexpected startup host result");
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting{};
    const auto drain = GetTickCount64() + 3000;
    do {
        Win(QueryInformationJobObject(job.value, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), nullptr), "fixture job accounting");
        if (accounting.ActiveProcesses) Sleep(2);
    } while (accounting.ActiveProcesses && GetTickCount64() < drain);
    Require(accounting.TotalProcesses == test.expectedProcesses, "unexpected child creation count");
    Require(accounting.ActiveProcesses == 0, "owned disposable child still active when host returned");
    if (test.expectedProcesses == 1) {
        Require(!Exists(directory / L"entered.json"), "refused/review case executed child");
        Require(!Exists(directory / L"owned-exit.json"), "no-child case wrote exit proof");
        Require(Exists(directory / L"process-context.json") == test.existingContext, "no-child case changed process context presence");
        if (test.existingContext) Require(Read(directory / L"process-context.json") == "preserve existing context\n", "existing context overwritten");
    } else {
        const auto report = Read(directory / L"owned-exit.json");
        Require(report.find("\"token\":\"0123456789abcdef0123456789abcdef\"") != std::string::npos, "owned exit token mismatch");
        Require(Flag(report, "processExitVerified"), "host did not prove signaled child exit");
        Require(Flag(report, "resumeAttempted") == test.expectResume && Flag(report, "resumed") == test.expectResume, "resume semantics mismatch");
        if (test.expectNormal >= 0) Require(Flag(report, "normalRequested") == (test.expectNormal != 0), "normal request semantics mismatch");
        Require(Flag(report, "forceAttempted") == test.expectForce, "force semantics mismatch");
        Require(Number(report, "exitCode") == test.expectedChildExit, "actual child exit code mismatch");
        Require(Number(report, "expectedPid") > 0 && Number(report, "observationError") == 0, "owned process identity/status invalid");
        Require(Exists(directory / L"entered.json") == test.expectEntry, "application execution marker mismatch");
        if (test.expectEntry) {
            const auto entered = Read(directory / L"entered.json");
            Require(Number(entered, "expectedPid") == Number(report, "expectedPid") && Flag(entered, "startupQueryValid"), "receipt/context did not join actual application");
        }
        if (test.expectForce) {
            Require(Flag(report, "forceCallSucceeded"), "owned force call failed");
            Require(Number(report, "forceAttemptMilliseconds") >= Number(report, "normalRequestMilliseconds") + 1000, "force skipped full grace");
        }
        if (!test.expectResume) Require(Flag(report, "neverExecutedCleanupAttempted") && Flag(report, "neverExecutedCleanupCallSucceeded"), "suspended cleanup evidence missing");
        if (std::wstring(test.mode) == L"cooperative" && test.expectResume) Require(Exists(directory / L"entered.json.normal"), "normal-stop file was not consumed");
        if (test.noReceipt) {
            Require(elapsed < 8000, "main startup receipt wait defeated independent owner deadline");
            Require(Number(report, "normalRequestMilliseconds") >= 2000, "overall deadline started late or fired early");
        }
    }
    ++cases; std::cout << "PASS startup-owned " << test.name << '\n';
}
}

int main(int count, char**) {
    try {
        Require(count == 1, "fixture accepts no arbitrary target or arguments");
        const auto root = FixedRoot();
        // Keep disposable target-side evidence below the legacy CRT path limit;
        // the bootstrap DLL itself also retains Detours' MAX_PATH name bound.
        const auto evidence = root / (L"t-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64() % 100000));
        Require(fs::create_directory(evidence), "fresh fixture evidence root unavailable");
        std::cout << "Startup-owned disposable evidence: " << evidence.string() << '\n';
        Test normal{"normal-stop"}; Run(root, evidence, normal);
        Test hung{"ignored-normal-stop"}; hung.mode = L"ignore"; hung.expectedHostExit = 15; hung.expectForce = true; hung.expectedChildExit = forcedExit; Run(root, evidence, hung);
        Test blocked{"watcher-across-main-receipt-wait"}; blocked.mode = L"ignore"; blocked.noReceipt = true; blocked.expectedHostExit = 2; blocked.expectForce = true; blocked.expectedChildExit = forcedExit; Run(root, evidence, blocked);
        for (const wchar_t* stage : {L"before-insert", L"before-payload", L"before-resume"}) {
            const std::wstring wide(stage); const auto name = Ascii(wide);
            Test failed{name.c_str()}; failed.faultHost = true; failed.fault = stage; failed.expectedHostExit = 1;
            failed.expectResume = false; failed.expectNormal = false; failed.expectEntry = false; failed.expectedChildExit = forcedExit;
            Run(root, evidence, failed);
        }
        Test late{"after-resume-exception-normal"}; late.faultHost = true; late.fault = L"after-resume"; late.expectedHostExit = 1; Run(root, evidence, late);
        Test lateHung{"after-resume-exception-force"}; lateHung.faultHost = true; lateHung.fault = L"after-resume"; lateHung.mode = L"ignore";
        lateHung.expectedHostExit = 1; lateHung.expectForce = true; lateHung.expectedChildExit = forcedExit; Run(root, evidence, lateHung);
        Test nonzero{"nonzero-child-exit"}; nonzero.mode = L"exit17"; nonzero.expectedHostExit = 16; nonzero.expectedChildExit = 17; nonzero.expectNormal = -1;
        // The process may exit between the receipt and explicit owner finish;
        // normalRequested is allowed either way and inspected separately below.
        Run(root, evidence, nonzero);
        Test review{"owned-review-no-child"}; review.launch = false; review.expectedProcesses = 1; Run(root, evidence, review);
        Test manual{"manual-review-unchanged"}; manual.launch = false; manual.owned = false; manual.expectedProcesses = 1; Run(root, evidence, manual);
        for (const wchar_t* flag : {L"--owned-run-directory", L"--owned-run-token", L"--owned-overall-seconds", L"--owned-normal-grace-seconds", L"--acknowledge-owned-force-close"}) {
            const std::wstring wide(flag + 2); const std::string name = "missing-" + Ascii(wide);
            Test missing{name.c_str()}; missing.expectedHostExit = 1; missing.expectedProcesses = 1;
            missing.change = [flag](std::vector<std::wstring>& args, const fs::path&) { RemoveFlag(args, flag); };
            Run(root, evidence, missing);
        }
        struct Refusal { const char* name; const wchar_t* flag; const wchar_t* value; };
        for (const Refusal& refusal : {Refusal{"wrong-force-approval", L"--acknowledge-owned-force-close", L"yes"},
                 Refusal{"uppercase-token", L"--owned-run-token", L"0123456789ABCDEF0123456789abcdef"},
                 Refusal{"short-token", L"--owned-run-token", L"0123"}, Refusal{"zero-overall", L"--owned-overall-seconds", L"0"},
                 Refusal{"long-overall", L"--owned-overall-seconds", L"481"}, Refusal{"zero-grace", L"--owned-normal-grace-seconds", L"0"},
                 Refusal{"long-grace", L"--owned-normal-grace-seconds", L"31"}, Refusal{"wrong-reviewed-hash", L"--expected-target-sha256", L"0000000000000000000000000000000000000000000000000000000000000000"}}) {
            Test refused{refusal.name}; refused.expectedHostExit = 1; refused.expectedProcesses = 1;
            refused.change = [refusal](std::vector<std::wstring>& args, const fs::path&) { SetFlag(args, refusal.flag, refusal.value); };
            Run(root, evidence, refused);
        }
        Test duplicate{"duplicate-owned-option"}; duplicate.expectedHostExit = 1; duplicate.expectedProcesses = 1;
        duplicate.change = [](std::vector<std::wstring>& args, const fs::path&) { args.insert(args.end(), {L"--owned-run-token", token}); }; Run(root, evidence, duplicate);
        Test stale{"stale-process-context"}; stale.expectedHostExit = 1; stale.expectedProcesses = 1; stale.existingContext = true;
        stale.change = [](std::vector<std::wstring>&, const fs::path& directory) { WriteNew(directory / L"process-context.json", "preserve existing context\n"); };
        Run(root, evidence, stale);
        const std::string longName(150, 'x');
        Test longPath{longName.c_str()};
        longPath.change = [root](std::vector<std::wstring>& args, const fs::path& directory) {
            Require((directory / L"owned-exit.json").wstring().size() > MAX_PATH, "long-path case is not actually long");
            SetFlag(args, L"--workdir", root.wstring());
        };
        Run(root, evidence, longPath);
        std::cout << "PASS startup-owned fixture: " << cases << " cases, " << assertions
                  << " assertions. Fixed disposable siblings only; no BeamNG launch.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL startup-owned fixture: " << error.what() << '\n'; return 1;
    }
}
