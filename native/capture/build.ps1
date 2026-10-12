param([switch]$RunTest,[switch]$Warp)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/native-capture'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
$beamrtVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$beamrtInstallation=& $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$beamrtInstallation){throw 'Installed x64 MSVC required; no installer will be run.'}
$beamrtVcvars=Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
$beamrtEnvironment=& $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
if($LASTEXITCODE){throw 'MSVC environment initialization failed'}
foreach($beamrtLine in $beamrtEnvironment){if($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$'){
    [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
}}
$beamrtFxc=(Get-Command fxc.exe -ErrorAction Stop).Source
# Official MIT-licensed source, pinned to the verified v4.0.1 commit. Confined
# to ignored build dependencies; never copied into BeamNG's Bin64 or deployed.
$beamrtDetoursCommit='e4bfd6b03e50de46b47abfbd1e46b384f0c5f833'
$beamrtDependencyParent=Join-Path $beamrtRoot '.beamrt-validation/dependencies'
[IO.Directory]::CreateDirectory($beamrtDependencyParent)|Out-Null
$beamrtDetours=Join-Path $beamrtDependencyParent "detours-$beamrtDetoursCommit"
if(!(Test-Path -LiteralPath $beamrtDetours)){
    & git clone --filter=blob:none --no-checkout https://github.com/microsoft/Detours.git $beamrtDetours
    if($LASTEXITCODE){throw 'Pinned Detours source fetch failed'}
    & git -C $beamrtDetours checkout --detach $beamrtDetoursCommit
    if($LASTEXITCODE){throw 'Pinned Detours checkout failed'}
}
$beamrtActual=& git -C $beamrtDetours rev-parse HEAD
$beamrtOrigin=& git -C $beamrtDetours remote get-url origin
$beamrtDirty=& git -C $beamrtDetours status --porcelain --untracked-files=no
if($beamrtActual -ne $beamrtDetoursCommit -or $beamrtOrigin -ne 'https://github.com/microsoft/Detours.git' -or $beamrtDirty){throw 'Dependency checkout changed; refusing to overwrite/use it.'}
Push-Location (Join-Path $beamrtDetours 'src')
try { & nmake.exe /nologo
    if($LASTEXITCODE){throw 'Pinned Detours build failed'}
} finally {Pop-Location}
foreach($beamrtStage in @(@('vs_5_0','mainV','fixture.vs.cso'),@('ps_5_0','mainP','fixture.ps.cso'),@('cs_5_0','mainC','fixture.cs.cso'))){
    & $beamrtFxc /nologo /Ges /WX /O3 /T $beamrtStage[0] /E $beamrtStage[1] /Fo (Join-Path $beamrtOutput $beamrtStage[2]) (Join-Path $PSScriptRoot 'fixture.hlsl')
    if($LASTEXITCODE){throw 'Capture fixture shader compilation failed'}
}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'beamrt_capture.cpp') (Join-Path $PSScriptRoot 'sdk_methods.c') /Febeamrt_capture.dll /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') d3d12.lib
    if($LASTEXITCODE){throw 'Native interception DLL compilation failed'}
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'self_test.cpp')){
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'self_test.cpp') /Febeamrt_capture_test.exe /link beamrt_capture.lib d3d12.lib dxgi.lib
        if($LASTEXITCODE){throw 'Interception test compilation failed'}
    }
} finally {Pop-Location}
if($RunTest){
    $beamrtArgs=@((Join-Path $beamrtOutput 'fixture.vs.cso'),(Join-Path $beamrtOutput 'fixture.ps.cso'),(Join-Path $beamrtOutput 'fixture.cs.cso'))
    if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_capture_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Isolated native interception validation failed'}
}
Write-Output "Capture artifacts: $beamrtOutput. No BeamNG loading, launcher, injection or installation performed."
