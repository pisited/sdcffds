param([Parameter(Mandatory=$true)][string]$NativeIncludes,[switch]$RunTest,[switch]$Warp)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtGame=[IO.Path]::GetFullPath($NativeIncludes)
if(!(Test-Path -LiteralPath (Join-Path $beamrtGame 'shaders/common/postFx/postFx.h.hlsl'))){throw 'Installed BeamNG headers required; no substitutes or installer.'}
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
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/water-receiver'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
function Compile-WaterFixture([string]$Source,[string]$Target,[string]$Entry,[string]$Name){
    $beamrtStageDefines=if($Target.StartsWith('vs_')){@('/D','SHADER_STAGE_VS=1')}else{@('/D','SHADER_STAGE_PS=1')}
    & $beamrtFxc /nologo /Ges /WX /O3 /T $Target /E $Entry @beamrtStageDefines /I $beamrtRoot /I $beamrtGame /Fo (Join-Path $beamrtOutput $Name) $Source
    if($LASTEXITCODE){throw "Water receiver compilation failed: $Name"}
}
Compile-WaterFixture (Join-Path $PSScriptRoot 'water_receiver_fixture.hlsl') vs_5_0 mainV water.vs.cso
Compile-WaterFixture (Join-Path $PSScriptRoot 'water_receiver_fixture.hlsl') ps_5_0 mainP water-helper.ps.cso
Compile-WaterFixture (Join-Path $beamrtRoot 'shaders/beamrt/beamrtWaterReceiverPreviewP_v001.hlsl') ps_5_0 main water-preview.ps.cso
Compile-WaterFixture (Join-Path $beamrtRoot 'shaders/beamrt/beamrtWaterReceiverPreviewP_v001.hlsl') vs_5_0 main water-preview.vs.cso
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'water_receiver_test.cpp') /Febeamrt_water_receiver_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'Water receiver GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_water_receiver_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline water receiver regression failed'}
}
Write-Output "Water receiver artifacts: $beamrtOutput. Geometry preview only; no BeamNG execution."
