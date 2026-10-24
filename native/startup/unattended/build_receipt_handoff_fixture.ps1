param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$beamrtRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$beamrtWork = Join-Path $beamrtRoot '.beamrt-validation/early-shim-ack-b7a090e8687b4adaa6a9cd7eb509e2b8'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $beamrtWork ('receipt-handoff-fixture-' + [Guid]::NewGuid().ToString('N')) }
$beamrtOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (!$beamrtOutput.StartsWith($beamrtWork + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The fixed disposable build must be a fresh child directory inside the current handoff preparation.'
}
if (Test-Path -LiteralPath $beamrtOutput) { throw 'Refusing to overwrite an existing output directory.' }

# Fixed read-only inputs only: no target option, dependency install, rebuild of
# the startup host/DLL, test execution, or BeamNG loading exists in this script.
$beamrtFrozen = Join-Path $beamrtRoot '.beamrt-validation/native-startup-resource-e96d984928844cce8d4f8e2882c5be70'
$beamrtInputs = @(
    @{ Name='beamrt_startup_host.exe'; Path=(Join-Path $beamrtWork 'build/beamrt_startup_host.exe'); SHA256='fe36d8067fa1b8bc128a2fc2df880011a1b5a46d9a666d6e1022418d2b7dda55' },
    @{ Name='beamrt_startup_bootstrap.dll'; Path=(Join-Path $beamrtFrozen 'beamrt_startup_bootstrap.dll'); SHA256='e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38' },
    @{ Name='binding.vs.cso'; Path=(Join-Path $beamrtFrozen 'binding.vs.cso'); SHA256='5574ee84b01de3c361fd083c3cc918bd893cc0f4a9c862e18d65983ab459811f' },
    @{ Name='binding.ps.cso'; Path=(Join-Path $beamrtFrozen 'binding.ps.cso'); SHA256='0b41369f3dce102dedb50e049bd08f3dfdd86626995d1609da36543023f7a09f' }
)
foreach ($beamrtInput in $beamrtInputs) {
    if ((Get-FileHash -LiteralPath $beamrtInput.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $beamrtInput.SHA256) {
        throw ('Frozen handoff fixture input changed: ' + $beamrtInput.Name)
    }
}
if (!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or !$env:INCLUDE -or !$env:LIB) {
    $beamrtVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $beamrtInstallation = & $beamrtVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$beamrtInstallation) { throw 'MSVC x64 tools unavailable; no installer will be run.' }
    $beamrtVcvars = Join-Path $beamrtInstallation 'VC/Auxiliary/Build/vcvars64.bat'
    $beamrtEnvironment = & $env:COMSPEC /d /c "`"$beamrtVcvars`" >nul && set"
    if ($LASTEXITCODE) { throw 'MSVC environment initialization failed.' }
    foreach ($beamrtLine in $beamrtEnvironment) {
        if ($beamrtLine -match '^(PATH|INCLUDE|LIB|LIBPATH)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}
[IO.Directory]::CreateDirectory($beamrtOutput) | Out-Null
foreach ($beamrtInput in $beamrtInputs) {
    $beamrtDestination = Join-Path $beamrtOutput $beamrtInput.Name
    Copy-Item -LiteralPath $beamrtInput.Path -Destination $beamrtDestination
    if ((Get-FileHash -LiteralPath $beamrtDestination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $beamrtInput.SHA256) {
        throw ('Copied handoff fixture input changed: ' + $beamrtInput.Name)
    }
}
Push-Location $beamrtOutput
try {
    & cl.exe /nologo /W4 /WX /EHsc /std:c++17 /MT (Join-Path $PSScriptRoot 'receipt_handoff_child.cpp') /Febeamrt_binding_startup_fixture.exe /link /SUBSYSTEM:WINDOWS shell32.lib d3d12.lib dxgi.lib
    if ($LASTEXITCODE) { throw 'Disposable real-receipt handoff child compilation failed.' }
} finally { Pop-Location }
foreach ($beamrtName in @('beamrt_binding_startup_fixture.exe') + @($beamrtInputs.Name)) {
    $beamrtHash = (Get-FileHash -LiteralPath (Join-Path $beamrtOutput $beamrtName) -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "$beamrtName SHA-256: $beamrtHash"
}
Write-Output "Fixed real-receipt handoff fixture artifacts: $beamrtOutput. Build only: no native fixture, startup host, DLL or BeamNG was executed."
