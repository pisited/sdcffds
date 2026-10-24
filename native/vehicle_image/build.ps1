param([switch]$RunTest)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/vehicle-gpu-image'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
if(!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB){
    $beamrtVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $beamrtInstallation=& $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if(!$beamrtInstallation){throw 'Installed x64 MSVC required; no installer.'}
    $beamrtVcvars=Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment=& $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if($LASTEXITCODE){throw 'MSVC initialization failed'}
    foreach($beamrtLine in $beamrtEnvironment){if($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$'){[Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')}}
}
$beamrtSdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$beamrtFxc=Get-ChildItem -LiteralPath $beamrtSdk -Directory|Sort-Object Name -Descending|ForEach-Object{Join-Path $_.FullName 'x64/fxc.exe'}|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
if(!$beamrtFxc){throw 'Installed FXC required; no installer.'}
& $beamrtFxc /nologo /Ges /Gis /WX /O3 /T cs_5_0 /E main /Fo (Join-Path $beamrtOutput 'image.cso') (Join-Path $PSScriptRoot 'image.cs.hlsl')
if($LASTEXITCODE){throw 'GPU image shader compilation failed'}
& $beamrtFxc /nologo /Ges /Gis /WX /O3 /D BEAMRT_GPU_LINEAR_REFERENCE=1 /T cs_5_0 /E main /Fo (Join-Path $beamrtOutput 'image-reference.cso') (Join-Path $PSScriptRoot 'image.cs.hlsl')
if($LASTEXITCODE){throw 'GPU image reference shader compilation failed'}
Push-Location $beamrtOutput
try{& cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'image.cpp') /Febeamrt_vehicle_gpu_image.exe /link d3d12.lib dxgi.lib d3dcompiler.lib ws2_32.lib bcrypt.lib
    if($LASTEXITCODE){throw 'GPU image host compilation failed'}
}finally{Pop-Location}
if($RunTest){& (Join-Path $beamrtOutput 'beamrt_vehicle_gpu_image.exe') (Join-Path $beamrtOutput 'image.cso') --self-test;if($LASTEXITCODE){throw 'GPU image hardware self-test failed'}}
Write-Output "Isolated GPU image artifacts: $beamrtOutput"
