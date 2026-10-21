param([switch]$RunTest)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# CPU-only exact-location representation experiment. No DLL, observer hook,
# GPU/device, startup build, game target, dependency download or attachment.
if(!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB){
    $beamrtVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if(!(Test-Path -LiteralPath $beamrtVswhere)){throw 'Existing MSVC locator unavailable; no install attempted.'}
    $beamrtInstallation=& $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if(!$beamrtInstallation){throw 'Existing MSVC unavailable; no install attempted.'}
    $beamrtVcvars=Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment=& $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if($LASTEXITCODE){throw 'MSVC environment initialization failed'}
    foreach($beamrtLine in $beamrtEnvironment){if($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$'){
        [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
    }}
}
$beamrtOutput=Join-Path $beamrtRoot ('.beamrt-validation/descriptor-location-store-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
$beamrtSources=@('build_descriptor_location_store.ps1','descriptor_location_store.h','descriptor_location_store_fixture.cpp',
    'descriptor_view_store.h','resource_tracker.h','resource_view_validation.h','resource_profile.h','resource_storage_validation.h')
foreach($beamrtName in $beamrtSources){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $beamrtName) -Destination (Join-Path $beamrtOutput $beamrtName)}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /O2 descriptor_location_store_fixture.cpp /Febeamrt_descriptor_location_store_fixture.exe
    if($LASTEXITCODE){throw 'CPU-only exact-location fixture compilation failed'}
    if($RunTest){& ./beamrt_descriptor_location_store_fixture.exe 2>&1 | Tee-Object -FilePath 'fixture.log'
        if($LASTEXITCODE){throw 'CPU-only exact-location fixture failed'}}
}finally{
    Pop-Location
    $beamrtArtifacts=@(Get-ChildItem -LiteralPath $beamrtOutput -File)
    $beamrtArtifacts | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash |
        Export-Csv -LiteralPath (Join-Path $beamrtOutput 'artifacts.sha256.csv') -NoTypeInformation
    Write-Output "CPU-only exact-location artifacts: $beamrtOutput. No production ABI/cap change, observer loading, game or lighting change."
}
