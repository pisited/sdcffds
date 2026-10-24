param([string]$SettingsDirectory='C:/Users/ab/AppData/Local/BeamNG/BeamNG.drive/current/settings')
$ErrorActionPreference='Stop'
$beamrtRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$beamrtArtifacts=Join-Path $beamrtRoot '.beamrt-validation/vehicle-gpu-probe'
$beamrtExecutable=Join-Path $beamrtArtifacts 'beamrt_vehicle_gpu_probe.exe'
$beamrtShader=Join-Path $beamrtArtifacts 'trace.cso'
$beamrtSettings=[IO.Path]::GetFullPath($SettingsDirectory)
if(!(Test-Path -LiteralPath $beamrtExecutable) -or !(Test-Path -LiteralPath $beamrtShader)){throw 'Build and test the GPU helper before starting it.'}
if(!(Test-Path -LiteralPath $beamrtSettings -PathType Container)){throw 'Existing BeamNG settings directory required.'}
$beamrtConfig=Join-Path $beamrtSettings 'beamrtGpuProbeEndpoint.json'
if(Test-Path -LiteralPath $beamrtConfig){
    $beamrtPrevious=Get-Content -LiteralPath $beamrtConfig -Raw|ConvertFrom-Json
    if($beamrtPrevious.host -eq '127.0.0.1' -and $beamrtPrevious.expires -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()){
        $beamrtListening=Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $beamrtPrevious.port -State Listen -ErrorAction SilentlyContinue
        if($beamrtListening){throw 'An unexpired local GPU endpoint is still listening; use that session before starting another.'}
    }
}
$beamrtStamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$beamrtStdout=Join-Path $beamrtArtifacts ('live-'+$beamrtStamp+'.stdout.log')
$beamrtStderr=Join-Path $beamrtArtifacts ('live-'+$beamrtStamp+'.stderr.log')
$beamrtStarted=[DateTime]::UtcNow
$beamrtProcess=Start-Process -FilePath $beamrtExecutable -ArgumentList @(('"'+$beamrtShader+'"'),('"'+$beamrtConfig+'"')) -WindowStyle Hidden -RedirectStandardOutput $beamrtStdout -RedirectStandardError $beamrtStderr -PassThru
$beamrtReady=$false
for($beamrtAttempt=0;$beamrtAttempt -lt 100;$beamrtAttempt++){
    if($beamrtProcess.HasExited){throw ('GPU helper exited: '+(Get-Content -LiteralPath $beamrtStderr -Raw))}
    if((Test-Path -LiteralPath $beamrtConfig) -and (Get-Item -LiteralPath $beamrtConfig).LastWriteTimeUtc -ge $beamrtStarted){
        $beamrtEndpoint=Get-Content -LiteralPath $beamrtConfig -Raw|ConvertFrom-Json
        if($beamrtEndpoint.schema -eq 'beamrt.gpu-ray-probe.v1' -and $beamrtEndpoint.host -eq '127.0.0.1' -and $beamrtEndpoint.hardware -eq $true){$beamrtReady=$true;break}
    }
    Start-Sleep -Milliseconds 100
}
if(!$beamrtReady){throw 'GPU helper readiness not confirmed; inspect its private logs.'}
$beamrtReceipt=@{pid=$beamrtProcess.Id;startedUtc=$beamrtStarted.ToString('o');expires=$beamrtEndpoint.expires;
    port=$beamrtEndpoint.port;executableSha256=(Get-FileHash -LiteralPath $beamrtExecutable -Algorithm SHA256).Hash;
    shaderSha256=(Get-FileHash -LiteralPath $beamrtShader -Algorithm SHA256).Hash;
    stdout=$beamrtStdout;stderr=$beamrtStderr;gameIntegrationVerified=$false}
$beamrtReceipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $beamrtArtifacts ('live-'+$beamrtStamp+'.receipt.json')) -Encoding utf8
Write-Output ('Local hardware GPU helper ready for one batch; expires in 10 minutes. Process '+$beamrtProcess.Id+'. No game attachment.')
