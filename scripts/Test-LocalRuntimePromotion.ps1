#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CpuZipPath,
    [Parameter(Mandatory)][string]$CudaZipPath,
    [Parameter(Mandatory)][string]$CpuAcceptanceEvidencePath,
    [Parameter(Mandatory)][string]$CudaAcceptanceEvidencePath,
    [Parameter(Mandatory)][string]$AssetRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalRuntimePromotion.psm1') -Force

$contract = Get-LocalRuntimePromotionContract
$results = [Collections.Generic.List[object]]::new()

function Add-Pass {
    param([string]$Name, [string]$Kind)
    $results.Add([ordered]@{ name = $Name; kind = $Kind; result = 'PASS' })
}

function Invoke-Positive {
    param([string]$Name, [scriptblock]$Body)
    & $Body | Out-Null
    Add-Pass $Name 'positive'
}

function Invoke-Negative {
    param([string]$Name, [scriptblock]$Body)
    $failedClosed = $false
    try { & $Body | Out-Null }
    catch { $failedClosed = $true }
    if (-not $failedClosed) { throw "Negative did not fail closed: $Name" }
    Add-Pass $Name 'negative'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-promotion-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    Invoke-Positive 'exact CPU candidate' {
        Assert-PromotionFile $CpuZipPath $contract.CpuName $contract.CpuBytes $contract.CpuSha256
    }
    Invoke-Positive 'exact CUDA candidate' {
        Assert-PromotionFile $CudaZipPath $contract.CudaName $contract.CudaBytes $contract.CudaSha256
    }
    Invoke-Positive 'exact CPU acceptance evidence' {
        Assert-CandidateAcceptanceEvidence $CpuAcceptanceEvidencePath cpu
    }
    Invoke-Positive 'exact CUDA acceptance evidence' {
        Assert-CandidateAcceptanceEvidence $CudaAcceptanceEvidencePath cuda
    }
    $badAcceptance = Get-Content -LiteralPath $CpuAcceptanceEvidencePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 64
    $badAcceptance.causal_backend.details.model_backend_cpu = $false
    $badAcceptancePath = Join-Path $temp 'bad-acceptance.json'
    [IO.File]::WriteAllText($badAcceptancePath, ($badAcceptance | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
    Invoke-Negative 'acceptance causal backend altered' {
        Assert-CandidateAcceptanceEvidence $badAcceptancePath cpu
    }

    $mutatedDir = Join-Path $temp 'mutated'
    New-Item -ItemType Directory -Path $mutatedDir | Out-Null
    $mutated = Join-Path $mutatedDir $contract.CpuName
    [IO.File]::Copy($CpuZipPath, $mutated)
    $stream = [IO.File]::Open($mutated, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.WriteByte(0) } finally { $stream.Dispose() }
    Invoke-Negative 'mutated ZIP' {
        Assert-PromotionFile $mutated $contract.CpuName $contract.CpuBytes $contract.CpuSha256
    }

    $neighborDir = Join-Path $temp 'neighbor'
    New-Item -ItemType Directory -Path $neighborDir | Out-Null
    $neighbor = Join-Path $neighborDir $contract.CpuName
    [IO.File]::WriteAllBytes($neighbor, [byte[]]@(1, 2, 3))
    Invoke-Negative 'neighbor size or hash' {
        Assert-PromotionFile $neighbor $contract.CpuName $contract.CpuBytes $contract.CpuSha256
    }

    Invoke-Negative 'crossed backend' {
        Assert-BackendIdentity ([pscustomobject]@{ backend = 'cpu' }) 'cuda'
    }
    Invoke-Negative 'model artifact in inventory' {
        Assert-NoModelPayload @([pscustomobject]@{ path = 'models/fixed.gguf'; size = 1; sha256 = ('0' * 64) }) $contract.ModelBytes $contract.ModelSha256
    }

    $privacyRaw = Join-Path $temp 'privacy-raw'
    New-Item -ItemType Directory -Path $privacyRaw | Out-Null
    [IO.File]::WriteAllText((Join-Path $privacyRaw 'metadata.json'), '{"path":"C:\Users\Owner\secret"}')
    Invoke-Negative 'raw private path' { Assert-NoPrivatePathText $privacyRaw }
    $privacyEscaped = Join-Path $temp 'privacy-escaped'
    New-Item -ItemType Directory -Path $privacyEscaped | Out-Null
    [IO.File]::WriteAllText((Join-Path $privacyEscaped 'metadata.json'), '{"path":"C:\\Users\\Owner\\secret"}')
    Invoke-Negative 'escaped private path' { Assert-NoPrivatePathText $privacyEscaped }

    $now = [DateTime]::UtcNow
    $safeDefender = [pscustomobject]@{
        AMServiceEnabled = $true; AntivirusEnabled = $true; AntispywareEnabled = $true
        RealTimeProtectionEnabled = $true; DefenderSignaturesOutOfDate = $false
        AntivirusSignatureLastUpdated = $now.AddHours(-1); AntivirusSignatureVersion = 'test'
    }
    Invoke-Positive 'safe Defender state' { Assert-DefenderState $safeDefender @() $now }
    $inactiveDefender = $safeDefender.PSObject.Copy(); $inactiveDefender.RealTimeProtectionEnabled = $false
    Invoke-Negative 'Defender inactive' { Assert-DefenderState $inactiveDefender @() $now }
    $staleDefender = $safeDefender.PSObject.Copy(); $staleDefender.DefenderSignaturesOutOfDate = $true
    Invoke-Negative 'Defender stale' { Assert-DefenderState $staleDefender @() $now }
    Invoke-Negative 'Defender threat' { Assert-DefenderState $safeDefender @([pscustomobject]@{ id = 1 }) $now }

    $missing = Join-Path $temp 'missing'
    New-Item -ItemType Directory -Path $missing | Out-Null
    foreach ($name in @('LICENSE', 'NOTICE', $contract.PatchName)) { [IO.File]::WriteAllText((Join-Path $missing $name), 'x') }
    Invoke-Negative 'missing SBOM' { Assert-RequiredPromotionMembers $missing @('LICENSE', 'NOTICE', $contract.PatchName, 'sbom.spdx.json') }
    Remove-Item -LiteralPath (Join-Path $missing 'LICENSE')
    Invoke-Negative 'missing license' { Assert-RequiredPromotionMembers $missing @('LICENSE') }
    Remove-Item -LiteralPath (Join-Path $missing $contract.PatchName)
    Invoke-Negative 'missing patch' { Assert-RequiredPromotionMembers $missing @($contract.PatchName) }

    $validManifest = Get-Content -LiteralPath (Join-Path $AssetRoot 'release-manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 64
    Invoke-Positive 'honest local provenance' { Assert-LocalProvenanceManifest $validManifest }
    $githubManifest = $validManifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $githubManifest.provenance.github_built = $true
    Invoke-Negative 'manifest claiming GitHub build' { Assert-LocalProvenanceManifest $githubManifest }
    $selfManifest = $validManifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $selfManifest | Add-Member -NotePropertyName release_manifest -NotePropertyValue ([pscustomobject]@{ name = 'release-manifest.json'; sha256 = ('A' * 64) })
    Invoke-Negative 'manifest self reference' { Assert-LocalProvenanceManifest $selfManifest }
    $modelManifest = $validManifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    $modelManifest.compatible_model.included = $true
    Invoke-Negative 'manifest says model included' { Assert-LocalProvenanceManifest $modelManifest }
    $candidateManifest = $validManifest | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64
    $candidateManifest.candidates[0].sha256 = ('B' * 64)
    Invoke-Negative 'manifest candidate digest altered' { Assert-LocalProvenanceManifest $candidateManifest }

    Invoke-Negative 'asset omitted' { Assert-ExactAssetSet @($contract.AssetNames | Select-Object -Skip 1) $contract.AssetNames }
    Invoke-Negative 'asset extra' { Assert-ExactAssetSet (@($contract.AssetNames) + 'extra.bin') $contract.AssetNames }
    Invoke-Positive 'exact seven-asset set' { Assert-ExactAssetSet @($contract.AssetNames) $contract.AssetNames }
    Invoke-Negative 'preexisting draft' { Assert-EmptyReleaseSurface @([pscustomobject]@{ draft = $true }) '' }
    Invoke-Negative 'preexisting tag' { Assert-EmptyReleaseSurface @() 'abc refs/tags/existing' }
    Invoke-Negative 'clobber argument' { Assert-NoClobberArgument @('upload', '--clobber') }

    $validDraft = [pscustomobject]@{ tag_name = $contract.Tag; target_commitish = $contract.TargetCommit; draft = $true; prerelease = $false }
    Invoke-Positive 'exact private draft' { Assert-DraftReleaseContract $validDraft $contract.Tag $contract.TargetCommit }
    $wrongTarget = $validDraft.PSObject.Copy(); $wrongTarget.target_commitish = ('0' * 40)
    Invoke-Negative 'wrong target' { Assert-DraftReleaseContract $wrongTarget $contract.Tag $contract.TargetCommit }
    $publicRelease = $validDraft.PSObject.Copy(); $publicRelease.draft = $false
    Invoke-Negative 'public release' { Assert-DraftReleaseContract $publicRelease $contract.Tag $contract.TargetCommit }
    $prerelease = $validDraft.PSObject.Copy(); $prerelease.prerelease = $true
    Invoke-Negative 'unexpected prerelease' { Assert-DraftReleaseContract $prerelease $contract.Tag $contract.TargetCommit }

    Invoke-Negative 'build script guard' { Assert-NoBuildIntent 'pwsh ./scripts/Build-Runtime.ps1 -Backend cpu' }
    Invoke-Negative 'compiler guard' { Assert-NoBuildIntent 'nvcc.exe kernel.cu' }
    Invoke-Negative 'workflow dispatch guard' { Assert-NoBuildIntent 'gh workflow run build-release.yml' }
    Invoke-Positive 'verification intent allowed' { Assert-NoBuildIntent 'pwsh ./scripts/Prepare-LocalRuntimeDraft.ps1' }

    $downloadDir = Join-Path $temp 'download-mismatch'
    New-Item -ItemType Directory -Path $downloadDir | Out-Null
    $badDownload = Join-Path $downloadDir $contract.CpuName
    [IO.File]::WriteAllBytes($badDownload, [byte[]]@(9))
    Invoke-Negative 'redownload bytes mismatch' {
        Assert-PromotionFile $badDownload $contract.CpuName $contract.CpuBytes $contract.CpuSha256
    }

    $checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Invoke-Negative 'AssetRoot inside checkout' { Assert-SafeExistingOutsideCheckoutPath $checkout $checkout 'AssetRoot' }
    $junction = Join-Path $temp 'asset-junction'
    New-Item -ItemType Junction -Path $junction -Target ([IO.Path]::GetFullPath($AssetRoot)) | Out-Null
    try {
        Invoke-Negative 'AssetRoot reparse point' { Assert-SafeExistingOutsideCheckoutPath $junction $checkout 'AssetRoot' }
    }
    finally {
        Remove-Item -LiteralPath $junction -Force
    }

    $authorizedSnapshot = @(Get-AuthorizedAssetSnapshot -AssetRoot $AssetRoot -CheckoutRoot $checkout)
    Invoke-Positive 'authorized seven-asset snapshot' { Assert-AssetSnapshot $AssetRoot $authorizedSnapshot }

    $ledgerRoot = Join-Path $temp 'ledger-root'
    New-Item -ItemType Directory -Path $ledgerRoot | Out-Null
    foreach ($name in $contract.AssetNames) { [IO.File]::Copy((Join-Path $AssetRoot $name), (Join-Path $ledgerRoot $name)) }
    $ledgerPath = Join-Path $ledgerRoot 'SHA256SUMS.txt'
    $validLedger = [IO.File]::ReadAllText($ledgerPath)
    Invoke-Positive 'exact six-entry checksum ledger' { Assert-ExactChecksumLedger $ledgerPath $ledgerRoot }
    [IO.File]::WriteAllText($ledgerPath, '')
    Invoke-Negative 'empty checksum ledger' { Assert-ExactChecksumLedger $ledgerPath $ledgerRoot }
    $firstLedgerLine = @($validLedger -split "`r?`n" | Where-Object { $_ })[0]
    [IO.File]::WriteAllText($ledgerPath, ((1..6 | ForEach-Object { $firstLedgerLine }) -join "`n") + "`n")
    Invoke-Negative 'duplicate checksum ledger' { Assert-ExactChecksumLedger $ledgerPath $ledgerRoot }
    $ledgerLines = @($validLedger -split "`r?`n" | Where-Object { $_ })
    [IO.File]::WriteAllText($ledgerPath, (($ledgerLines | Select-Object -Skip 1) -join "`n") + "`n")
    Invoke-Negative 'omitted checksum entry' { Assert-ExactChecksumLedger $ledgerPath $ledgerRoot }
    [IO.File]::WriteAllText($ledgerPath, $validLedger + (('C' * 64) + "  extra.bin`n"))
    Invoke-Negative 'extra checksum entry' { Assert-ExactChecksumLedger $ledgerPath $ledgerRoot }

    $mutatedAsset = Join-Path $ledgerRoot $contract.CpuName
    $mutationStream = [IO.File]::Open($mutatedAsset, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $mutationStream.WriteByte(7) } finally { $mutationStream.Dispose() }
    $coordinatedLines = @($ledgerLines | ForEach-Object {
        if ($_ -match ('  ' + [regex]::Escape($contract.CpuName) + '$')) {
            '{0}  {1}' -f (Get-PromotionSha256 $mutatedAsset), $contract.CpuName
        }
        else { $_ }
    })
    [IO.File]::WriteAllText($ledgerPath, ($coordinatedLines -join "`n") + "`n")
    Invoke-Positive 'coordinated mutation fools ledger alone' { Assert-ExactChecksumLedger $ledgerPath $ledgerRoot }
    Invoke-Negative 'frozen contract rejects coordinated mutation' { Get-AuthorizedAssetSnapshot $ledgerRoot $checkout }
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemp).StartsWith('diagnotes-promotion-tests-', [StringComparison]::Ordinal)) {
        [IO.Directory]::Delete($resolvedTemp, $true)
    }
}

[ordered]@{
    status = 'PASS'
    total = $results.Count
    positives = @($results | Where-Object kind -eq 'positive').Count
    negatives = @($results | Where-Object kind -eq 'negative').Count
    results = $results
} | ConvertTo-Json -Depth 8
