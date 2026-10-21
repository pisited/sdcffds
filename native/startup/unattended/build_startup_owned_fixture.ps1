param([switch]$RunTests, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$beamrtRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$beamrtValidationRoot = [IO.Path]::GetFullPath((Join-Path $beamrtRoot '.beamrt-validation'))
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $beamrtValidationRoot ('startup-owned-fixture-' + [Guid]::NewGuid().ToString('N'))
}
$beamrtOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (!$beamrtOutput.StartsWith($beamrtValidationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Disposable output must be a new child directory inside .beamrt-validation.'
}
if (Test-Path -LiteralPath $beamrtOutput) { throw 'Refusing to overwrite an existing output directory.' }
$beamrtDetours = Join-Path $beamrtValidationRoot 'dependencies/detours-e4bfd6b03e50de46b47abfbd1e46b384f0c5f833'
if (!(Test-Path -LiteralPath (Join-Path $beamrtDetours 'lib.X64/detours.lib'))) {
    throw 'Reviewed Detours dependency unavailable; this fixture does not install dependencies.'
}
# Reuse exact already-reviewed passive/no-receipt bootstrap binaries. Neither
# artifact contains active capture/GI behavior without separate opt-in payloads.
$beamrtBootstrapRoot = Join-Path $beamrtValidationRoot 'native-startup-resource-e96d984928844cce8d4f8e2882c5be70'
$beamrtBootstrapPins = @{
    'beamrt_startup_bootstrap.dll' = 'e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38'
    'beamrt_startup_no_receipt.dll' = '954a9b7bcdf96a83a554e8abcf146756703a48dea8ac027e5d5d1c415eac811c'
}
foreach ($beamrtName in $beamrtBootstrapPins.Keys) {
    $beamrtSource = Join-Path $beamrtBootstrapRoot $beamrtName
    if ((Get-FileHash -LiteralPath $beamrtSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne $beamrtBootstrapPins[$beamrtName]) {
        throw "Reviewed fixture bootstrap changed: $beamrtName"
    }
}
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
foreach ($beamrtName in $beamrtBootstrapPins.Keys) {
    Copy-Item -LiteralPath (Join-Path $beamrtBootstrapRoot $beamrtName) -Destination (Join-Path $beamrtOutput $beamrtName)
    if ((Get-FileHash -LiteralPath (Join-Path $beamrtOutput $beamrtName) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $beamrtBootstrapPins[$beamrtName]) {
        throw "Copied fixture bootstrap changed: $beamrtName"
    }
}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot '../launcher.cpp') /Febeamrt_startup_host.exe /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') bcrypt.lib shell32.lib
    if ($LASTEXITCODE) { throw 'Reviewed startup host compilation failed.' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /DBEAMRT_STARTUP_TEST_FAULTS /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot '../launcher.cpp') /Febeamrt_startup_fault_host.exe /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') bcrypt.lib shell32.lib
    if ($LASTEXITCODE) { throw 'Disposable fault host compilation failed.' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'startup_owned_child.cpp') /Febeamrt_startup_fixture.exe /link /SUBSYSTEM:WINDOWS shell32.lib
    if ($LASTEXITCODE) { throw 'Hidden disposable owned child compilation failed.' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'startup_owned_fixture.cpp') /Festartup_owned_fixture.exe /link bcrypt.lib
    if ($LASTEXITCODE) { throw 'Owned startup integration fixture compilation failed.' }
    if ($RunTests) {
        & (Join-Path $beamrtOutput 'beamrt_startup_host.exe') --self-test
        if ($LASTEXITCODE) { throw 'No-launch startup contract tests failed.' }
        & (Join-Path $beamrtOutput 'startup_owned_fixture.exe')
        if ($LASTEXITCODE) { throw 'Disposable startup owned-session integration failed.' }
    }
} finally { Pop-Location }
foreach ($beamrtName in @('beamrt_startup_host.exe', 'beamrt_startup_fault_host.exe', 'beamrt_startup_fixture.exe', 'startup_owned_fixture.exe') + @($beamrtBootstrapPins.Keys)) {
    $beamrtHash = (Get-FileHash -LiteralPath (Join-Path $beamrtOutput $beamrtName) -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "$beamrtName SHA-256: $beamrtHash"
}
Write-Output "Startup-owned disposable artifacts: $beamrtOutput. No BeamNG or existing process was launched or attached."
