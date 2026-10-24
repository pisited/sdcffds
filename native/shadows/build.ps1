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
    $beamrtCandidates=@((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10,
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'))
    $beamrtSdk=$beamrtCandidates|Where-Object{$_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin'))}|Select-Object -First 1
    if(!$beamrtSdk){throw 'Installed Windows SDK required; no installer.'}
    $beamrtFxc=Get-ChildItem (Join-Path $beamrtSdk 'bin') -Directory|Sort-Object Name -Descending|
        ForEach-Object{Join-Path $_.FullName 'x64/fxc.exe'}|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
    if(!$beamrtFxc){throw 'Installed FXC required; no installer.'}
}
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/sun-shadows'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
function Compile-SunFixture([string]$Source,[string]$Target,[string]$Entry,[string]$Name,[string[]]$Extra=@()){
    & $beamrtFxc /nologo /Ges /WX /O3 /T $Target /E $Entry /I $beamrtRoot /I $beamrtGame @Extra /Fo (Join-Path $beamrtOutput $Name) $Source
    if($LASTEXITCODE){throw "Sunlight fixture shader compilation failed: $Name"}
}
Compile-SunFixture (Join-Path $PSScriptRoot 'fixture.hlsl') vs_5_0 mainV fixture.vs.cso @('/D','SHADER_STAGE_VS=1')
Compile-SunFixture (Join-Path $beamrtRoot 'shaders/beamrt/beamrtMeshSunVisibilityP_v001.hlsl') ps_5_0 main producer.ps.cso
foreach($beamrtMode in 0..3){Compile-SunFixture (Join-Path $PSScriptRoot 'fixture.hlsl') ps_5_0 mainP "consumer$beamrtMode.ps.cso" @('/D',"BEAMRT_SUN_COMPARISON=$beamrtMode")}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'self_test.cpp') /Febeamrt_sun_shader_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'Sunlight GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_sun_shader_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline sunlight producer/consumer validation failed'}
}
Write-Output "Sunlight fixture artifacts: $beamrtOutput. No BeamNG launch or native DLL."
