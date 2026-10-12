param([string]$Python='python',[switch]$SyntheticFixture,[switch]$RunTest,[switch]$Warp,[string]$NativeIncludes='')
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Reuse the existing packed-scene fixture and installed compiler discovery.
# This builds offline artifacts only; it does not start/modify BeamNG.
& (Join-Path $beamrtRoot 'native/worker/build.ps1') -Python $Python -SyntheticFixture:$SyntheticFixture
$beamrtFxc=(Get-Command fxc.exe -ErrorAction Stop).Source
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/native-gi'
[IO.Directory]::CreateDirectory($beamrtOutput) | Out-Null
function Compile-BeamRTGI([string]$Source,[string]$Target,[string]$Entry,[string]$Output,[string[]]$Extra=@()) {
    & $beamrtFxc /nologo /Ges /WX /O3 /T $Target /E $Entry /I $beamrtRoot @Extra /Fo (Join-Path $beamrtOutput $Output) $Source
    if($LASTEXITCODE) { throw "Shader compilation failed: $Source ($Target)" }
}
Compile-BeamRTGI (Join-Path $PSScriptRoot 'visibility.cs.hlsl') cs_5_0 main visibility.cso
Compile-BeamRTGI (Join-Path $PSScriptRoot 'consumer_test.hlsl') vs_5_0 mainV consumer.vs.cso
Compile-BeamRTGI (Join-Path $PSScriptRoot 'consumer_test.hlsl') ps_5_0 mainP consumer.ps.cso
if($NativeIncludes) {
    $beamrtIncludePath=[IO.Path]::GetFullPath($NativeIncludes)
    if(!(Test-Path -LiteralPath (Join-Path $beamrtIncludePath 'shaders/common/postFx/postFx.h.hlsl'))) { throw 'BeamNG include directory invalid; no game headers bundled.' }
    foreach($beamrtEntry in @('beamrtGITraceP_v082.hlsl','beamrtGITraceP_v083.hlsl','beamrtGITraceP_v084.hlsl','beamrtGIReceiverExportP_v001.hlsl')) {
        $beamrtSource=Join-Path $beamrtRoot "shaders/beamrt/$beamrtEntry"
        Compile-BeamRTGI $beamrtSource vs_5_0 main "$beamrtEntry.vs.cso" @('/I',$beamrtIncludePath,'/D','SHADER_STAGE_VS=1')
        $beamrtMain=if($beamrtEntry -like '*ReceiverExport*') {'beamrtReceiverMain'} else {'main'}
        Compile-BeamRTGI $beamrtSource ps_5_0 $beamrtMain "$beamrtEntry.ps.cso" @('/I',$beamrtIncludePath)
    }
}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD /LD (Join-Path $PSScriptRoot 'beamrt_gi.cpp') /Febeamrt_native_gi.dll /link d3d12.lib
    if($LASTEXITCODE) { throw 'Native GI resource adapter compilation failed' }
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MD (Join-Path $PSScriptRoot 'self_test.cpp') /Febeamrt_gi_test.exe /link beamrt_native_gi.lib d3d12.lib dxgi.lib
    if($LASTEXITCODE) { throw 'Native GI GPU test compilation failed' }
} finally { Pop-Location }
if($RunTest) {
    $beamrtArgs=@((Join-Path $beamrtRoot '.beamrt-validation/native-worker/fixture.bin'),(Join-Path $beamrtOutput 'visibility.cso'),(Join-Path $beamrtOutput 'consumer.vs.cso'),(Join-Path $beamrtOutput 'consumer.ps.cso'))
    if($Warp) { $beamrtArgs+='--warp' }
    & (Join-Path $beamrtOutput 'beamrt_gi_test.exe') @beamrtArgs
    if($LASTEXITCODE) { throw 'Offline native-to-GI validation failed' }
}
Write-Output "Offline GI artifacts: $beamrtOutput. No loading, injection or game installation."
