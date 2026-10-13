param([switch]$RunTest,[switch]$Warp,[string]$InspectRoot)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& (Join-Path $beamrtRoot 'native/capture/build.ps1')
if($LASTEXITCODE){throw 'Existing toolchain preparation failed'}
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/gi-bindings'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'root_inspect.cpp') /Febeamrt_root_inspect.exe /link d3d12.lib
    if($LASTEXITCODE){throw 'CPU root inspector compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD (Join-Path $PSScriptRoot 'pipeline_audit.cpp') (Join-Path $PSScriptRoot 'pipeline_slots.c') /Febeamrt_pipeline_audit.dll /link
    if($LASTEXITCODE){throw 'Standalone creation-audit dependency compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD (Join-Path $PSScriptRoot 'gi_bindings.cpp') (Join-Path $PSScriptRoot 'binding_slots.c') /Febeamrt_gi_bindings.dll /link beamrt_pipeline_audit.lib d3d12.lib
    if($LASTEXITCODE){throw 'Standalone binding observer compilation failed'}
    & fxc.exe /nologo /Ges /WX /T vs_5_0 /E mainV /Fo binding.vs.cso (Join-Path $PSScriptRoot 'binding_fixture.hlsl')
    if($LASTEXITCODE){throw 'Binding fixture vertex compilation failed'}
    & fxc.exe /nologo /Ges /WX /T ps_5_0 /E mainP /Fo binding.ps.cso (Join-Path $PSScriptRoot 'binding_fixture.hlsl')
    if($LASTEXITCODE){throw 'Binding fixture pixel compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'binding_fixture.cpp') (Join-Path $PSScriptRoot 'binding_slots.c') /Febeamrt_binding_fixture.exe /link beamrt_gi_bindings.lib beamrt_pipeline_audit.lib d3d12.lib dxgi.lib
    if($LASTEXITCODE){throw 'Binding fixture compilation failed'}
    if($InspectRoot){
        & ./beamrt_root_inspect.exe $InspectRoot
        if($LASTEXITCODE){throw 'SDK root inspection failed'}
    }
    if($RunTest){
        $beamrtTestRoot=$InspectRoot
        if(!$beamrtTestRoot){
            # CI/disposable SDK layout; never claim this came from the game.
            $beamrtTestRoot=Join-Path $beamrtOutput ('fixture-root-'+[Guid]::NewGuid().ToString('N')+'.bin')
            & ./beamrt_root_inspect.exe --fixture-root-out $beamrtTestRoot
            if($LASTEXITCODE){throw 'Owned fixture root generation failed'}
        }
        $beamrtArgs=@('binding.vs.cso','binding.ps.cso',$beamrtTestRoot)
        if($Warp){$beamrtArgs+='--warp'}
        & ./beamrt_binding_fixture.exe @beamrtArgs
        if($LASTEXITCODE){throw 'Binding recording fixture failed'}
    }
}finally{Pop-Location}
Write-Output "Binding-inspection artifacts: $beamrtOutput. No BeamNG launch, loading or lighting change."
