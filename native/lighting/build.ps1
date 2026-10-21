param([Parameter(Mandatory=$true)][string]$NativeIncludes,[switch]$RunTest,[switch]$Warp)
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Reuse compiler discovery; builds only ignored offline artifacts.
& (Join-Path $beamrtRoot 'native/shadows/build.ps1') -NativeIncludes $NativeIncludes
if($LASTEXITCODE){throw 'Existing offline shader toolchain preparation failed'}
$beamrtFxc=(Get-Command fxc.exe -ErrorAction Stop).Source
$beamrtOutput=Join-Path $beamrtRoot '.beamrt-validation/lighting-history'
[IO.Directory]::CreateDirectory($beamrtOutput)|Out-Null
& $beamrtFxc /nologo /Ges /WX /O3 /T vs_5_0 /E main /Fo (Join-Path $beamrtOutput 'fixture.vs.cso') (Join-Path $PSScriptRoot 'fixture.vs.hlsl')
if($LASTEXITCODE){throw 'History fixture vertex compilation failed'}
foreach($beamrtEntry in @('beamrtMomentsP_v001.hlsl','beamrtTemporalP_v071.hlsl','beamrtReflectionTemporalP_v038.hlsl',
    'beamrtReflectionMomentsP_v001.hlsl','beamrtReflectionAtrousP_v002.hlsl','beamrtReflectionAtrousP_v003.hlsl')){
    & $beamrtFxc /nologo /Ges /WX /O3 /T ps_5_0 /E main /I $beamrtRoot /I $NativeIncludes /Fo (Join-Path $beamrtOutput "$beamrtEntry.ps.cso") (Join-Path $beamrtRoot "shaders/beamrt/$beamrtEntry")
    if($LASTEXITCODE){throw "History shader compilation failed: $beamrtEntry"}
}
# Read the real Lua format fields, not a separately hardcoded fixture format.
$beamrtLua=Get-Content -LiteralPath (Join-Path $beamrtRoot 'lua/ge/extensions/beamrt/main.lua') -Raw
$beamrtFormats=@()
foreach($beamrtTarget in @('CurrentMoments','HistoryMoments')){
    $beamrtMatch=[regex]::Match($beamrtLua,'(?s):setField\("target", 0, "#BeamRT_'+$beamrtTarget+'"\).*?:setField\("targetFormat", 0, "(GFXFormatR(?:16G16B16A16|32G32B32A32)F)"\)')
    if(!$beamrtMatch.Success){throw "Literal GI moments format unavailable: $beamrtTarget"}
    $beamrtFormats+=if($beamrtMatch.Groups[1].Value -eq 'GFXFormatR16G16B16A16F'){'16'}else{'32'}
}
if($beamrtFormats[0] -ne $beamrtFormats[1]){throw 'Current/history GI moments formats differ'}
Push-Location $beamrtOutput
try{
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'self_test.cpp') /Febeamrt_history_shader_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'History shader GPU fixture compilation failed'}
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'reflection_filter_test.cpp') /Febeamrt_reflection_filter_test.exe /link d3d12.lib dxgi.lib d3dcompiler.lib
    if($LASTEXITCODE){throw 'Reflection filter GPU fixture compilation failed'}
}finally{Pop-Location}
if($RunTest){
    $beamrtArgs=@($beamrtOutput,$beamrtFormats[0]);if($Warp){$beamrtArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_history_shader_test.exe') @beamrtArgs
    if($LASTEXITCODE){throw 'Offline lighting-history shader regression failed'}
    $beamrtFilterArgs=@($beamrtOutput);if($Warp){$beamrtFilterArgs+='--warp'}
    & (Join-Path $beamrtOutput 'beamrt_reflection_filter_test.exe') @beamrtFilterArgs
    if($LASTEXITCODE){throw 'Offline reflection filter regression failed'}
}
Write-Output "History artifacts: $beamrtOutput; Lua-selected GI moments format: $($beamrtFormats[0]). No BeamNG execution."
