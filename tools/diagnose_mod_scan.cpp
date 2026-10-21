// Read-only reproduction of a recursive unpacked-mod directory scan.
// No files are created, removed, opened for writing, or moved by this program.
#include <filesystem>
#include <iostream>
#include <string>
#include <system_error>

int wmain(int argc, wchar_t* argv[]) {
    namespace fs = std::filesystem;
    if (argc < 2 || argc > 3 ||
        (argc == 3 && std::wstring(argv[2]) != L"--skip-validation")) {
        std::wcerr << L"Usage: diagnose_mod_scan ROOT [--skip-validation]\n";
        return 2;
    }
    const fs::path root(argv[1]);
    const bool skipValidation = argc == 3;
    std::error_code error;
    fs::recursive_directory_iterator entry(root, fs::directory_options::none, error);
    const fs::recursive_directory_iterator end;
    if (error) {
        std::wcerr << L"FAIL opening root=" << root.native()
                   << L" code=" << error.value() << L"\n";
        std::cerr << "message=" << error.message() << '\n';
        return 1;
    }
    std::size_t count = 0;
    std::size_t skipped = 0;
    while (entry != end) {
        const fs::path lastPath = entry->path();
        const int lastDepth = entry.depth();
        ++count;
        if (skipValidation && lastDepth == 0 &&
            lastPath.filename() == L".beamrt-validation") {
            entry.disable_recursion_pending();
            ++skipped;
            std::wcout << L"SKIP=" << lastPath.native() << L"\n";
        }
        entry.increment(error);
        if (error) {
            std::wcerr << L"FAIL increment after=" << lastPath.native()
                       << L"\nlast_path_characters=" << lastPath.native().size()
                       << L" depth=" << lastDepth << L" entries=" << count
                       << L" code=" << error.value() << L"\n";
            std::cerr << "message=" << error.message() << '\n';
            return 1;
        }
    }
    std::wcout << L"PASS entries=" << count << L" skipped=" << skipped
               << L" root=" << root.native() << L"\n";
    return 0;
}
