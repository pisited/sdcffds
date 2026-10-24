param([string]$InspectRoot)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/cluster-root-inspector'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
if(!(Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $beamrtVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $beamrtInstallation=& $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if(!$beamrtInstallation){throw 'Installed MSVC required; no installer will run.'}
    $beamrtVcvars=Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment=& $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if($LASTEXITCODE){throw 'MSVC environment initialization failed'}
    foreach($beamrtLine in $beamrtEnvironment) {
        if($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
        }
    }
}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'root_layout_inspect.cpp') /Febeamrt_root_layout_inspect.exe /link d3d12.lib
    if($LASTEXITCODE){throw 'CPU-only root inspector build failed'}
    if($InspectRoot) {
        & ./beamrt_root_layout_inspect.exe $InspectRoot
        if($LASTEXITCODE){throw 'Root inspection refused'}
    }
} finally {Pop-Location}
