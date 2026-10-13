# Reproducible local test environment

BeamRT's offline tests use Python plus **Lupa 2.8**, explicitly importing Lua 5.1
and LuaJIT 2.1. Python 3.10 is the verified local base; a special new Python
installation is not required. CI uses Python 3.11 with the same package pin.

From the unpacked BeamRT folder in PowerShell, bootstrap once:

```powershell
./tools/test.ps1 -Setup -Python 'C:/Users/ab/AppData/Local/Programs/Python/Python310/python.exe'
```

Subsequent test runs need no setup/download:

```powershell
./tools/test.ps1
```

The script creates `.beamrt-validation/python-tests`, downloads the official
binary wheel from PyPI and verifies both Lua runtimes. Python isolated mode
excludes user-site packages and environment search-path overrides. The script
prints the actual executable, package location and runtime implementations;
results belong to the environment where the script ran. Separate filesystem
views must bootstrap their own environment with the same tracked requirements.

Dependencies and environment files are ignored by Git. The requirements/script
are tracked. No global package installation, interpreter replacement, registry
or PATH changes, game loading or BeamNG reload is involved. Existing incomplete
environments are retained, not automatically deleted or overwritten.

Native builds can use the same test interpreter explicitly:

```powershell
./native/gi/build.ps1 -Python ./.beamrt-validation/python-tests/Scripts/python.exe -RunTest
```

Native GPU fixtures still require the installed MSVC/Windows SDK toolchain.
Passing source/Lua tests does not prove shader execution or BeamNG integration.
