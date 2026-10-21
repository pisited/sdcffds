param([Parameter(Mandatory=$true)][string]$NativeIncludes,[switch]$RunTest,[switch]$Warp,
    [string]$OutputDirectory=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex/beamrt-sssr-fork'))
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtGame=[IO.Path]::GetFullPath($NativeIncludes)
if(!(Test-Path -LiteralPath (Join-Path $beamrtGame 'shaders/common/postFx/postFx.h.hlsl'))){throw 'Installed BeamNG shader headers required; no substitutes or installer.'}
$beamrtOutput=[IO.Path]::GetFullPath($OutputDirectory)
if($beamrtOutput.StartsWith($beamrtRoot,[StringComparison]::OrdinalIgnoreCase) -or
    $beamrtOutput.StartsWith($beamrtGame,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture artifacts must stay outside the mod and game installation.'}
if(!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB){
    $beamrtVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $beamrtInstallation=& $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if(!$beamrtInstallation){throw 'Installed x64 MSVC required; no installer.'}
    $beamrtVcvars=Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment=& $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if($LASTEXITCODE){throw 'MSVC initialization failed'}
    foreach($beamrtLine in $beamrtEnvironment){if($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$'){
        [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
    }}
}
$beamrtFxc=(Get-Command fxc.exe -ErrorAction SilentlyContinue).Source
if(!$beamrtFxc){
    $beamrtSdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $beamrtFxc=Get-ChildItem -LiteralPath $beamrtSdk -Directory|Sort-Object Name -Descending|
        ForEach-Object{Join-Path $_.FullName 'x64/fxc.exe'}|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
    if(!$beamrtFxc){throw 'Installed FXC required; no installer.'}
}
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
$beamrtFxcJobs=@(
    @((Join-Path $PSScriptRoot 'sssr_fork_fixture.hlsl'),'vs_5_0','mainV','core.vs.cso'),
    @((Join-Path $PSScriptRoot 'sssr_fork_fixture.hlsl'),'ps_5_0','mainP','core.ps.cso'),
    @((Join-Path $PSScriptRoot 'sssr_fork_vertex.hlsl'),'vs_5_0','fixtureMainV','fork.vs.cso'),
    @((Join-Path $PSScriptRoot 'reflection_radiance_fixture.hlsl'),'vs_5_0','mainV','compose.vs.cso'),
    @((Join-Path $PSScriptRoot 'fixture.vs.hlsl'),'vs_5_0','main','temporal.vs.cso'),
    @((Join-Path $beamrtRoot 'shaders/beamrt/nativeSsr/traceP_v002.hlsl'),'ps_5_0','main','fork.ps.cso'),
    @((Join-Path $beamrtRoot 'shaders/beamrt/beamrtReflectionComposeP_v034.hlsl'),'ps_5_0','main','compose034.ps.cso'),
    @((Join-Path $beamrtRoot 'shaders/beamrt/beamrtReflectionComposeP_v035.hlsl'),'ps_5_0','main','compose035.ps.cso'),
    @((Join-Path $beamrtRoot 'shaders/beamrt/beamrtReflectionTemporalP_v039.hlsl'),'ps_5_0','main','temporal039.ps.cso'),
    @((Join-Path $beamrtRoot 'shaders/beamrt/beamrtReflectionTemporalP_v040.hlsl'),'ps_5_0','main','temporal040.ps.cso')
)
foreach($beamrtJob in $beamrtFxcJobs){
    & $beamrtFxc /nologo /Ges /WX /O3 /T $beamrtJob[1] /E $beamrtJob[2] /I $beamrtRoot /I $beamrtGame /Fo (Join-Path $beamrtOutput $beamrtJob[3]) $beamrtJob[0]
    if($LASTEXITCODE){throw "Fork compilation failed: $($beamrtJob[3])"}
}
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'sssr_fork_test.cpp') /Febeamrt_sssr_fork_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'SSSR fork GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_sssr_fork_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline SSSR fork regression failed'}
}
Write-Output "Owned SSSR fork artifacts: $beamrtOutput. Build/test only; no BeamNG execution or native override."
