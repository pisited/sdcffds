param([switch]$RunTest,[switch]$Warp,[switch]$RunCompactTests,[switch]$RunInternedTests)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Offline-only, fresh artifacts. Never call the startup/capture/worker build or
# replace their frozen DLLs. No dependency download, game path or launch option.
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
$beamrtSdkCandidates=@((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10,
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'))
$beamrtSdk=$beamrtSdkCandidates | Where-Object {$_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin'))} | Select-Object -First 1
if(!$beamrtSdk){throw 'Existing SDK directory unavailable; no install attempted.'}
$beamrtFxc=Get-ChildItem (Join-Path $beamrtSdk 'bin') -Directory | Sort-Object Name -Descending |
    ForEach-Object {Join-Path $_.FullName 'x64/fxc.exe'} | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
if(!$beamrtFxc){throw 'Existing SDK FXC unavailable; no install attempted.'}
$beamrtOutput=Join-Path $beamrtRoot ('.beamrt-validation/resource-tracker-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
$beamrtSources=@('build_resource_tracker.ps1','resource_tracker.h','resource_record.h','resource_copy_diagnostics.h','resource_copy_validation.h','resource_view_validation.h','resource_profile.h','resource_storage_validation.h','descriptor_view_store.h','descriptor_location_store.h','resource_view_storage.h','resource_tracker.cpp','resource_slots.c','resource_fixture.cpp','binding_test_support.h',
    'gi_bindings.h','gi_bindings.cpp','binding_slots.c','binding_validation.h','binding_thread_diagnostics.h','gi_root_layout.h',
    'pipeline_audit.h','pipeline_audit.cpp','pipeline_slots.c','pipeline_root_metadata.h','startup_contract.h','binding_handoff.h','resource_handoff.h','binding_fixture.hlsl','root_inspect.cpp')
foreach($beamrtName in $beamrtSources){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $beamrtName) -Destination (Join-Path $beamrtOutput $beamrtName)}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD resource_tracker.cpp resource_slots.c /Febeamrt_resource_tracker.dll
    if($LASTEXITCODE){throw 'Offline resource tracker compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD pipeline_audit.cpp pipeline_slots.c /Febeamrt_pipeline_audit.dll
    if($LASTEXITCODE){throw 'Fixture-only creation observer compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD gi_bindings.cpp binding_slots.c /Febeamrt_gi_bindings.dll /link beamrt_pipeline_audit.lib d3d12.lib
    if($LASTEXITCODE){throw 'Fixture-only recording observer compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT root_inspect.cpp /Febeamrt_root_inspect.exe /link d3d12.lib
    if($LASTEXITCODE){throw 'Fixture root inspector compilation failed'}
    & $beamrtFxc /nologo /Ges /WX /T vs_5_0 /E mainV /Fo binding.vs.cso binding_fixture.hlsl
    if($LASTEXITCODE){throw 'Fixture vertex shader compilation failed'}
    & $beamrtFxc /nologo /Ges /WX /T ps_5_0 /E mainP /Fo binding.ps.cso binding_fixture.hlsl
    if($LASTEXITCODE){throw 'Fixture pixel shader compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT resource_fixture.cpp resource_slots.c /Febeamrt_resource_fixture.exe /link beamrt_resource_tracker.lib beamrt_gi_bindings.lib beamrt_pipeline_audit.lib d3d12.lib dxgi.lib
    if($LASTEXITCODE){throw 'Resource-to-recording fixture compilation failed'}
    & ./beamrt_root_inspect.exe --fixture-root-out fixture-root.bin
    if($LASTEXITCODE){throw 'Fixture-owned root generation failed'}
    $beamrtArguments=@('binding.vs.cso','binding.ps.cso','fixture-root.bin')
    if($Warp){$beamrtArguments+='--warp'}
    if($RunTest){
        foreach($beamrtVariant in @('heap','resource','view','draw','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')){
            $beamrtVariantArguments=@($beamrtArguments)
            if($beamrtVariant -eq 'overlap'){$beamrtVariantArguments+='--overlap-first'}
            elseif($beamrtVariant -ne 'heap'){$beamrtVariantArguments+="--$beamrtVariant-pressure"}
            & ./beamrt_resource_fixture.exe @beamrtVariantArguments 2>&1 | Tee-Object -FilePath "fixture-$beamrtVariant.log"
            if($LASTEXITCODE){throw "Offline resource-to-recording $beamrtVariant fixture failed"}
        }
        foreach($beamrtVariant in @('normal','resource','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')){
            $beamrtVariantArguments=@($beamrtArguments)+@('--descriptor-mode')
            if($beamrtVariant -eq 'resource'){$beamrtVariantArguments+='--resource-pressure'}
            elseif($beamrtVariant -eq 'overlap'){$beamrtVariantArguments+='--overlap-first'}
            elseif($beamrtVariant -like 'copy*'){$beamrtVariantArguments+="--$beamrtVariant-pressure"}
            & ./beamrt_resource_fixture.exe @beamrtVariantArguments 2>&1 | Tee-Object -FilePath "fixture-descriptor-$beamrtVariant.log"
            if($LASTEXITCODE){throw "Offline descriptor-admission $beamrtVariant fixture failed"}
        }
    }
    # Explicit opt-in only: the established 18 legacy-profile processes above
    # remain unchanged, including their original location/payload budget.
    if($RunCompactTests){
        foreach($beamrtVariant in @('normal','location','payload','byte')){
            $beamrtVariantArguments=@($beamrtArguments)+@('--descriptor-mode','--compact-storage')
            if($beamrtVariant -ne 'normal'){$beamrtVariantArguments+="--compact-$beamrtVariant-pressure"}
            & ./beamrt_resource_fixture.exe @beamrtVariantArguments 2>&1 | Tee-Object -FilePath "fixture-compact-$beamrtVariant.log"
            if($LASTEXITCODE){throw "Offline compact-storage $beamrtVariant fixture failed"}
        }
    }
    # Heap-interned representation is a separate explicit API/profile opt-in.
    # Its byte budget is reached before the logical 4096-location limit; the
    # CPU Store fixture, rather than the outer heap guard, tests its directory.
    if($RunInternedTests){
        foreach($beamrtVariant in @('normal','payload','byte')){
            $beamrtVariantArguments=@($beamrtArguments)+@('--descriptor-mode','--interned-storage')
            if($beamrtVariant -ne 'normal'){$beamrtVariantArguments+="--interned-$beamrtVariant-pressure"}
            & ./beamrt_resource_fixture.exe @beamrtVariantArguments 2>&1 | Tee-Object -FilePath "fixture-interned-$beamrtVariant.log"
            if($LASTEXITCODE){throw "Offline interned-storage $beamrtVariant fixture failed"}
        }
    }
}finally{
    Pop-Location
    $beamrtFiles=@(Get-ChildItem -LiteralPath $beamrtOutput -File)
    $beamrtFiles | ForEach-Object {Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256} |
        Select-Object Path,Hash | Export-Csv -LiteralPath (Join-Path $beamrtOutput 'artifacts.sha256.csv') -NoTypeInformation
    Write-Output "Offline resource artifacts: $beamrtOutput. No startup build, BeamNG loading or lighting change."
}
