param([switch]$RunTest,[switch]$Warp)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Existing toolchain and existing shader fixtures only; no new tracing algorithm.
& (Join-Path $beamrtRoot 'native/capture/build.ps1')
if($LASTEXITCODE){throw 'Fixture/toolchain preparation failed'}
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/pipeline-audit'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
Push-Location $beamrtOutput
try {
    & fxc.exe /nologo /Ges /WX /Od /T vs_5_0 /E mainV /Fo fixture.alt.vs.cso (Join-Path $beamrtRoot 'native/capture/fixture.hlsl')
    if($LASTEXITCODE){throw 'Alternate valid shader fixture compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT /LD (Join-Path $PSScriptRoot 'pipeline_audit.cpp') (Join-Path $PSScriptRoot 'pipeline_slots.c') /Febeamrt_pipeline_audit.dll /link
    if($LASTEXITCODE){throw 'Pipeline creation audit compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'pipeline_fixture.cpp') (Join-Path $PSScriptRoot 'pipeline_slots.c') /Febeamrt_pipeline_fixture.exe /link beamrt_pipeline_audit.lib d3d12.lib dxgi.lib
    if($LASTEXITCODE){throw 'Pipeline creation fixture compilation failed'}
    if($RunTest){
        $beamrtFixtureArgs=@((Join-Path $beamrtRoot '.beamrt-validation/native-capture/fixture.vs.cso'),(Join-Path $beamrtRoot '.beamrt-validation/native-capture/fixture.ps.cso'),(Join-Path $beamrtOutput 'fixture.alt.vs.cso'))
        if($Warp){$beamrtFixtureArgs+='--warp'}
        & ./beamrt_pipeline_fixture.exe @beamrtFixtureArgs
        if($LASTEXITCODE){throw 'Pipeline audit fixture failed'}
        & ./beamrt_pipeline_fixture.exe @beamrtFixtureArgs --conflict
        if($LASTEXITCODE){throw 'Pipeline audit conflict fixture failed'}
    }
}finally{Pop-Location}
Write-Output "Standalone pipeline audit artifacts: $beamrtOutput. This build/test does not start the startup host, game capture or GI."
