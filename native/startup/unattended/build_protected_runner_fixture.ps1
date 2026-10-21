param([switch]$RunTests, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$beamrtRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$beamrtValidation = Join-Path $beamrtRoot '.beamrt-validation'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $beamrtValidation ('protected-runner-fixture-' + [Guid]::NewGuid().ToString('N')) }
$beamrtOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (!$beamrtOutput.StartsWith($beamrtValidation + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $beamrtOutput)) {
    throw 'A fresh output directory inside project validation is required.'
}
$beamrtPython = Join-Path $beamrtValidation 'python-tests/Scripts/python.exe'
if (!(Test-Path -LiteralPath $beamrtPython -PathType Leaf)) { throw 'Pinned project test Python missing; no install will be performed.' }
# This preparation borrows only already-built exact disposable artifacts. It
# cannot compile/select BeamNG or dispatch any game execution profile.
$beamrtArtifacts = Join-Path $beamrtValidation 'early-shim-ack-b7a090e8687b4adaa6a9cd7eb509e2b8/receipt-handoff-fixture-0aac44691eb242b3a778f2a8bb9c7940'
$beamrtDecoder = Join-Path $beamrtValidation 'prepared-interned-observation-33567a29140a4465a2d4e18ed6a85d5b/analyzer/receipt_decoder.exe'
$beamrtPins = @{
    host=@{Leaf='beamrt_startup_host.exe';SHA='fe36d8067fa1b8bc128a2fc2df880011a1b5a46d9a666d6e1022418d2b7dda55'}
    target=@{Leaf='beamrt_binding_startup_fixture.exe';SHA='99c4e0713a7aa39a98d43ce8930633ef29b76fa7c940eb627aca9292fe1d182e'}
    dll=@{Leaf='beamrt_startup_bootstrap.dll';SHA='e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38'}
    vertex=@{Leaf='binding.vs.cso';SHA='5574ee84b01de3c361fd083c3cc918bd893cc0f4a9c862e18d65983ab459811f'}
    pixel=@{Leaf='binding.ps.cso';SHA='0b41369f3dce102dedb50e049bd08f3dfdd86626995d1609da36543023f7a09f'}
    decoder=@{Leaf='receipt_decoder.exe';SHA='0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804'}
}
$beamrtFiles = @{}
foreach ($beamrtRole in $beamrtPins.Keys) {
    $beamrtPath = if ($beamrtRole -eq 'decoder') { $beamrtDecoder } else { Join-Path $beamrtArtifacts $beamrtPins[$beamrtRole].Leaf }
    if ((Get-FileHash -LiteralPath $beamrtPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $beamrtPins[$beamrtRole].SHA) { throw ('Fixed fixture pin changed: ' + $beamrtRole) }
    $beamrtFiles[$beamrtRole] = @{path=$beamrtPath;sha256=$beamrtPins[$beamrtRole].SHA}
}
[IO.Directory]::CreateDirectory($beamrtOutput) | Out-Null
$beamrtCode = Join-Path $beamrtOutput 'code'
[IO.Directory]::CreateDirectory($beamrtCode) | Out-Null
$beamrtHelpers = @{}
foreach ($beamrtLeaf in @('protected_runner.py','protected_inputs.py','startup_plan.py','receipt_ack.py','receipt_handoff.py','receipt_handoff_fixture.py')) {
    $beamrtSource = Join-Path $PSScriptRoot $beamrtLeaf
    $beamrtDestination = Join-Path $beamrtCode $beamrtLeaf
    Copy-Item -LiteralPath $beamrtSource -Destination $beamrtDestination
    $beamrtHash = (Get-FileHash -LiteralPath $beamrtDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-FileHash -LiteralPath $beamrtSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne $beamrtHash) { throw 'Frozen source copy changed.' }
    $beamrtHelpers[$beamrtLeaf] = @{path=$beamrtDestination;sha256=$beamrtHash}
}
$beamrtRunner = Join-Path $beamrtCode 'protected_runner.py'
$beamrtCases = @()
foreach ($beamrtCase in @('validated-ack','withheld-ack','wrong-review-digest')) {
    # Keep old native receipt writers below MAX_PATH; owner metadata long-path
    # support is not silently generalized to all core artifact writers.
    $beamrtRun = Join-Path $beamrtValidation ('pr-' + [Guid]::NewGuid().ToString('N').Substring(0,12))
    [IO.Directory]::CreateDirectory($beamrtRun) | Out-Null
    $beamrtCandidate = [ordered]@{schema=1;profile='fixed-warp-receipt-v1';files=$beamrtFiles;helpers=$beamrtHelpers;
        run_directory=$beamrtRun;token='0123456789abcdef0123456789abcdef';limits=@{overall_timeout=20;quit_grace=1;receipt_wait=5}}
    $beamrtCandidateFile = Join-Path $beamrtOutput ($beamrtCase + '.candidate.json')
    $beamrtCandidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $beamrtCandidateFile -Encoding utf8
    $beamrtReviewFile = Join-Path $beamrtOutput ($beamrtCase + '.review.json')
    & $beamrtPython -I -B $beamrtRunner --candidate $beamrtCandidateFile > $beamrtReviewFile
    if ($LASTEXITCODE) { throw 'Protected fixture review failed; no launch requested.' }
    if ((Get-ChildItem -LiteralPath $beamrtRun -Force).Count) { throw 'Review mode changed the run directory.' }
    $beamrtReview = Get-Content -LiteralPath $beamrtReviewFile -Raw | ConvertFrom-Json
    $beamrtCases += [pscustomobject]@{Case=$beamrtCase;Candidate=$beamrtCandidateFile;RunDirectory=$beamrtRun;Digest=$beamrtReview.candidateSHA256}
}
if ($RunTests) {
    foreach ($beamrtCase in $beamrtCases) {
        $beamrtAcknowledgement = if ($beamrtCase.Case -eq 'wrong-review-digest') { '0' * 64 } else { $beamrtCase.Digest }
        $beamrtExtra = @()
        if ($beamrtCase.Case -eq 'withheld-ack') { $beamrtExtra += '--withhold-fixture-ack' }
        $beamrtLog = Join-Path $beamrtOutput ($beamrtCase.Case + '.execution.log')
        & $beamrtPython -I -B $beamrtRunner --candidate $beamrtCase.Candidate --execute-reviewed-fixture --expected-candidate-sha256 $beamrtAcknowledgement @beamrtExtra *> $beamrtLog
        $beamrtExit = $LASTEXITCODE
        if ($beamrtCase.Case -eq 'wrong-review-digest') {
            if ($beamrtExit -ne 1 -or (Get-ChildItem -LiteralPath $beamrtCase.RunDirectory -Force).Count) { throw 'Wrong digest reached claim/process creation.' }
        } else {
            if ($beamrtExit) { Get-Content -LiteralPath $beamrtLog; throw ('Protected execution failed: ' + $beamrtCase.Case) }
            $beamrtResult = Get-Content -LiteralPath (Join-Path $beamrtCase.RunDirectory 'runner-result.json') -Raw | ConvertFrom-Json
            if ($beamrtResult.status -ne 'fixture_pass' -or !$beamrtResult.hostExitVerified -or !$beamrtResult.nativeReportedChildExitVerified -or $beamrtResult.independentChildExitVerified -or $beamrtResult.gameExecutionAvailable) { throw 'Protected result proof boundaries mismatched.' }
        }
        Write-Output ('PASS protected fixed fixture: ' + $beamrtCase.Case)
    }
    $beamrtPositive = $beamrtCases | Where-Object Case -eq 'validated-ack'
    $beamrtResultFile = Join-Path $beamrtPositive.RunDirectory 'runner-result.json'
    $beamrtBefore = (Get-FileHash -LiteralPath $beamrtResultFile -Algorithm SHA256).Hash
    & $beamrtPython -I -B $beamrtRunner --candidate $beamrtPositive.Candidate --execute-reviewed-fixture --expected-candidate-sha256 $beamrtPositive.Digest *> (Join-Path $beamrtOutput 'replay.execution.log')
    if ($LASTEXITCODE -ne 1 -or (Get-FileHash -LiteralPath $beamrtResultFile -Algorithm SHA256).Hash -ne $beamrtBefore) { throw 'Replay was not refused unchanged.' }
    Write-Output 'PASS protected fixed fixture: consumed-attempt replay refused unchanged'
}
$beamrtCases | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $beamrtOutput 'cases.csv')
Write-Output ('Protected fixture evidence: ' + $beamrtOutput)
Write-Output 'Game execution remains unavailable. No BeamNG target was selected or launched.'
# The final replay is an EXPECTED native exit1. Return this script's aggregate
# success explicitly instead of leaking that child status to its caller.
exit 0
