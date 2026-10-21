param([switch]$RunTests, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$beamrtRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$beamrtValidationRoot = [IO.Path]::GetFullPath((Join-Path $beamrtRoot '.beamrt-validation'))
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $beamrtValidationRoot ('startup-stop-channel-build-' + [Guid]::NewGuid().ToString('N'))
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
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD (Join-Path $PSScriptRoot 'startup_stop_channel_fixture.cpp') /Festartup_stop_channel_fixture.exe /link ole32.lib
    if ($LASTEXITCODE) { throw 'Fixed file-channel fixture compilation failed.' }
    if ($RunTests) {
        & (Join-Path $beamrtOutput 'startup_stop_channel_fixture.exe')
        if ($LASTEXITCODE) { throw 'Fixed file-channel fixture failed.' }
    }
} finally { Pop-Location }
Write-Output "Startup stop-channel file-only artifacts: $beamrtOutput. No process, BeamNG, startup host or DLL was launched."
