#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cpu', 'cuda')]
    [string]$Backend,
    [ValidateSet('Release')]
    [string]$Configuration = 'Release',
    [string]$CudaArch = '75;80;86;89',
    [string]$CudaVersion = '12.8',
    [switch]$Local,
    [string]$LocalWorkRoot,
    [switch]$FreshLocalWorkRoot,
    [switch]$ReuseLocalCuda
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SourceCommit = '4f9676226f667d14608487df744f375db87127f8'
$PatchSha256 = '80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84'
$PatchBytes = 1793
$Version = 'nemo-speech-v0.1.0-diagnotes-lid.3'
$VcpkgTriplet = 'x64-windows-static-md'
$ExpectedVcpkgCommit = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$CudaInstallerUrl = 'https://developer.download.nvidia.com/compute/cuda/12.8.0/network_installers/cuda_12.8.0_windows_network.exe'
$CudaInstallerSha256 = '89E7C44B526B6E30EC5089F221E918090D11F1D5B33C48FBFE08C6AC13F8A95C'
$CudaInstallerMd5 = '1D7E1CF4047F2B8D9A8096E18EBEA1C7'
$CudaLicenseSha256 = 'E2C71BABFD18A8E69542DD7E9CA018F9CAA438094001A58E6BC4D8C999BF0D07'
$VsLicenseUrl = 'https://visualstudio.microsoft.com/wp-content/uploads/2021/11/Visual-Studio-2022-Community-License-EN.docx'
$VsLicenseSha256 = '41A207B10C8AB91D0D2F10A854715F73DCA54509581692D2FE179AA3FFCB8540'
$VsRedistListUrl = 'https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution'
$VsRedistListSha256 = '299A7995A78922F974AADC4E99D1ED659A6C7B897A5986DCB6B919BC7F64DB9B'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PatchPath = Join-Path $RepoRoot 'patches\realtime-language-v1.patch'
$runIdentity = $null
$WorkRoot = $null
$SourceRoot = $null
$BuildRoot = $null
$InstallRoot = $null
$PackageRoot = $null
$ArtifactsRoot = $null
$EvidenceRoot = $null
$ExecutionMode = if ($Local) { 'local' } else { 'github' }
$RecipeCommit = $null
$LocalBuildBase = $null
$LocalCudaProofPath = $null

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE" }
}

function Get-ProcessEnvironmentMap {
    $map = [ordered]@{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator() | Sort-Object Key) {
        $map[[string]$entry.Key] = [string]$entry.Value
    }
    return $map
}

function Restore-ProcessEnvironmentMap {
    param([Parameter(Mandatory)][Collections.IDictionary]$Snapshot)
    $current = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($current.Keys)) {
        if (-not $Snapshot.Contains([string]$key)) {
            [Environment]::SetEnvironmentVariable([string]$key, $null, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue
        }
    }
    foreach ($entry in $Snapshot.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }
}

function Test-GitHubActionsEnvironment {
    $names = @('GITHUB_ACTIONS','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_WORKSPACE','GITHUB_SHA','RUNNER_TEMP')
    $present = @($names | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, 'Process')) })
    $markers = @([Environment]::GetEnvironmentVariables('Process').Keys | Where-Object {
        [string]$_ -match '^(?i:GITHUB_|RUNNER_)' -and
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable([string]$_, 'Process'))
    })
    $coherent = $env:GITHUB_ACTIONS -ceq 'true' -and $present.Count -eq $names.Count
    return [pscustomobject]@{ detected=$markers.Count -gt 0; coherent=$coherent; present=@($markers) }
}

function Resolve-ValidatedLocalWorkRoot {
    param(
        [Parameter(Mandatory)][string]$RequestedRoot,
        [Parameter(Mandatory)][string]$LocalAppDataRoot,
        [switch]$RequireExisting
    )
    if ([string]::IsNullOrWhiteSpace($RequestedRoot) -or [string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        throw 'Local root and LOCALAPPDATA must be explicit.'
    }
    if (-not [IO.Path]::IsPathFullyQualified($RequestedRoot) -or -not [IO.Path]::IsPathFullyQualified($LocalAppDataRoot)) {
        throw 'Local root and LOCALAPPDATA must be fully qualified.'
    }
    if ($RequestedRoot.StartsWith('\\', [StringComparison]::Ordinal) -or
        $RequestedRoot.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $RequestedRoot.StartsWith('\\.\', [StringComparison]::Ordinal)) {
        throw 'UNC and device local roots are forbidden.'
    }
    $segments = @($RequestedRoot -split '[\\/]')
    if (@($segments | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -ne 0) {
        throw 'Local root cannot contain dot segments.'
    }
    $base = [IO.Path]::GetFullPath((Join-Path $LocalAppDataRoot 'DiagNotes\RuntimeBuild')).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath($RequestedRoot).TrimEnd('\')
    if ($candidate -ceq $base -or -not $candidate.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local root must be a strict child of LOCALAPPDATA\DiagNotes\RuntimeBuild.'
    }
    if ($RequireExisting -and -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw 'Expected local root does not exist.'
    }
    $localAppData = [IO.Path]::GetFullPath($LocalAppDataRoot).TrimEnd('\')
    $relative = [IO.Path]::GetRelativePath($localAppData, $candidate)
    $cursor = $localAppData
    if (Test-Path -LiteralPath $cursor) {
        $localAppDataItem = Get-Item -LiteralPath $cursor -Force
        if (($localAppDataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'LOCALAPPDATA is a reparse point.'
        }
    }
    foreach ($segment in @($relative -split '[\\/]')) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Local root chain contains a reparse point.'
            }
            if (-not $item.PSIsContainer) { throw 'Local root chain contains a non-directory.' }
        }
    }
    return [pscustomobject]@{ base=$base; root=$candidate }
}

function Resolve-LocalBuildTools {
    param([Parameter(Mandatory)][string]$VsWherePath)
    if (-not (Test-Path -LiteralPath $VsWherePath -PathType Leaf)) { throw 'vswhere.exe is missing.' }
    $json = (& $VsWherePath -latest -products Microsoft.VisualStudio.Product.BuildTools `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'vswhere failed.' }
    $instances = @($json | ConvertFrom-Json -Depth 20)
    if ($instances.Count -ne 1) { throw 'Expected exactly one latest Visual Studio Build Tools instance.' }
    $vsInstall = [IO.Path]::GetFullPath([string]$instances[0].installationPath).TrimEnd('\')
    $toolsetDirectories = @(Get-ChildItem -LiteralPath (Join-Path $vsInstall 'VC\Tools\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
    if ($toolsetDirectories.Count -eq 0) { throw 'No MSVC toolset directory is installed.' }
    $toolset = $toolsetDirectories[0].Name
    $hostBin = Join-Path $toolsetDirectories[0].FullName 'bin\Hostx64\x64'
    $tools = [ordered]@{
        cmake = Join-Path $vsInstall 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        ninja = Join-Path $vsInstall 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
        cl = Join-Path $hostBin 'cl.exe'
        dumpbin = Join-Path $hostBin 'dumpbin.exe'
    }
    foreach ($entry in $tools.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) { throw "Local Build Tools lacks $($entry.Key)." }
        $resolved = (Resolve-Path -LiteralPath $entry.Value).Path
        if (-not $resolved.StartsWith($vsInstall + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Local $($entry.Key) escaped the Build Tools installation."
        }
    }
    return [pscustomobject]@{
        vs_install=$vsInstall
        product_display_version=[string]$instances[0].catalog.productDisplayVersion
        toolset_version=$toolset
        cmake=$tools.cmake
        ninja=$tools.ninja
        cl=$tools.cl
        dumpbin=$tools.dumpbin
    }
}

function Resolve-MsvcRedistFromCacheContract {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Entries,
        [switch]$RequireMaterialized
    )
    $errors = @()
    foreach ($key in @('CMAKE_CXX_COMPILER','MSVC_REDIST_DIR')) {
        if (-not $Entries.Contains($key)) { $errors += "missing $key" }
    }
    if ($errors.Count -ne 0) { return [pscustomobject]@{ passed=$false; errors=@($errors) } }
    $clEntry = $Entries['CMAKE_CXX_COMPILER']
    $redistEntry = $Entries['MSVC_REDIST_DIR']
    if ($clEntry.type -cne 'FILEPATH') { $errors += 'CMAKE_CXX_COMPILER type' }
    if ($redistEntry.type -cne 'PATH') { $errors += 'MSVC_REDIST_DIR type' }
    $clPath = [IO.Path]::GetFullPath(([string]$clEntry.value).Replace('/','\')).TrimEnd('\')
    $redistVersionRoot = [IO.Path]::GetFullPath(([string]$redistEntry.value).Replace('/','\')).TrimEnd('\')
    $clMatch = [regex]::Match($clPath, '^(?<vs>.+)\\VC\\Tools\\MSVC\\(?<toolset>\d+\.\d+\.\d+)\\bin\\Hostx64\\x64\\cl\.exe$', 'IgnoreCase')
    $redistMatch = [regex]::Match($redistVersionRoot, '^(?<vs>.+)\\VC\\Redist\\MSVC\\(?<redist>\d+\.\d+\.\d+)$', 'IgnoreCase')
    if (-not $clMatch.Success) { $errors += 'compiler path shape' }
    if (-not $redistMatch.Success) { $errors += 'Redist path shape' }
    if ($clMatch.Success -and $redistMatch.Success) {
        if (-not $clMatch.Groups['vs'].Value.Equals($redistMatch.Groups['vs'].Value, [StringComparison]::OrdinalIgnoreCase)) { $errors += 'Visual Studio installation mismatch' }
        $toolsetParts = $clMatch.Groups['toolset'].Value.Split('.')
        $redistParts = $redistMatch.Groups['redist'].Value.Split('.')
        if ($toolsetParts[0] -cne $redistParts[0] -or $toolsetParts[1] -cne $redistParts[1]) { $errors += 'toolset/Redist family mismatch' }
    }
    $dumpbinPath = Join-Path (Split-Path -Parent $clPath) 'dumpbin.exe'
    $redistRoot = Join-Path $redistVersionRoot 'x64\Microsoft.VC143.CRT'
    $openmpRedistRoot = Join-Path $redistVersionRoot 'x64\Microsoft.VC143.OpenMP'
    if ($RequireMaterialized) {
        foreach ($path in @($clPath,$dumpbinPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += "missing materialized file $path" } }
        if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) { $errors += 'missing materialized x64 Redist root' }
        if (-not (Test-Path -LiteralPath $openmpRedistRoot -PathType Container)) { $errors += 'missing materialized x64 OpenMP Redist root' }
        foreach ($path in @($redistVersionRoot,$redistRoot,$openmpRedistRoot)) {
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $errors += 'Redist path is a reparse point' }
            }
        }
    }
    return [pscustomobject]@{
        passed=$errors.Count -eq 0; errors=@($errors); cl_path=$clPath; dumpbin_path=$dumpbinPath
        vs_install=if ($clMatch.Success) { $clMatch.Groups['vs'].Value } else { $null }
        toolset_version=if ($clMatch.Success) { $clMatch.Groups['toolset'].Value } else { $null }
        redist_version=if ($redistMatch.Success) { $redistMatch.Groups['redist'].Value } else { $null }
        redist_version_root=$redistVersionRoot; redist_root=$redistRoot; openmp_redist_root=$openmpRedistRoot
    }
}

function Get-CudaComponentFileMap {
    return [ordered]@{
        nvcc_12_8 = @('bin\nvcc.exe','bin\nvcc.profile','nvvm\bin\cicc.exe')
        cudart_12_8 = @('bin\cudart64_12.dll')
        cublas_12_8 = @('bin\cublas64_12.dll','bin\cublasLt64_12.dll')
        cublas_dev_12_8 = @('include\cublas_v2.h','lib\x64\cublas.lib','lib\x64\cublasLt.lib')
        thrust_12_8 = @('include\thrust\version.h')
    }
}

function Test-LocalCudaReuseProof {
    param(
        [Parameter(Mandatory)][string]$CudaRoot,
        [Parameter(Mandatory)][string]$ProofPath
    )
    $errors = @()
    if (-not (Test-Path -LiteralPath $ProofPath -PathType Leaf)) { return [pscustomobject]@{ passed=$false; errors=@('consented CUDA install proof missing') } }
    try { $proof = [IO.File]::ReadAllText($ProofPath) | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
    catch { return [pscustomobject]@{ passed=$false; errors=@('invalid CUDA install proof JSON') } }
    $expectedArguments = @('-s','-n','nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
    $expectedComponents = @('nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
    if ([string]$proof.schema -cne 'diagnotes-local-cuda-install-proof-v1') { $errors += 'proof schema' }
    if ([string]$proof.installer_url -cne $CudaInstallerUrl -or [string]$proof.installer_sha256 -cne $CudaInstallerSha256 -or [string]$proof.installer_md5 -cne $CudaInstallerMd5) { $errors += 'installer identity' }
    if ((@($proof.arguments | ForEach-Object { [string]$_ }) | ConvertTo-Json -Compress) -cne ($expectedArguments | ConvertTo-Json -Compress)) { $errors += 'installer arguments' }
    if ((@($proof.components | ForEach-Object { [string]$_ }) | ConvertTo-Json -Compress) -cne ($expectedComponents | ConvertTo-Json -Compress)) { $errors += 'component cardinality' }
    if ([bool]$proof.display_driver_requested -or -not [bool]$proof.driver_inventory_unchanged -or -not [bool]$proof.nvidia_service_task_state_unchanged) { $errors += 'driver/service continuity' }
    if (@($proof.lingering_installer_processes).Count -ne 0) { $errors += 'lingering installer history' }
    $versionPath = Join-Path $CudaRoot 'version.json'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { $errors += 'version.json missing' }
    else {
        $versionContract = Test-CudaVersionJson -Json ([IO.File]::ReadAllText($versionPath))
        if (-not $versionContract.passed -or [string]$proof.version_json_sha256 -cne (Get-FileHash -LiteralPath $versionPath -Algorithm SHA256).Hash) { $errors += 'version metadata' }
    }
    $expectedFiles = @(Get-CudaComponentFileMap).Values | ForEach-Object { $_ } | ForEach-Object { $_ }
    $proofFiles = @($proof.files)
    if ($proofFiles.Count -ne $expectedFiles.Count) { $errors += 'proof file cardinality' }
    foreach ($relative in $expectedFiles) {
        $matches = @($proofFiles | Where-Object { [string]$_.path -ceq $relative.Replace('\','/') })
        $path = Join-Path $CudaRoot $relative
        if ($matches.Count -ne 1 -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += "missing proof file $relative"; continue }
        $item = Get-Item -LiteralPath $path
        if ([int64]$matches[0].size -ne $item.Length -or [string]$matches[0].sha256 -cne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) { $errors += "CUDA proof divergence $relative" }
    }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; errors=@($errors) }
}

function Resolve-CudaToolkitLicensePath {
    param(
        [Parameter(Mandatory)][string]$CudaRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedSha256
    )
    $candidates = @(@('LICENSE','EULA.txt') | ForEach-Object { Join-Path $CudaRoot $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($candidates.Count -eq 0) { throw 'Pinned CUDA Toolkit license is missing.' }
    if ($candidates.Count -ne 1) { throw 'Pinned CUDA Toolkit license path is ambiguous.' }
    $hash = (Get-FileHash -LiteralPath $candidates[0] -Algorithm SHA256).Hash
    if ($hash -cne $ExpectedSha256) { throw 'Pinned CUDA Toolkit license hash mismatch.' }
    return [pscustomobject]@{ path=$candidates[0]; name=(Split-Path -Leaf $candidates[0]); sha256=$hash }
}

function Resolve-CudaRuntimeDependencyPath {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CudaRoot
    )
    $allowed = @('cudart64_12.dll','cublas64_12.dll','cublasLt64_12.dll')
    $matches = @($allowed | Where-Object { $_ -ieq $Name })
    if ($matches.Count -ne 1) { throw 'CUDA runtime dependency name is outside the exact allowlist.' }
    $resolvedRoot = [IO.Path]::GetFullPath($CudaRoot).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $resolvedRoot (Join-Path 'bin' $matches[0])))
    if (-not $candidate.StartsWith($resolvedRoot + '\bin\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
        (Get-Item -LiteralPath $candidate).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw 'Exact CUDA runtime dependency is absent or escaped the toolkit bin directory.'
    }
    return $candidate
}

function Get-ProcessEnvironmentVariableState {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$Name)
    $variables = [Environment]::GetEnvironmentVariables('Process')
    $present = $variables.Contains($Name)
    return [pscustomobject]@{
        name=$Name
        present=$present
        value=if ($present) { [string]$variables[$Name] } else { $null }
    }
}

function Restore-ProcessEnvironmentVariableState {
    param([Parameter(Mandatory)][psobject]$State)
    if ($null -eq $State.PSObject.Properties['name'] -or
        $null -eq $State.PSObject.Properties['present'] -or
        $null -eq $State.PSObject.Properties['value'] -or
        [string]$State.name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'Invalid process environment variable state.'
    }
    $name = [string]$State.name
    if ([bool]$State.present) {
        Set-Item -LiteralPath "Env:$name" -Value ([string]$State.value)
    } else {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    $restored = Get-ProcessEnvironmentVariableState -Name $name
    if ($restored.present -ne [bool]$State.present -or
        ($restored.present -and $restored.value -cne [string]$State.value)) {
        throw "Unable to restore process environment variable state: $name"
    }
}

function Test-GgmlPatchSeriesContract {
    param(
        [Parameter(Mandatory)][string]$GgmlRoot,
        [Parameter(Mandatory)][string]$PatchDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
        [ValidateRange(1,100)][int]$ExpectedPatchCount = 16
    )
    $errors = @()
    $expectedTree = $null
    $currentTree = $null
    $changedPaths = @()
    $patchFiles = @()

    if (-not (Test-Path -LiteralPath (Join-Path $GgmlRoot '.git'))) { $errors += 'ggml repository missing' }
    if (-not (Test-Path -LiteralPath $PatchDirectory -PathType Container)) { $errors += 'ggml patch directory missing' }
    if ($errors.Count -eq 0) {
        $actualCommit = (& git -C $GgmlRoot rev-parse HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $ExpectedCommit) { $errors += 'ggml commit mismatch' }
        $patchFiles = @(Get-ChildItem -LiteralPath $PatchDirectory -File -Filter '*.patch' | Sort-Object Name)
        if ($patchFiles.Count -ne $ExpectedPatchCount) { $errors += 'ggml patch cardinality mismatch' }
        for ($index = 0; $index -lt $patchFiles.Count; $index++) {
            $expectedPrefix = ('{0:D4}-' -f ($index + 1))
            if (-not $patchFiles[$index].Name.StartsWith($expectedPrefix, [StringComparison]::Ordinal) -or
                -not $patchFiles[$index].Name.EndsWith('.patch', [StringComparison]::Ordinal)) {
                $errors += 'ggml patch sequence mismatch'
                break
            }
        }
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-ggml-series-' + [Guid]::NewGuid().ToString('N'))
    $previousGitIndexState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
    try {
        if ($errors.Count -eq 0) {
            [void][IO.Directory]::CreateDirectory($temporaryRoot)
            $expectedIndex = Join-Path $temporaryRoot 'expected.index'
            [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $expectedIndex, 'Process')
            & git -C $GgmlRoot read-tree HEAD 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'unable to initialize expected ggml tree' }
            for ($index = 0; $index -lt $patchFiles.Count; $index++) {
                $normalizedPatch = Join-Path $temporaryRoot ('patch-{0:D4}.patch' -f ($index + 1))
                $patchText = [IO.File]::ReadAllText($patchFiles[$index].FullName).Replace("`r", '')
                [IO.File]::WriteAllText($normalizedPatch, $patchText, [Text.UTF8Encoding]::new($false))
                & git -C $GgmlRoot apply --cached --whitespace=nowarn -- $normalizedPatch 2>$null
                if ($LASTEXITCODE -ne 0) { throw 'ggml patch series does not apply exactly to the pinned commit' }
            }
            $expectedTree = (& git -C $GgmlRoot write-tree 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $expectedTree -notmatch '^[0-9a-f]{40}$') { throw 'unable to materialize expected ggml tree' }
            $changedPaths = @(& git -C $GgmlRoot diff --cached --name-only --diff-filter=ACDMRTUXB HEAD 2>$null)
            if ($LASTEXITCODE -ne 0 -or $changedPaths.Count -eq 0) { throw 'ggml patch series has no inspectable changes' }

            $currentIndex = Join-Path $temporaryRoot 'current.index'
            [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $currentIndex, 'Process')
            & git -C $GgmlRoot read-tree HEAD 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'unable to initialize current ggml tree' }
            & git -C $GgmlRoot add -A -- . 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'unable to inspect current ggml tree' }
            $currentTree = (& git -C $GgmlRoot write-tree 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $currentTree -notmatch '^[0-9a-f]{40}$') { throw 'unable to materialize current ggml tree' }
            if ($currentTree -cne $expectedTree) { $errors += 'current ggml tree is not the exact pinned patch series' }
        }
    } catch {
        $errors += $_.Exception.Message
    } finally {
        try { Restore-ProcessEnvironmentVariableState -State $previousGitIndexState }
        catch { $errors += $_.Exception.Message }
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        $temporaryPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-ggml-series-'
        if ($resolvedTemporaryRoot.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedTemporaryRoot) { Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force }
        } else {
            $errors += 'ggml patch inspection cleanup boundary failed'
        }
    }
    return [pscustomobject]@{
        passed=$errors.Count -eq 0
        errors=@($errors)
        patch_count=$patchFiles.Count
        changed_paths=@($changedPaths)
        expected_tree=$expectedTree
        current_tree=$currentTree
    }
}

function ConvertTo-SanitizedEvidenceText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    foreach ($privateRoot in @($env:RUNNER_TEMP, $env:GITHUB_WORKSPACE, $env:USERPROFILE, $WorkRoot)) {
        if (-not $privateRoot) { continue }
        $root = ([string]$privateRoot).TrimEnd([char[]]@('\', '/'))
        $variants = @()
        foreach ($baseVariant in @($root, $root.Replace('\', '/'), $root.Replace('/', '\')) | Sort-Object -Unique) {
            $variants += $baseVariant
            $variants += $baseVariant.Replace('\', '\\')
        }
        foreach ($variant in @($variants | Sort-Object -Unique | Sort-Object -Property Length -Descending)) {
            $Content = [regex]::Replace(
                $Content,
                [regex]::Escape($variant),
                '<private-path>',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    }
    $Content = $Content -replace '(?im)\b(authorization)\s*[:=]\s*[^\r\n]+', '$1=<redacted>'
    $Content = $Content -replace '(?im)\b(bearer)\s+[^\s,\r\n]+', '$1 <redacted>'
    $Content = $Content -replace '(?im)(["'']?(?:token|secret|password)["'']?\s*[:=]\s*)[^\r\n]+', '$1<redacted>'
    $Content = $Content -replace '(?i)((?:https?://|/)[^\s?]+)\?[^\s#]+', '$1?<redacted-query>'
    return $Content
}

function Test-EvidenceTextPrivacyContract {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    return $Content -notmatch '(?i)(?:[A-Z]:\\{1,2}Users\\{1,2}|D:\\{1,2}a\\{1,2}|Authorization\s*[:=]\s*(?!<redacted>)|Bearer\s+(?!<redacted>)|["'']?(?:token|secret|password)["'']?\s*[:=]\s*(?!<redacted>))'
}

function Get-EvidencePrivacyViolations {
    param([Parameter(Mandatory)][string]$Root)
    $violations = @()
    Get-ChildItem -LiteralPath $Root -File -Recurse | ForEach-Object {
        if ($_.Extension -notin @('.json','.txt','.log','.diff')) { return }
        if (-not (Test-EvidenceTextPrivacyContract -Content ([IO.File]::ReadAllText($_.FullName)))) {
            $violations += [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')
        }
    }
    return @($violations)
}

function New-UpstreamBuildArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$RequestedBackend,
        [Parameter(Mandatory)][string]$RequestedConfiguration,
        [Parameter(Mandatory)][string]$RequestedBuildRoot,
        [Parameter(Mandatory)][string]$RequestedTriplet,
        [Parameter(Mandatory)][string]$RequestedCudaArch
    )
    $arguments = [ordered]@{
        Backend = $RequestedBackend
        Profile = 'asr'
        Http = $true
        Config = $RequestedConfiguration
        BuildDir = $RequestedBuildRoot
        VcpkgTriplet = $RequestedTriplet
        Architecture = 'x64'
        Compiler = 'msvc'
        Jobs = 4
    }
    if ($RequestedBackend -eq 'cuda') {
        $arguments['CudaArch'] = $RequestedCudaArch
        $arguments['CublasShim'] = $true
    }
    return $arguments
}

function Test-RuntimeIdentityContract {
    param(
        [Parameter(Mandatory)][string]$ObservedSourceCommit,
        [Parameter(Mandatory)][string]$ObservedPatchSha256,
        [Parameter(Mandatory)][long]$ObservedPatchBytes,
        [Parameter(Mandatory)][string]$ObservedVersion,
        [Parameter(Mandatory)][string]$ObservedTriplet,
        [Parameter(Mandatory)][string]$ObservedCudaArch,
        [Parameter(Mandatory)][string]$ObservedVcpkgCommit
    )
    $errors = @()
    if ($ObservedSourceCommit -cne '4f9676226f667d14608487df744f375db87127f8') { $errors += 'source commit' }
    if ($ObservedPatchSha256 -cne '80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84') { $errors += 'patch SHA-256' }
    if ($ObservedPatchBytes -ne 1793) { $errors += 'patch bytes' }
    if ($ObservedVersion -cne 'nemo-speech-v0.1.0-diagnotes-lid.3') { $errors += 'identity' }
    if ($ObservedTriplet -cne 'x64-windows-static-md') { $errors += 'triplet' }
    if ($ObservedCudaArch -cne '75;80;86;89') { $errors += 'CUDA architecture matrix' }
    if ($ObservedVcpkgCommit -cne '9e593bb18ea69cc5095e012465dcd675a822ed0d') { $errors += 'vcpkg commit' }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; errors=@($errors) }
}

function New-ProfileArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$RequestedBackend,
        [Parameter(Mandatory)][string]$RequestedSourceRoot,
        [Parameter(Mandatory)][string]$RequestedBuildRoot,
        [Parameter(Mandatory)][string]$RequestedCudaArch,
        [switch]$ReassertToolchainFromCache
    )
    $arguments = @(
        '-S', $RequestedSourceRoot, '-B', $RequestedBuildRoot,
        '-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON',
        '-DNEMO_SPEECH_BUILD_ASR=ON',
        '-DNEMO_SPEECH_BUILD_HTTP=ON',
        '-DNEMO_SPEECH_BUILD_CLI=ON',
        '-DNEMO_SPEECH_BUILD_DIAR=OFF',
        '-DNEMO_SPEECH_BUILD_TTS=OFF',
        '-DNEMO_SPEECH_BUILD_NMT=OFF',
        '-DNEMO_SPEECH_WITH_NMT=OFF',
        '-DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF',
        '-DNEMO_SPEECH_BUILD_GRPC=OFF',
        '-DNEMO_SPEECH_WITH_GRPC=OFF',
        '-DNEMO_SPEECH_BUILD_TESTS=OFF',
        '-DBUILD_TESTING=OFF',
        '-DNEMO_SPEECH_BUILD_EXAMPLES=OFF',
        '-DNEMO_SPEECH_BUILD_TOOLS=OFF'
    )
    if ($ReassertToolchainFromCache) {
        $cachePath = Join-Path $RequestedBuildRoot 'CMakeCache.txt'
        if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
            throw 'The upstream build did not materialize CMakeCache.txt before the contracted profile reconfigure.'
        }
        $parsedCache = ConvertFrom-CMakeCacheText -Text ([IO.File]::ReadAllText($cachePath))
        if ($parsedCache.errors.Count -ne 0 -or -not $parsedCache.entries.Contains('CMAKE_TOOLCHAIN_FILE')) {
            throw 'The upstream build did not leave an inspectable CMAKE_TOOLCHAIN_FILE cache entry.'
        }
        $toolchainPath = $parsedCache.entries['CMAKE_TOOLCHAIN_FILE'].value
        if ([IO.Path]::GetFileName($toolchainPath.Replace('/','\')) -cne 'vcpkg.cmake' -or
            -not (Test-Path -LiteralPath $toolchainPath -PathType Leaf)) {
            throw 'The upstream build did not leave a materialized vcpkg.cmake toolchain path.'
        }
        # The upstream helper passes an untyped -D assignment on a reused build
        # tree. Reassert FILEPATH so the cache contract is stable for local reruns.
        $arguments += "-DCMAKE_TOOLCHAIN_FILE:FILEPATH=$toolchainPath"
    }
    if ($RequestedBackend -eq 'cuda') {
        $arguments += @('-DGGML_CUDA=ON', '-DGGML_VULKAN=OFF', '-DNEMO_SPEECH_CUBLAS_SHIM=ON', "-DCMAKE_CUDA_ARCHITECTURES:STRING=$RequestedCudaArch")
    } else {
        $arguments += @('-DGGML_CUDA=OFF', '-DGGML_VULKAN=OFF', '-DNEMO_SPEECH_GGML_PATCHED=OFF')
    }
    return $arguments
}

function ConvertFrom-CMakeCacheText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $entries = [ordered]@{}
    $errors = @()
    $lines = [regex]::Split($Text, "`r`n|`n", [Text.RegularExpressions.RegexOptions]::None)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Contains("`r")) {
            $errors += "line $($index + 1): bare CR is not permitted"
            continue
        }
        if ($line -match '^[\t ]*$' -or $line -match '^[\t ]*(?:#|//)') { continue }
        $match = [regex]::Match($line, '^(?<key>[^:=\t ]+):(?<type>[^=\t ]+)=(?<value>.*)$')
        if (-not $match.Success) {
            $errors += "line $($index + 1): malformed cache entry"
            continue
        }
        $key = $match.Groups['key'].Value
        if ($entries.Contains($key)) {
            $errors += "line $($index + 1): duplicate key $key"
            continue
        }
        $entries[$key] = [pscustomobject]@{
            key = $key
            type = $match.Groups['type'].Value
            value = $match.Groups['value'].Value
            line = $index + 1
        }
    }
    return [pscustomobject]@{ entries=$entries; errors=@($errors); line_count=$lines.Count }
}

function Test-CMakeCacheContract {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$RequestedBackend,
        [Parameter(Mandatory)][string]$RequestedTriplet,
        [Parameter(Mandatory)][string]$RequestedCudaArch
    )
    $parsed = ConvertFrom-CMakeCacheText -Text $Text
    $errors = @($parsed.errors)
    $expected = [ordered]@{
        NEMO_SPEECH_BUILD_ASR = @('BOOL','ON')
        NEMO_SPEECH_BUILD_HTTP = @('BOOL','ON')
        NEMO_SPEECH_BUILD_CLI = @('BOOL','ON')
        NEMO_SPEECH_BUILD_DIAR = @('BOOL','OFF')
        NEMO_SPEECH_BUILD_TTS = @('BOOL','OFF')
        NEMO_SPEECH_BUILD_NMT = @('BOOL','OFF')
        NEMO_SPEECH_BUILD_MIC_CAPTURE = @('BOOL','OFF')
        VCPKG_TARGET_TRIPLET = @('STRING',$RequestedTriplet)
        CMAKE_EXPORT_COMPILE_COMMANDS = @('BOOL','ON')
    }
    if ($RequestedBackend -eq 'cuda') {
        $expected['CMAKE_CUDA_ARCHITECTURES'] = @('STRING',$RequestedCudaArch)
    }
    foreach ($item in $expected.GetEnumerator()) {
        if (-not $parsed.entries.Contains($item.Key)) {
            $errors += "missing $($item.Key)"
            continue
        }
        $entry = $parsed.entries[$item.Key]
        if ($entry.type -cne $item.Value[0] -or $entry.value -cne $item.Value[1]) {
            $errors += "invalid $($item.Key)"
        }
    }
    foreach ($requiredPath in @(
        @('CMAKE_TOOLCHAIN_FILE','FILEPATH','vcpkg.cmake'),
        @('CMAKE_CXX_COMPILER','FILEPATH','cl.exe')
    )) {
        if (-not $parsed.entries.Contains($requiredPath[0])) {
            $errors += "missing $($requiredPath[0])"
            continue
        }
        $entry = $parsed.entries[$requiredPath[0]]
        $leaf = [IO.Path]::GetFileName($entry.value.Replace('/','\'))
        if ($entry.type -cne $requiredPath[1] -or $leaf -cne $requiredPath[2]) {
            $errors += "invalid $($requiredPath[0])"
        }
    }
    if (-not $parsed.entries.Contains('MSVC_REDIST_DIR')) {
        $errors += 'missing MSVC_REDIST_DIR'
    } else {
        $redistEntry = $parsed.entries['MSVC_REDIST_DIR']
        if ($redistEntry.type -cne 'PATH' -or -not [IO.Path]::IsPathRooted($redistEntry.value.Replace('/','\'))) {
            $errors += 'invalid MSVC_REDIST_DIR'
        }
    }
    if ($parsed.entries.Contains('CMAKE_MSVC_RUNTIME_LIBRARY')) {
        $runtimeEntry = $parsed.entries['CMAKE_MSVC_RUNTIME_LIBRARY']
        if ($runtimeEntry.type -cne 'STRING' -or $runtimeEntry.value -cne 'MultiThreadedDLL') {
            $errors += 'invalid CMAKE_MSVC_RUNTIME_LIBRARY'
        }
    }
    return [pscustomobject]@{
        passed = $errors.Count -eq 0
        errors = @($errors)
        entries = $parsed.entries
    }
}

function ConvertFrom-CMakeSetText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $entries = [ordered]@{}
    $errors = @()
    $lines = [regex]::Split($Text, "`r`n|`n", [Text.RegularExpressions.RegexOptions]::None)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Contains("`r")) { $errors += "line $($index + 1): bare CR"; continue }
        if ($line -match '^[\t ]*$' -or $line -match '^[\t ]*#') { continue }
        $match = [regex]::Match($line, '^[\t ]*set\([\t ]*(?<key>[A-Za-z0-9_]+)[\t ]+(?<value>[^\s\)]+)[\t ]*\)[\t ]*$')
        if (-not $match.Success) { continue }
        $key = $match.Groups['key'].Value
        if ($entries.Contains($key)) { $errors += "line $($index + 1): duplicate key $key"; continue }
        $entries[$key] = $match.Groups['value'].Value
    }
    return [pscustomobject]@{ entries=$entries; errors=@($errors) }
}

function ConvertFrom-ExactKeyValueText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $entries = [ordered]@{}
    $errors = @()
    $lines = [regex]::Split($Text, "`r`n|`n", [Text.RegularExpressions.RegexOptions]::None)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Contains("`r")) { $errors += "line $($index + 1): bare CR"; continue }
        if ($line.Length -eq 0) { continue }
        $match = [regex]::Match($line, '^(?<key>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.+)$')
        if (-not $match.Success) { $errors += "line $($index + 1): malformed key/value"; continue }
        $key = $match.Groups['key'].Value
        if ($entries.Contains($key)) { $errors += "line $($index + 1): duplicate key $key"; continue }
        $entries[$key] = $match.Groups['value'].Value
    }
    return [pscustomobject]@{ entries=$entries; errors=@($errors) }
}

function Test-CudaVersionJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    try {
        $document = $Json | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ passed=$false; reason='invalid JSON' }
    }
    if ($null -eq $document.cuda -or [string]$document.cuda.name -cne 'CUDA SDK' -or
        [string]$document.cuda.version -cne '12.8.0') {
        return [pscustomobject]@{ passed=$false; reason='cuda identity/version mismatch' }
    }
    return [pscustomobject]@{ passed=$true; reason='CUDA SDK 12.8.0' }
}

function Test-NvccVersionText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = @([regex]::Split($Text, "`r`n|`n", [Text.RegularExpressions.RegexOptions]::None) | Where-Object { $_.Length -gt 0 })
    if (@($lines | Where-Object { $_.Contains("`r") }).Count -ne 0) {
        return [pscustomobject]@{ passed=$false; reason='bare CR' }
    }
    $semantic = @($lines | Where-Object { $_ -match '^Cuda compilation tools, release (?<release>[0-9]+\.[0-9]+), V(?<version>[0-9]+\.[0-9]+\.[0-9]+)$' })
    if ($semantic.Count -ne 1) { return [pscustomobject]@{ passed=$false; reason='ambiguous semantic version line' } }
    $match = [regex]::Match($semantic[0], '^Cuda compilation tools, release (?<release>[0-9]+\.[0-9]+), V(?<version>[0-9]+\.[0-9]+\.[0-9]+)$')
    if ($match.Groups['release'].Value -cne '12.8' -or -not $match.Groups['version'].Value.StartsWith('12.8.', [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ passed=$false; reason='nvcc version mismatch' }
    }
    return [pscustomobject]@{ passed=$true; reason=$semantic[0] }
}

function ConvertTo-ShortMsvcVersionString {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Text,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$ExpectedToolsetVersion
    )
    if ($null -eq $Text -or $Text.GetType() -ne [string]) { throw 'MSVC version probe output must be exactly one string.' }
    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 4096) { throw 'MSVC version probe output length is invalid.' }
    if ($ExitCode -ne 0) { throw 'MSVC version probe returned a nonzero exit code.' }
    if ($value -match '(?i)(?:[A-Z]:\\Users\\|D:\\a\\|Authorization\s*[:=]|Bearer\s+|["'']?(?:token|secret|password)["'']?\s*[:=])') {
        throw 'MSVC version probe output contains a private or credential marker.'
    }
    $toolsetMatch = [regex]::Match($ExpectedToolsetVersion, '^14\.(?<minor>[0-9]{1,3})\.[0-9]{1,5}$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $toolsetMatch.Success) { throw 'Effective MSVC toolset version is structurally invalid.' }
    $versionMatches = [regex]::Matches($value, '(?<![0-9])(?<version>19\.(?<minor>[0-9]{1,3})\.[0-9]{1,5})(?![0-9])', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($versionMatches.Count -ne 1) { throw 'MSVC version probe must contain exactly one compiler version.' }
    $version = $versionMatches[0].Groups['version'].Value
    $semanticLines = @([regex]::Split($value, "`r`n|`n", [Text.RegularExpressions.RegexOptions]::None) |
        Where-Object { $_ -match "(?<![0-9])$([regex]::Escape($version))(?![0-9])" -and $_ -cmatch '\bx64\b' })
    if ($semanticLines.Count -ne 1) { throw 'MSVC version probe must contain exactly one x64 compiler banner.' }
    if ($versionMatches[0].Groups['minor'].Value -cne $toolsetMatch.Groups['minor'].Value) {
        throw 'MSVC compiler and effective toolset minor versions differ.'
    }
    return [string]$version
}

function Get-MsvcVersionText {
    param(
        [Parameter(Mandatory)][string]$ClPath,
        [Parameter(Mandatory)][string]$ExpectedToolsetVersion
    )
    if (-not (Test-Path -LiteralPath $ClPath -PathType Leaf) -or [IO.Path]::GetFileName($ClPath) -cne 'cl.exe') {
        throw 'MSVC version probe requires a materialized cl.exe path.'
    }
    $process = [Diagnostics.Process]::new()
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ClPath
        $startInfo.WorkingDirectory = Split-Path -Parent $ClPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'MSVC version probe did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit(10 * 1000)
        if (-not $completed) {
            try { $process.Kill($true) } catch {}
            try { $process.WaitForExit() } catch {}
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not $completed) { throw 'MSVC version probe timed out.' }
        return ConvertTo-ShortMsvcVersionString -Text ($stderr + "`n" + $stdout) -ExitCode $process.ExitCode -ExpectedToolsetVersion $ExpectedToolsetVersion
    } finally {
        $process.Dispose()
    }
}

function Test-MicrosoftSignerIdentity {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Subject
    )
    if ($Status -cne 'Valid') { return $false }
    $fields = [ordered]@{}
    foreach ($part in @($Subject -split ',[ ]*')) {
        $match = [regex]::Match($part, '^(?<key>CN|O|L|S|C)=(?<value>[^,]+)$')
        if (-not $match.Success) { return $false }
        $key = $match.Groups['key'].Value
        if ($fields.Contains($key)) { return $false }
        $fields[$key] = $match.Groups['value'].Value
    }
    return $fields.Contains('O') -and $fields['O'] -ceq 'Microsoft Corporation'
}

function Test-MsvcRedistFileContract {
    param(
        [Parameter(Mandatory)][string]$SourceSha256,
        [Parameter(Mandatory)][string]$BundleSha256,
        [Parameter(Mandatory)][string]$SourceSignatureStatus,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceSignerSubject,
        [Parameter(Mandatory)][string]$BundleSignatureStatus,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BundleSignerSubject
    )
    $errors = @()
    if ($SourceSha256 -notmatch '^(?i:[0-9a-f]{64})$' -or $BundleSha256 -notmatch '^(?i:[0-9a-f]{64})$' -or $SourceSha256 -cne $BundleSha256) { $errors += 'Redist bytes differ from effective toolset' }
    if (-not (Test-MicrosoftSignerIdentity -Status $SourceSignatureStatus -Subject $SourceSignerSubject) -or
        -not (Test-MicrosoftSignerIdentity -Status $BundleSignatureStatus -Subject $BundleSignerSubject) -or
        $SourceSignerSubject -cne $BundleSignerSubject) { $errors += 'Redist signer identity' }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; errors=@($errors) }
}

function Test-IsAllowedMsvcRedistributableName {
    param([Parameter(Mandatory)][string]$Name)
    if (-not [regex]::IsMatch($Name, '^[0-9A-Za-z_.]+$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { return $false }
    $normalized = $Name.ToUpperInvariant()
    if ([regex]::IsMatch($normalized, '^(?:MSVCP|VCRUNTIME|CONCRT|VCCORLIB)140(?:_[0-9A-Z]+)?\.DLL$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { return $true }
    return @('MSVCP140_ATOMIC_WAIT.DLL','MSVCP140_CODECVT_IDS.DLL','VCOMP140.DLL') -ccontains $normalized
}

function Resolve-MsvcRedistSourcePath {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RedistVersionRoot
    )
    if (-not (Test-IsAllowedMsvcRedistributableName -Name $Name)) { throw "Unsupported MSVC Redist name: $Name" }
    $relative = if ($Name -ieq 'vcomp140.dll') {
        'x64\Microsoft.VC143.OpenMP\vcomp140.dll'
    } else {
        Join-Path 'x64\Microsoft.VC143.CRT' $Name
    }
    $root = [IO.Path]::GetFullPath($RedistVersionRoot).TrimEnd('\')
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'MSVC Redist source escaped its version root.' }
    return $path
}

function ConvertFrom-DumpbinDependentsText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = [regex]::Split($Text, "`r`n|`n", [Text.RegularExpressions.RegexOptions]::None)
    if (@($lines | Where-Object { $_.Contains("`r") }).Count -ne 0) {
        return [pscustomobject]@{ passed=$false; dependencies=@(); reason='bare CR' }
    }
    $headerIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -ceq '  Image has the following dependencies:') { $headerIndexes += $index }
    }
    if ($headerIndexes.Count -ne 1) {
        return [pscustomobject]@{ passed=$false; dependencies=@(); reason='dependency section cardinality' }
    }
    $dependencies = @()
    $started = $false
    for ($index = $headerIndexes[0] + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Length -eq 0) {
            if ($started) { break }
            continue
        }
        $match = [regex]::Match($line, '^    (?<name>[A-Za-z0-9_.-]+(?i:\.dll))$')
        if (-not $match.Success) {
            return [pscustomobject]@{ passed=$false; dependencies=@(); reason='unrecognized dependency line' }
        }
        $started = $true
        $dependencies += $match.Groups['name'].Value
    }
    if ($dependencies.Count -eq 0 -or @($dependencies | Sort-Object -Unique).Count -ne $dependencies.Count) {
        return [pscustomobject]@{ passed=$false; dependencies=@(); reason='empty or duplicate dependency set' }
    }
    return [pscustomobject]@{ passed=$true; dependencies=@($dependencies); reason='strict dumpbin dependency section' }
}

function Get-RuntimeFileClassification {
    param([Parameter(Mandatory)][string]$RelativePath)
    if (-not (Test-CanonicalRuntimeRelativePath -Path $RelativePath)) {
        return [pscustomobject]@{ passed=$false; reason='non-canonical runtime path' }
    }
    $path = $RelativePath
    $redistMatch = [regex]::Match($path, '^bin/(?<name>[^/]+(?i:\.dll))$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($redistMatch.Success -and (Test-IsAllowedMsvcRedistributableName -Name $redistMatch.Groups['name'].Value)) {
        return [pscustomobject]@{
            passed=$true
            origin='Microsoft Visual C++ Redist from effective MSVC toolchain'
            license='LicenseRef-Microsoft-Visual-Cpp-Runtime'
        }
    }
    $rules = @(
        [pscustomobject]@{ pattern='^bin/ggml(?:-[A-Za-z0-9_-]+)?\.dll$'; origin='ggml'; license='MIT' },
        [pscustomobject]@{ pattern='^bin/(?:cublas|cublasLt|cudart)64_12\.dll$'; origin='NeMo-Speech.cpp CUDA shim + CUDA runtime'; license='Apache-2.0 AND LicenseRef-NVIDIA-CUDA-Toolkit' },
        [pscustomobject]@{ pattern='^bin/nemo-speech\.exe$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^bin/nemo_speech_asr(?:_c)?\.dll$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^(?:LICENSE|NOTICE|realtime-language-v1\.patch|runtime-build\.json|inventory\.json|sbom\.spdx\.json|msvc-redist-inventory\.json|pe-imports\.json)$'; origin='DiagNotes runtime recipe'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^share/licenses/microsoft-visual-cpp-runtime/(?:Visual-Studio-2022-Community-License-EN\.docx|Visual-Studio-2022-Redistribution\.html|Redist\.txt)$'; origin='Microsoft official license/REDIST evidence'; license='LicenseRef-Microsoft-Visual-Studio-2022' },
        [pscustomobject]@{ pattern='^share/licenses/nvidia-cuda-toolkit/EULA\.txt$'; origin='NVIDIA CUDA Toolkit'; license='LicenseRef-NVIDIA-CUDA-Toolkit' },
        [pscustomobject]@{ pattern='^share/licenses/cpp-httplib/.+$'; origin='cpp-httplib'; license='MIT' },
        [pscustomobject]@{ pattern='^share/licenses/sentencepiece/.+$'; origin='sentencepiece'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^share/licenses/nemo-speech/.+$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^share/doc/nemo-speech/(?:README|CONTRIBUTING)\.md$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^share/doc/nemo-speech/docs/[A-Za-z0-9_/-]+\.md$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^share/nemo-speech/config/(?:README\.md|[a-z0-9_-]+\.example\.yaml)$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' },
        [pscustomobject]@{ pattern='^share/nemo-speech/model-index\.json$'; origin='NeMo-Speech.cpp distribution'; license='Apache-2.0' }
    )
    $matches = @($rules | Where-Object { $path -match $_.pattern })
    if ($matches.Count -ne 1) { return [pscustomobject]@{ passed=$false; reason="classification cardinality $($matches.Count)" } }
    return [pscustomobject]@{ passed=$true; origin=$matches[0].origin; license=$matches[0].license }
}

function Test-RuntimeBinaryProfile {
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][ValidateSet('cpu','cuda')][string]$RequestedBackend
    )
    $errors = @()
    if ($Names -notcontains 'nemo-speech.exe') { $errors += 'nemo-speech.exe missing' }
    if ($Names -notcontains 'nemo_speech_asr.dll') { $errors += 'nemo_speech_asr.dll missing' }
    if ($Names -notcontains 'nemo_speech_asr_c.dll') { $errors += 'nemo_speech_asr_c.dll missing' }
    if ($RequestedBackend -eq 'cuda' -and $Names -notcontains 'ggml-cuda.dll') { $errors += 'ggml-cuda.dll missing' }
    if ($RequestedBackend -eq 'cpu') {
        foreach ($name in $Names) {
            if ($name -match '^(?i:ggml-cuda(?:-[A-Za-z0-9_-]+)?\.dll|cublas64_[0-9]+\.dll|cublasLt64_[0-9]+\.dll|cudart64_[0-9]+\.dll)$') {
                $errors += "CPU contains CUDA binary $name"
            }
        }
    }
    if ($Names -contains 'nvcuda.dll') { $errors += 'host driver redistributed' }
    foreach ($name in $Names) {
        $classification = Get-RuntimeFileClassification -RelativePath "bin/$name"
        if (-not $classification.passed) { $errors += "unclassified binary $name" }
    }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; errors=@($errors) }
}

function Test-CanonicalRuntimeRelativePath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path.Contains('\')) { return $false }
    if ($Path.StartsWith('/', [StringComparison]::Ordinal) -or $Path.EndsWith('/', [StringComparison]::Ordinal) -or $Path.Contains('//')) { return $false }
    foreach ($segment in @($Path.Split('/'))) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..' -or $segment.Contains(':')) { return $false }
    }
    return $true
}

function Get-RuntimeTreeRecords {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'Runtime tree root is missing.' }
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($resolvedRoot, $file.FullName).Replace('\','/')
        if (-not (Test-CanonicalRuntimeRelativePath -Path $relative)) { throw 'Runtime tree contains a non-canonical path.' }
        if (-not $seen.Add($relative)) { throw 'Runtime tree contains a case-insensitive path collision.' }
        $records += [pscustomobject]@{ path=$relative; size=[int64]$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    return @($records)
}

function ConvertTo-CanonicalRuntimeRecordMap {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $errors = @()
    foreach ($record in @($Records)) {
        $pathProperty = $record.PSObject.Properties['path']
        $sizeProperty = $record.PSObject.Properties['size']
        $hashProperty = $record.PSObject.Properties['sha256']
        if ($null -eq $pathProperty -or $null -eq $sizeProperty -or $null -eq $hashProperty) { $errors += 'record fields'; continue }
        $path = [string]$pathProperty.Value
        $hash = [string]$hashProperty.Value
        $size = [int64]$sizeProperty.Value
        if (-not (Test-CanonicalRuntimeRelativePath -Path $path) -or $size -lt 0 -or $hash -notmatch '^(?i:[0-9a-f]{64})$') { $errors += "invalid record $path"; continue }
        if ($map.ContainsKey($path)) { $errors += "duplicate record $path"; continue }
        $map.Add($path, [pscustomobject]@{ path=$path; size=$size; sha256=$hash.ToUpperInvariant() })
    }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; map=$map; errors=@($errors) }
}

function Test-PayloadMetadataClosure {
    param(
        [Parameter(Mandatory)][object[]]$PayloadRecords,
        [Parameter(Mandatory)][object[]]$ActualRecords,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InventoryJson,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SbomJson,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetadataEvidenceJson
    )
    $errors = @()
    try { $inventoryDocument = $InventoryJson | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
    catch { return [pscustomobject]@{ passed=$false; errors=@('invalid inventory JSON') } }
    try { $sbomDocument = $SbomJson | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
    catch { return [pscustomobject]@{ passed=$false; errors=@('invalid SBOM JSON') } }
    try { $metadataDocument = $MetadataEvidenceJson | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
    catch { return [pscustomobject]@{ passed=$false; errors=@('invalid metadata evidence JSON') } }

    if ([string]$inventoryDocument.schema -cne 'diagnotes-runtime-inventory-v2' -or [string]$inventoryDocument.scope -cne 'payload-only') { $errors += 'inventory schema or scope' }
    $exclusions = @($inventoryDocument.exclusions | ForEach-Object { [string]$_ })
    if ($exclusions.Count -ne 2 -or $exclusions[0] -cne 'inventory.json' -or $exclusions[1] -cne 'sbom.spdx.json') { $errors += 'inventory exclusions' }
    $payloadMapResult = ConvertTo-CanonicalRuntimeRecordMap -Records $PayloadRecords
    $inventoryMapResult = ConvertTo-CanonicalRuntimeRecordMap -Records @($inventoryDocument.files)
    $actualMapResult = ConvertTo-CanonicalRuntimeRecordMap -Records $ActualRecords
    if (-not $payloadMapResult.passed) { $errors += $payloadMapResult.errors }
    if (-not $inventoryMapResult.passed) { $errors += $inventoryMapResult.errors }
    if (-not $actualMapResult.passed) { $errors += $actualMapResult.errors }

    $sbomRecords = @()
    if ([string]$sbomDocument.spdxVersion -cne 'SPDX-2.3' -or [string]$sbomDocument.dataLicense -cne 'CC0-1.0') { $errors += 'SBOM schema' }
    foreach ($entry in @($sbomDocument.files)) {
        $checksums = @($entry.checksums)
        if ($checksums.Count -ne 1 -or [string]$checksums[0].algorithm -cne 'SHA256') { $errors += 'SBOM checksum shape'; continue }
        $sbomRecords += [pscustomobject]@{ path=[string]$entry.fileName; size=if ($inventoryMapResult.map.ContainsKey([string]$entry.fileName)) { $inventoryMapResult.map[[string]$entry.fileName].size } else { 0 }; sha256=[string]$checksums[0].checksumValue }
    }
    $sbomMapResult = ConvertTo-CanonicalRuntimeRecordMap -Records $sbomRecords
    if (-not $sbomMapResult.passed) { $errors += $sbomMapResult.errors }

    foreach ($left in @($payloadMapResult.map, $inventoryMapResult.map, $sbomMapResult.map)) {
        if ($left.Count -ne $payloadMapResult.map.Count) { $errors += 'payload cardinality'; continue }
        foreach ($path in $payloadMapResult.map.Keys) {
            if (-not $left.ContainsKey($path) -or $left[$path].size -ne $payloadMapResult.map[$path].size -or $left[$path].sha256 -cne $payloadMapResult.map[$path].sha256) { $errors += "payload divergence $path" }
        }
    }

    $metadataRecords = @($metadataDocument.files | ForEach-Object { [pscustomobject]@{ path=[string]$_.name; size=[int64]$_.size; sha256=[string]$_.sha256 } })
    $metadataMapResult = ConvertTo-CanonicalRuntimeRecordMap -Records $metadataRecords
    if ([string]$metadataDocument.schema -cne 'diagnotes-payload-metadata-evidence-v1' -or -not $metadataMapResult.passed -or
        $metadataMapResult.map.Count -ne 2 -or -not $metadataMapResult.map.ContainsKey('inventory.json') -or -not $metadataMapResult.map.ContainsKey('sbom.spdx.json')) { $errors += 'metadata evidence shape' }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $serializedMetadata = [ordered]@{
        'inventory.json'=$utf8.GetBytes($InventoryJson)
        'sbom.spdx.json'=$utf8.GetBytes($SbomJson)
    }
    foreach ($entry in $serializedMetadata.GetEnumerator()) {
        $serializedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.Value))
        if (-not $metadataMapResult.map.ContainsKey($entry.Key) -or $metadataMapResult.map[$entry.Key].size -ne $entry.Value.Length -or
            $metadataMapResult.map[$entry.Key].sha256 -cne $serializedHash) { $errors += "serialized metadata divergence $($entry.Key)" }
    }

    $expectedFinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $payloadMapResult.map.Keys) { [void]$expectedFinal.Add($path) }
    [void]$expectedFinal.Add('inventory.json'); [void]$expectedFinal.Add('sbom.spdx.json')
    if ($actualMapResult.map.Count -ne $expectedFinal.Count) { $errors += 'final tree cardinality' }
    foreach ($path in $expectedFinal) {
        if (-not $actualMapResult.map.ContainsKey($path)) { $errors += "final tree missing $path"; continue }
        $expected = if ($payloadMapResult.map.ContainsKey($path)) { $payloadMapResult.map[$path] } elseif ($metadataMapResult.map.ContainsKey($path)) { $metadataMapResult.map[$path] } else { $null }
        if ($null -eq $expected -or $actualMapResult.map[$path].size -ne $expected.size -or $actualMapResult.map[$path].sha256 -cne $expected.sha256) { $errors += "final tree divergence $path" }
    }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; errors=@($errors) }
}

function Test-MsvcRedistClosureContract {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PresentNames, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ImportedNames)
    $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $imported = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $errors = @()
    foreach ($name in $PresentNames) { if (-not (Test-IsAllowedMsvcRedistributableName -Name $name) -or -not $present.Add($name)) { $errors += 'invalid or duplicate present Redist' } }
    foreach ($name in $ImportedNames) { if (-not (Test-IsAllowedMsvcRedistributableName -Name $name) -or -not $imported.Add($name)) { $errors += 'invalid or duplicate imported Redist' } }
    if ($present.Count -ne $imported.Count) { $errors += 'Redist set cardinality mismatch' }
    foreach ($name in $present) { if (-not $imported.Contains($name)) { $errors += "orphan Redist $name" } }
    foreach ($name in $imported) { if (-not $present.Contains($name)) { $errors += "missing imported Redist $name" } }
    return [pscustomobject]@{ passed=$errors.Count -eq 0; errors=@($errors) }
}

function Remove-PreinstalledMsvcRedistributables {
    param([Parameter(Mandatory)][string]$Root)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $binRoot = [IO.Path]::GetFullPath((Join-Path $resolvedRoot 'bin'))
    if (-not $binRoot.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $binRoot -PathType Container)) {
        throw 'Runtime bin root is absent or escaped before Redist minimization.'
    }
    $removed = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $binRoot -File | Sort-Object Name)) {
        if (-not (Test-IsAllowedMsvcRedistributableName -Name $file.Name)) { continue }
        Remove-Item -LiteralPath $file.FullName -Force
        if (Test-Path -LiteralPath $file.FullName) { throw "Failed to remove preinstalled Redist: $($file.Name)" }
        $removed += $file.Name
    }
    return @($removed)
}

function ConvertFrom-WindowsCommandLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)
    $arguments = [Collections.Generic.List[string]]::new()
    $builder = [Text.StringBuilder]::new()
    $quoted = $false
    $argumentStarted = $false
    $backslashes = 0
    for ($index = 0; $index -lt $CommandLine.Length; $index++) {
        $character = $CommandLine[$index]
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * [math]::Floor($backslashes / 2)))
                if (($backslashes % 2) -eq 1) {
                    [void]$builder.Append('"')
                    $argumentStarted = $true
                } else {
                    $quoted = -not $quoted
                    $argumentStarted = $true
                }
                $backslashes = 0
                continue
            }
            $quoted = -not $quoted
            $argumentStarted = $true
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
            $argumentStarted = $true
        }
        if ([char]::IsWhiteSpace($character) -and -not $quoted) {
            if ($argumentStarted) {
                $arguments.Add($builder.ToString())
                [void]$builder.Clear()
                $argumentStarted = $false
            }
            continue
        }
        [void]$builder.Append($character)
        $argumentStarted = $true
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * $backslashes)); $argumentStarted = $true }
    if ($quoted) { throw 'Unterminated quoted argument.' }
    if ($argumentStarted) { $arguments.Add($builder.ToString()) }
    return ,$arguments.ToArray()
}

function Test-CompileCommandsContract {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $errors = @()
    $opaque = $false
    try {
        $decoded = $Json | ConvertFrom-Json -Depth 20 -NoEnumerate -ErrorAction Stop
        $entries = @($decoded)
    } catch {
        return [pscustomobject]@{ passed=$false; inspectable=$false; count=0; errors=@('invalid JSON'); sanitized_commands=@() }
    }
    if ($entries.Count -eq 0) {
        return [pscustomobject]@{ passed=$false; inspectable=$false; count=0; errors=@('zero entries'); sanitized_commands=@() }
    }
    $summaries = @()
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        $hasArguments = $null -ne $entry.PSObject.Properties['arguments']
        $hasCommand = $null -ne $entry.PSObject.Properties['command']
        if ($hasArguments -eq $hasCommand) {
            $errors += "entry $index must contain exactly one command representation"
            continue
        }
        try {
            $arguments = if ($hasArguments) { @($entry.arguments | ForEach-Object { [string]$_ }) }
                else { @(ConvertFrom-WindowsCommandLine -CommandLine ([string]$entry.command)) }
        } catch {
            $errors += "entry $index command line is invalid"
            continue
        }
        if ($arguments.Count -eq 0 -or [string]::IsNullOrWhiteSpace($arguments[0])) {
            $errors += "entry $index is empty"
            continue
        }
        if (@($arguments | Where-Object { $_ -match '^@' }).Count -gt 0) {
            $errors += "entry $index uses opaque response arguments"
            $opaque = $true
            continue
        }
        $compiler = [IO.Path]::GetFileName($arguments[0].Replace('/','\')).ToLowerInvariant()
        if ($compiler -notin @('cl','cl.exe','nvcc','nvcc.exe')) {
            $errors += "entry $index has non-compiler command"
            continue
        }
        $isNvcc = $compiler -in @('nvcc','nvcc.exe')
        $hasCompileAction = @($arguments | Where-Object { $_ -ceq '/c' -or $_ -ceq '-c' }).Count -gt 0
        if (-not $hasCompileAction) {
            $errors += "entry $index lacks compile action"
            continue
        }
        $forwarded = [Collections.Generic.List[string]]::new()
        for ($argIndex = 1; $argIndex -lt $arguments.Count; $argIndex++) {
            $argument = $arguments[$argIndex]
            if ($argument -in @('-Xcompiler','--compiler-options')) {
                if ($argIndex + 1 -ge $arguments.Count) { $errors += "entry $index has incomplete compiler forwarding"; continue }
                $argIndex++
                @($arguments[$argIndex] -split ',') | ForEach-Object { $forwarded.Add($_) }
            } elseif ($argument -match '^(?:-Xcompiler|--compiler-options)=(.+)$') {
                @($Matches[1] -split ',') | ForEach-Object { $forwarded.Add($_) }
            }
        }
        if (@($forwarded | Where-Object { $_ -match '^@' }).Count -gt 0) {
            $errors += "entry $index uses opaque forwarded response arguments"
            $opaque = $true
        }
        $crtArguments = if ($isNvcc) { @($forwarded.ToArray()) } else { $arguments }
        $forbidden = @($crtArguments | Where-Object { $_ -cin @('/MT','-MT','/MTd','-MTd','/MDd','-MDd') })
        $mdTokens = @($crtArguments | Where-Object { $_ -ceq '/MD' -or $_ -ceq '-MD' })
        $hasMd = $mdTokens.Count -eq 1
        if ($forbidden.Count -gt 0) { $errors += "entry $index contains forbidden CRT flag" }
        if ($mdTokens.Count -eq 0) { $errors += "entry $index lacks /MD" }
        elseif ($mdTokens.Count -ne 1) { $errors += "entry $index has ambiguous CRT forwarding" }
        $summaries += [pscustomobject]@{ index=$index; compiler=$compiler; argument_count=$arguments.Count; has_md=$hasMd; forbidden_count=$forbidden.Count }
    }
    return [pscustomobject]@{
        passed = $errors.Count -eq 0
        inspectable = -not $opaque
        count = $entries.Count
        errors = @($errors)
        sanitized_commands = @($summaries)
    }
}

function Get-RuntimeGateManifest {
    return @(
        [pscustomobject]@{ id='source-patch'; dependencies=@() },
        [pscustomobject]@{ id='cache'; dependencies=@() },
        [pscustomobject]@{ id='vcpkg'; dependencies=@('cache') },
        [pscustomobject]@{ id='compile-arguments-inspectable'; dependencies=@() },
        [pscustomobject]@{ id='crt'; dependencies=@('compile-arguments-inspectable') },
        [pscustomobject]@{ id='profile'; dependencies=@() },
        [pscustomobject]@{ id='legal'; dependencies=@('cache') },
        [pscustomobject]@{ id='pe-closure'; dependencies=@('cache','legal') },
        [pscustomobject]@{ id='inventory'; dependencies=@('profile','legal','pe-closure') },
        [pscustomobject]@{ id='sbom'; dependencies=@('inventory') },
        [pscustomobject]@{ id='payload-closure'; dependencies=@('inventory','sbom') },
        [pscustomobject]@{ id='zip-extraction'; dependencies=@('payload-closure') },
        [pscustomobject]@{ id='defender-tree'; dependencies=@('zip-extraction') },
        [pscustomobject]@{ id='defender-zip'; dependencies=@('zip-extraction') },
        [pscustomobject]@{ id='privacy'; dependencies=@() },
        [pscustomobject]@{ id='candidate-bytes-ready'; dependencies=@('source-patch','cache','vcpkg','crt','profile','legal','pe-closure','inventory','sbom','zip-extraction','defender-tree','defender-zip','privacy') },
        [pscustomobject]@{ id='attestation-created'; dependencies=@('candidate-bytes-ready') },
        [pscustomobject]@{ id='attestation-digest-verified'; dependencies=@('attestation-created') },
        [pscustomobject]@{ id='candidate-upload-eligible'; dependencies=@('attestation-digest-verified') }
    )
}

function Invoke-RuntimeGateGraph {
    param(
        [Parameter(Mandatory)][object[]]$Manifest,
        [Parameter(Mandatory)][Collections.IDictionary]$Observations
    )
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($gate in $Manifest) {
        if (-not $known.Add([string]$gate.id)) { throw "Duplicate gate id: $($gate.id)" }
        foreach ($dependency in @($gate.dependencies)) {
            if (-not $known.Contains([string]$dependency)) { throw "Unknown or forward dependency: $dependency" }
        }
    }
    $results = [ordered]@{}
    foreach ($gate in $Manifest) {
        $blockedBy = @($gate.dependencies | Where-Object { $results[$_].status -ne 'PASS' })
        if ($blockedBy.Count -gt 0) {
            $results[$gate.id] = [pscustomobject]@{ id=$gate.id; status='BLOCKED'; reason=('dependencies: ' + ($blockedBy -join ',')); dependencies=@($gate.dependencies) }
            continue
        }
        if (-not $Observations.Contains($gate.id)) {
            $results[$gate.id] = [pscustomobject]@{ id=$gate.id; status='BLOCKED'; reason='not observed'; dependencies=@($gate.dependencies) }
            continue
        }
        $observation = $Observations[$gate.id]
        $status = [string]$observation.status
        if ($status -notin @('PASS','FAIL')) { throw "Invalid observed status for $($gate.id): $status" }
        $results[$gate.id] = [pscustomobject]@{ id=$gate.id; status=$status; reason=[string]$observation.reason; dependencies=@($gate.dependencies) }
    }
    return @($results.Values)
}

$processEnvironmentSnapshot = Get-ProcessEnvironmentMap
try {
$githubContext = Test-GitHubActionsEnvironment
if ($Local) {
    if ($githubContext.detected) { throw 'Local mode is forbidden when any GitHub Actions marker is present.' }
    if ([string]::IsNullOrWhiteSpace($LocalWorkRoot)) { throw 'Local mode requires -LocalWorkRoot.' }
    if ($ReuseLocalCuda -and $Backend -ne 'cuda') { throw '-ReuseLocalCuda is valid only for the local CUDA backend.' }
} else {
    if (-not $githubContext.coherent) { throw 'Non-local mode requires a coherent GitHub Actions environment.' }
    if (-not [string]::IsNullOrWhiteSpace($LocalWorkRoot) -or $FreshLocalWorkRoot -or $ReuseLocalCuda) {
        throw 'Local-only parameters are forbidden in GitHub mode.'
    }
}

if ($Local) {
    $localRootContract = Resolve-ValidatedLocalWorkRoot -RequestedRoot $LocalWorkRoot -LocalAppDataRoot $env:LOCALAPPDATA
    if ($FreshLocalWorkRoot -and (Test-Path -LiteralPath $localRootContract.root)) {
        throw 'Fresh local work root already exists.'
    }
    if ($Backend -eq 'cuda' -and $env:DIAGNOTES_LOCAL_CUDA_SUPERVISED -cne '1') {
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        $childArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',('"' + $PSCommandPath + '"'),'-Backend','cuda','-Configuration',$Configuration,'-CudaArch',('"' + $CudaArch + '"'),'-CudaVersion',$CudaVersion,'-Local','-LocalWorkRoot',('"' + $localRootContract.root + '"'))
        if ($FreshLocalWorkRoot) { $childArguments += '-FreshLocalWorkRoot' }
        if ($ReuseLocalCuda) { $childArguments += '-ReuseLocalCuda' }
        $env:DIAGNOTES_LOCAL_CUDA_SUPERVISED = '1'
        $cudaChild = Start-Process -FilePath $pwshPath -ArgumentList $childArguments -PassThru -NoNewWindow
        if (-not $cudaChild.WaitForExit(180 * 60 * 1000)) {
            & taskkill.exe /PID $cudaChild.Id /T /F | Out-Null
            throw 'Local CUDA build exceeded the 180 minute limit; its process tree was terminated.'
        }
        if ($cudaChild.ExitCode -ne 0) { throw "Supervised local CUDA build failed with exit code $($cudaChild.ExitCode)." }
        return
    }
    New-Item -ItemType Directory -Force -Path $localRootContract.base | Out-Null
    if (-not (Test-Path -LiteralPath $localRootContract.root)) {
        New-Item -ItemType Directory -Path $localRootContract.root | Out-Null
    }
    $localRootContract = Resolve-ValidatedLocalWorkRoot -RequestedRoot $localRootContract.root -LocalAppDataRoot $env:LOCALAPPDATA -RequireExisting
    $LocalBuildBase = $localRootContract.base
    $LocalCudaProofPath = Join-Path $LocalBuildBase 'cuda-12.8-install-proof.json'
    $runIdentity = [Guid]::NewGuid().ToString('N')
    $WorkRoot = $localRootContract.root
    $attemptRoot = Join-Path $WorkRoot "runs\$runIdentity"
    $SourceRoot = Join-Path $WorkRoot 'source'
    $BuildRoot = Join-Path $WorkRoot "build-$Backend"
    $InstallRoot = Join-Path $attemptRoot 'install'
    $PackageRoot = Join-Path $attemptRoot 'package'
    $ArtifactsRoot = Join-Path $attemptRoot 'artifacts'
    $EvidenceRoot = Join-Path $ArtifactsRoot "evidence-$Backend"
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $localTools = Resolve-LocalBuildTools -VsWherePath $vsWhere
    $env:Path = ((Split-Path -Parent $localTools.cmake),(Split-Path -Parent $localTools.ninja),(Split-Path -Parent $localTools.cl),$env:Path -join ';')
    $RecipeCommit = ((git -C $RepoRoot rev-parse HEAD) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $RecipeCommit -notmatch '^[0-9a-f]{40}$') { throw 'Unable to identify the local recipe commit.' }
} else {
    $runIdentity = "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
    $WorkRoot = Join-Path $env:RUNNER_TEMP "diagnotes-runtime-$Backend-$runIdentity"
    $SourceRoot = Join-Path $WorkRoot 'source'
    $BuildRoot = Join-Path $WorkRoot 'build'
    $InstallRoot = Join-Path $WorkRoot 'install'
    $PackageRoot = Join-Path $WorkRoot 'package'
    $ArtifactsRoot = Join-Path $RepoRoot 'artifacts'
    $EvidenceRoot = Join-Path $ArtifactsRoot "evidence-$Backend"
    $RecipeCommit = $env:GITHUB_SHA
}

$identityContract = Test-RuntimeIdentityContract -ObservedSourceCommit $SourceCommit -ObservedPatchSha256 $PatchSha256 `
    -ObservedPatchBytes $PatchBytes -ObservedVersion $Version -ObservedTriplet $VcpkgTriplet `
    -ObservedCudaArch $CudaArch -ObservedVcpkgCommit $ExpectedVcpkgCommit
if (-not $identityContract.passed) { throw "Runtime identity contract failed: $($identityContract.errors -join ', ')" }

if ($Backend -eq 'cpu' -and $CudaArch -ne '75;80;86;89') {
    throw 'CudaArch is immutable even when the CPU job ignores it.'
}
if ($CudaArch -ne '75;80;86;89' -or $CudaArch -eq 'native') {
    throw "CUDA architecture matrix must be exactly 75;80;86;89, got $CudaArch"
}

$patchInfo = Get-Item -LiteralPath $PatchPath
$patchHash = (Get-FileHash -LiteralPath $PatchPath -Algorithm SHA256).Hash
$patchRaw = [IO.File]::ReadAllBytes($patchInfo.FullName)
if ($patchInfo.Length -ne $PatchBytes -or $patchHash -ne $PatchSha256) {
    throw "Canonical patch mismatch: bytes=$($patchInfo.Length), sha256=$patchHash"
}
if ($patchRaw[0] -eq 0xEF -and $patchRaw[1] -eq 0xBB -and $patchRaw[2] -eq 0xBF) {
    throw 'Canonical patch must not have a UTF-8 BOM.'
}
if ($patchRaw -contains 13) { throw 'Canonical patch must use LF only.' }
if ($patchRaw[-1] -ne 10 -or $patchRaw[-2] -eq 10) { throw 'Canonical patch must end in exactly one LF.' }

if ($Local) {
    [void](Resolve-ValidatedLocalWorkRoot -RequestedRoot $WorkRoot -LocalAppDataRoot $env:LOCALAPPDATA -RequireExisting)
    if ($FreshLocalWorkRoot -and @($SourceRoot,$BuildRoot,$InstallRoot,$PackageRoot,$ArtifactsRoot | Where-Object { Test-Path -LiteralPath $_ }).Count -ne 0) {
        throw 'Fresh local root contains reusable source, build, install, package or evidence state.'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $InstallRoot) | Out-Null
} else {
    if (Test-Path -LiteralPath $WorkRoot) { throw 'Unique clean work root already exists.' }
    New-Item -ItemType Directory -Path $WorkRoot | Out-Null
}
New-Item -ItemType Directory -Force -Path $ArtifactsRoot, $EvidenceRoot | Out-Null
if ($Backend -eq 'cuda') {
    $sanitizerEvidenceRoot = Join-Path $ArtifactsRoot 'sanitizer-preflight'
    $sanitizerEvidencePath = Join-Path $sanitizerEvidenceRoot 'sanitizer-preflight.json'
    $sanitizerTestPath = Join-Path $RepoRoot 'scripts\Test-BuildRuntimeHelpers.ps1'
    New-Item -ItemType Directory -Force -Path $sanitizerEvidenceRoot | Out-Null
    $sanitizerTestArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$sanitizerTestPath,'-BuildScriptPath',$PSCommandPath,'-EvidencePath',$sanitizerEvidencePath)
    Invoke-Checked -FilePath pwsh -Arguments $sanitizerTestArguments
}
$sourceWasReused = Test-Path -LiteralPath $SourceRoot
$expectedGgmlCommit = $null
$ggmlPatchSeriesContract = $null
if ($sourceWasReused) {
    if (-not $Local -or -not (Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))) { throw 'Unexpected pre-existing source root.' }
    if ((git -C $SourceRoot rev-parse HEAD).Trim() -ne $SourceCommit) { throw 'Reused source pin mismatch.' }
    if ((git -C $SourceRoot symbolic-ref -q HEAD 2>$null)) { throw 'Reused source must remain detached.' }
    $sourceStatus = @(git -C $SourceRoot status --porcelain=v1 --untracked-files=all)
    $expectedSourceStatus = if ($Backend -eq 'cuda') { @(' M ggml',' M server/http/http_server.cpp') } else { @(' M server/http/http_server.cpp') }
    if (($sourceStatus | ConvertTo-Json -Compress) -cne ($expectedSourceStatus | ConvertTo-Json -Compress)) { throw 'Reused source status escaped the canonical patch contract.' }
    $sourceNumstat = @((git -C $SourceRoot diff --numstat -- server/http/http_server.cpp) -split '\s+')
    if ($sourceNumstat.Count -lt 2 -or $sourceNumstat[0] -ne '7' -or $sourceNumstat[1] -ne '0') { throw 'Reused source diff does not contain exactly seven canonical additions.' }
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect reused source.' }
    foreach ($submodule in @('llama.cpp','third_party/cpp-httplib')) {
        $submoduleStatus = @(git -C (Join-Path $SourceRoot $submodule) status --porcelain=v1 --untracked-files=all)
        if ($LASTEXITCODE -ne 0 -or $submoduleStatus.Count -ne 0) { throw "Reused submodule is dirty: $submodule" }
    }
    if ($Backend -eq 'cuda') {
        $ggmlTreeEntry = (& git -C $SourceRoot ls-tree HEAD -- ggml 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $ggmlTreeEntry -notmatch '^160000 commit (?<commit>[0-9a-f]{40})\tggml$') { throw 'Unable to resolve pinned ggml commit.' }
        $expectedGgmlCommit = $Matches['commit']
        $ggmlPatchSeriesContract = Test-GgmlPatchSeriesContract -GgmlRoot (Join-Path $SourceRoot 'ggml') -PatchDirectory (Join-Path $SourceRoot 'ggml-patches') -ExpectedCommit $expectedGgmlCommit
        if (-not $ggmlPatchSeriesContract.passed) { throw ('Reused ggml patch series contract failed: ' + ($ggmlPatchSeriesContract.errors -join '; ')) }
    } else {
        $ggmlStatus = @(git -C (Join-Path $SourceRoot 'ggml') status --porcelain=v1 --untracked-files=all)
        if ($LASTEXITCODE -ne 0 -or $ggmlStatus.Count -ne 0) { throw 'Reused submodule is dirty: ggml' }
    }
} else {
    Invoke-Checked git clone --filter=blob:none https://github.com/NVIDIA/NeMo-Speech.cpp.git $SourceRoot
    Invoke-Checked git -C $SourceRoot checkout --detach $SourceCommit
    if ((git -C $SourceRoot rev-parse HEAD).Trim() -ne $SourceCommit) { throw 'Detached source pin mismatch.' }
    Invoke-Checked git -C $SourceRoot submodule update --init ggml llama.cpp third_party/cpp-httplib
    Invoke-Checked git -C $SourceRoot apply --check $PatchPath
    Invoke-Checked git -C $SourceRoot apply $PatchPath
}
$changed = @(git -C $SourceRoot diff --name-only)
$expectedChanged = if ($sourceWasReused -and $Backend -eq 'cuda') { @('ggml','server/http/http_server.cpp') } else { @('server/http/http_server.cpp') }
if (($changed | ConvertTo-Json -Compress) -cne ($expectedChanged | ConvertTo-Json -Compress)) {
    throw "Functional diff escaped allowlist: $($changed -join ', ')"
}
$hunks = @((git -C $SourceRoot diff --unified=0 -- server/http/http_server.cpp | Select-String '^@@').Line)
if ($hunks.Count -ne 2) { throw "Expected exactly two functional hunks, got $($hunks.Count)" }

if ($Backend -eq 'cuda') {
    $cudaRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$CudaVersion"
    $cudaWasReused = $false
    if (Test-Path -LiteralPath "$cudaRoot\bin\nvcc.exe") {
        if (-not $Local) { throw 'Unexpected pre-existing CUDA 12.8 toolkit; GitHub mode requires a clean runner.' }
        if (-not $ReuseLocalCuda) { throw 'Local CUDA exists but -ReuseLocalCuda and its consented proof were not supplied.' }
        $reuseProof = Test-LocalCudaReuseProof -CudaRoot $cudaRoot -ProofPath $LocalCudaProofPath
        if (-not $reuseProof.passed) { throw ('Local CUDA reuse proof failed: ' + ($reuseProof.errors -join '; ')) }
        $env:CUDA_PATH = $cudaRoot
        $env:CUDA_PATH_V12_8 = $cudaRoot
        $env:Path = "$cudaRoot\bin;$env:Path"
        $nvccVersion = (& "$cudaRoot\bin\nvcc.exe" --version 2>&1 | Out-String)
        if (-not (Test-NvccVersionText -Text $nvccVersion).passed) { throw 'Reused local nvcc does not report release 12.8.' }
        $cudaWasReused = $true
    } elseif ($ReuseLocalCuda) {
        throw '-ReuseLocalCuda was requested but the proven CUDA 12.8 toolkit is absent.'
    }

    if (-not $cudaWasReused) {
    if ($Local) {
        $systemDrive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($cudaRoot).TrimEnd(':','\'))
        if ($systemDrive.Free -lt 100GB) { throw 'Less than 100 GB free before CUDA installation.' }
        $downloadRoot = Join-Path $LocalBuildBase 'downloads'
        New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
        $installer = Join-Path $downloadRoot 'cuda_12.8.0_windows_network.exe'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { Invoke-WebRequest -Uri $CudaInstallerUrl -OutFile $installer }
    } else {
        $installer = Join-Path $WorkRoot 'cuda_12.8.0_windows_network.exe'
        Invoke-WebRequest -Uri $CudaInstallerUrl -OutFile $installer
    }
    $installerSha = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    $installerMd5 = (Get-FileHash -LiteralPath $installer -Algorithm MD5).Hash
    if ($installerSha -ne $CudaInstallerSha256 -or $installerMd5 -ne $CudaInstallerMd5) {
        throw "Pinned CUDA installer hash mismatch: sha256=$installerSha md5=$installerMd5"
    }

    function Get-NvidiaState {
        $services = @(Get-CimInstance Win32_Service | Where-Object {
            $_.Name -match '(?i)nvidia|cuda' -or $_.DisplayName -match '(?i)nvidia|cuda'
        } | Sort-Object Name | Select-Object Name, DisplayName, State, StartMode, PathName)
        $tasks = @(Get-ScheduledTask | Where-Object {
            $_.TaskName -match '(?i)nvidia|cuda' -or $_.TaskPath -match '(?i)nvidia|cuda'
        } | Sort-Object TaskPath, TaskName | Select-Object TaskPath, TaskName, State)
        return [ordered]@{ services=$services; tasks=$tasks }
    }

    function Get-InstallerLogSnapshot {
        $roots = @(
            (Join-Path $env:ProgramFiles 'NVIDIA Corporation\Installer2'),
            (Join-Path $env:ProgramData 'NVIDIA Corporation\Installer2'),
            (Join-Path $env:TEMP 'CUDA'),
            (Join-Path $env:TEMP 'NVIDIA')
        ) | Where-Object { Test-Path -LiteralPath $_ }
        $snapshot = @{}
        foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -match '(?i)^\.(log|txt|json|xml)$' -and
                -not $_.FullName.StartsWith($WorkRoot, [StringComparison]::OrdinalIgnoreCase)
            } | ForEach-Object {
                $snapshot[$_.FullName] = "$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
            }
        }
        return $snapshot
    }

    function Write-SanitizedInstallerLog {
        param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
        $content = [string]::Empty
        if (Test-Path -LiteralPath $InputPath -PathType Leaf) {
            $readContent = Get-Content -LiteralPath $InputPath -Raw -ErrorAction Stop
            if ($null -ne $readContent) { $content = [string]$readContent }
        }
        foreach ($privateRoot in @($env:RUNNER_TEMP, $env:GITHUB_WORKSPACE, $env:USERPROFILE, $WorkRoot)) {
            if (-not $privateRoot) { continue }
            $root = ([string]$privateRoot).TrimEnd([char[]]@('\', '/'))
            $variants = @()
            foreach ($baseVariant in @($root, $root.Replace('\', '/'), $root.Replace('/', '\')) | Sort-Object -Unique) {
                $variants += $baseVariant
                $variants += $baseVariant.Replace('\', '\\')
            }
            foreach ($variant in @($variants | Sort-Object -Unique | Sort-Object -Property Length -Descending)) {
                $content = [regex]::Replace(
                    $content,
                    [regex]::Escape($variant),
                    '<private-path>',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
            }
        }
        $content = $content -replace '(?im)\b(authorization)\s*[:=]\s*[^\r\n]+', '$1=<redacted>'
        $content = $content -replace '(?im)\b(bearer)\s+[^\s,\r\n]+', '$1 <redacted>'
        $content = $content -replace '(?im)(["'']?(?:token|secret|password)["'']?\s*[:=]\s*)[^\r\n]+', '$1<redacted>'
        $content = $content -replace '(?i)((?:https?://|/)[^\s?]+)\?[^\s#]+', '$1?<redacted-query>'
        if ([string]::IsNullOrEmpty($content)) { $content = '<empty>' }
        [IO.File]::WriteAllText($OutputPath, $content, [Text.UTF8Encoding]::new($false))
    }

    $installerRunRoot = Join-Path $WorkRoot ('cuda-installer-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $installerRunRoot | Out-Null
    $installerStdout = Join-Path $installerRunRoot 'installer.stdout.log'
    $installerStderr = Join-Path $installerRunRoot 'installer.stderr.log'
    $installerEvidencePath = Join-Path $EvidenceRoot 'cuda-installer-result.json'

    $installerArguments = @('-s','-n','nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
    if (($installerArguments -join ' ') -match '(?i)Display\.Driver' -or $installerArguments.Count -ne 7) {
        throw 'CUDA installer argument allowlist changed or includes Display.Driver.'
    }

    $driverBeforePath = Join-Path $installerRunRoot 'drivers-before.txt'
    $driverAfterPath = Join-Path $installerRunRoot 'drivers-after.txt'
    (& pnputil.exe /enum-drivers 2>&1 | Out-String) | Set-Content -LiteralPath $driverBeforePath -Encoding utf8NoBOM
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inventory Windows driver packages before CUDA installation.' }
    $driverBeforeHash = (Get-FileHash -LiteralPath $driverBeforePath -Algorithm SHA256).Hash
    $nvidiaStateBefore = Get-NvidiaState
    $logSnapshotBefore = Get-InstallerLogSnapshot

    $installerProcess = $null
    $installerExitCode = $null
    $installerStarted = $null
    $installerEnded = $null
    $installerFailureType = $null
    $sanitizerFailureTypes = @()
    try {
        $installerStarted = [DateTimeOffset]::UtcNow
        $installerProcess = if ($Local) {
            Start-Process -FilePath $installer -ArgumentList $installerArguments -Wait -PassThru -Verb RunAs
        } else {
            Start-Process -FilePath $installer -ArgumentList $installerArguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $installerStdout -RedirectStandardError $installerStderr
        }
        $installerEnded = [DateTimeOffset]::UtcNow
        if ($null -eq $installerProcess) { throw 'Pinned CUDA installer returned no process object.' }
        $installerExitCode = $installerProcess.ExitCode
    } catch {
        if ($null -eq $installerEnded) { $installerEnded = [DateTimeOffset]::UtcNow }
        $installerFailureType = $_.Exception.GetType().FullName
    } finally {
        foreach ($logPair in @(
            @($installerStdout, (Join-Path $EvidenceRoot 'cuda-installer-stdout.log')),
            @($installerStderr, (Join-Path $EvidenceRoot 'cuda-installer-stderr.log'))
        )) {
            try {
                Write-SanitizedInstallerLog -InputPath $logPair[0] -OutputPath $logPair[1]
            } catch {
                $sanitizerFailureTypes += $_.Exception.GetType().FullName
            }
        }
    }

    if ($null -ne $installerFailureType -or $null -eq $installerProcess -or $null -eq $installerExitCode) {
        $startFailureEvidence = [ordered]@{
            schema='diagnotes-cuda-installer-v2'; status='start_failed'
            installer_url=$CudaInstallerUrl; installer_sha256=$installerSha; installer_md5=$installerMd5
            arguments=$installerArguments; display_driver_requested=$false
            started_utc=if ($installerStarted) { $installerStarted.ToString('O') } else { $null }
            ended_utc=if ($installerEnded) { $installerEnded.ToString('O') } else { $null }
            exit_code=$installerExitCode; failure_type=$installerFailureType
            sanitizer_failure_types=$sanitizerFailureTypes
            post_install_gates='not_evaluated'
        }
        $evidenceWriteFailureType = $null
        try {
            $startFailureEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $installerEvidencePath -Encoding utf8NoBOM
        } catch {
            $evidenceWriteFailureType = $_.Exception.GetType().FullName
        }
        if ($evidenceWriteFailureType) {
            throw "Pinned CUDA installer invocation failed ($installerFailureType); evidence write also failed ($evidenceWriteFailureType)."
        }
        throw "Pinned CUDA installer invocation failed ($installerFailureType)."
    }

    $driverAfterHash = $null
    $nvidiaStateUnchanged = $null
    $lingeringInstallerNames = @()
    $nativeLogEvidence = @()
    $componentInventoryStatus = if ($installerExitCode -eq 0) { 'not_started' } else { 'not_evaluated_exit_nonzero' }
    $nvccVersionIs128 = $false
    $postGateStage = 'driver_inventory_after'
    $postGateFailureType = $null
    try {
        (& pnputil.exe /enum-drivers 2>&1 | Out-String) | Set-Content -LiteralPath $driverAfterPath -Encoding utf8NoBOM
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inventory Windows driver packages after CUDA installation.' }
        $driverAfterHash = (Get-FileHash -LiteralPath $driverAfterPath -Algorithm SHA256).Hash

        $postGateStage = 'nvidia_service_task_state'
        $nvidiaStateAfter = Get-NvidiaState
        $nvidiaStateBeforeJson = $nvidiaStateBefore | ConvertTo-Json -Depth 8 -Compress
        $nvidiaStateAfterJson = $nvidiaStateAfter | ConvertTo-Json -Depth 8 -Compress
        $nvidiaStateUnchanged = $nvidiaStateBeforeJson -ceq $nvidiaStateAfterJson

        $postGateStage = 'native_log_inventory'
        $logSnapshotAfter = Get-InstallerLogSnapshot
        $changedNativeLogs = @($logSnapshotAfter.Keys | Where-Object {
            -not $logSnapshotBefore.ContainsKey($_) -or $logSnapshotBefore[$_] -ne $logSnapshotAfter[$_]
        } | Sort-Object)
        $nativeLogIndex = 0
        foreach ($nativeLog in $changedNativeLogs) {
            $nativeLogIndex++
            $sanitizedName = "cuda-installer-native-$nativeLogIndex.log"
            try {
                Write-SanitizedInstallerLog -InputPath $nativeLog -OutputPath (Join-Path $EvidenceRoot $sanitizedName)
                $nativeLogEvidence += [ordered]@{
                    evidence=$sanitizedName
                    size=(Get-Item -LiteralPath $nativeLog).Length
                    sha256=(Get-FileHash -LiteralPath $nativeLog -Algorithm SHA256).Hash
                }
            } catch {
                $sanitizerFailureTypes += $_.Exception.GetType().FullName
            }
        }

        $postGateStage = 'lingering_installer_processes'
        $lingeringInstallerNames = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '(?i)cuda.*(setup|install)|nvidia.*(setup|install)'
        } | Select-Object -ExpandProperty ProcessName)

        if ($installerExitCode -eq 0) {
            $postGateStage = 'component_inventory'
            $componentInventoryStatus = 'in_progress'
            $componentFiles = [ordered]@{
                nvcc_12_8 = @('bin\nvcc.exe','bin\nvcc.profile','nvvm\bin\cicc.exe')
                cudart_12_8 = @('bin\cudart64_12.dll')
                cublas_12_8 = @('bin\cublas64_12.dll','bin\cublasLt64_12.dll')
                cublas_dev_12_8 = @('include\cublas_v2.h','lib\x64\cublas.lib','lib\x64\cublasLt.lib')
                thrust_12_8 = @('include\thrust\version.h')
            }
            $componentInventory = @()
            foreach ($component in $componentFiles.GetEnumerator()) {
                $files = @($component.Value | ForEach-Object {
                    $path = Join-Path $cudaRoot $_
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "CUDA component inventory lacks $($component.Key): $_" }
                    [ordered]@{
                        path=$_.Replace('\','/')
                        size=(Get-Item -LiteralPath $path).Length
                        sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    }
                })
                $componentInventory += [ordered]@{ component=$component.Key.Replace('_','.'); files=$files }
            }
            $cudaVersionMetadata = Join-Path $cudaRoot 'version.json'
            if (-not (Test-Path -LiteralPath $cudaVersionMetadata)) { throw 'CUDA 12.8 native version.json metadata is missing.' }
            $cudaVersionRaw = Get-Content -LiteralPath $cudaVersionMetadata -Raw
            $cudaVersionContract = Test-CudaVersionJson -Json $cudaVersionRaw
            if (-not $cudaVersionContract.passed) { throw "CUDA native version metadata failed: $($cudaVersionContract.reason)" }
            [ordered]@{
                schema='diagnotes-cuda-component-inventory-v1'; toolkit='12.8'
                version_json_sha256=(Get-FileHash -LiteralPath $cudaVersionMetadata -Algorithm SHA256).Hash
                components=$componentInventory; display_driver_in_allowlist=$false
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'cuda-component-inventory.json') -Encoding utf8NoBOM
            $componentInventoryStatus = 'complete'

            $postGateStage = 'nvcc_version'
            if (-not (Test-Path -LiteralPath "$cudaRoot\bin\nvcc.exe")) {
                throw 'Pinned minimal CUDA Toolkit install did not produce nvcc.exe.'
            }
            $env:CUDA_PATH = $cudaRoot
            $env:CUDA_PATH_V12_8 = $cudaRoot
            $env:Path = "$cudaRoot\bin;$env:Path"
            $nvccVersion = (& "$cudaRoot\bin\nvcc.exe" --version 2>&1 | Out-String)
            [IO.File]::WriteAllText(
                (Join-Path $EvidenceRoot 'nvcc-version.sanitized.txt'),
                (ConvertTo-SanitizedEvidenceText -Content $nvccVersion),
                [Text.UTF8Encoding]::new($false)
            )
            $nvccVersionContract = Test-NvccVersionText -Text $nvccVersion
            $nvccVersionIs128 = $nvccVersionContract.passed
            if (-not $nvccVersionIs128) { throw 'nvcc does not report release 12.8.' }
        }
        $postGateStage = 'complete'
    } catch {
        if ($componentInventoryStatus -eq 'in_progress') { $componentInventoryStatus = 'incomplete' }
        $postGateFailureType = $_.Exception.GetType().FullName
    }

    $driverInventoryUnchanged = $null -ne $driverAfterHash -and $driverBeforeHash -eq $driverAfterHash
    $noLingeringInstallers = $lingeringInstallerNames.Count -eq 0
    $installerSucceeded = (
        $installerExitCode -eq 0 -and
        $null -eq $postGateFailureType -and
        $driverInventoryUnchanged -and
        $nvidiaStateUnchanged -eq $true -and
        $noLingeringInstallers -and
        $sanitizerFailureTypes.Count -eq 0 -and
        $componentInventoryStatus -eq 'complete' -and
        $nvccVersionIs128
    )
    $installerEvidence = [ordered]@{
        schema='diagnotes-cuda-installer-v2'
        status=if ($installerSucceeded) { 'completed' } elseif ($installerExitCode -ne 0) { 'bootstrapper_failed' } else { 'post_install_failed' }
        installer_url=$CudaInstallerUrl; installer_sha256=$installerSha; installer_md5=$installerMd5
        arguments=$installerArguments; display_driver_requested=$false
        started_utc=$installerStarted.ToString('O'); ended_utc=$installerEnded.ToString('O')
        exit_code=$installerExitCode
        driver_inventory_before_sha256=$driverBeforeHash
        driver_inventory_after_sha256=$driverAfterHash
        driver_inventory_unchanged=$driverInventoryUnchanged
        nvidia_service_task_state_unchanged=$nvidiaStateUnchanged
        lingering_installer_processes=$lingeringInstallerNames
        sanitizer_failure_types=$sanitizerFailureTypes
        sanitized_native_logs=$nativeLogEvidence
        component_inventory_status=$componentInventoryStatus
        nvcc_12_8=$nvccVersionIs128
        post_gate_stage=$postGateStage
        post_gate_failure_type=$postGateFailureType
    }
    $evidenceWriteFailureType = $null
    try {
        $installerEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $installerEvidencePath -Encoding utf8NoBOM
        $installerEvidence | ConvertTo-Json -Depth 8
    } catch {
        $evidenceWriteFailureType = $_.Exception.GetType().FullName
    }

    if ($installerExitCode -ne 0) {
        if ($evidenceWriteFailureType) { throw "Pinned CUDA installer failed with exit code $installerExitCode; evidence write also failed ($evidenceWriteFailureType)." }
        throw "Pinned CUDA installer failed with exit code $installerExitCode."
    }
    if ($evidenceWriteFailureType) { throw "CUDA installer evidence write failed ($evidenceWriteFailureType)." }
    if ($sanitizerFailureTypes.Count -ne 0) { throw 'CUDA installer log sanitization failed.' }
    if ($null -ne $postGateFailureType) { throw "CUDA post-install gate failed at $postGateStage ($postGateFailureType)." }
    if (-not $driverInventoryUnchanged) { throw 'Windows driver package inventory changed during CUDA installation.' }
    if ($nvidiaStateUnchanged -ne $true) { throw 'NVIDIA service or scheduled-task inventory changed during CUDA installation.' }
    if (-not $noLingeringInstallers) { throw 'A CUDA/NVIDIA installer process remained after direct completion.' }
    if ($componentInventoryStatus -ne 'complete') { throw 'CUDA component inventory did not complete.' }
    if (-not $nvccVersionIs128) { throw 'nvcc 12.8 verification failed.' }
    if ($Local) {
        $proofFiles = @()
        foreach ($relative in @((Get-CudaComponentFileMap).Values | ForEach-Object { $_ } | ForEach-Object { $_ })) {
            $path = Join-Path $cudaRoot $relative
            $proofFiles += [ordered]@{ path=$relative.Replace('\','/'); size=(Get-Item -LiteralPath $path).Length; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
        [ordered]@{
            schema='diagnotes-local-cuda-install-proof-v1'; cuda_root=$cudaRoot
            installer_url=$CudaInstallerUrl; installer_sha256=$CudaInstallerSha256; installer_md5=$CudaInstallerMd5
            arguments=$installerArguments; components=@('nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
            display_driver_requested=$false; driver_inventory_unchanged=$driverInventoryUnchanged
            nvidia_service_task_state_unchanged=$nvidiaStateUnchanged; lingering_installer_processes=$lingeringInstallerNames
            version_json_sha256=(Get-FileHash -LiteralPath (Join-Path $cudaRoot 'version.json') -Algorithm SHA256).Hash
            files=$proofFiles
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LocalCudaProofPath -Encoding utf8NoBOM
    }
    }
}

$upstreamBuild = Join-Path $SourceRoot 'scripts\windows\build.ps1'
$buildArgs = New-UpstreamBuildArguments -RequestedBackend $Backend -RequestedConfiguration $Configuration `
    -RequestedBuildRoot $BuildRoot -RequestedTriplet $VcpkgTriplet -RequestedCudaArch $CudaArch
# Run upstream in-process so its vcvars64 import remains available for the
# contracted ASR+HTTP-only reconfigure below. A child pwsh discards INCLUDE,
# LIB, and LIBPATH on exit and makes the otherwise valid MSVC build non-repeatable.
& $upstreamBuild @buildArgs

# Reconfigure the upstream ASR preset to the contracted ASR+HTTP-only surface.
$profileArgs = New-ProfileArguments -RequestedBackend $Backend -RequestedSourceRoot $SourceRoot `
    -RequestedBuildRoot $BuildRoot -RequestedCudaArch $CudaArch -ReassertToolchainFromCache
Invoke-Checked cmake @profileArgs
Invoke-Checked cmake --build $BuildRoot --parallel 4
Invoke-Checked cmake --install $BuildRoot --prefix $InstallRoot --config $Configuration
$gateManifest = @(Get-RuntimeGateManifest)
$gateObservations = [ordered]@{}
$gateResultsPath = Join-Path $EvidenceRoot 'gate-results.json'

function Set-GateObservation {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet('PASS','FAIL')][string]$Status, [Parameter(Mandatory)][string]$Reason)
    $script:gateObservations[$Id] = [pscustomobject]@{ status=$Status; reason=(ConvertTo-SanitizedEvidenceText -Content $Reason) }
}

function Test-GateObservationPassed {
    param([Parameter(Mandatory)][string]$Id)
    return $gateObservations.Contains($Id) -and $gateObservations[$Id].status -eq 'PASS'
}

function Write-GateResults {
    $gateResults = @(Invoke-RuntimeGateGraph -Manifest $gateManifest -Observations $gateObservations)
    $payload = [ordered]@{
        schema='diagnotes-runtime-gates-v1'; backend=$Backend; source_commit=$SourceCommit
        recipe_commit=$RecipeCommit; execution_mode=$ExecutionMode; stage='candidate-bytes'; gates=$gateResults
    }
    $json = $payload | ConvertTo-Json -Depth 8
    $temporaryPath = Join-Path $EvidenceRoot ('gate-results.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $gateResultsPath -Force
    return $payload
}

try {
    $functionalDiff = (git -C $SourceRoot diff --binary -- server/http/http_server.cpp | Out-String)
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'functional.diff'), (ConvertTo-SanitizedEvidenceText -Content $functionalDiff), [Text.UTF8Encoding]::new($false))
    if ($Backend -eq 'cuda') {
        if (-not $expectedGgmlCommit) {
            $ggmlTreeEntry = (& git -C $SourceRoot ls-tree HEAD -- ggml 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $ggmlTreeEntry -notmatch '^160000 commit (?<commit>[0-9a-f]{40})\tggml$') { throw 'Unable to resolve pinned ggml commit after build.' }
            $expectedGgmlCommit = $Matches['commit']
        }
        $ggmlPatchSeriesContract = Test-GgmlPatchSeriesContract -GgmlRoot (Join-Path $SourceRoot 'ggml') -PatchDirectory (Join-Path $SourceRoot 'ggml-patches') -ExpectedCommit $expectedGgmlCommit
        if (-not $ggmlPatchSeriesContract.passed) { throw ('ggml patch series contract failed after build: ' + ($ggmlPatchSeriesContract.errors -join '; ')) }
        $ggmlEvidence = [ordered]@{
            schema='diagnotes-ggml-patch-series-v1'
            source_commit=$SourceCommit
            ggml_commit=$expectedGgmlCommit
            patch_count=$ggmlPatchSeriesContract.patch_count
            changed_paths=@($ggmlPatchSeriesContract.changed_paths)
            expected_tree=$ggmlPatchSeriesContract.expected_tree
            current_tree=$ggmlPatchSeriesContract.current_tree
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'ggml-patch-series.json'), $ggmlEvidence, [Text.UTF8Encoding]::new($false))
    }
    Set-GateObservation source-patch PASS 'source, canonical server patch, allowlist, two hunks and exact ggml patch series verified'
} catch { Set-GateObservation source-patch FAIL $_.Exception.Message }

$cacheContract = $null
$cache = $null
try {
    $cache = [IO.File]::ReadAllText((Join-Path $BuildRoot 'CMakeCache.txt'))
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'CMakeCache.sanitized.txt'), (ConvertTo-SanitizedEvidenceText -Content $cache), [Text.UTF8Encoding]::new($false))
    $cacheContract = Test-CMakeCacheContract -Text $cache -RequestedBackend $Backend -RequestedTriplet $VcpkgTriplet -RequestedCudaArch $CudaArch
    if (-not $cacheContract.passed) { throw ($cacheContract.errors -join '; ') }
    Set-GateObservation cache PASS 'structured CMake cache contract passed'
} catch { Set-GateObservation cache FAIL $_.Exception.Message }

$vcpkgRoot = $null
$tripletPath = $null
$vcpkgHead = $null
if (Test-GateObservationPassed cache) {
    try {
        $vcpkgToolchain = $cacheContract.entries['CMAKE_TOOLCHAIN_FILE'].value
        $vcpkgRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $vcpkgToolchain))
        $tripletPath = Join-Path $vcpkgRoot "triplets\$VcpkgTriplet.cmake"
        if (-not (Test-Path -LiteralPath $tripletPath -PathType Leaf)) { throw 'Pinned vcpkg triplet file is missing.' }
        $tripletContract = ConvertFrom-CMakeSetText -Text ([IO.File]::ReadAllText($tripletPath))
        if ($tripletContract.errors.Count -ne 0 -or -not $tripletContract.entries.Contains('VCPKG_LIBRARY_LINKAGE') -or
            -not $tripletContract.entries.Contains('VCPKG_CRT_LINKAGE') -or $tripletContract.entries['VCPKG_LIBRARY_LINKAGE'] -cne 'static' -or
            $tripletContract.entries['VCPKG_CRT_LINKAGE'] -cne 'dynamic') { throw 'vcpkg triplet does not declare static libraries with dynamic CRT.' }
        $vcpkgHead = (git -C $vcpkgRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $vcpkgHead -cne $ExpectedVcpkgCommit) { throw 'Effective vcpkg checkout differs from its pin.' }
        [ordered]@{ schema='diagnotes-vcpkg-v1'; commit=$vcpkgHead; triplet=$VcpkgTriplet; triplet_sha256=(Get-FileHash -LiteralPath $tripletPath -Algorithm SHA256).Hash; library_linkage='static'; crt_linkage='dynamic' } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'vcpkg.json') -Encoding utf8NoBOM
        Set-GateObservation vcpkg PASS 'vcpkg pin and structural triplet contract passed'
    } catch { Set-GateObservation vcpkg FAIL $_.Exception.Message }
}

$compileContract = $null
try {
    $compileDatabasePath = Join-Path $BuildRoot 'compile_commands.json'
    if (-not (Test-Path -LiteralPath $compileDatabasePath -PathType Leaf)) { throw 'compile_commands.json is missing.' }
    $compileDatabaseRaw = [IO.File]::ReadAllText($compileDatabasePath)
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'compile-commands.sanitized.json'), (ConvertTo-SanitizedEvidenceText -Content $compileDatabaseRaw), [Text.UTF8Encoding]::new($false))
    $compileContract = Test-CompileCommandsContract -Json $compileDatabaseRaw
    $compileContract.sanitized_commands | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'compile-command-summary.json') -Encoding utf8NoBOM
    if (-not $compileContract.inspectable) {
        Set-GateObservation compile-arguments-inspectable FAIL 'OPAQUE_OR_INVALID_COMPILE_ARGUMENTS'
    } else {
        Set-GateObservation compile-arguments-inspectable PASS 'all compile arguments are structurally inspectable'
        if ($compileContract.passed) { Set-GateObservation crt PASS 'all compile entries prove Release /MD and exclude debug/static CRT' }
        else { Set-GateObservation crt FAIL ($compileContract.errors -join '; ') }
    }
} catch { Set-GateObservation compile-arguments-inspectable FAIL $_.Exception.Message }

$zipStem = if ($Backend -eq 'cpu') { "$Version-windows-x86_64-cpu" } else { "$Version-windows-x86_64-cuda-sm75-sm80-sm86-sm89" }
$BundleRoot = Join-Path $PackageRoot $zipStem
$bundleStaged = $false
try {
    New-Item -ItemType Directory -Force -Path $BundleRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $InstallRoot 'bin') -Destination (Join-Path $BundleRoot 'bin') -Recurse
    if (Test-Path -LiteralPath (Join-Path $InstallRoot 'share')) { Copy-Item -LiteralPath (Join-Path $InstallRoot 'share') -Destination (Join-Path $BundleRoot 'share') -Recurse }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $BundleRoot 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'NOTICE') -Destination (Join-Path $BundleRoot 'NOTICE')
    Copy-Item -LiteralPath $PatchPath -Destination (Join-Path $BundleRoot 'realtime-language-v1.patch')
    $bundleStaged = $true
} catch { Set-GateObservation profile FAIL ('bundle staging: ' + $_.Exception.Message) }

$binNames = @()
if ($bundleStaged) {
    try {
        $binNames = @(Get-ChildItem -LiteralPath (Join-Path $BundleRoot 'bin') -File | Select-Object -ExpandProperty Name)
        $profileContract = Test-RuntimeBinaryProfile -Names $binNames -RequestedBackend $Backend
        if (-not $profileContract.passed) { throw ($profileContract.errors -join '; ') }
        Set-GateObservation profile PASS 'binary profile is exact and exhaustively classified'
    } catch { Set-GateObservation profile FAIL $_.Exception.Message }
}

$clPath = $null
$vsInstall = $null
$redistRoot = $null
$redistVersion = $null
$reportedToolsetVersion = $null
$dumpbinPath = $null
$installedRedistList = $null
if ($bundleStaged -and (Test-GateObservationPassed cache)) {
    try {
        $clPath = $cacheContract.entries['CMAKE_CXX_COMPILER'].value.Replace('/', '\')
        $redistContract = Resolve-MsvcRedistFromCacheContract -Entries $cacheContract.entries -RequireMaterialized
        if (-not $redistContract.passed) { throw ('Effective MSVC Redist contract failed: ' + ($redistContract.errors -join '; ')) }
        $clPath = $redistContract.cl_path
        $vsInstall = $redistContract.vs_install
        $reportedToolsetVersion = $redistContract.toolset_version
        $redistVersion = $redistContract.redist_version
        $redistVersionRoot = $redistContract.redist_version_root
        $redistRoot = $redistContract.redist_root
        $dumpbinPath = $redistContract.dumpbin_path
        [ordered]@{
            schema='diagnotes-effective-msvc-redist-v1'; source='CMakeCache.txt'
            cl_path=(ConvertTo-SanitizedEvidenceText -Content $clPath)
            toolset_version=$reportedToolsetVersion
            redist_version=$redistVersion
            redist_directory=(ConvertTo-SanitizedEvidenceText -Content $redistContract.redist_version_root)
            version_relation='same Visual Studio installation and major.minor family'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'effective-msvc-redist.json') -Encoding utf8NoBOM

        $msvcLicenseDir = Join-Path $BundleRoot 'share\licenses\microsoft-visual-cpp-runtime'
        New-Item -ItemType Directory -Force -Path $msvcLicenseDir | Out-Null
        $vsLicensePath = Join-Path $msvcLicenseDir 'Visual-Studio-2022-Community-License-EN.docx'
        $vsRedistListPath = Join-Path $msvcLicenseDir 'Visual-Studio-2022-Redistribution.html'
        Invoke-WebRequest -Uri $VsLicenseUrl -OutFile $vsLicensePath
        Invoke-WebRequest -Uri $VsRedistListUrl -OutFile $vsRedistListPath
        if ((Get-FileHash -LiteralPath $vsLicensePath -Algorithm SHA256).Hash -cne $VsLicenseSha256) { throw 'Visual Studio license pin mismatch.' }
        if ((Get-FileHash -LiteralPath $vsRedistListPath -Algorithm SHA256).Hash -cne $VsRedistListSha256) { throw 'Visual Studio REDIST pin mismatch.' }
        $installedRedistList = Get-ChildItem -LiteralPath (Join-Path $vsInstall 'Licenses') -Filter 'Redist.txt' -File -Recurse |
            Sort-Object @{Expression={ if ($_.Directory.Name -eq '1033') { 0 } else { 1 } }}, FullName | Select-Object -First 1
        if (-not $installedRedistList) { throw 'Installed Visual Studio Redist.txt is missing.' }
        Copy-Item -LiteralPath $installedRedistList.FullName -Destination (Join-Path $msvcLicenseDir 'Redist.txt')

        if ($Backend -eq 'cuda') {
            $cudaLicense = Resolve-CudaToolkitLicensePath -CudaRoot $env:CUDA_PATH -ExpectedSha256 $CudaLicenseSha256
            $cudaLicenseDir = Join-Path $BundleRoot 'share\licenses\nvidia-cuda-toolkit'
            New-Item -ItemType Directory -Force -Path $cudaLicenseDir | Out-Null
            Copy-Item -LiteralPath $cudaLicense.path -Destination (Join-Path $cudaLicenseDir 'EULA.txt')
        }
        [ordered]@{
            schema='diagnotes-legal-pins-v1'; visual_studio_license_sha256=$VsLicenseSha256; visual_studio_redist_list_sha256=$VsRedistListSha256
            installed_redist_pointer_sha256=(Get-FileHash -LiteralPath $installedRedistList.FullName -Algorithm SHA256).Hash
            cuda_license_sha256=if ($Backend -eq 'cuda') { $CudaLicenseSha256 } else { $null }
            cuda_eula_present=($Backend -ne 'cuda' -or (Test-Path -LiteralPath (Join-Path $BundleRoot 'share\licenses\nvidia-cuda-toolkit\EULA.txt')))
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'legal.json') -Encoding utf8NoBOM
        Set-GateObservation legal PASS 'pinned legal bytes and in-package notices are present'
    } catch { Set-GateObservation legal FAIL $_.Exception.Message }
}

$peClosure = $null
function New-WindowsSystemDllSet {
    $names = @(
        'ADVAPI32.dll','BCRYPT.dll','BCRYPTPRIMITIVES.dll','CABINET.dll','CFGMGR32.dll','COMCTL32.dll','COMDLG32.dll',
        'CRYPT32.dll','DBGHELP.dll','DNSAPI.dll','GDI32.dll','IMM32.dll','IPHLPAPI.dll','KERNEL32.dll','MSWSOCK.dll',
        'NETAPI32.dll','NORMALIZ.dll','NTDLL.dll','OLE32.dll','OLEAUT32.dll','POWRPROF.dll','PSAPI.dll','RPCRT4.dll',
        'SECUR32.dll','SETUPAPI.dll','SHELL32.dll','SHLWAPI.dll','USER32.dll','USERENV.dll','UCRTBASE.dll','VERSION.dll',
        'WINHTTP.dll','WINMM.dll','WS2_32.dll','WTSAPI32.dll'
    )
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $names) {
        if (-not $set.Add($name)) { throw "Duplicate Windows system DLL: $name" }
    }
    if ($set.Count -ne 35) { throw 'Windows system DLL allowlist cardinality mismatch.' }
    return ,$set
}
$systemDlls = New-WindowsSystemDllSet
function Get-PeDependencies {
    param([Parameter(Mandatory)][string]$Path)
    $output = (& $dumpbinPath /DEPENDENTS $Path 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'dumpbin dependency inspection failed.' }
    $parsed = ConvertFrom-DumpbinDependentsText -Text $output
    if (-not $parsed.passed) { throw "dumpbin dependency output failed structural parsing: $($parsed.reason)" }
    return @($parsed.dependencies)
}

function Resolve-PeClosure {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][bool]$AllowMsvcCopy,
        [string]$CudaRoot
    )
    $binRoot = Join-Path $Root 'bin'
    $files = @{}
    Get-ChildItem -LiteralPath $binRoot -File -Recurse | Where-Object { $_.Extension -in '.exe','.dll' } | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if ($files.ContainsKey($key)) { throw 'Case-insensitive duplicate PE basename in bundle.' }
        $files[$key] = $_.FullName
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    $files.Values | ForEach-Object { $queue.Enqueue($_) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $recordedMsvc = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $edges = @()
    $copied = @()
    $copiedCuda = @()
    while ($queue.Count -gt 0) {
        $importer = $queue.Dequeue()
        if (-not $seen.Add($importer)) { continue }
        foreach ($dependency in Get-PeDependencies -Path $importer) {
            $key = $dependency.ToLowerInvariant()
            $classification = $null
            $resolved = $null
            if (Test-IsAllowedMsvcRedistributableName -Name $dependency) {
                if ($dependency -match '(?i)d\.dll$') { throw 'Debug MSVC runtime import is not redistributable.' }
                $source = Resolve-MsvcRedistSourcePath -Name $dependency -RedistVersionRoot $redistVersionRoot
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Required MSVC DLL is absent from Redist.' }
                if ($files.ContainsKey($key)) { $resolved = $files[$key] }
                else {
                    if (-not $AllowMsvcCopy) { throw 'Clean ZIP extraction lacks an app-local MSVC dependency.' }
                    $resolved = Join-Path $binRoot $dependency
                    Copy-Item -LiteralPath $source -Destination $resolved
                    $files[$key] = $resolved
                }
                $sourceSignature = Get-AuthenticodeSignature -LiteralPath $source
                $signature = Get-AuthenticodeSignature -LiteralPath $resolved
                $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
                $resolvedHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
                $fileContract = Test-MsvcRedistFileContract -SourceSha256 $sourceHash -BundleSha256 $resolvedHash `
                    -SourceSignatureStatus ([string]$sourceSignature.Status) -SourceSignerSubject $(if ($null -eq $sourceSignature.SignerCertificate) { '' } else { $sourceSignature.SignerCertificate.Subject }) `
                    -BundleSignatureStatus ([string]$signature.Status) -BundleSignerSubject $(if ($null -eq $signature.SignerCertificate) { '' } else { $signature.SignerCertificate.Subject })
                if (-not $fileContract.passed) { throw ('App-local MSVC DLL contract failed: ' + ($fileContract.errors -join '; ')) }
                if ($recordedMsvc.Add($dependency)) {
                    $redistRelativePath = [IO.Path]::GetRelativePath($redistVersionRoot, $source).Replace('\','/')
                    $copied += [ordered]@{
                        name=$dependency; size=(Get-Item -LiteralPath $resolved).Length; sha256=$resolvedHash
                        file_version=(Get-Item -LiteralPath $resolved).VersionInfo.FileVersion; product_version=(Get-Item -LiteralPath $resolved).VersionInfo.ProductVersion
                        architecture='x64'; origin="VC/Redist/MSVC/$redistVersion/$redistRelativePath"
                        license='LicenseRef-Microsoft-Visual-Cpp-Runtime'; signer=$signature.SignerCertificate.Subject
                    }
                }
                $classification = 'msvc-redist-app-local'
            } elseif ($files.ContainsKey($key)) { $classification = 'app-local'; $resolved = $files[$key] }
            elseif (-not [string]::IsNullOrWhiteSpace($CudaRoot) -and $dependency -match '^(?i:cudart64_12\.dll|cublas64_12\.dll|cublasLt64_12\.dll)$') {
                if (-not $AllowMsvcCopy) { throw 'Clean ZIP extraction lacks an app-local CUDA runtime dependency.' }
                $source = Resolve-CudaRuntimeDependencyPath -Name $dependency -CudaRoot $CudaRoot
                $resolved = Join-Path $binRoot $dependency
                Copy-Item -LiteralPath $source -Destination $resolved
                $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
                $resolvedHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
                if ($resolvedHash -cne $sourceHash) { throw 'App-local CUDA runtime dependency hash mismatch.' }
                $files[$key] = $resolved
                $copiedCuda += [ordered]@{
                    name=$dependency; size=(Get-Item -LiteralPath $resolved).Length; sha256=$resolvedHash
                    file_version=(Get-Item -LiteralPath $resolved).VersionInfo.FileVersion
                    origin="CUDA Toolkit bin/$dependency"; license='LicenseRef-NVIDIA-CUDA-Toolkit'
                }
                $classification = 'nvidia-cuda-runtime-app-local'
            }
            elseif ($dependency -match '^(?i:api-ms-win-|ext-ms-win-)') { $classification = 'windows-api-set' }
            elseif ($systemDlls.Contains($dependency)) { $classification = 'windows-system' }
            elseif ($Backend -eq 'cuda' -and $dependency -ieq 'nvcuda.dll') { $classification = 'nvidia-host-driver-prerequisite' }
            else { throw "Unresolved non-system PE dependency: $dependency" }
            $edges += [ordered]@{ importer=[IO.Path]::GetFileName($importer); dependency=$dependency; classification=$classification }
            if ($resolved) { $queue.Enqueue($resolved) }
        }
    }
    $presentMsvc = @($files.Values | ForEach-Object { [IO.Path]::GetFileName($_) } | Where-Object { Test-IsAllowedMsvcRedistributableName -Name $_ })
    $redistClosure = Test-MsvcRedistClosureContract -PresentNames $presentMsvc -ImportedNames @($recordedMsvc)
    if (-not $redistClosure.passed) { throw ('MSVC Redist closure failed: ' + ($redistClosure.errors -join '; ')) }
    return [ordered]@{ edges=$edges; copied_msvc=$copied; copied_cuda=$copiedCuda; pe_count=$seen.Count }
}

if ($bundleStaged -and (Test-GateObservationPassed cache) -and (Test-GateObservationPassed legal)) {
    try {
        $preinstalledMsvcRemoved = @(Remove-PreinstalledMsvcRedistributables -Root $BundleRoot)
        $peClosure = Resolve-PeClosure -Root $BundleRoot -AllowMsvcCopy $true -CudaRoot $(if ($Backend -eq 'cuda') { $env:CUDA_PATH } else { $null })
        [ordered]@{
            schema='diagnotes-msvc-redist-v1'; toolset_version=$reportedToolsetVersion; redist_version=$redistVersion
            redist_directory="VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC143.CRT"
            redist_directories=@("VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC143.CRT","VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC143.OpenMP")
            visual_studio_license_sha256=$VsLicenseSha256
            visual_studio_redist_list_sha256=$VsRedistListSha256; installed_redist_pointer_sha256=(Get-FileHash -LiteralPath $installedRedistList.FullName -Algorithm SHA256).Hash
            dlls=$peClosure.copied_msvc
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BundleRoot 'msvc-redist-inventory.json') -Encoding utf8NoBOM
        [ordered]@{ schema='diagnotes-pe-closure-v1'; imports=$peClosure.edges } | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $BundleRoot 'pe-imports.json') -Encoding utf8NoBOM
        [ordered]@{ schema='diagnotes-pe-closure-evidence-v1'; pe_count=$peClosure.pe_count; import_count=$peClosure.edges.Count; preinstalled_msvc_removed=$preinstalledMsvcRemoved; copied_cuda=$peClosure.copied_cuda; signer_policy='Status Valid and O=Microsoft Corporation; CUDA bytes equal pinned toolkit components' } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'pe-closure.json') -Encoding utf8NoBOM
        Set-GateObservation pe-closure PASS 'strict dumpbin parser, PE closure and structured signer identity passed'
    } catch { Set-GateObservation pe-closure FAIL $_.Exception.Message }
}

$inventory = @()
$payloadRecords = @()
$inventoryJson = $null
$sbomJson = $null
$metadataEvidenceJson = $null
$toolchain = $null
if ((Test-GateObservationPassed profile) -and (Test-GateObservationPassed legal) -and (Test-GateObservationPassed pe-closure)) {
    try {
        $msvcVersionText = Get-MsvcVersionText -ClPath $clPath -ExpectedToolsetVersion $reportedToolsetVersion
        $toolchain = [ordered]@{
            identity=$Version; backend=$Backend; source_commit=$SourceCommit; patch_sha256=$PatchSha256; patch_bytes=$PatchBytes
            cuda_architectures=if ($Backend -eq 'cuda') { @('75','80','86','89') } else { @() }
            runtime_capabilities=@('realtime-language-v1'); execution_mode=$ExecutionMode; github_image_os=$env:ImageOS; github_image_version=$env:ImageVersion
            cmake=(& cmake --version | Select-Object -First 1); ninja=(& ninja --version | Select-Object -First 1)
            msvc=$msvcVersionText; windows_sdk=$env:WindowsSDKVersion; vcpkg_commit=$ExpectedVcpkgCommit
            vcpkg_triplet=$VcpkgTriplet; msvc_toolset_version=$reportedToolsetVersion; msvc_crt='dynamic-app-local'
            cuda=if ($Backend -eq 'cuda') { (& "$env:CUDA_PATH\bin\nvcc.exe" --version | Select-Object -Last 1) } else { $null }
            cuda_installer=if ($Backend -eq 'cuda') { [ordered]@{ url=$CudaInstallerUrl; sha256=$CudaInstallerSha256; md5=$CudaInstallerMd5; components=@('nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8'); driver=$false } } else { $null }
            cmake_profile=[ordered]@{ asr=$true; http=$true; cli=$true; diar=$false; tts=$false; nmt=$false; mic_capture=$false }
            authenticode='absent-by-contract'
        }
        $toolchain | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BundleRoot 'runtime-build.json') -Encoding utf8NoBOM
        $toolchain | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'toolchain.json') -Encoding utf8NoBOM
        $payloadRecords = @(Get-RuntimeTreeRecords -Root $BundleRoot)
        foreach ($record in $payloadRecords) {
            $classification = Get-RuntimeFileClassification -RelativePath $record.path
            if (-not $classification.passed) { throw "Inventory path is unclassified: $($record.path)" }
            $inventory += [ordered]@{
                path=$record.path; size=$record.size; sha256=$record.sha256
                kind=if ([IO.Path]::GetExtension($record.path) -in '.exe','.dll') { 'PE' } else { 'data' }; origin=$classification.origin; license=$classification.license
            }
        }
        $inventoryJson = [ordered]@{ schema='diagnotes-runtime-inventory-v2'; scope='payload-only'; exclusions=@('inventory.json','sbom.spdx.json'); files=$inventory } | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $BundleRoot 'inventory.json'), $inventoryJson, [Text.UTF8Encoding]::new($false))
        [ordered]@{ schema='diagnotes-inventory-evidence-v1'; file_count=$inventory.Count; unknown_count=0 } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $EvidenceRoot 'inventory.json') -Encoding utf8NoBOM
        Set-GateObservation inventory PASS 'payload-only inventory serializes every operational file with exact exclusions'
    } catch { Set-GateObservation inventory FAIL $_.Exception.Message }
}

if (Test-GateObservationPassed inventory) {
    try {
        $spdxFiles = @($inventory | ForEach-Object {
            [ordered]@{ fileName=$_.path; checksums=@([ordered]@{algorithm='SHA256';checksumValue=$_.sha256}); licenseConcluded=$_.license; licenseInfoInFiles=@($_.license) }
        })
        $sbomJson = [ordered]@{
            spdxVersion='SPDX-2.3'; dataLicense='CC0-1.0'; SPDXID='SPDXRef-DOCUMENT'; name="$zipStem-sbom"
            documentNamespace=if ($Local) { "urn:diagnotes:local-runtime:${runIdentity}:$zipStem" } else { "https://github.com/dnl0037/diagnotes-nemotron-runtime/sbom/$zipStem/$env:GITHUB_RUN_ID" }
            creationInfo=[ordered]@{ created=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); creators=@('Tool: Build-Runtime.ps1') }
            files=$spdxFiles
        } | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText((Join-Path $BundleRoot 'sbom.spdx.json'), $sbomJson, [Text.UTF8Encoding]::new($false))
        [ordered]@{ schema='diagnotes-sbom-evidence-v1'; files=$spdxFiles.Count; inventory_files=$inventory.Count } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'sbom.json') -Encoding utf8NoBOM
        if ($spdxFiles.Count -ne $inventory.Count) { throw 'SBOM/inventory cardinality mismatch.' }
        Set-GateObservation sbom PASS 'SPDX cardinality and SHA-256 values derive from exact inventory'
    } catch { Set-GateObservation sbom FAIL $_.Exception.Message }
}

if ((Test-GateObservationPassed inventory) -and (Test-GateObservationPassed sbom)) {
    try {
        $metadataFiles = @('inventory.json','sbom.spdx.json') | ForEach-Object {
            $path = Join-Path $BundleRoot $_
            [ordered]@{ name=$_; size=(Get-Item -LiteralPath $path).Length; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
        $metadataEvidenceJson = [ordered]@{ schema='diagnotes-payload-metadata-evidence-v1'; files=@($metadataFiles) } | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'payload-metadata.json'), $metadataEvidenceJson, [Text.UTF8Encoding]::new($false))
        $treeRecords = @(Get-RuntimeTreeRecords -Root $BundleRoot)
        $payloadClosure = Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $treeRecords `
            -InventoryJson $inventoryJson -SbomJson $sbomJson -MetadataEvidenceJson $metadataEvidenceJson
        if (-not $payloadClosure.passed) { throw ('Payload closure failed: ' + ($payloadClosure.errors -join '; ')) }
        Set-GateObservation payload-closure PASS 'serialized inventory, SBOM, detached metadata and exact final tree are bijective'
    } catch { Set-GateObservation payload-closure FAIL $_.Exception.Message }
}

$zipPath = Join-Path $ArtifactsRoot "$zipStem.zip"
$recheckRoot = $null
$extractedClosure = $null
if (Test-GateObservationPassed payload-closure) {
    try {
        $preCompressionRecords = @(Get-RuntimeTreeRecords -Root $BundleRoot)
        $preCompressionClosure = Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $preCompressionRecords `
            -InventoryJson $inventoryJson -SbomJson $sbomJson -MetadataEvidenceJson $metadataEvidenceJson
        if (-not $preCompressionClosure.passed) { throw ('Pre-compression payload closure failed: ' + ($preCompressionClosure.errors -join '; ')) }
        Compress-Archive -LiteralPath $BundleRoot -DestinationPath $zipPath -CompressionLevel Optimal
        $extracted = Join-Path (Split-Path -Parent $PackageRoot) 'zip-recheck'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extracted
        $recheckRoot = Join-Path $extracted $zipStem
        if (-not (Test-Path -LiteralPath (Join-Path $recheckRoot 'bin\nemo-speech.exe') -PathType Leaf)) { throw 'Clean ZIP extraction lacks nemo-speech.exe.' }
        $extractedRecords = @(Get-RuntimeTreeRecords -Root $recheckRoot)
        $extractedPayloadClosure = Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $extractedRecords `
            -InventoryJson ([IO.File]::ReadAllText((Join-Path $recheckRoot 'inventory.json'))) `
            -SbomJson ([IO.File]::ReadAllText((Join-Path $recheckRoot 'sbom.spdx.json'))) -MetadataEvidenceJson $metadataEvidenceJson
        if (-not $extractedPayloadClosure.passed) { throw ('Extracted payload closure failed: ' + ($extractedPayloadClosure.errors -join '; ')) }
        $extractedClosure = Resolve-PeClosure -Root $recheckRoot -AllowMsvcCopy $false -CudaRoot $(if ($Backend -eq 'cuda') { $env:CUDA_PATH } else { $null })
        [ordered]@{
            schema='diagnotes-zip-recheck-v1'; name=(Split-Path -Leaf $zipPath); size=(Get-Item -LiteralPath $zipPath).Length
            sha256=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash; inventoried_files=$inventory.Count; pe_import_edges=$extractedClosure.edges.Count
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'zip-recheck.json') -Encoding utf8NoBOM
        Set-GateObservation zip-extraction PASS 'final ZIP and clean extraction preserve exact payload plus two detached-covered metadata files'
    } catch { Set-GateObservation zip-extraction FAIL $_.Exception.Message }
}

$defenderScans = @()
$defenderInfrastructure = $null
if (Test-GateObservationPassed zip-extraction) {
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        if (-not $mpStatus.AntivirusEnabled -or -not $mpStatus.RealTimeProtectionEnabled) { throw 'Microsoft Defender is not enabled.' }
        $mpCandidates = @((Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'))
        $platformRoot = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
        if (Test-Path -LiteralPath $platformRoot) {
            $mpCandidates += @(Get-ChildItem -LiteralPath $platformRoot -Filter 'MpCmdRun.exe' -File -Recurse | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
        }
        $mpCmd = @($mpCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
        if ($mpCmd.Count -ne 1) { throw 'Microsoft Defender CLI is missing.' }
        foreach ($scanTarget in @(
            [pscustomobject]@{ id='defender-tree'; name='clean-extracted-tree'; path=$recheckRoot },
            [pscustomobject]@{ id='defender-zip'; name='final-zip'; path=$zipPath }
        )) {
            $scanStarted = [DateTimeOffset]::UtcNow
            $scanOutput = (& $mpCmd[0] -Scan -ScanType 3 -File $scanTarget.path 2>&1 | Out-String)
            $scanExit = $LASTEXITCODE
            $scanEnded = [DateTimeOffset]::UtcNow
            [IO.File]::WriteAllText((Join-Path $EvidenceRoot "$($scanTarget.id).sanitized.log"), (ConvertTo-SanitizedEvidenceText -Content $scanOutput), [Text.UTF8Encoding]::new($false))
            $defenderScans += [ordered]@{ target=$scanTarget.name; started_utc=$scanStarted.ToString('o'); ended_utc=$scanEnded.ToString('o'); exit_code=$scanExit }
            if ($scanExit -eq 0) { Set-GateObservation $scanTarget.id PASS "$($scanTarget.name) Defender scan clean" }
            else { Set-GateObservation $scanTarget.id FAIL "$($scanTarget.name) Defender exit $scanExit" }
        }
    } catch {
        $defenderInfrastructure = $_.Exception.Message
        if (-not $gateObservations.Contains('defender-tree')) { Set-GateObservation defender-tree FAIL $defenderInfrastructure }
        if (-not $gateObservations.Contains('defender-zip')) { Set-GateObservation defender-zip FAIL $defenderInfrastructure }
    } finally {
        [ordered]@{
            schema='diagnotes-defender-v2'; infrastructure_error=if ($defenderInfrastructure) { ConvertTo-SanitizedEvidenceText -Content $defenderInfrastructure } else { $null }
            scans=$defenderScans
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'defender.json') -Encoding utf8NoBOM
    }
}

try {
    $privacyViolations = @(Get-EvidencePrivacyViolations -Root $EvidenceRoot)
    if ($privacyViolations.Count -ne 0) { throw ('unsanitized evidence: ' + ($privacyViolations -join ',')) }
    Set-GateObservation privacy PASS 'sanitized evidence contains no private-root or credential markers'
} catch { Set-GateObservation privacy FAIL $_.Exception.Message }

$internalPrerequisites = @(
    'source-patch','cache','vcpkg','compile-arguments-inspectable','crt','profile','legal','pe-closure',
    'inventory','sbom','payload-closure','zip-extraction','defender-tree','defender-zip','privacy'
)
if (@($internalPrerequisites | Where-Object { -not (Test-GateObservationPassed $_) }).Count -eq 0) {
    Set-GateObservation candidate-bytes-ready PASS 'all internal candidate byte prerequisites passed'
}

$gatePayload = $null
$gateWriteFailure = $null
try { $gatePayload = Write-GateResults } catch { $gateWriteFailure = $_.Exception.GetType().FullName }
if ($gateWriteFailure) { throw "Unable to materialize gate-results.json: $gateWriteFailure" }
$candidateGate = @($gatePayload.gates | Where-Object id -eq 'candidate-bytes-ready')
if ($candidateGate.Count -ne 1 -or $candidateGate[0].status -ne 'PASS') {
    $failed = @($gatePayload.gates | Where-Object { $_.status -ne 'PASS' -and $_.id -notin @('attestation-created','attestation-digest-verified','candidate-upload-eligible') } | ForEach-Object { "$($_.id)=$($_.status)" })
    throw "Runtime candidate gates failed: $($failed -join ', ')"
}

$result = [ordered]@{
    backend=$Backend; zip=(Split-Path -Leaf $zipPath); size=(Get-Item $zipPath).Length
    sha256=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash; files=$binNames
    pe_import_edges=$extractedClosure.edges.Count; defender='clean'; gate_results=(Split-Path -Leaf $gateResultsPath)
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'build-result.json') -Encoding utf8NoBOM
$postBuildPrivacyViolations = @(Get-EvidencePrivacyViolations -Root $EvidenceRoot)
if ($postBuildPrivacyViolations.Count -ne 0) {
    throw ('Post-build evidence privacy contract failed: ' + ($postBuildPrivacyViolations -join ','))
}
$result | ConvertTo-Json -Depth 6
} finally {
    Restore-ProcessEnvironmentMap -Snapshot $processEnvironmentSnapshot
}
