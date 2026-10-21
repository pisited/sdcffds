param([switch]$RunTest,[switch]$Checked)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# CPU-only replacement-storage experiment. No DLL, observer hook, GPU/device,
# startup build, game path, dependency download or process attachment.
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
$beamrtOutput=Join-Path $beamrtRoot ('.beamrt-validation/descriptor-view-store-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
$beamrtSources=@('build_descriptor_view_store.ps1','descriptor_view_store.h','descriptor_view_store_fixture.cpp',
    'resource_tracker.h','resource_view_validation.h','resource_profile.h','resource_storage_validation.h','resource_copy_diagnostics.h','resource_copy_validation.h')
foreach($beamrtName in $beamrtSources){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $beamrtName) -Destination (Join-Path $beamrtOutput $beamrtName)
}
Push-Location $beamrtOutput
try {
    [string[]]$beamrtOptimization=if($Checked){@('/Od','/RTC1')}else{@('/O2')}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT @beamrtOptimization descriptor_view_store_fixture.cpp /Febeamrt_descriptor_view_store_fixture.exe
    if($LASTEXITCODE){throw 'CPU-only descriptor storage fixture compilation failed'}
    if($RunTest){
        & ./beamrt_descriptor_view_store_fixture.exe 2>&1 | Tee-Object -FilePath 'fixture.log'
        if($LASTEXITCODE){throw 'CPU-only descriptor storage fixture failed'}
    }
}finally{
    Pop-Location
    $beamrtFiles=@(Get-ChildItem -LiteralPath $beamrtOutput -File)
    $beamrtFiles | ForEach-Object {Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256} |
        Select-Object Path,Hash | Export-Csv -LiteralPath (Join-Path $beamrtOutput 'artifacts.sha256.csv') -NoTypeInformation
    Write-Output "CPU-only descriptor storage artifacts: $beamrtOutput. No observer loading, game or lighting change."
}
