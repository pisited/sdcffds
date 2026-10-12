param([string]$Python = 'python', [switch]$SyntheticFixture, [switch]$RunTest, [switch]$Warp)
$ErrorActionPreference = 'Stop'
$beamrtRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtOutput = Join-Path $beamrtRoot '.beamrt-validation/native-worker'
[IO.Directory]::CreateDirectory($beamrtOutput) | Out-Null
if (!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB) {
    $beamrtVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $beamrtInstallation = & $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$beamrtInstallation) { throw 'MSVC x64 build tools not found; no installer will be run.' }
    $beamrtVcvars = Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment = & $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if ($LASTEXITCODE) { throw 'MSVC environment initialization failed' }
    foreach ($beamrtLine in $beamrtEnvironment) {
        if ($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}
$beamrtSdkCandidates = @(
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10,
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10')
)
$beamrtSdk = $beamrtSdkCandidates | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin')) } | Select-Object -First 1
if (!$beamrtSdk) { throw 'Windows SDK directory not found; no installer will be run.' }
$beamrtFxc = Get-ChildItem (Join-Path $beamrtSdk 'bin') -Directory |
    Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'x64/fxc.exe' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (!$beamrtFxc) { throw 'Windows SDK FXC not found; no installer will be run.' }
$beamrtShader = Join-Path $beamrtOutput 'trace.cso'
& $beamrtFxc /nologo /Ges /WX /O3 /T cs_5_0 /E main /I $beamrtRoot /Fo $beamrtShader (Join-Path $PSScriptRoot 'trace.cs.hlsl')
if ($LASTEXITCODE) { throw 'Native compute shader compilation failed' }
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD /LD (Join-Path $PSScriptRoot 'beamrt_worker.cpp') /Febeamrt_native_worker.dll /link d3d12.lib dxgi.lib
    if ($LASTEXITCODE) { throw 'Native DLL compilation failed' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD (Join-Path $PSScriptRoot 'self_test.cpp') /Febeamrt_worker_test.exe /link beamrt_native_worker.lib d3d12.lib dxgi.lib
    if ($LASTEXITCODE) { throw 'Native self-test compilation failed' }
} finally { Pop-Location }
$beamrtFixture = Join-Path $beamrtOutput 'fixture.bin'
$beamrtFixtureArgs = @('-B', (Join-Path $beamrtRoot 'tools/beamrt_native_fixture.py'), '--output', $beamrtFixture)
if ($SyntheticFixture) { $beamrtFixtureArgs += '--synthetic' }
& $Python @beamrtFixtureArgs
if ($LASTEXITCODE) { throw 'Fixture preparation failed' }
if ($RunTest) {
    $beamrtTestArgs = @($beamrtFixture, $beamrtShader)
    if ($Warp) { $beamrtTestArgs += '--warp' }
    & (Join-Path $beamrtOutput 'beamrt_worker_test.exe') @beamrtTestArgs
    if ($LASTEXITCODE) { throw 'Offline native GPU validation failed' }
}
Write-Output "Offline artifacts: $beamrtOutput. No game installation or injection performed."
