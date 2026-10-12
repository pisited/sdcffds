param([string]$Python='python',[switch]$Setup)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$beamrtEnvironment=Join-Path $beamrtRoot '.beamrt-validation/python-tests'
$beamrtTestPython=Join-Path $beamrtEnvironment 'Scripts/python.exe'
$beamrtRequirements=Join-Path $PSScriptRoot 'requirements-tests.txt'

if(!(Test-Path -LiteralPath $beamrtTestPython)) {
    if(!$Setup){throw 'Test environment missing. Run ./tools/test.ps1 -Setup -Python <existing-python.exe> once.'}
    if(Test-Path -LiteralPath $beamrtEnvironment) {
        throw 'An incomplete/nonstandard test environment exists; retained unchanged. Inspect it before creating a replacement.'
    }
    # The environment excludes system/user site packages. No global Python,
    # registry, PATH, BeamNG settings or game files are modified.
    & $Python -I -m venv $beamrtEnvironment
    if($LASTEXITCODE){throw 'Project-local Python environment creation failed; partial files retained.'}
}
if($Setup) {
    & $beamrtTestPython -I -m pip --isolated install --disable-pip-version-check --no-cache-dir --only-binary=:all: --no-deps --index-url https://pypi.org/simple -r $beamrtRequirements
    if($LASTEXITCODE){throw 'Pinned test dependency installation failed; no source build or global installation attempted.'}
}
# -I prevents a hidden user-site package, PYTHONPATH or unrelated environment
# from satisfying the imports. Both runtimes must exist in this environment.
& $beamrtTestPython -I -B -c "import sys, pathlib, importlib.metadata as m; import lupa; from lupa.lua51 import LuaRuntime as Lua51; from lupa.luajit21 import LuaRuntime as LuaJIT; assert m.version('lupa')=='2.8', 'Unexpected Lupa version; rerun -Setup'; assert pathlib.Path(lupa.__file__).resolve().is_relative_to(pathlib.Path(sys.prefix).resolve()), 'Lupa loaded outside the test environment'; print('Interpreter:',sys.executable); print('Lupa:',m.version('lupa'),lupa.__file__); print('Runtimes:',Lua51().lua_implementation,'/',LuaJIT().lua_implementation)"
if($LASTEXITCODE){throw 'Pinned Lua 5.1/LuaJIT test runtimes unavailable. Rerun with -Setup.'}
& $beamrtTestPython -I -B -m unittest discover -s (Join-Path $PSScriptRoot 'tests') -p 'test_*.py'
if($LASTEXITCODE){throw 'BeamRT regression tests failed.'}
