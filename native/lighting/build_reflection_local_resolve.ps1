param([Parameter(Mandatory=$true)][string]$NativeIncludes,[switch]$RunTest,[switch]$Warp)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtGame=[IO.Path]::GetFullPath($NativeIncludes)
if(!(Test-Path -LiteralPath (Join-Path $beamrtGame 'shaders/common/postFx/postFx.h.hlsl'))){throw 'Installed BeamNG shader headers required; no substitutes or installer.'}
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
$beamrtOutput=Join-Path $env:TEMP 'brt-rdisp'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
function Compile-LocalResolve([string]$Source,[string]$Target,[string]$Entry,[string]$Name){
    & $beamrtFxc /nologo /Ges /WX /O3 /T $Target /E $Entry /I $beamrtRoot /I $beamrtGame /Fo (Join-Path $beamrtOutput $Name) $Source
    if($LASTEXITCODE){throw "Reflection local resolve compilation failed: $Name"}
}
$beamrtFixture=Join-Path $PSScriptRoot 'reflection_local_resolve_fixture.hlsl'
Compile-LocalResolve $beamrtFixture vs_5_0 mainV local.vs.cso
Compile-LocalResolve $beamrtFixture ps_5_0 mainP local.ps.cso
foreach($beamrtVersion in @('033','034')){
    Compile-LocalResolve (Join-Path $beamrtRoot "shaders/beamrt/beamrtReflectionComposeP_v$beamrtVersion.hlsl") ps_5_0 main "compose$beamrtVersion.ps.cso"
}
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'reflection_local_resolve_test.cpp') /Felocal.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'Reflection local resolve GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'local.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline reflection local resolve regression failed'}
}
Write-Output "Reflection local resolve artifacts: $beamrtOutput. No BeamNG execution."
