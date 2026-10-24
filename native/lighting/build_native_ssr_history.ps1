param([Parameter(Mandatory=$true)][string]$NativeIncludes,[switch]$RunTest,[switch]$Warp,
    [string]$OutputDirectory=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex/beamrt-native-ssr-history'))
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtGame=[IO.Path]::GetFullPath($NativeIncludes)
if(!(Test-Path -LiteralPath (Join-Path $beamrtGame 'shaders/common/postFx/sssr/include/ffx_denoiser_reflections_config.h'))){throw 'Installed BeamNG shader headers required; no substitutes or installer.'}
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
$beamrtFixture=Join-Path $PSScriptRoot 'native_ssr_history_fixture.hlsl'
foreach($beamrtStage in @(@('vs_5_0','mainV','history.vs.cso'),@('ps_5_0','mainP','history.ps.cso'))){
    & $beamrtFxc /nologo /Ges /WX /O3 /T $beamrtStage[0] /E $beamrtStage[1] /I $beamrtRoot /I $beamrtGame /Fo (Join-Path $beamrtOutput $beamrtStage[2]) $beamrtFixture
    if($LASTEXITCODE){throw "Native history helper compilation failed: $($beamrtStage[2])"}
}
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'native_ssr_history_test.cpp') /Febeamrt_native_ssr_history_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'Native history helper GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_native_ssr_history_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline native history helper regression failed'}
}
Write-Output "Native-history helper artifacts: $beamrtOutput. Not deployed; no BeamNG execution or native override."
