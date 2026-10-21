param([switch]$RunTests, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$beamrtRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$beamrtValidationRoot = [IO.Path]::GetFullPath((Join-Path $beamrtRoot '.beamrt-validation'))
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $beamrtValidationRoot ('owned-watchdog-build-' + [Guid]::NewGuid().ToString('N'))
}
$beamrtOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (!$beamrtOutput.StartsWith($beamrtValidationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Disposable build output must be a new child directory inside .beamrt-validation.'
}
if (Test-Path -LiteralPath $beamrtOutput) { throw 'Refusing to overwrite an existing output directory.' }
if (!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB) {
    $beamrtVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $beamrtInstallation = & $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$beamrtInstallation) { throw 'MSVC x64 build tools not found; no installer will be run.' }
    $beamrtVcvars = Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment = & $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if ($LASTEXITCODE) { throw 'MSVC environment initialization failed.' }
    foreach ($beamrtLine in $beamrtEnvironment) {
        if ($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}
[IO.Directory]::CreateDirectory($beamrtOutput) | Out-Null
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD (Join-Path $PSScriptRoot 'watchdog_policy_test.cpp') /Fewatchdog_policy_test.exe
    if ($LASTEXITCODE) { throw 'Portable policy fixture compilation failed.' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD (Join-Path $PSScriptRoot 'owned_watchdog_child.cpp') /Feowned_watchdog_child.exe /link /SUBSYSTEM:WINDOWS shell32.lib
    if ($LASTEXITCODE) { throw 'Hidden disposable child compilation failed.' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD (Join-Path $PSScriptRoot 'owned_watchdog_fixture.cpp') /Feowned_watchdog_fixture.exe /link ole32.lib
    if ($LASTEXITCODE) { throw 'Exact-owned native fixture compilation failed.' }
    if ($RunTests) {
        & (Join-Path $beamrtOutput 'watchdog_policy_test.exe')
        if ($LASTEXITCODE) { throw 'Portable policy fixture failed.' }
        & (Join-Path $beamrtOutput 'owned_watchdog_fixture.exe')
        if ($LASTEXITCODE) { throw 'Exact-owned disposable process fixture failed.' }
    }
} finally { Pop-Location }
Write-Output "Owned-watchdog disposable artifacts: $beamrtOutput. No BeamNG, startup host, DLL or existing process was launched or attached."
