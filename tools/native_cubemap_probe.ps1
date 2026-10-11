#Requires -Version 7.2
[CmdletBinding()]
param(
  [ValidateSet('Stage', 'EnableMagenta', 'Disable', 'Status')]
  [string]$Action = 'Stage',
  [string]$GameRoot = 'E:\SteamLibrary\steamapps\common\BeamNG.drive',
  [string]$ModRoot = (Split-Path -Parent $PSScriptRoot)
)

# Opt-in diagnostic only. Never edits the game installation, deletes shader
# caches, restarts the game, or changes BeamRT/native graphics settings.
$ErrorActionPreference = 'Stop'
$probeId = 'beamrt-native-scene-cubemap-probe-v1'
$reviewedNativeHash = '48A97618E397F7DE5A09837939EF8C1E9862DD335808FB3477E2894D90D7C1DB'
$probeRoot = [IO.Path]::GetFullPath($ModRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $probeRoot -PathType Container)) { throw 'ModRoot must exist.' }
$probeGameRoot = [IO.Path]::GetFullPath($GameRoot).TrimEnd('\', '/')
if ($probeRoot.Equals($probeGameRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $probeRoot.StartsWith($probeGameRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $probeGameRoot.StartsWith($probeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The explicit mod root must not overlap the game installation.'
}
$nativePath = Join-Path $GameRoot 'shaders\common\material\shadergen\permutations.h.hlsl'
$targetPath = Join-Path $probeRoot 'shaders\common\material\shadergen\permutations.h.hlsl'
$workPath = Join-Path $probeRoot '.beamrt-validation\native-reflection-experiment'
$stagedPath = Join-Path $workPath 'staged\permutations.magenta.h.hlsl'
$manifestPath = Join-Path $probeRoot 'shaders\beamrt\nativeCubemapProbeManifest.json'
$statePath = Join-Path $workPath 'active-state.json'

function Assert-NoRedirectedAncestors([string]$Path) {
  $current = [IO.Path]::GetFullPath($Path)
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing a redirected/junction ancestor; use an ordinary explicit mod/source path.'
      }
    }
    $parent = [IO.Path]::GetDirectoryName($current)
    if ($parent -eq $current) { break }
    $current = $parent
  }
}

Assert-NoRedirectedAncestors $probeRoot
Assert-NoRedirectedAncestors $probeGameRoot

function Assert-ProbeOwnedPath([string]$Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($probeRoot + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase)) { throw 'Write/move target escaped the explicit mod root.' }
  Assert-NoRedirectedAncestors $resolved
  return $resolved
}

function Write-ProbeBytesAtomic([string]$Path, [byte[]]$Bytes, [bool]$Replace) {
  $resolved = Assert-ProbeOwnedPath $Path
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($resolved)) -Force | Out-Null
  $temporary = Assert-ProbeOwnedPath ($resolved + '.' + [Guid]::NewGuid().ToString('N') + '.pending')
  $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
  $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
  if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $expected) {
    throw 'Temporary publication hash mismatch. Live file was not replaced.'
  }
  # All bytes and ownership are durable before the single same-directory
  # rename. An interrupted preparation leaves only an unreferenced .pending
  # file, never a truncated live shader or a half-written ownership record.
  Assert-ProbeOwnedPath $resolved | Out-Null
  [IO.File]::Move($temporary, $resolved, $Replace)
}

function Read-ProbeJson([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-ProbeJson([string]$Path, $Value) {
  $resolved = Assert-ProbeOwnedPath $Path
  $old = Read-ProbeJson $resolved
  if ($old -and $old.experimentId -ne $probeId) { throw 'Refusing to replace an unowned JSON file.' }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 6))
  Write-ProbeBytesAtomic $resolved $bytes $true
}

function Get-ProbeStatus {
  $state = Read-ProbeJson $statePath
  $exists = Test-Path -LiteralPath $targetPath -PathType Leaf
  $actualHash = if ($exists) { (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash } else { $null }
  $nativeHash = if (Test-Path -LiteralPath $nativePath -PathType Leaf) {
    (Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash
  } else { $null }
  return [ordered]@{
    experimentId = $probeId
    activeOverrideOnDisk = $exists
    ownedOverride = [bool]($exists -and $state -and $state.experimentId -eq $probeId -and
      $state.overrideSha256 -eq $actualHash -and $state.target -eq $targetPath)
    target = $targetPath
    nativeSource = $nativePath
    nativeSourceMatchesReviewedVersion = [bool]($nativeHash -eq $reviewedNativeHash)
    diskSha256 = $actualHash
    nativeSha256 = $nativeHash
    manifest = $manifestPath
    vfsResolution = 'unverified; use the in-game inspector'
    gpuExecution = 'unverified; magenta appearance is required'
    refreshRequired = 'Full BeamNG restart after enabling or disabling; source changes alone do not prove live shader replacement.'
  }
}

function New-ProbeStage {
  if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) { throw 'Installed native shader not found.' }
  if ((Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash -ne $reviewedNativeHash) {
    throw 'Native shader differs from the reviewed version. Re-review before activating an override.'
  }
  $nativeSource = [IO.File]::ReadAllText($nativePath)
  $call = 'calculateCubeReflection(material, material.positionWS, material.instanceId, material.geomNormalWS)'
  if ([regex]::Matches($nativeSource, [regex]::Escape($call)).Count -ne 2) {
    throw 'Expected exactly two modern cubemap call sites; refusing a broad patch.'
  }
  $insertion = 'void processVisibility(inout Material material, float2 vPos) {'
  if ([regex]::Matches($nativeSource, [regex]::Escape($insertion)).Count -ne 1) {
    throw 'Expected exactly one helper insertion point.'
  }
  $hook = @'
// BEAMRT_NATIVE_SCENE_CUBEMAP_PROBE_V1: diagnostic, not suppression/replacement.
#ifndef BEAMRT_NATIVE_SCENE_CUBEMAP_TEST
#define BEAMRT_NATIVE_SCENE_CUBEMAP_TEST 1
#endif
float3 beamrtNativeSceneCubemapTint(float3 nativeContribution) {
#if BEAMRT_NATIVE_SCENE_CUBEMAP_TEST && defined(MFT_SceneCubeMap) && !defined(SHADERGEN_CUSTOM_MATERIAL_CBUFFER)
    // Native focus metadata is available only in ordinary material buffers.
    // Do not affect custom cubemap sources, custom material buffers or focused mirrors.
    if (!any(getMaterialData().reflectionVectorsPacked != 0)) {
        // Preserve the native environment lobe's linear luminance. Zero stays
        // zero; no flat diagnostic light, clipping or arbitrary gain is added.
        return float3(1.0, 0.0, 1.0) * (hdrLuminance(nativeContribution) / 0.2848);
    }
#endif
    return nativeContribution;
}

'@
  $generated = '// BEAMRT_OWNED_NATIVE_OVERRIDE_V1; source SHA256 ' + $reviewedNativeHash + "`n" +
    $nativeSource.Replace($call, ('beamrtNativeSceneCubemapTint(' + $call + ')'))
  $generated = $generated.Replace($insertion, ($hook + "`n" + $insertion))
  $resolvedStage = Assert-ProbeOwnedPath $stagedPath
  if (Test-Path -LiteralPath $resolvedStage -PathType Leaf) {
    if (-not ([IO.File]::ReadAllText($resolvedStage).StartsWith('// BEAMRT_OWNED_NATIVE_OVERRIDE_V1;'))) {
      throw 'Refusing to overwrite an unowned staged file.'
    }
  }
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($resolvedStage)) -Force | Out-Null
  Write-ProbeBytesAtomic $resolvedStage ([Text.UTF8Encoding]::new($false).GetBytes($generated)) $true
  $manifest = [ordered]@{
    experimentId = $probeId
    mode = 'scene-cubemap magenta diagnostic'
    nativeSha256 = $reviewedNativeHash
    nativeSha1 = (Get-FileHash -LiteralPath $nativePath -Algorithm SHA1).Hash
    overrideSha256 = (Get-FileHash -LiteralPath $resolvedStage -Algorithm SHA256).Hash
    overrideSha1 = (Get-FileHash -LiteralPath $resolvedStage -Algorithm SHA1).Hash
    target = $targetPath
    virtualPath = '/shaders/common/material/shadergen/permutations.h.hlsl'
    stagedPath = $resolvedStage
    patchedCallSites = 2
    exclusions = @('getCustomCubemap source branch', 'custom material constant buffers', 'nonzero reflectionVectorsPacked', 'deprecated V0 materials', 'water shader path')
    dynamicCaptureExclusion = 'Not established; no native reflection-pass flag was found.'
    sourceScope = 'Only the completed modern scene-cubemap contribution is tinted; native sampling and all other lighting remain unchanged.'
    gpuExecutionVerified = $false
    refreshRequired = 'Full application restart; no shader-cache deletion or guessed reload API.'
  }
  Write-ProbeJson $manifestPath $manifest
  return $manifest
}

switch ($Action) {
  'Stage' {
    $manifest = New-ProbeStage
    [ordered]@{action = 'staged only'; activeOverrideOnDisk = (Test-Path -LiteralPath $targetPath);
      manifest = $manifest; status = (Get-ProbeStatus)} | ConvertTo-Json -Depth 7
  }
  'EnableMagenta' {
    $manifest = New-ProbeStage
    $target = Assert-ProbeOwnedPath $targetPath
    if (Test-Path -LiteralPath $target) {
      $status = Get-ProbeStatus
      if (-not $status.ownedOverride -or $status.diskSha256 -ne $manifest.overrideSha256) {
        throw 'Refusing to overwrite an unknown or changed active override. Disable the owned test first.'
      }
      $status | ConvertTo-Json -Depth 4
      break
    }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
    # Record ownership before exclusive creation, so a successful write can be
    # recovered even if the final status write is interrupted.
    $state = [ordered]@{experimentId = $probeId; target = $target;
      overrideSha256 = $manifest.overrideSha256; nativeSha256 = $reviewedNativeHash;
      enabledOnDisk = $false; gpuExecutionVerified = $false}
    Write-ProbeJson $statePath $state
    $bytes = [IO.File]::ReadAllBytes($stagedPath)
    Write-ProbeBytesAtomic $target $bytes $false
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $manifest.overrideSha256) {
      throw 'Published override hash mismatch. Inspect ownership before attempting any recovery.'
    }
    $state.enabledOnDisk = $true
    Write-ProbeJson $statePath $state
    Get-ProbeStatus | ConvertTo-Json -Depth 4
  }
  'Disable' {
    $status = Get-ProbeStatus
    if (-not $status.activeOverrideOnDisk) { $status | ConvertTo-Json -Depth 4; break }
    if (-not $status.ownedOverride) { throw 'Refusing to move an unknown or modified native-path override.' }
    $from = Assert-ProbeOwnedPath $targetPath
    $archiveDir = Assert-ProbeOwnedPath (Join-Path $workPath 'restored')
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    $archive = Assert-ProbeOwnedPath (Join-Path $archiveDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fffffff') + '.permutations.magenta.h.hlsl'))
    Move-Item -LiteralPath $from -Destination $archive
    $state = Read-ProbeJson $statePath
    $state.enabledOnDisk = $false
    $state | Add-Member -NotePropertyName restoredArchive -NotePropertyValue $archive -Force
    Write-ProbeJson $statePath $state
    [ordered]@{action = 'Owned override archived; native disk path no longer shadowed';
      recoverableArchive = $archive; status = (Get-ProbeStatus)} | ConvertTo-Json -Depth 5
  }
  'Status' { Get-ProbeStatus | ConvertTo-Json -Depth 4 }
}
