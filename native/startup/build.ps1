param([switch]$RunContractTests,[switch]$RunProcessTests,[switch]$RunDeviceTests,[switch]$RunEntryTests,[switch]$RunImportTests,[switch]$RunPipelineStartupTests,[switch]$RunBindingStartupTests,[switch]$RunLoaderTests,[switch]$RunResourceStartupTests,[switch]$FreshArtifacts,[switch]$WarpResourceStartupOnly)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Reuse the existing strict toolchain and pinned Detours verification. This
# builds capture artifacts but does NOT link/load capture into this bootstrap.
& (Join-Path $beamrtRoot 'native/capture/build.ps1')
if($LASTEXITCODE){throw 'Pinned toolchain/dependency preparation failed'}
$beamrtPinnedDetours='e4bfd6b03e50de46b47abfbd1e46b384f0c5f833'
$beamrtDetours=Join-Path $beamrtRoot ".beamrt-validation/dependencies/detours-$beamrtPinnedDetours"
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/native-startup'
if($FreshArtifacts){$beamrtOutput=Join-Path $beamrtRoot ('.beamrt-validation/native-startup-resource-'+[Guid]::NewGuid().ToString('N'))}
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
Push-Location $beamrtOutput
try {
    & ml64.exe /nologo /c /Foentry_thunk.obj (Join-Path $PSScriptRoot 'entry_thunk.asm')
    if($LASTEXITCODE){throw 'Native entry thunk assembly failed'}
    $beamrtBootstrapSources=@((Join-Path $PSScriptRoot 'bootstrap.cpp'),(Join-Path $PSScriptRoot 'device_observer.cpp'),(Join-Path $PSScriptRoot 'import_observer.cpp'),(Join-Path $PSScriptRoot 'entry_rendezvous.cpp'),(Join-Path $PSScriptRoot 'pipeline_handoff.cpp'),(Join-Path $PSScriptRoot 'pipeline_audit.cpp'),(Join-Path $PSScriptRoot 'pipeline_slots.c'),(Join-Path $PSScriptRoot 'binding_handoff.cpp'),(Join-Path $PSScriptRoot 'gi_bindings.cpp'),(Join-Path $PSScriptRoot 'binding_slots.c'),(Join-Path $PSScriptRoot 'resource_handoff.cpp'),(Join-Path $PSScriptRoot 'resource_tracker.cpp'),(Join-Path $PSScriptRoot 'resource_slots.c'),'entry_thunk.obj')
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD /DBEAMRT_PIPELINE_HANDOFF /DBEAMRT_BINDING_EMBEDDED /DBEAMRT_RESOURCE_EMBEDDED /I (Join-Path $beamrtDetours 'include') @beamrtBootstrapSources /Febeamrt_startup_bootstrap.dll /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') '/export:DetourFinishHelperProcess,@1,NONAME' /MAP:beamrt_startup_bootstrap.map
    if($LASTEXITCODE){throw 'Review bootstrap compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'launcher.cpp') /Febeamrt_startup_host.exe /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') bcrypt.lib shell32.lib
    if($LASTEXITCODE){throw 'Review startup host compilation failed'}
    if($RunProcessTests -or $RunDeviceTests -or $RunEntryTests -or $RunImportTests -or $RunPipelineStartupTests -or $RunBindingStartupTests -or $RunLoaderTests -or $RunResourceStartupTests){
        # Separate disposable variants; fault behavior is absent from production.
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'fixture_target.cpp') /Febeamrt_startup_fixture.exe /link /subsystem:windows shell32.lib
        if($LASTEXITCODE){throw 'Disposable target compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /DBEAMRT_STARTUP_TEST_FAULTS /I (Join-Path $beamrtDetours 'include') (Join-Path $PSScriptRoot 'launcher.cpp') /Febeamrt_startup_fault_host.exe /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') bcrypt.lib shell32.lib
        if($LASTEXITCODE){throw 'Disposable fault host compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD /DBEAMRT_PIPELINE_HANDOFF /DBEAMRT_BINDING_EMBEDDED /DBEAMRT_RESOURCE_EMBEDDED /DBEAMRT_STARTUP_TEST_NO_RECEIPT /I (Join-Path $beamrtDetours 'include') @beamrtBootstrapSources /Febeamrt_startup_no_receipt.dll /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') '/export:DetourFinishHelperProcess,@1,NONAME'
        if($LASTEXITCODE){throw 'Disposable no-receipt bootstrap compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'process_test.cpp') /Febeamrt_startup_process_test.exe /link bcrypt.lib
        if($LASTEXITCODE){throw 'Disposable process harness compilation failed'}
        & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'device_fixture.cpp') /Febeamrt_device_fixture.exe /link /subsystem:windows shell32.lib d3d12.lib dxgi.lib
        if($LASTEXITCODE){throw 'Disposable device fixture compilation failed'}
        if($RunEntryTests){
            & ml64.exe /nologo /c /Foentry_fixture_thunk.obj (Join-Path $PSScriptRoot 'entry_fixture_thunk.asm')
            if($LASTEXITCODE){throw 'Disposable original-entry thunk assembly failed'}
            & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'entry_fixture.cpp') entry_fixture_thunk.obj /Febeamrt_entry_fixture.exe /link /subsystem:windows /entry:BeamRT_EntryFixtureEntry shell32.lib d3d12.lib dxgi.lib
            if($LASTEXITCODE){throw 'Disposable entry fixture compilation failed'}
            foreach($beamrtVariant in @('passive','auto','fail')){
                $beamrtEntryDefines=@('/DBEAMRT_ENTRY_TEST_FRAME')
                if($beamrtVariant -ne 'passive'){$beamrtEntryDefines+='/DBEAMRT_ENTRY_FIXTURE_AUTOSTART'}
                if($beamrtVariant -eq 'fail'){$beamrtEntryDefines+='/DBEAMRT_ENTRY_FIXTURE_INIT_FAIL'}
                & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD /DBEAMRT_PIPELINE_HANDOFF /DBEAMRT_BINDING_EMBEDDED /DBEAMRT_RESOURCE_EMBEDDED @beamrtEntryDefines /I (Join-Path $beamrtDetours 'include') @beamrtBootstrapSources "/Febeamrt_entry_${beamrtVariant}_fixture.dll" /link (Join-Path $beamrtDetours 'lib.X64/detours.lib') '/export:DetourFinishHelperProcess,@1,NONAME'
                if($LASTEXITCODE){throw "Disposable $beamrtVariant entry bootstrap compilation failed"}
            }
        }
        if($RunImportTests -or $RunLoaderTests){
            & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'import_fixture.cpp') /Febeamrt_import_fixture.exe /link /subsystem:windows shell32.lib d3d12.lib dxgi.lib
            if($LASTEXITCODE){throw 'Disposable import fixture compilation failed'}
            $beamrtOrdinalDefinition=Join-Path $PSScriptRoot 'import_ordinal_fixture.def'
            & lib.exe /nologo "/def:$beamrtOrdinalDefinition" /machine:x64 /out:beamrt_d3d12_ordinal_fixture.lib
            if($LASTEXITCODE){throw 'Test-only ordinal import library failed'}
            & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /DBEAMRT_IMPORT_ORDINAL_FIXTURE (Join-Path $PSScriptRoot 'import_fixture.cpp') /Febeamrt_import_ordinal_fixture.exe /link /subsystem:windows shell32.lib beamrt_d3d12_ordinal_fixture.lib dxgi.lib
            if($LASTEXITCODE){throw 'Disposable ordinal import fixture compilation failed'}
        }
        if($RunLoaderTests){
            & lib.exe /nologo "/def:$(Join-Path $PSScriptRoot 'loader_missing_fixture.def')" /machine:x64 /out:beamrt_missing_loader_fixture.lib
            if($LASTEXITCODE){throw 'Test-only missing-dependency import library failed'}
            & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'loader_missing_fixture.cpp') /Febeamrt_loader_missing_fixture.exe /link /subsystem:windows beamrt_missing_loader_fixture.lib
            if($LASTEXITCODE){throw 'Disposable unresolved-dependency loader control compilation failed'}
        }
        if($RunPipelineStartupTests){
            & fxc.exe /nologo /Ges /WX /Od /T ps_5_0 /E mainP /Fo fixture.alt.ps.cso (Join-Path $beamrtRoot 'native/capture/fixture.hlsl')
            if($LASTEXITCODE){throw 'Alternate valid pixel shader compilation failed'}
            & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'pipeline_startup_fixture.cpp') /Febeamrt_pipeline_startup_fixture.exe /link /subsystem:windows shell32.lib d3d12.lib dxgi.lib bcrypt.lib
            if($LASTEXITCODE){throw 'Startup-connected creation fixture compilation failed'}
        }
        if($RunBindingStartupTests -or $RunResourceStartupTests){
            & fxc.exe /nologo /Ges /WX /T vs_5_0 /E mainV /Fo binding.vs.cso (Join-Path $PSScriptRoot 'binding_fixture.hlsl')
            if($LASTEXITCODE){throw 'Startup binding vertex fixture compilation failed'}
            & fxc.exe /nologo /Ges /WX /T ps_5_0 /E mainP /Fo binding.ps.cso (Join-Path $PSScriptRoot 'binding_fixture.hlsl')
            if($LASTEXITCODE){throw 'Startup binding pixel fixture compilation failed'}
            & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'binding_startup_fixture.cpp') /Febeamrt_binding_startup_fixture.exe /link /subsystem:windows shell32.lib d3d12.lib dxgi.lib
            if($LASTEXITCODE){throw 'Startup binding fixture compilation failed'}
        }
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
if($RunEntryTests){
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput --entry
    if($LASTEXITCODE){throw 'Disposable native-entry rendezvous validation failed'}
}
if($RunLoaderTests){
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput --loader
    if($LASTEXITCODE){throw 'Disposable loader evidence controls failed'}
}
if($RunImportTests){
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput --import
    if($LASTEXITCODE){throw 'Disposable import observer validation failed'}
}
if($RunPipelineStartupTests){
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput --pipeline
    if($LASTEXITCODE){throw 'Startup-connected pipeline audit fixture failed'}
}
if($RunBindingStartupTests){
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput --bindings
    if($LASTEXITCODE){throw 'Startup-connected binding observation fixture failed'}
}
if($RunResourceStartupTests){
    $beamrtResourceMode=if($WarpResourceStartupOnly){'--resources-warp'}else{'--resources'}
    & (Join-Path $beamrtOutput 'beamrt_startup_process_test.exe') $beamrtOutput $beamrtResourceMode
    if($LASTEXITCODE){throw 'Startup-connected resource observation fixture failed'}
}
foreach($beamrtName in @('beamrt_startup_host.exe','beamrt_startup_bootstrap.dll')){
    $beamrtPath=Join-Path $beamrtOutput $beamrtName
    $beamrtHash=(Get-FileHash -LiteralPath $beamrtPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "$beamrtName SHA-256: $beamrtHash"
}
Write-Output "Startup artifacts: $beamrtOutput. Process-test opt-in=$RunProcessTests; device-test opt-in=$RunDeviceTests; import-test opt-in=$RunImportTests; pipeline-test opt-in=$RunPipelineStartupTests; no BeamNG deployment, game launch or game-file changes."
