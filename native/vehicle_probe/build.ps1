param([switch]$RunTest)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/vehicle-gpu-probe'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
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
$beamrtSdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$beamrtFxc=Get-ChildItem -LiteralPath $beamrtSdk -Directory|Sort-Object Name -Descending|
    ForEach-Object{Join-Path $_.FullName 'x64/fxc.exe'}|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
if(!$beamrtFxc){throw 'Installed FXC required; no installer.'}
& $beamrtFxc /nologo /Ges /Gis /WX /O3 /T cs_5_0 /E main /Fo (Join-Path $beamrtOutput 'trace.cso') (Join-Path $PSScriptRoot 'trace.cs.hlsl')
if($LASTEXITCODE){throw 'GPU probe shader compilation failed'}
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'probe.cpp') /Febeamrt_vehicle_gpu_probe.exe /link d3d12.lib dxgi.lib d3dcompiler.lib ws2_32.lib bcrypt.lib
    if($LASTEXITCODE){throw 'GPU probe compilation failed'}
}finally{Pop-Location}
if($RunTest){
    & (Join-Path $beamrtOutput 'beamrt_vehicle_gpu_probe.exe') (Join-Path $beamrtOutput 'trace.cso') --self-test
    if($LASTEXITCODE){throw 'GPU probe self-test failed'}
}
Write-Output "Isolated GPU probe artifacts: $beamrtOutput"
