#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CpuZipPath,
    [Parameter(Mandatory)][string]$CudaZipPath,
    [Parameter(Mandatory)][string]$CpuAcceptanceEvidencePath,
    [Parameter(Mandatory)][string]$CudaAcceptanceEvidencePath,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$AssetRoot,
    [switch]$SkipDefenderScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalRuntimePromotion.psm1') -Force

if ($SkipDefenderScan) {
    throw 'Defender scanning cannot be skipped for a promotion candidate.'
}

$contract = Get-LocalRuntimePromotionContract
$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$work = Assert-FreshOutsideCheckoutPath -LiteralPath $WorkRoot -CheckoutRoot $checkout -Label 'WorkRoot'
$assets = Assert-FreshOutsideCheckoutPath -LiteralPath $AssetRoot -CheckoutRoot $checkout -Label 'AssetRoot'
if ($work.Equals($assets, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkRoot and AssetRoot must be distinct.'
}

$driveName = [IO.Path]::GetPathRoot($work).TrimEnd('\').TrimEnd(':')
$drive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
if ($drive.Free -lt 100GB) {
    throw "Less than 100 GB is free on the verification drive: $([Math]::Round($drive.Free / 1GB, 1)) GB."
}

Assert-NoBuildIntent -Text $MyInvocation.Line | Out-Null
$processStart = Assert-NoBuildProcesses
$cpu = Assert-PromotionFile -LiteralPath $CpuZipPath -ExpectedName $contract.CpuName -ExpectedBytes $contract.CpuBytes -ExpectedSha256 $contract.CpuSha256
$cuda = Assert-PromotionFile -LiteralPath $CudaZipPath -ExpectedName $contract.CudaName -ExpectedBytes $contract.CudaBytes -ExpectedSha256 $contract.CudaSha256
$cpuAcceptance = Assert-CandidateAcceptanceEvidence -LiteralPath $CpuAcceptanceEvidencePath -ExpectedBackend cpu
$cudaAcceptance = Assert-CandidateAcceptanceEvidence -LiteralPath $CudaAcceptanceEvidencePath -ExpectedBackend cuda

$defenderStart = Get-LiveDefenderState
$baselineDetections = @(Get-DefenderDetectionKeys)

New-Item -ItemType Directory -Path $work | Out-Null
New-Item -ItemType Directory -Path $assets | Out-Null
$cpuExtract = Join-Path $work 'cpu-extracted'
$cudaExtract = Join-Path $work 'cuda-extracted'
New-Item -ItemType Directory -Path $cpuExtract | Out-Null
New-Item -ItemType Directory -Path $cudaExtract | Out-Null

Write-Host 'Defender scan: immutable CPU ZIP'
Start-MpScan -ScanType CustomScan -ScanPath ([IO.Path]::GetFullPath($CpuZipPath)) -ErrorAction Stop
Write-Host 'Defender scan: immutable CUDA ZIP'
Start-MpScan -ScanType CustomScan -ScanPath ([IO.Path]::GetFullPath($CudaZipPath)) -ErrorAction Stop

$cpuTop = Assert-ZipEntrySafety -ZipPath $CpuZipPath
$cudaTop = Assert-ZipEntrySafety -ZipPath $CudaZipPath
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($CpuZipPath), $cpuExtract)
[IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($CudaZipPath), $cudaExtract)

Write-Host 'Defender scan: fresh CPU extraction'
Start-MpScan -ScanType CustomScan -ScanPath $cpuExtract -ErrorAction Stop
Write-Host 'Defender scan: fresh CUDA extraction'
Start-MpScan -ScanType CustomScan -ScanPath $cudaExtract -ErrorAction Stop

$privateMarkers = @([Environment]::GetFolderPath('UserProfile'))
$cpuStructure = Assert-ExtractedRuntime -ExtractRoot $cpuExtract -Backend cpu -ExpectedTopRoot $cpuTop `
    -PublicLicensePath (Join-Path $checkout 'LICENSE') -PublicNoticePath (Join-Path $checkout 'NOTICE') `
    -PrivateMarkers $privateMarkers
$cudaStructure = Assert-ExtractedRuntime -ExtractRoot $cudaExtract -Backend cuda -ExpectedTopRoot $cudaTop `
    -PublicLicensePath (Join-Path $checkout 'LICENSE') -PublicNoticePath (Join-Path $checkout 'NOTICE') `
    -PrivateMarkers $privateMarkers

$defenderForManifest = Get-LiveDefenderState
$detectionForManifest = Assert-NoNewDefenderDetection -BaselineKeys $baselineDetections

foreach ($copy in @(
    @($CpuZipPath, $contract.CpuName),
    @($CudaZipPath, $contract.CudaName),
    @((Join-Path $checkout 'LICENSE'), 'LICENSE'),
    @((Join-Path $checkout 'NOTICE'), 'NOTICE'),
    @((Join-Path $checkout ('patches/' + $contract.PatchName)), $contract.PatchName)
)) {
    [IO.File]::Copy([IO.Path]::GetFullPath($copy[0]), (Join-Path $assets $copy[1]), $false)
}

$staticAssets = @()
foreach ($name in @('LICENSE', 'NOTICE', $contract.PatchName)) {
    $path = Join-Path $assets $name
    $staticAssets += [ordered]@{ name = $name; bytes = (Get-Item -LiteralPath $path).Length; sha256 = Get-PromotionSha256 $path }
}
if ($staticAssets[2].bytes -ne $contract.PatchBytes -or $staticAssets[2].sha256 -cne $contract.PatchSha256) {
    throw 'Canonical patch changed while assembling assets.'
}

$manifestObject = [ordered]@{
    schema = 'diagnotes-local-runtime-release-manifest-v1'
    identity = $contract.Identity
    release_tag = $contract.Tag
    target_commit = $contract.TargetCommit
    source = [ordered]@{
        upstream_repository = 'https://github.com/NVIDIA/NeMo-Speech.cpp'
        upstream_commit = $contract.SourceCommit
        patch = [ordered]@{ name = $contract.PatchName; bytes = $contract.PatchBytes; sha256 = $contract.PatchSha256 }
    }
    provenance = [ordered]@{
        kind = 'local-build-local-verification'
        statement = 'These immutable runtime ZIPs were built and verified locally. GitHub hosts the draft assets but did not build them.'
        github_built = $false
        slsa = $false
        actions_build_attestation = $false
        accepted_debt = 'No independent GitHub build provenance is claimed for this PoC release candidate.'
    }
    compatible_model = [ordered]@{
        repository = $contract.ModelRepo
        revision = $contract.ModelRevision
        bytes = $contract.ModelBytes
        sha256 = $contract.ModelSha256
        included = $false
        license_separate = $true
    }
    candidates = @(
        [ordered]@{
            name = $cpu.name; backend = 'cpu'; architectures = @('x86_64'); bytes = $cpu.bytes; sha256 = $cpu.sha256
            runtime_capabilities = @('realtime-language-v1'); toolchain = $cpuStructure.toolchain
        },
        [ordered]@{
            name = $cuda.name; backend = 'cuda'; architectures = @('sm75', 'sm80', 'sm86', 'sm89'); bytes = $cuda.bytes; sha256 = $cuda.sha256
            runtime_capabilities = @('realtime-language-v1'); toolchain = $cudaStructure.toolchain
        }
    )
    detached_assets = $staticAssets
    asset_set = @($contract.AssetNames)
    defender = [ordered]@{
        engine = $defenderForManifest.engine
        antivirus_enabled = $defenderForManifest.antivirus_enabled
        antispyware_enabled = $defenderForManifest.antispyware_enabled
        realtime_enabled = $defenderForManifest.realtime_enabled
        signatures_out_of_date = $defenderForManifest.signatures_out_of_date
        signature_version = $defenderForManifest.signature_version
        signature_updated_utc = $defenderForManifest.signature_updated_utc
        scans = @('cpu-zip', 'cuda-zip', 'cpu-fresh-extraction', 'cuda-fresh-extraction')
        active_threat_count = 0
        new_detection_count = $detectionForManifest.new_detection_count
    }
    verification = [ordered]@{
        generated_utc = [DateTime]::UtcNow.ToString('o')
        zip_bytes_rechecked = $true
        extraction_fresh = $true
        binaries_executed = $false
        model_loaded = $false
        audio_used = $false
        live_acceptance_performed = $true
        acceptance_reused = $false
        acceptance = @($cpuAcceptance, $cudaAcceptance)
        cpu = $cpuStructure
        cuda = $cudaStructure
    }
}
Assert-LocalProvenanceManifest -Manifest $manifestObject | Out-Null
$manifestPath = Join-Path $assets 'release-manifest.json'
Write-Utf8NoBom -LiteralPath $manifestPath -Text (($manifestObject | ConvertTo-Json -Depth 64) + "`n")

$sumNames = @($contract.AssetNames | Where-Object { $_ -cne 'SHA256SUMS.txt' } | Sort-Object)
$sumLines = foreach ($name in $sumNames) {
    $path = Join-Path $assets $name
    '{0}  {1}' -f (Get-PromotionSha256 $path), $name
}
Write-Utf8NoBom -LiteralPath (Join-Path $assets 'SHA256SUMS.txt') -Text (($sumLines -join "`n") + "`n")

$actualAssetNames = @(Get-ChildItem -LiteralPath $assets -File -Force | ForEach-Object Name)
Assert-ExactAssetSet -ActualNames $actualAssetNames -ExpectedNames $contract.AssetNames | Out-Null
$manifestRoundTrip = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 64
Assert-LocalProvenanceManifest -Manifest $manifestRoundTrip | Out-Null
Assert-ExactChecksumLedger -LedgerPath (Join-Path $assets 'SHA256SUMS.txt') -AssetRoot $assets | Out-Null
$assetSnapshot = @(Get-AuthorizedAssetSnapshot -AssetRoot $assets -CheckoutRoot $checkout)

$cpuFinal = Assert-PromotionFile -LiteralPath $CpuZipPath -ExpectedName $contract.CpuName -ExpectedBytes $contract.CpuBytes -ExpectedSha256 $contract.CpuSha256
$cudaFinal = Assert-PromotionFile -LiteralPath $CudaZipPath -ExpectedName $contract.CudaName -ExpectedBytes $contract.CudaBytes -ExpectedSha256 $contract.CudaSha256
$cpuCopy = Assert-PromotionFile -LiteralPath (Join-Path $assets $contract.CpuName) -ExpectedName $contract.CpuName -ExpectedBytes $contract.CpuBytes -ExpectedSha256 $contract.CpuSha256
$cudaCopy = Assert-PromotionFile -LiteralPath (Join-Path $assets $contract.CudaName) -ExpectedName $contract.CudaName -ExpectedBytes $contract.CudaBytes -ExpectedSha256 $contract.CudaSha256
$defenderEnd = Get-LiveDefenderState
$detectionResult = Assert-NoNewDefenderDetection -BaselineKeys $baselineDetections
$processEnd = Assert-NoBuildProcesses

$evidence = [ordered]@{
    schema = 'diagnotes-local-runtime-promotion-evidence-v1'
    status = 'PREPARED_FOR_PRIVATE_DRAFT'
    provenance = 'local-build-local-verification'
    target_commit = $contract.TargetCommit
    free_gib_at_start = [Math]::Round($drive.Free / 1GB, 1)
    candidates = @($cpuFinal, $cudaFinal)
    acceptance = @($cpuAcceptance, $cudaAcceptance)
    assembled_candidate_copies = @($cpuCopy, $cudaCopy)
    structure = @($cpuStructure, $cudaStructure)
    defender = [ordered]@{
        start = $defenderStart
        end = $defenderEnd
        baseline_detection_count = $detectionResult.baseline_detection_count
        new_detection_count = $detectionResult.new_detection_count
        scans_completed = @('cpu-zip', 'cuda-zip', 'cpu-fresh-extraction', 'cuda-fresh-extraction')
    }
    no_build_guard = [ordered]@{ start = $processStart; end = $processEnd; binaries_executed = $false }
    asset_hashes = @($assetSnapshot | Sort-Object name)
}
$evidencePath = Join-Path $work 'promotion-evidence.json'
Write-Utf8NoBom -LiteralPath $evidencePath -Text (($evidence | ConvertTo-Json -Depth 64) + "`n")

[ordered]@{
    status = 'PREPARED_FOR_PRIVATE_DRAFT'
    asset_root = $assets
    evidence_path = $evidencePath
    asset_count = $evidence.asset_hashes.Count
    cpu_sha256 = $cpuFinal.sha256
    cuda_sha256 = $cudaFinal.sha256
    defender_new_detections = $detectionResult.new_detection_count
    no_build_processes = $processEnd.forbidden_process_count
} | ConvertTo-Json -Depth 8
