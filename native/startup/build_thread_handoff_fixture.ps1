param([switch]$RunTest)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# This fixture needs only the existing compiler. Do not invoke the GPU/startup
# build scripts, fetch dependencies, rebuild DLLs, or initialize a game process.
if(!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB){
    $beamrtVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if(!(Test-Path -LiteralPath $beamrtVswhere)){throw 'MSVC locator unavailable; no installer will be run.'}
    $beamrtInstallation=& $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if(!$beamrtInstallation){throw 'MSVC x64 build tools unavailable; no installer will be run.'}
    $beamrtVcvars=Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment=& $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if($LASTEXITCODE){throw 'MSVC environment initialization failed'}
    foreach($beamrtLine in $beamrtEnvironment){if($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$'){
        [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process')
    }}
}
$beamrtOutput=Join-Path $beamrtRoot ('.beamrt-validation/thread-handoff-fixture-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
foreach($beamrtName in @('thread_handoff_fixture.cpp','thread_handoff_fixture_model.h')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $beamrtName) -Destination (Join-Path $beamrtOutput $beamrtName)
}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT 'thread_handoff_fixture.cpp' /Febeamrt_thread_handoff_fixture.exe
    if($LASTEXITCODE){throw 'CPU-only callback interval fixture compilation failed'}
    if($RunTest){
        & ./beamrt_thread_handoff_fixture.exe 2>&1 | Tee-Object -FilePath (Join-Path $beamrtOutput 'fixture.log')
        if($LASTEXITCODE){throw 'CPU-only callback interval fixture failed'}
    }
}finally{Pop-Location}
$beamrtFiles=@(Get-ChildItem -LiteralPath $beamrtOutput -File)
$beamrtFiles | ForEach-Object {Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256} |
    Select-Object Path,Hash | Export-Csv -LiteralPath (Join-Path $beamrtOutput 'artifacts.sha256.csv') -NoTypeInformation
Write-Output "CPU-only handoff fixture artifacts: $beamrtOutput. No native observer or game changes."
