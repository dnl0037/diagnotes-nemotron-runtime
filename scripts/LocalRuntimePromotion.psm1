Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimePathPrivacy.psm1') -Force

function Get-LocalRuntimePromotionContract {
    [CmdletBinding()]
    param()

    $checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $targetCommit = (& git -C $checkout rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $targetCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve the exact local promotion target commit.'
    }
    [ordered]@{
        Repository = 'dnl0037/diagnotes-nemotron-runtime'
        Account = 'dnl0037'
        Tag = 'nemo-speech-v0.1.0-diagnotes-lid.4'
        TargetCommit = $targetCommit
        Identity = 'nemo-speech-v0.1.0-diagnotes-lid.4'
        SourceCommit = '4f9676226f667d14608487df744f375db87127f8'
        PatchName = 'realtime-language-v1.patch'
        PatchBytes = 1793L
        PatchSha256 = '80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84'
        LicenseBytes = 11342L
        LicenseSha256 = '04DDE563FD6A4C599C8050829F8F563E270D0444BB0D478540925859BBDC63EA'
        NoticeBytes = 1124L
        NoticeSha256 = 'F443F2A3E1247AD8423AE854168623233AC91035A26C2ABA374C8E8F84A85C3F'
        CpuName = 'nemo-speech-v0.1.0-diagnotes-lid.4-windows-x86_64-cpu.zip'
        CpuBytes = 2640737L
        CpuSha256 = '26357B22CF0A4B7B59D980AD06068C998339DF21F76B5A57FA381CD238D2889B'
        CudaName = 'nemo-speech-v0.1.0-diagnotes-lid.4-windows-x86_64-cuda-sm75-sm80-sm86-sm89.zip'
        CudaBytes = 170665359L
        CudaSha256 = '89CA829838353F81F920C75B829C82C7B68F02DA275D704DD71B099B5EE6240D'
        ModelRepo = 'nvidia/nemotron-3.5-asr-streaming-0.6b'
        ModelRevision = '1c8deaecc64b91f034d73e08dd8b64625eb3395d'
        ModelBytes = 741548352L
        ModelSha256 = 'A5C435F294EEA8F88CE68DD27B8C3BFEA7F777CB2FBBA04FCD30EAA555F429AE'
        AssetNames = @(
            'nemo-speech-v0.1.0-diagnotes-lid.4-windows-x86_64-cpu.zip',
            'nemo-speech-v0.1.0-diagnotes-lid.4-windows-x86_64-cuda-sm75-sm80-sm86-sm89.zip',
            'release-manifest.json',
            'SHA256SUMS.txt',
            'LICENSE',
            'NOTICE',
            'realtime-language-v1.patch'
        )
    }
}

function Get-PromotionSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-PromotionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][long]$ExpectedBytes,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )

    $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    if ($item.Name -cne $ExpectedName) {
        throw "Unexpected file name: '$($item.Name)' (expected '$ExpectedName')."
    }
    if ($item.Length -ne $ExpectedBytes) {
        throw "Unexpected size for '$ExpectedName': $($item.Length) (expected $ExpectedBytes)."
    }
    $actualHash = Get-PromotionSha256 -LiteralPath $item.FullName
    if ($actualHash -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "Unexpected SHA-256 for '$ExpectedName': $actualHash."
    }
    [ordered]@{ name = $item.Name; bytes = $item.Length; sha256 = $actualHash }
}

function Assert-NoBuildIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $forbidden = '(?i)(Build-Runtime\.ps1|(?:^|[\\/\s])cmake(?:\.exe)?(?:$|\s)|(?:^|[\\/\s])ninja(?:\.exe)?(?:$|\s)|(?:^|[\\/\s])msbuild(?:\.exe)?(?:$|\s)|(?:^|[\\/\s])cl(?:\.exe)?(?:$|\s)|(?:^|[\\/\s])link(?:\.exe)?(?:$|\s)|(?:^|[\\/\s])nvcc(?:\.exe)?(?:$|\s)|vcpkg(?:\.exe)?\s+(?:build|install)|cuda_12\.8\.0_windows_network\.exe|workflow\s+(?:run|dispatch)|build-release\.yml)'
    if ($Text -match $forbidden) {
        throw 'Build or build-workflow intent is forbidden by the local promotion contract.'
    }
    $true
}

function Assert-NoBuildProcesses {
    [CmdletBinding()]
    param()

    $names = @('cmake', 'ninja', 'msbuild', 'cl', 'link', 'nvcc', 'vcpkg')
    $active = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName.ToLowerInvariant() })
    $commandMatches = @(
        Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.CommandLine -and
                $_.ProcessId -ne $PID -and
                $_.CommandLine -match '(?i)(Build-Runtime\.ps1|cuda_12\.8\.0_windows_network\.exe)'
            }
    )
    if ($active.Count -gt 0 -or $commandMatches.Count -gt 0) {
        $labels = @($active | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) +
            @($commandMatches | ForEach-Object { "$($_.Name):$($_.ProcessId)" })
        throw "Forbidden build process is active: $($labels -join ', ')."
    }
    [ordered]@{ checked_utc = [DateTime]::UtcNow.ToString('o'); forbidden_process_count = 0 }
}

function Assert-FreshOutsideCheckoutPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$CheckoutRoot,
        [Parameter(Mandatory)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $repo = [IO.Path]::GetFullPath($CheckoutRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($full.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be outside the checkout."
    }
    if (Test-Path -LiteralPath $full) {
        throw "$Label must be a fresh absent path: '$full'."
    }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Label parent does not exist: '$parent'."
    }
    $parentItem = Get-Item -LiteralPath $parent -Force
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label parent may not be a reparse point."
    }
    $full
}

function Assert-SafeExistingOutsideCheckoutPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$CheckoutRoot,
        [Parameter(Mandatory)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $repo = [IO.Path]::GetFullPath($CheckoutRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "$Label does not exist." }
    if ($full.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be outside the checkout."
    }
    $cursor = Get-Item -LiteralPath $full -Force
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path traverses a reparse point: '$($cursor.FullName)'."
        }
        $parent = Split-Path -Parent $cursor.FullName
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor.FullName) { break }
        $cursor = Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
    foreach ($file in Get-ChildItem -LiteralPath $full -File -Force) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label contains a reparse-point asset: '$($file.Name)'."
        }
    }
    $full
}

function Assert-DefenderState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Status,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ActiveThreats,
        [Parameter(Mandatory)][DateTime]$NowUtc
    )

    foreach ($property in @('AMServiceEnabled', 'AntivirusEnabled', 'AntispywareEnabled', 'RealTimeProtectionEnabled')) {
        if (-not [bool]$Status.$property) {
            throw "Microsoft Defender state is unsafe: $property is not enabled."
        }
    }
    if ([bool]$Status.DefenderSignaturesOutOfDate) {
        throw 'Microsoft Defender signatures are marked out of date.'
    }
    $signatureUtc = ([DateTime]$Status.AntivirusSignatureLastUpdated).ToUniversalTime()
    if (($NowUtc - $signatureUtc).TotalHours -gt 48 -or $signatureUtc -gt $NowUtc.AddMinutes(5)) {
        throw 'Microsoft Defender signature timestamp is stale or invalid.'
    }
    if (@($ActiveThreats).Count -ne 0) {
        throw 'Microsoft Defender reports an active threat.'
    }
    [ordered]@{
        engine = 'Microsoft Defender Antivirus'
        service_enabled = [bool]$Status.AMServiceEnabled
        antivirus_enabled = [bool]$Status.AntivirusEnabled
        antispyware_enabled = [bool]$Status.AntispywareEnabled
        realtime_enabled = [bool]$Status.RealTimeProtectionEnabled
        signatures_out_of_date = [bool]$Status.DefenderSignaturesOutOfDate
        signature_version = [string]$Status.AntivirusSignatureVersion
        signature_updated_utc = $signatureUtc.ToString('o')
        active_threat_count = 0
    }
}

function Get-LiveDefenderState {
    [CmdletBinding()]
    param()

    $status = Get-MpComputerStatus -ErrorAction Stop
    $threats = @(Get-MpThreat -ErrorAction Stop | Where-Object { $_.IsActive })
    Assert-DefenderState -Status $status -ActiveThreats $threats -NowUtc ([DateTime]::UtcNow)
}

function Get-DefenderDetectionKeys {
    [CmdletBinding()]
    param()

    @(
        Get-MpThreatDetection -ErrorAction Stop |
            ForEach-Object { "$(($_.ThreatID -as [string]))|$(($_.InitialDetectionTime -as [string]))|$(($_.Resources -join ','))" }
    )
}

function Assert-NoNewDefenderDetection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BaselineKeys)

    $after = @(Get-DefenderDetectionKeys)
    $new = @($after | Where-Object { $BaselineKeys -notcontains $_ })
    if ($new.Count -ne 0) {
        throw "Microsoft Defender recorded $($new.Count) new detection(s) during promotion verification."
    }
    [ordered]@{ baseline_detection_count = $BaselineKeys.Count; new_detection_count = 0 }
}

function Read-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    Get-Content -LiteralPath $LiteralPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 64
}

function Assert-NoPrivatePathText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$AdditionalForbidden = @()
    )

    $scan = Test-PathPrivacyContract -LiteralPaths @($Root) -PhysicalRoots @($AdditionalForbidden) `
        -LeafPhysicalRoots @($AdditionalForbidden) -UserProfile ([Environment]::GetFolderPath('UserProfile')) `
        -UserName ([Environment]::UserName) -RelativeTo $Root
    if (-not $scan.passed) {
        $categories = @($scan.violations.category | Sort-Object -Unique)
        throw "Private path marker found in candidate bytes: $($categories -join ',')."
    }
    $true
}

function Assert-CandidateAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$ExpectedBackend
    )

    $contract = Get-LocalRuntimePromotionContract
    $raw = Get-Content -LiteralPath $LiteralPath -Raw -Encoding utf8
    if ($raw -match '(?i)"(?:text|transcript|delta|words?)"\s*:' -or
        $raw -match '(?i)[A-Z]:\\(?:\\)?Users\\|[A-Z]:/(?:Users)/') {
        throw 'Acceptance evidence contains transcript or private-path material.'
    }
    $evidence = $raw | ConvertFrom-Json -Depth 64
    $expectedName = if ($ExpectedBackend -eq 'cpu') { $contract.CpuName } else { $contract.CudaName }
    $expectedBytes = if ($ExpectedBackend -eq 'cpu') { $contract.CpuBytes } else { $contract.CudaBytes }
    $expectedHash = if ($ExpectedBackend -eq 'cpu') { $contract.CpuSha256 } else { $contract.CudaSha256 }
    $expectedDevice = if ($ExpectedBackend -eq 'cpu') { 'cpu' } else { 'cuda:0' }
    if ($evidence.schema -cne 'diagnotes-runtime-candidate-acceptance-v1' -or
        $evidence.backend -cne $ExpectedBackend -or -not [bool]$evidence.passed -or
        $evidence.candidate.name -cne $expectedName -or [long]$evidence.candidate.size -ne $expectedBytes -or
        ([string]$evidence.candidate.sha256).ToUpperInvariant() -cne $expectedHash -or
        $evidence.model.repo -cne 'nemotron-3.5-asr-streaming-0.6b' -or
        $evidence.model.revision -cne $contract.ModelRevision -or [long]$evidence.model.size -ne $contract.ModelBytes -or
        ([string]$evidence.model.sha256).ToUpperInvariant() -cne $contract.ModelSha256 -or
        $evidence.defender.status -cne 'PASS' -or -not [bool]$evidence.defender.real_time_protection -or
        [int]$evidence.defender.scan_exit_code -ne 0 -or $evidence.ready.status -cne 'PASS' -or
        -not [bool]$evidence.ready.ready -or $evidence.ready.device -cne $expectedDevice -or
        (@($evidence.ready.capabilities) -join ';') -cne 'asr' -or
        (@($evidence.ready.runtime_capabilities) -join ';') -cne 'realtime-language-v1' -or
        $evidence.causal_backend.status -cne 'PASS') {
        throw "Acceptance evidence is not exact for $ExpectedBackend."
    }
    $fixtures = @($evidence.fixtures)
    if ($fixtures.Count -ne 2 -or (@($fixtures.id | Sort-Object) -join ';') -cne 'synthetic-en;synthetic-es') {
        throw "Acceptance fixture set is not exact for $ExpectedBackend."
    }
    foreach ($fixture in $fixtures) {
        $prefix = if ($fixture.id -ceq 'synthetic-en') { 'en' } else { 'es' }
        if ($fixture.http.status -cne 'PASS' -or -not [bool]$fixture.http.result_nonempty -or
            [string]$fixture.http.language -notmatch ('^(?i:' + $prefix + ')(?:[-_]|$)') -or
            $fixture.realtime.status -cne 'PASS' -or -not [bool]$fixture.realtime.result_nonempty -or
            [bool]$fixture.realtime.ambiguous -or
            [string]$fixture.realtime.language -notmatch ('^(?i:' + $prefix + ')(?:[-_]|$)')) {
            throw "Acceptance fixture failed for $ExpectedBackend."
        }
    }
    $details = $evidence.causal_backend.details
    if ($ExpectedBackend -eq 'cpu') {
        if (-not [bool]$details.model_backend_cpu -or [bool]$details.cuda_model_backend_absent -ne $true -or
            -not [bool]$details.fallback_absent) { throw 'CPU causal evidence is not exact.' }
    } else {
        if (-not [bool]$details.model_backend_cuda0 -or -not [bool]$details.cuda_device_sm86 -or
            -not [bool]$details.cuda_graph_compute -or -not [bool]$details.fallback_absent) {
            throw 'CUDA causal evidence is not exact.'
        }
    }
    [ordered]@{ backend=$ExpectedBackend; candidate_name=$expectedName; candidate_bytes=$expectedBytes; candidate_sha256=$expectedHash; passed=$true }
}

function Assert-RequiredPromotionMembers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$RelativePaths
    )

    foreach ($relative in $RelativePaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) {
            throw "Required archive member is absent: '$relative'."
        }
    }
    $true
}

function Assert-BackendIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RuntimeMetadata,
        [Parameter(Mandatory)][ValidateSet('cpu', 'cuda')][string]$ExpectedBackend
    )

    if ([string]$RuntimeMetadata.backend -cne $ExpectedBackend) {
        throw "Backend is crossed: '$($RuntimeMetadata.backend)' is not '$ExpectedBackend'."
    }
    $true
}

function Assert-NoModelPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$InventoryFiles,
        [Parameter(Mandatory)][long]$ForbiddenBytes,
        [Parameter(Mandatory)][string]$ForbiddenSha256
    )

    $modelArtifacts = @($InventoryFiles | Where-Object { [string]$_.path -match '(?i)\.(gguf|nemo|ckpt|safetensors)$' })
    if ($modelArtifacts.Count -ne 0 -or
        @($InventoryFiles | Where-Object { [long]$_.size -eq $ForbiddenBytes -or ([string]$_.sha256).ToUpperInvariant() -ceq $ForbiddenSha256.ToUpperInvariant() }).Count -ne 0) {
        throw 'A model artifact is included in the runtime ZIP.'
    }
    $true
}

function Assert-ZipEntrySafety {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or
                $name -match '^[A-Za-z]:' -or $name.Split('/') -contains '..') {
                throw "Unsafe ZIP entry: '$name'."
            }
            [void]$roots.Add($name.Split('/')[0])
        }
        if ($roots.Count -ne 1) {
            throw "ZIP must contain exactly one top-level root; found $($roots.Count)."
        }
        @($roots)[0]
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-ExtractedRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExtractRoot,
        [Parameter(Mandatory)][ValidateSet('cpu', 'cuda')][string]$Backend,
        [Parameter(Mandatory)][string]$ExpectedTopRoot,
        [Parameter(Mandatory)][string]$PublicLicensePath,
        [Parameter(Mandatory)][string]$PublicNoticePath,
        [Parameter(Mandatory)][string[]]$PrivateMarkers
    )

    $contract = Get-LocalRuntimePromotionContract
    $root = Join-Path $ExtractRoot $ExpectedTopRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Expected extracted root is absent: '$ExpectedTopRoot'."
    }
    $actualRoots = @(Get-ChildItem -LiteralPath $ExtractRoot -Force)
    if ($actualRoots.Count -ne 1 -or $actualRoots[0].Name -cne $ExpectedTopRoot) {
        throw 'Extraction contains an unexpected top-level item.'
    }

    $required = @('inventory.json', 'sbom.spdx.json', 'runtime-build.json', 'pe-imports.json',
        'msvc-redist-inventory.json', 'LICENSE', 'NOTICE', $contract.PatchName,
        'share/nemo-speech/model-index.json')
    Assert-RequiredPromotionMembers -Root $root -RelativePaths $required | Out-Null

    $runtime = Read-JsonFile (Join-Path $root 'runtime-build.json')
    Assert-BackendIdentity -RuntimeMetadata $runtime -ExpectedBackend $Backend | Out-Null
    if ($runtime.identity -cne $contract.Identity -or
        $runtime.source_commit -cne $contract.SourceCommit -or
        ([string]$runtime.patch_sha256).ToUpperInvariant() -cne $contract.PatchSha256 -or
        [long]$runtime.patch_bytes -ne $contract.PatchBytes -or
        $runtime.execution_mode -cne 'local' -or $runtime.authenticode -cne 'absent-by-contract') {
        throw "runtime-build.json does not match the frozen $Backend contract."
    }
    $capabilities = @($runtime.runtime_capabilities)
    if ($capabilities.Count -ne 1 -or $capabilities[0] -cne 'realtime-language-v1') {
        throw 'Runtime capability contract is not exact.'
    }
    if ($runtime.vcpkg_commit -cne '9e593bb18ea69cc5095e012465dcd675a822ed0d' -or
        $runtime.vcpkg_triplet -cne 'x64-windows-static-md' -or
        $runtime.msvc_toolset_version -cne '14.44.35207' -or
        $runtime.msvc_crt -cne 'dynamic-app-local') {
        throw 'Frozen toolchain contract is not exact.'
    }
    if ($Backend -eq 'cpu') {
        if ($null -ne $runtime.cuda_architectures -or $null -ne $runtime.cuda -or $null -ne $runtime.cuda_installer) {
            throw 'CPU candidate unexpectedly declares CUDA metadata.'
        }
    }
    else {
        if ((@($runtime.cuda_architectures) -join ';') -cne '75;80;86;89' -or
            $runtime.cuda -cne 'Build cuda_12.8.r12.8/compiler.35404655_0' -or
            [bool]$runtime.cuda_installer.driver -or
            (@($runtime.cuda_installer.components) -join ';') -cne 'nvcc_12.8;cudart_12.8;cublas_12.8;cublas_dev_12.8;thrust_12.8') {
            throw 'CUDA candidate does not carry the exact matrix/toolkit contract.'
        }
    }

    $inventory = Read-JsonFile (Join-Path $root 'inventory.json')
    if ($inventory.schema -cne 'diagnotes-runtime-inventory-v2' -or $inventory.scope -cne 'payload-only' -or
        (@($inventory.exclusions) -join ';') -cne 'inventory.json;sbom.spdx.json') {
        throw 'Inventory contract is invalid.'
    }
    $inventoryMap = @{}
    foreach ($record in @($inventory.files)) {
        $relative = ([string]$record.path).Replace('\', '/')
        if ($relative.StartsWith('/') -or $relative.Split('/') -contains '..' -or $inventoryMap.ContainsKey($relative)) {
            throw "Unsafe or duplicate inventory path: '$relative'."
        }
        $filePath = Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $checked = Assert-PromotionFile -LiteralPath $filePath -ExpectedName ([IO.Path]::GetFileName($relative)) -ExpectedBytes ([long]$record.size) -ExpectedSha256 ([string]$record.sha256)
        $inventoryMap[$relative] = $checked
    }
    $diskPayload = @(
        Get-ChildItem -LiteralPath $root -File -Recurse -Force |
            ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') } |
            Where-Object { $_ -notin @('inventory.json', 'sbom.spdx.json') }
    )
    if ($diskPayload.Count -ne $inventoryMap.Count -or @($diskPayload | Where-Object { -not $inventoryMap.ContainsKey($_) }).Count -ne 0) {
        throw 'Inventory and extracted payload are not bidirectionally equal.'
    }

    $sbom = Read-JsonFile (Join-Path $root 'sbom.spdx.json')
    if ($sbom.spdxVersion -cne 'SPDX-2.3' -or @($sbom.files).Count -ne $inventoryMap.Count) {
        throw 'SBOM contract or cardinality is invalid.'
    }
    $sbomMap = @{}
    foreach ($record in @($sbom.files)) {
        $relative = [string]$record.fileName
        $sha = @($record.checksums | Where-Object { $_.algorithm -ceq 'SHA256' })
        if ($sha.Count -ne 1 -or $sbomMap.ContainsKey($relative)) {
            throw "SBOM entry is ambiguous or duplicated: '$relative'."
        }
        $sbomMap[$relative] = ([string]$sha[0].checksumValue).ToUpperInvariant()
    }
    foreach ($relative in $inventoryMap.Keys) {
        if (-not $sbomMap.ContainsKey($relative) -or $sbomMap[$relative] -cne $inventoryMap[$relative].sha256) {
            throw "SBOM does not match inventory for '$relative'."
        }
    }

    $patch = Assert-PromotionFile -LiteralPath (Join-Path $root $contract.PatchName) -ExpectedName $contract.PatchName -ExpectedBytes $contract.PatchBytes -ExpectedSha256 $contract.PatchSha256
    $publicPatch = Assert-PromotionFile -LiteralPath (Join-Path (Split-Path -Parent $PublicLicensePath) ('patches/' + $contract.PatchName)) -ExpectedName $contract.PatchName -ExpectedBytes $contract.PatchBytes -ExpectedSha256 $contract.PatchSha256
    if ($patch.sha256 -cne $publicPatch.sha256) { throw 'Archive patch differs from the canonical public patch.' }
    foreach ($legal in @(@('LICENSE', $PublicLicensePath), @('NOTICE', $PublicNoticePath))) {
        $inside = Join-Path $root $legal[0]
        if ((Get-PromotionSha256 $inside) -cne (Get-PromotionSha256 $legal[1])) {
            throw "Archive $($legal[0]) differs from the public canonical file."
        }
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $root 'share/licenses') -File -Recurse -ErrorAction Stop).Count -eq 0) {
        throw 'Archive license tree is empty.'
    }

    $modelIndex = Read-JsonFile (Join-Path $root 'share/nemo-speech/model-index.json')
    $fixedModel = @($modelIndex.models | Where-Object { $_.repo -ceq $contract.ModelRepo -and $_.revision -ceq $contract.ModelRevision })
    if ($fixedModel.Count -ne 1) { throw 'Compatible model metadata is absent or ambiguous.' }
    Assert-NoModelPayload -InventoryFiles @($inventory.files) -ForbiddenBytes $contract.ModelBytes -ForbiddenSha256 $contract.ModelSha256 | Out-Null

    Assert-NoPrivatePathText -Root $root -AdditionalForbidden $PrivateMarkers | Out-Null

    $pe = Read-JsonFile (Join-Path $root 'pe-imports.json')
    if ($pe.schema -cne 'diagnotes-pe-closure-v1' -or @($pe.imports).Count -eq 0) { throw 'PE closure metadata is invalid.' }
    $peFiles = @($inventory.files | Where-Object { $_.kind -ceq 'PE' } | ForEach-Object { [IO.Path]::GetFileName([string]$_.path) })
    $binNames = @($inventory.files | Where-Object { ([string]$_.path).StartsWith('bin/', [StringComparison]::Ordinal) } | ForEach-Object { [IO.Path]::GetFileName([string]$_.path) })
    $allowedClasses = @('app-local', 'msvc-redist-app-local', 'windows-system', 'windows-api-set',
        'nvidia-cuda-runtime-app-local', 'nvidia-host-driver-prerequisite')
    foreach ($edge in @($pe.imports)) {
        if ($peFiles -notcontains [string]$edge.importer -or $allowedClasses -notcontains [string]$edge.classification) {
            throw 'PE closure contains an unknown importer or classification.'
        }
        if ($edge.classification -in @('app-local', 'msvc-redist-app-local', 'nvidia-cuda-runtime-app-local') -and
            $binNames -notcontains [string]$edge.dependency) {
            throw "PE app-local dependency is absent: '$($edge.dependency)'."
        }
        if ($edge.classification -ceq 'nvidia-host-driver-prerequisite' -and [string]$edge.dependency -cne 'nvcuda.dll') {
            throw "Unexpected NVIDIA host-driver prerequisite: '$($edge.dependency)'."
        }
    }
    $redist = Read-JsonFile (Join-Path $root 'msvc-redist-inventory.json')
    if ($redist.schema -cne 'diagnotes-msvc-redist-v1' -or @($redist.dlls).Count -lt 4 -or
        @($redist.dlls | Where-Object { $_.name -ieq 'VCOMP140.DLL' }).Count -ne 1) {
        throw 'MSVC Redist inventory is incomplete.'
    }
    foreach ($dll in @($redist.dlls)) {
        $match = @($inventory.files | Where-Object { $_.path -ieq "bin/$($dll.name)" })
        if ($match.Count -ne 1 -or ([string]$match[0].sha256).ToUpperInvariant() -cne ([string]$dll.sha256).ToUpperInvariant()) {
            throw "MSVC Redist DLL is not closed in inventory: '$($dll.name)'."
        }
    }

    $hasCudaPe = $binNames -contains 'ggml-cuda.dll'
    if (($Backend -eq 'cpu' -and $hasCudaPe) -or ($Backend -eq 'cuda' -and -not $hasCudaPe)) {
        throw "Backend payload is crossed for '$Backend'."
    }
    if ($Backend -eq 'cuda') {
        foreach ($name in @('ggml-cuda.dll', 'cublas64_12.dll', 'cudart64_12.dll')) {
            if ($binNames -notcontains $name) { throw "CUDA payload is missing '$name'." }
        }
    }

    [ordered]@{
        backend = $Backend
        top_root = $ExpectedTopRoot
        inventory_files = $inventoryMap.Count
        sbom_files = $sbomMap.Count
        pe_imports = @($pe.imports).Count
        redist_dlls = @($redist.dlls).Count
        model_included = $false
        private_path_found = $false
        source_commit = $runtime.source_commit
        patch_sha256 = $patch.sha256
        capabilities = @($runtime.runtime_capabilities)
        architectures = if ($Backend -eq 'cuda') { @($runtime.cuda_architectures) } else { @() }
        toolchain = [ordered]@{
            cmake = $runtime.cmake
            ninja = $runtime.ninja
            msvc = $runtime.msvc
            windows_sdk = $runtime.windows_sdk
            vcpkg_commit = $runtime.vcpkg_commit
            vcpkg_triplet = $runtime.vcpkg_triplet
            msvc_toolset_version = $runtime.msvc_toolset_version
            msvc_crt = $runtime.msvc_crt
            cuda = $runtime.cuda
        }
    }
}

function Assert-ExactAssetSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ActualNames,
        [Parameter(Mandatory)][string[]]$ExpectedNames
    )

    $actual = @($ActualNames | Sort-Object)
    $expected = @($ExpectedNames | Sort-Object)
    if ($actual.Count -ne $expected.Count -or @(Compare-Object $expected $actual -CaseSensitive).Count -ne 0) {
        throw "Asset set is not exact. Expected $($expected -join ', '); actual $($actual -join ', ')."
    }
    $true
}

function Assert-LocalProvenanceManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $contract = Get-LocalRuntimePromotionContract
    $json = $Manifest | ConvertTo-Json -Depth 64 -Compress
    if ($Manifest.schema -cne 'diagnotes-local-runtime-release-manifest-v1' -or
        $Manifest.identity -cne $contract.Identity -or $Manifest.release_tag -cne $contract.Tag -or
        $Manifest.target_commit -cne $contract.TargetCommit -or
        $Manifest.source.upstream_commit -cne $contract.SourceCommit -or
        $Manifest.source.patch.name -cne $contract.PatchName -or
        [long]$Manifest.source.patch.bytes -ne $contract.PatchBytes -or
        ([string]$Manifest.source.patch.sha256).ToUpperInvariant() -cne $contract.PatchSha256 -or
        $Manifest.provenance.kind -cne 'local-build-local-verification' -or
        [bool]$Manifest.provenance.github_built -or [bool]$Manifest.provenance.slsa -or
        [bool]$Manifest.provenance.actions_build_attestation) {
        throw 'Manifest identity, source, patch, target, or local provenance is not exact.'
    }
    if ($json -match '(?i)GitHub-built|SLSA provenance|Actions build provenance' -or
        $json -match '(?i)[A-Z]:\\Users\\|[A-Z]:\\\\Users\\\\') {
        throw 'Manifest contains a forbidden provenance claim or private path.'
    }
    if ($Manifest.PSObject.Properties.Name -contains 'release_manifest') {
        $selfReference = $Manifest.release_manifest
        if ($selfReference -and [string]$selfReference.name -ieq 'release-manifest.json' -and
            (@($selfReference.PSObject.Properties.Name | Where-Object { $_ -in @('sha256', 'bytes') }).Count -ne 0)) {
            throw 'Manifest appears to self-reference its own digest or size.'
        }
    }

    if ($Manifest.compatible_model.repository -cne $contract.ModelRepo -or
        $Manifest.compatible_model.revision -cne $contract.ModelRevision -or
        [long]$Manifest.compatible_model.bytes -ne $contract.ModelBytes -or
        ([string]$Manifest.compatible_model.sha256).ToUpperInvariant() -cne $contract.ModelSha256 -or
        [bool]$Manifest.compatible_model.included -or -not [bool]$Manifest.compatible_model.license_separate) {
        throw 'Manifest model separation contract is not exact.'
    }

    Assert-ExactAssetSet -ActualNames @($Manifest.asset_set) -ExpectedNames $contract.AssetNames | Out-Null
    $expectedCandidates = @(
        [ordered]@{ name = $contract.CpuName; backend = 'cpu'; bytes = $contract.CpuBytes; sha256 = $contract.CpuSha256; arch = 'x86_64'; cuda = '' },
        [ordered]@{ name = $contract.CudaName; backend = 'cuda'; bytes = $contract.CudaBytes; sha256 = $contract.CudaSha256; arch = 'sm75;sm80;sm86;sm89'; cuda = 'Build cuda_12.8.r12.8/compiler.35404655_0' }
    )
    if (@($Manifest.candidates).Count -ne 2) { throw 'Manifest must describe exactly two runtime candidates.' }
    foreach ($expected in $expectedCandidates) {
        $candidate = @($Manifest.candidates | Where-Object { $_.name -ceq $expected.name })
        if ($candidate.Count -ne 1 -or $candidate[0].backend -cne $expected.backend -or
            [long]$candidate[0].bytes -ne $expected.bytes -or
            ([string]$candidate[0].sha256).ToUpperInvariant() -cne $expected.sha256 -or
            (@($candidate[0].architectures) -join ';') -cne $expected.arch -or
            (@($candidate[0].runtime_capabilities) -join ';') -cne 'realtime-language-v1') {
            throw "Manifest candidate contract is not exact for '$($expected.name)'."
        }
        $toolchain = $candidate[0].toolchain
        if ($toolchain.vcpkg_commit -cne '9e593bb18ea69cc5095e012465dcd675a822ed0d' -or
            $toolchain.vcpkg_triplet -cne 'x64-windows-static-md' -or
            $toolchain.msvc_toolset_version -cne '14.44.35207' -or
            $toolchain.msvc_crt -cne 'dynamic-app-local' -or [string]$toolchain.cuda -cne $expected.cuda) {
            throw "Manifest toolchain contract is not exact for '$($expected.name)'."
        }
    }

    $expectedDetached = @{
        'LICENSE' = [ordered]@{ bytes = $contract.LicenseBytes; sha256 = $contract.LicenseSha256 }
        'NOTICE' = [ordered]@{ bytes = $contract.NoticeBytes; sha256 = $contract.NoticeSha256 }
        $contract.PatchName = [ordered]@{ bytes = $contract.PatchBytes; sha256 = $contract.PatchSha256 }
    }
    if (@($Manifest.detached_assets).Count -ne 3) { throw 'Manifest must describe exactly three detached canonical assets.' }
    foreach ($name in $expectedDetached.Keys) {
        $asset = @($Manifest.detached_assets | Where-Object { $_.name -ceq $name })
        if ($asset.Count -ne 1 -or [long]$asset[0].bytes -ne $expectedDetached[$name].bytes -or
            ([string]$asset[0].sha256).ToUpperInvariant() -cne $expectedDetached[$name].sha256) {
            throw "Manifest detached asset contract is not exact for '$name'."
        }
    }

    if (-not [bool]$Manifest.defender.antivirus_enabled -or -not [bool]$Manifest.defender.antispyware_enabled -or
        -not [bool]$Manifest.defender.realtime_enabled -or [bool]$Manifest.defender.signatures_out_of_date -or
        [int]$Manifest.defender.active_threat_count -ne 0 -or [int]$Manifest.defender.new_detection_count -ne 0 -or
        (@($Manifest.defender.scans) -join ';') -cne 'cpu-zip;cuda-zip;cpu-fresh-extraction;cuda-fresh-extraction') {
        throw 'Manifest Defender contract is not green and exact.'
    }
    $signatureTime = ([DateTime]$Manifest.defender.signature_updated_utc).ToUniversalTime()
    if (([DateTime]::UtcNow - $signatureTime).TotalHours -gt 48) { throw 'Manifest Defender signature time is stale.' }
    if (-not [bool]$Manifest.verification.zip_bytes_rechecked -or -not [bool]$Manifest.verification.extraction_fresh -or
        [bool]$Manifest.verification.binaries_executed -or [bool]$Manifest.verification.model_loaded -or
        [bool]$Manifest.verification.audio_used -or -not [bool]$Manifest.verification.live_acceptance_performed -or
        [bool]$Manifest.verification.acceptance_reused -or @($Manifest.verification.acceptance).Count -ne 2 -or
        $Manifest.verification.cpu.backend -cne 'cpu' -or $Manifest.verification.cuda.backend -cne 'cuda' -or
        [bool]$Manifest.verification.cpu.model_included -or [bool]$Manifest.verification.cuda.model_included -or
        [bool]$Manifest.verification.cpu.private_path_found -or [bool]$Manifest.verification.cuda.private_path_found) {
        throw 'Manifest verification contract is not exact.'
    }
    $acceptance = @($Manifest.verification.acceptance)
    foreach ($expected in @(
        [ordered]@{ backend='cpu'; name=$contract.CpuName; bytes=$contract.CpuBytes; sha256=$contract.CpuSha256 },
        [ordered]@{ backend='cuda'; name=$contract.CudaName; bytes=$contract.CudaBytes; sha256=$contract.CudaSha256 }
    )) {
        $entry = @($acceptance | Where-Object { $_.backend -ceq $expected.backend })
        if ($entry.Count -ne 1 -or -not [bool]$entry[0].passed -or
            $entry[0].candidate_name -cne $expected.name -or [long]$entry[0].candidate_bytes -ne $expected.bytes -or
            ([string]$entry[0].candidate_sha256).ToUpperInvariant() -cne $expected.sha256) {
            throw "Manifest acceptance summary is not exact for '$($expected.backend)'."
        }
    }
    $true
}

function Assert-ExactChecksumLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [Parameter(Mandatory)][string]$AssetRoot
    )

    $contract = Get-LocalRuntimePromotionContract
    $expectedNames = @($contract.AssetNames | Where-Object { $_ -cne 'SHA256SUMS.txt' })
    $lines = @(Get-Content -LiteralPath $LedgerPath)
    if ($lines.Count -ne 6) { throw 'SHA256SUMS must contain exactly six entries.' }
    $seen = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '^([0-9A-F]{64})  ([^\\/]+)$') { throw "Malformed SHA256SUMS line: '$line'." }
        $hash = $Matches[1]
        $name = $Matches[2]
        if ($seen.ContainsKey($name)) { throw "Duplicate SHA256SUMS entry: '$name'." }
        $seen[$name] = $hash
    }
    Assert-ExactAssetSet -ActualNames @($seen.Keys) -ExpectedNames $expectedNames | Out-Null
    foreach ($name in $expectedNames) {
        if ((Get-PromotionSha256 (Join-Path $AssetRoot $name)) -cne $seen[$name]) {
            throw "SHA256SUMS mismatch for '$name'."
        }
    }
    $true
}

function Get-AuthorizedAssetSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetRoot,
        [Parameter(Mandatory)][string]$CheckoutRoot
    )

    $contract = Get-LocalRuntimePromotionContract
    $root = Assert-SafeExistingOutsideCheckoutPath -LiteralPath $AssetRoot -CheckoutRoot $CheckoutRoot -Label 'AssetRoot'
    Assert-ExactAssetSet -ActualNames @(Get-ChildItem -LiteralPath $root -File -Force | ForEach-Object Name) -ExpectedNames $contract.AssetNames | Out-Null
    Assert-PromotionFile (Join-Path $root $contract.CpuName) $contract.CpuName $contract.CpuBytes $contract.CpuSha256 | Out-Null
    Assert-PromotionFile (Join-Path $root $contract.CudaName) $contract.CudaName $contract.CudaBytes $contract.CudaSha256 | Out-Null
    Assert-PromotionFile (Join-Path $root 'LICENSE') 'LICENSE' $contract.LicenseBytes $contract.LicenseSha256 | Out-Null
    Assert-PromotionFile (Join-Path $root 'NOTICE') 'NOTICE' $contract.NoticeBytes $contract.NoticeSha256 | Out-Null
    Assert-PromotionFile (Join-Path $root $contract.PatchName) $contract.PatchName $contract.PatchBytes $contract.PatchSha256 | Out-Null
    $manifest = Get-Content -LiteralPath (Join-Path $root 'release-manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 64
    Assert-LocalProvenanceManifest $manifest | Out-Null
    Assert-ExactChecksumLedger -LedgerPath (Join-Path $root 'SHA256SUMS.txt') -AssetRoot $root | Out-Null
    Assert-NoPrivatePathText -Root $root | Out-Null
    @(
        $contract.AssetNames | ForEach-Object {
            $file = Get-Item -LiteralPath (Join-Path $root $_)
            [pscustomobject]@{ name = $_; bytes = $file.Length; sha256 = Get-PromotionSha256 $file.FullName }
        }
    )
}

function Assert-AssetSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssetRoot,
        [Parameter(Mandatory)][object[]]$Snapshot
    )

    Assert-ExactAssetSet -ActualNames @(Get-ChildItem -LiteralPath $AssetRoot -File -Force | ForEach-Object Name) -ExpectedNames @($Snapshot | ForEach-Object name) | Out-Null
    foreach ($expected in $Snapshot) {
        Assert-PromotionFile (Join-Path $AssetRoot $expected.name) $expected.name ([long]$expected.bytes) ([string]$expected.sha256) | Out-Null
    }
    $true
}

function Assert-NoClobberArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (@($Arguments | Where-Object { $_ -ieq '--clobber' }).Count -ne 0) {
        throw 'Asset replacement with --clobber is forbidden.'
    }
    $true
}

function Assert-DraftReleaseContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$ExpectedTag,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )

    if ([string]$Release.tag_name -cne $ExpectedTag -or [string]$Release.target_commitish -cne $ExpectedTarget -or
        -not [bool]$Release.draft -or [bool]$Release.prerelease) {
        throw 'GitHub release is not the exact private draft contract.'
    }
    $true
}

function Assert-EmptyReleaseSurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Releases,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RemoteTags
    )

    if (@($Releases).Count -ne 0) {
        throw 'A GitHub release or draft already exists.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RemoteTags)) {
        throw 'A remote Git tag already exists.'
    }
    $true
}

function Write-Utf8NoBom {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][string]$Text)

    [IO.File]::WriteAllText($LiteralPath, $Text, [Text.UTF8Encoding]::new($false))
}

Export-ModuleMember -Function @(
    'Get-LocalRuntimePromotionContract', 'Get-PromotionSha256', 'Assert-PromotionFile',
    'Assert-NoBuildIntent', 'Assert-NoBuildProcesses', 'Assert-FreshOutsideCheckoutPath',
    'Assert-SafeExistingOutsideCheckoutPath',
    'Assert-DefenderState', 'Get-LiveDefenderState', 'Get-DefenderDetectionKeys',
    'Assert-NoNewDefenderDetection', 'Assert-ZipEntrySafety', 'Assert-ExtractedRuntime',
    'Assert-ExactAssetSet', 'Assert-LocalProvenanceManifest', 'Assert-ExactChecksumLedger',
    'Get-AuthorizedAssetSnapshot', 'Assert-AssetSnapshot', 'Assert-RequiredPromotionMembers',
    'Assert-BackendIdentity', 'Assert-NoModelPayload', 'Assert-NoPrivatePathText',
    'Assert-CandidateAcceptanceEvidence',
    'Assert-NoClobberArgument', 'Assert-DraftReleaseContract', 'Assert-EmptyReleaseSurface',
    'Write-Utf8NoBom'
)
