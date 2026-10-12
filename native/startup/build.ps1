param([switch]$RunContractTests,[switch]$RunProcessTests,[switch]$RunDeviceTests)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Reuse the existing strict toolchain and pinned Detours verification. This
# builds capture artifacts but does NOT link/load capture into this bootstrap.
& (Join-Path $beamrtRoot 'native/capture/build.ps1')
if($LASTEXITCODE){throw 'Pinned toolchain/dependency preparation failed'}
$beamrtPinnedDetours='e4bfd6b03e50de46b47abfbd1e46b384f0c5f833'
$beamrtDetours=Join-Path $beamrtRoot ".beamrt-validation/dependencies/detours-$beamrtPinnedDetours"
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/native-startup'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'bootstrap.cpp') (Join-Path $PSScriptRoot 'device_observer.cpp') /Febeamrt_startup_bootstrap.dll /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') '/export:DetourFinishHelperProcess,@1,NONAME'
    if($LASTEXITCODE){throw 'Review bootstrap compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'launcher.cpp') /Febeamrt_startup_host.exe /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') bcrypt.lib shell32.lib
    if($LASTEXITCODE){throw 'Review startup host compilation failed'}
    if($RunProcessTests -or $RunDeviceTests){
        # Separate disposable variants; fault behavior is absent from production.
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'fixture_target.cpp') /Febeamrt_startup_fixture.exe /link /subsystem:windows shell32.lib
        if($LASTEXITCODE){throw 'Disposable target compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /DBEAMRT_STARTUP_TEST_FAULTS /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'launcher.cpp') /Febeamrt_startup_fault_host.exe /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') bcrypt.lib shell32.lib
        if($LASTEXITCODE){throw 'Disposable fault host compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD /DBEAMRT_STARTUP_TEST_NO_RECEIPT /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'bootstrap.cpp') (Join-Path $PSScriptRoot 'device_observer.cpp') /Febeamrt_startup_no_receipt.dll /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') '/export:DetourFinishHelperProcess,@1,NONAME'
        if($LASTEXITCODE){throw 'Disposable no-receipt bootstrap compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'process_test.cpp') /Febeamrt_startup_process_test.exe /link bcrypt.lib
        if($LASTEXITCODE){throw 'Disposable process harness compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'device_fixture.cpp') /Febeamrt_device_fixture.exe /link /subsystem:windows shell32.lib d3d12.lib dxgi.lib
        if($LASTEXITCODE){throw 'Disposable device fixture compilation failed'}
    }
} finally {Pop-Location}
if($RunContractTests){
    # Argument/payload tests only. Never invokes --launch-reviewed, creates a
    # child process or loads the bootstrap/capture/GI DLL into any process.
    & (Join-Path $beamrtOutput 'beamrt_startup_host.exe') --self-test
    if($LASTEXITCODE){throw 'No-launch startup contract tests failed'}
}
if($RunProcessTests){
    # Explicit opt-in approved for disposable fixtures only. Runner constructs
    # its own fixed target path; it never accepts a BeamNG executable path.
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput
    if($LASTEXITCODE){throw 'Disposable startup process validation failed'}
}
if($RunDeviceTests){
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput --device
    if($LASTEXITCODE){throw 'Disposable device observer validation failed'}
}
foreach($beamrtName in @('beamrt_startup_host.exe','beamrt_startup_bootstrap.dll')){
    $beamrtPath=Join-Path $beamrtOutput $beamrtName
    $beamrtHash=(Get-FileHash -LiteralPath $beamrtPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "$beamrtName SHA-256: $beamrtHash"
}
Write-Output "Startup artifacts: $beamrtOutput. Process-test opt-in=$RunProcessTests; device-test opt-in=$RunDeviceTests; no BeamNG deployment, game launch or game-file changes."
