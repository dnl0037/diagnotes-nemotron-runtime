#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AssetRoot,
    [Parameter(Mandatory)][string]$DownloadRoot,
    [Parameter(Mandatory)][string]$EvidencePath,
    [Parameter(ValueFromRemainingArguments)][string[]]$AdditionalArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalRuntimePromotion.psm1') -Force

$contract = Get-LocalRuntimePromotionContract
$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$assets = Assert-SafeExistingOutsideCheckoutPath -LiteralPath $AssetRoot -CheckoutRoot $checkout -Label 'AssetRoot'
$downloads = Assert-FreshOutsideCheckoutPath -LiteralPath $DownloadRoot -CheckoutRoot $checkout -Label 'DownloadRoot'
$evidenceFull = [IO.Path]::GetFullPath($EvidencePath)
$evidenceParent = Split-Path -Parent $evidenceFull
Assert-SafeExistingOutsideCheckoutPath -LiteralPath $evidenceParent -CheckoutRoot $checkout -Label 'EvidencePath parent' | Out-Null
if (Test-Path -LiteralPath $evidenceFull) { throw 'EvidencePath must not preexist.' }

Assert-NoClobberArgument -Arguments @($AdditionalArguments) | Out-Null
Assert-NoBuildIntent -Text $MyInvocation.Line | Out-Null
$processStart = Assert-NoBuildProcesses

# This snapshot is rooted in frozen ZIP/static-asset constants and a complete
# semantic manifest contract, not merely in the mutable checksum file.
$snapshot = @(Get-AuthorizedAssetSnapshot -AssetRoot $assets -CheckoutRoot $checkout)
$assetLocks = [Collections.Generic.List[IO.FileStream]]::new()
$releaseId = $null
$account = $null
$finalRelease = $null
$verifiedDownloads = @()
$processEnd = $null

try {
    # Keep all seven files read-only and non-deletable for the entire remote
    # transaction. gh may open additional read handles but no writer can race.
    foreach ($entry in $snapshot) {
        $assetLocks.Add([IO.File]::Open((Join-Path $assets $entry.name), [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::Read))
    }
    Assert-AssetSnapshot -AssetRoot $assets -Snapshot $snapshot | Out-Null

    $remote = (@(& git remote get-url origin) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $remote -notmatch '(?i)(?:github\.com[:/])dnl0037/diagnotes-nemotron-runtime(?:\.git)?$') {
        throw "Unexpected Git origin: '$remote'."
    }
    $remoteTarget = (@(& git ls-remote origin 'refs/heads/main') -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or ($remoteTarget -split '\s+')[0] -cne $contract.TargetCommit) {
        throw 'GitHub main is not the exact frozen target commit.'
    }

    $account = (@(& gh api user --jq .login) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $account -cne $contract.Account) {
        throw "Unexpected authenticated GitHub account: '$account'."
    }
    $releaseOutput = & gh api "repos/$($contract.Repository)/releases?per_page=100"
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate GitHub releases.' }
    $existingReleases = @($releaseOutput | ConvertFrom-Json -Depth 64)
    $remoteTags = (@(& git ls-remote --tags origin) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate remote tags.' }
    Assert-EmptyReleaseSurface -Releases $existingReleases -RemoteTags $remoteTags | Out-Null
    Assert-AssetSnapshot -AssetRoot $assets -Snapshot $snapshot | Out-Null

    $body = @'
Local-build, local-verification release candidate.

The two immutable runtime ZIPs were built and verified locally. GitHub did not build these bytes. No SLSA or GitHub Actions build provenance is claimed. The compatible model is not included and remains separately licensed.

This release is a private draft pending independent fiscalization. It is not consumer-ready.
'@
    $releaseJson = & gh api --method POST "repos/$($contract.Repository)/releases" `
        -f "tag_name=$($contract.Tag)" -f "target_commitish=$($contract.TargetCommit)" `
        -f "name=$($contract.Identity)" -f "body=$body" -F 'draft=true' -F 'prerelease=false'
    if ($LASTEXITCODE -ne 0) { throw 'GitHub draft creation failed.' }
    $release = $releaseJson | ConvertFrom-Json -Depth 64
    $releaseId = [long]$release.id
    Assert-DraftReleaseContract -Release $release -ExpectedTag $contract.Tag -ExpectedTarget $contract.TargetCommit | Out-Null

    foreach ($entry in $snapshot) {
        Assert-AssetSnapshot -AssetRoot $assets -Snapshot $snapshot | Out-Null
        & gh release upload $contract.Tag (Join-Path $assets $entry.name) --repo $contract.Repository
        if ($LASTEXITCODE -ne 0) { throw "Upload failed for '$($entry.name)'." }
    }
    Assert-AssetSnapshot -AssetRoot $assets -Snapshot $snapshot | Out-Null

    $uploadedOutput = & gh api "repos/$($contract.Repository)/releases/$releaseId"
    if ($LASTEXITCODE -ne 0) { throw 'Could not re-read the created draft.' }
    $uploaded = $uploadedOutput | ConvertFrom-Json -Depth 64
    Assert-DraftReleaseContract -Release $uploaded -ExpectedTag $contract.Tag -ExpectedTarget $contract.TargetCommit | Out-Null
    Assert-ExactAssetSet -ActualNames @($uploaded.assets | ForEach-Object name) -ExpectedNames $contract.AssetNames | Out-Null
    foreach ($asset in @($uploaded.assets)) {
        $expected = @($snapshot | Where-Object name -ceq $asset.name)
        if ($expected.Count -ne 1 -or [long]$asset.size -ne [long]$expected[0].bytes) {
            throw "Uploaded size differs for '$($asset.name)'."
        }
    }

    New-Item -ItemType Directory -Path $downloads | Out-Null
    & gh release download $contract.Tag --repo $contract.Repository --dir $downloads
    if ($LASTEXITCODE -ne 0) { throw 'Authenticated draft download failed.' }
    Assert-ExactAssetSet -ActualNames @(Get-ChildItem -LiteralPath $downloads -File -Force | ForEach-Object Name) -ExpectedNames $contract.AssetNames | Out-Null
    foreach ($expected in $snapshot) {
        $download = Get-Item -LiteralPath (Join-Path $downloads $expected.name)
        $downloadHash = Get-PromotionSha256 $download.FullName
        if ($download.Length -ne [long]$expected.bytes -or $downloadHash -cne [string]$expected.sha256) {
            throw "Authenticated redownload differs from the authorized snapshot for '$($expected.name)'."
        }
        $verifiedDownloads += [ordered]@{ name = $expected.name; bytes = $download.Length; sha256 = $downloadHash }
    }

    $finalOutput = & gh api "repos/$($contract.Repository)/releases/$releaseId"
    if ($LASTEXITCODE -ne 0) { throw 'Could not perform final draft readback.' }
    $finalRelease = $finalOutput | ConvertFrom-Json -Depth 64
    Assert-DraftReleaseContract -Release $finalRelease -ExpectedTag $contract.Tag -ExpectedTarget $contract.TargetCommit | Out-Null
    Assert-ExactAssetSet -ActualNames @($finalRelease.assets | ForEach-Object name) -ExpectedNames $contract.AssetNames | Out-Null
    $postDraftTags = (@(& git ls-remote --tags origin) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::IsNullOrWhiteSpace($postDraftTags)) {
        throw 'A public Git tag unexpectedly exists while the release is a draft.'
    }
    Assert-AssetSnapshot -AssetRoot $assets -Snapshot $snapshot | Out-Null
    $processEnd = Assert-NoBuildProcesses
}
catch {
    $primaryError = $_.Exception.Message
    $rollback = 'not-needed'
    if ($null -ne $releaseId) {
        $currentJson = & gh api "repos/$($contract.Repository)/releases/$releaseId" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $current = $currentJson | ConvertFrom-Json -Depth 32
            if ([bool]$current.draft -and [string]$current.tag_name -ceq $contract.Tag) {
                & gh api --method DELETE "repos/$($contract.Repository)/releases/$releaseId" | Out-Null
                if ($LASTEXITCODE -ne 0) { $rollback = 'draft-delete-failed' } else { $rollback = 'partial-draft-deleted' }
            }
            else { $rollback = 'not-deleted-release-not-private-draft' }
        }
        else { $rollback = 'draft-not-readable' }
    }
    throw "Draft transaction failed: $primaryError; rollback=$rollback; release_id=$releaseId."
}
finally {
    foreach ($handle in $assetLocks) { $handle.Dispose() }
}

$evidence = [ordered]@{
    schema = 'diagnotes-local-runtime-draft-evidence-v1'
    status = 'READY_TO_PUBLISH'
    repository = $contract.Repository
    authenticated_account = $account
    release_id = $releaseId
    administrative_url = [string]$finalRelease.html_url
    tag = [string]$finalRelease.tag_name
    target_commit = [string]$finalRelease.target_commitish
    is_draft = [bool]$finalRelease.draft
    is_prerelease = [bool]$finalRelease.prerelease
    provenance = 'local-build-local-verification'
    github_built = $false
    assets = @($verifiedDownloads | Sort-Object name)
    authenticated_redownload = [ordered]@{ exact = $true; asset_count = $verifiedDownloads.Count; compared_to_authorized_snapshot = $true }
    anonymous_download_tested = $false
    consumer_ready = $false
    no_build_guard = [ordered]@{ start = $processStart; end = $processEnd }
}
Write-Utf8NoBom -LiteralPath $evidenceFull -Text (($evidence | ConvertTo-Json -Depth 32) + "`n")

[ordered]@{
    status = 'READY_TO_PUBLISH'
    release_id = $releaseId
    administrative_url = [string]$finalRelease.html_url
    is_draft = [bool]$finalRelease.draft
    is_prerelease = [bool]$finalRelease.prerelease
    target_commit = [string]$finalRelease.target_commitish
    asset_count = $verifiedDownloads.Count
    evidence_path = $evidenceFull
} | ConvertTo-Json -Depth 8
