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
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/receiver-history'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
function Compile-ReceiverHistory([string]$Source,[string]$Target,[string]$Name){
    & $beamrtFxc /nologo /Ges /WX /O3 /T $Target /E main /I $beamrtRoot /I $beamrtGame /Fo (Join-Path $beamrtOutput $Name) $Source
    if($LASTEXITCODE){throw "Receiver history compilation failed: $Name"}
}
Compile-ReceiverHistory (Join-Path $PSScriptRoot 'reflection_receiver_history_fixture.hlsl') vs_5_0 receiver.vs.cso
foreach($beamrtEntry in @('beamrtReflectionTemporalP_v038.hlsl','beamrtReflectionTemporalP_v039.hlsl',
    'beamrtReflectionHitInputsP_v002.hlsl','beamrtReflectionHitCopyP_v002.hlsl')){
    Compile-ReceiverHistory (Join-Path $beamrtRoot "shaders/beamrt/$beamrtEntry") ps_5_0 "$beamrtEntry.ps.cso"
}
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'reflection_receiver_history_test.cpp') /Febeamrt_reflection_receiver_history_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'Reflection receiver-history GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_reflection_receiver_history_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline receiver-history regression failed'}
}
Write-Output "Receiver-history artifacts: $beamrtOutput. Synthetic resources only; no BeamNG execution."
