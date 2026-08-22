#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cpu', 'cuda')]
    [string]$Backend,
    [ValidateSet('Release')]
    [string]$Configuration = 'Release',
    [string]$CudaArch = '75;80;86;89',
    [string]$CudaVersion = '12.8'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SourceCommit = '4f9676226f667d14608487df744f375db87127f8'
$PatchSha256 = '80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84'
$PatchBytes = 1793
$Version = 'nemo-speech-v0.1.0-diagnotes-lid.2'
$ExpectedVcpkgCommit = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$CudaInstallerUrl = 'https://developer.download.nvidia.com/compute/cuda/12.8.0/network_installers/cuda_12.8.0_windows_network.exe'
$CudaInstallerSha256 = '89E7C44B526B6E30EC5089F221E918090D11F1D5B33C48FBFE08C6AC13F8A95C'
$CudaInstallerMd5 = '1D7E1CF4047F2B8D9A8096E18EBEA1C7'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PatchPath = Join-Path $RepoRoot 'patches\realtime-language-v1.patch'
$WorkRoot = Join-Path $env:RUNNER_TEMP "diagnotes-runtime-$Backend"
$SourceRoot = Join-Path $WorkRoot 'source'
$BuildRoot = Join-Path $WorkRoot 'build'
$InstallRoot = Join-Path $WorkRoot 'install'
$PackageRoot = Join-Path $WorkRoot 'package'
$ArtifactsRoot = Join-Path $RepoRoot 'artifacts'
$EvidenceRoot = Join-Path $ArtifactsRoot "evidence-$Backend"

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE" }
}

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

New-Item -ItemType Directory -Force -Path $WorkRoot, $ArtifactsRoot, $EvidenceRoot | Out-Null
if ($Backend -eq 'cuda') {
    $sanitizerEvidenceRoot = Join-Path $ArtifactsRoot 'sanitizer-preflight'
    $sanitizerEvidencePath = Join-Path $sanitizerEvidenceRoot 'sanitizer-preflight.json'
    $sanitizerTestPath = Join-Path $RepoRoot 'scripts\Test-BuildRuntimeHelpers.ps1'
    New-Item -ItemType Directory -Force -Path $sanitizerEvidenceRoot | Out-Null
    $sanitizerTestArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$sanitizerTestPath,'-BuildScriptPath',$PSCommandPath,'-EvidencePath',$sanitizerEvidencePath)
    Invoke-Checked -FilePath pwsh -Arguments $sanitizerTestArguments
}
Invoke-Checked git clone --filter=blob:none https://github.com/NVIDIA/NeMo-Speech.cpp.git $SourceRoot
Invoke-Checked git -C $SourceRoot checkout --detach $SourceCommit
if ((git -C $SourceRoot rev-parse HEAD).Trim() -ne $SourceCommit) { throw 'Detached source pin mismatch.' }
Invoke-Checked git -C $SourceRoot submodule update --init ggml llama.cpp third_party/cpp-httplib
Invoke-Checked git -C $SourceRoot apply --check $PatchPath
Invoke-Checked git -C $SourceRoot apply $PatchPath
$changed = @(git -C $SourceRoot diff --name-only)
if ($changed.Count -ne 1 -or $changed[0] -ne 'server/http/http_server.cpp') {
    throw "Functional diff escaped allowlist: $($changed -join ', ')"
}
$hunks = @((git -C $SourceRoot diff --unified=0 | Select-String '^@@').Line)
if ($hunks.Count -ne 2) { throw "Expected exactly two functional hunks, got $($hunks.Count)" }

if ($Backend -eq 'cuda') {
    $cudaRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$CudaVersion"
    if (Test-Path -LiteralPath "$cudaRoot\bin\nvcc.exe") {
        throw 'Unexpected pre-existing CUDA 12.8 toolkit; the authorized causal installer repetition cannot be skipped.'
    }

    $installer = Join-Path $WorkRoot 'cuda_12.8.0_windows_network.exe'
    Invoke-WebRequest -Uri $CudaInstallerUrl -OutFile $installer
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
            $variants = @($root, $root.Replace('\', '/'), $root.Replace('/', '\')) | Sort-Object -Unique
            foreach ($variant in $variants) {
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
        $installerProcess = Start-Process -FilePath $installer -ArgumentList $installerArguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $installerStdout -RedirectStandardError $installerStderr
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
            if ($cudaVersionRaw -notmatch '12\.8') { throw 'CUDA native version metadata does not identify 12.8.' }
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
            $nvccVersionIs128 = $nvccVersion -match 'release 12\.8'
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
}

$upstreamBuild = Join-Path $SourceRoot 'scripts\windows\build.ps1'
$buildArgs = @(
    '-Backend', $Backend,
    '-Profile', 'asr',
    '-Http',
    '-Config', $Configuration,
    '-BuildDir', $BuildRoot,
    '-VcpkgTriplet', 'x64-windows-static',
    '-Architecture', 'x64',
    '-Compiler', 'msvc',
    '-Jobs', '4'
)
if ($Backend -eq 'cuda') { $buildArgs += @('-CudaArch', $CudaArch, '-CublasShim') }
Invoke-Checked pwsh $upstreamBuild @buildArgs

# Reconfigure the upstream ASR preset to the contracted ASR+HTTP-only surface.
$profileArgs = @(
    '-S', $SourceRoot, '-B', $BuildRoot,
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
    '-DNEMO_SPEECH_BUILD_TOOLS=OFF',
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'
)
if ($Backend -eq 'cuda') {
    $profileArgs += @('-DGGML_CUDA=ON', '-DGGML_VULKAN=OFF', '-DNEMO_SPEECH_CUBLAS_SHIM=ON', "-DCMAKE_CUDA_ARCHITECTURES=$CudaArch")
} else {
    $profileArgs += @('-DGGML_CUDA=OFF', '-DGGML_VULKAN=OFF', '-DNEMO_SPEECH_GGML_PATCHED=OFF')
}
Invoke-Checked cmake @profileArgs
Invoke-Checked cmake --build $BuildRoot --parallel 4
Invoke-Checked cmake --install $BuildRoot --prefix $InstallRoot --config $Configuration

$cache = Get-Content -LiteralPath (Join-Path $BuildRoot 'CMakeCache.txt') -Raw
$requiredCache = @(
    'NEMO_SPEECH_BUILD_ASR:BOOL=ON', 'NEMO_SPEECH_BUILD_HTTP:BOOL=ON',
    'NEMO_SPEECH_BUILD_CLI:BOOL=ON', 'NEMO_SPEECH_BUILD_DIAR:BOOL=OFF',
    'NEMO_SPEECH_BUILD_TTS:BOOL=OFF', 'NEMO_SPEECH_BUILD_NMT:BOOL=OFF',
    'NEMO_SPEECH_BUILD_MIC_CAPTURE:BOOL=OFF'
)
foreach ($entry in $requiredCache) { if ($cache -notmatch [regex]::Escape($entry)) { throw "CMake cache lacks $entry" } }
if ($cache -match 'CMAKE_CUDA_ARCHITECTURES:[^=]*=(native|86)$') { throw 'CUDA architecture cache is incomplete or native.' }

$zipStem = if ($Backend -eq 'cpu') {
    "$Version-windows-x86_64-cpu"
} else {
    "$Version-windows-x86_64-cuda-sm75-sm80-sm86-sm89"
}
$BundleRoot = Join-Path $PackageRoot $zipStem
New-Item -ItemType Directory -Force -Path $BundleRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $InstallRoot 'bin') -Destination (Join-Path $BundleRoot 'bin') -Recurse
if (Test-Path -LiteralPath (Join-Path $InstallRoot 'share')) {
    Copy-Item -LiteralPath (Join-Path $InstallRoot 'share') -Destination (Join-Path $BundleRoot 'share') -Recurse
}
Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $BundleRoot 'LICENSE')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'NOTICE') -Destination (Join-Path $BundleRoot 'NOTICE')
Copy-Item -LiteralPath $PatchPath -Destination (Join-Path $BundleRoot 'realtime-language-v1.patch')

if ($Backend -eq 'cuda') {
    $cudaEula = Join-Path $env:CUDA_PATH 'EULA.txt'
    if (-not (Test-Path -LiteralPath $cudaEula)) { throw 'Pinned CUDA Toolkit EULA.txt is missing.' }
    $cudaLicenseDir = Join-Path $BundleRoot 'share\licenses\nvidia-cuda-toolkit'
    New-Item -ItemType Directory -Force -Path $cudaLicenseDir | Out-Null
    Copy-Item -LiteralPath $cudaEula -Destination (Join-Path $cudaLicenseDir 'EULA.txt')
}

$binNames = @(Get-ChildItem -LiteralPath (Join-Path $BundleRoot 'bin') -File | Select-Object -ExpandProperty Name)
$forbidden = @($binNames | Where-Object { $_ -match '(?i)diar|tts|nmt|translate|synth|mic|miniaudio' })
if ($forbidden.Count -gt 0) { throw "Forbidden profile output: $($forbidden -join ', ')" }
if ($binNames -notcontains 'nemo-speech.exe') { throw 'nemo-speech.exe missing from package.' }
if ($Backend -eq 'cuda' -and -not ($binNames -contains 'ggml-cuda.dll')) { throw 'ggml-cuda.dll missing from CUDA package.' }
if ($Backend -eq 'cpu' -and ($binNames -contains 'ggml-cuda.dll')) { throw 'CPU package contains ggml-cuda.dll.' }
if ($binNames -contains 'nvcuda.dll') { throw 'NVIDIA driver must not be redistributed.' }

$toolchain = [ordered]@{
    identity = $Version; backend = $Backend; source_commit = $SourceCommit
    patch_sha256 = $PatchSha256; patch_bytes = $PatchBytes
    cuda_architectures = if ($Backend -eq 'cuda') { @('75','80','86','89') } else { @() }
    runtime_capabilities = @('realtime-language-v1')
    github_image_os = $env:ImageOS; github_image_version = $env:ImageVersion
    cmake = (& cmake --version | Select-Object -First 1)
    ninja = (& ninja --version | Select-Object -First 1)
    msvc = (& cmd /c 'cl 2>&1' | Select-Object -First 1)
    windows_sdk = $env:WindowsSDKVersion
    vcpkg_commit = $ExpectedVcpkgCommit
    cuda = if ($Backend -eq 'cuda') { (& "$env:CUDA_PATH\bin\nvcc.exe" --version | Select-Object -Last 1) } else { $null }
    cuda_installer = if ($Backend -eq 'cuda') { [ordered]@{ url=$CudaInstallerUrl; sha256=$CudaInstallerSha256; md5=$CudaInstallerMd5; components=@('nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8'); driver=$false } } else { $null }
    cmake_profile = [ordered]@{ asr=$true; http=$true; cli=$true; diar=$false; tts=$false; nmt=$false; mic_capture=$false }
    authenticode = 'absent-by-contract'
}
$toolchain | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BundleRoot 'runtime-build.json') -Encoding utf8NoBOM
$cache | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'CMakeCache.txt') -Encoding utf8NoBOM
(git -C $SourceRoot diff --binary) | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'functional.diff') -Encoding utf8NoBOM
$toolchain | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'toolchain.json') -Encoding utf8NoBOM

$inventory = @()
Get-ChildItem -LiteralPath $BundleRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($BundleRoot, $_.FullName).Replace('\','/')
    $license = if ($relative -match '^bin/ggml') { 'MIT' }
        elseif ($relative -match '^bin/cublas64_') { 'Apache-2.0 AND LicenseRef-NVIDIA-CUDA-Toolkit' }
        elseif ($relative -match '^bin/') { 'Apache-2.0' }
        elseif ($relative -match 'cpp-httplib') { 'MIT' }
        elseif ($relative -match 'sentencepiece') { 'Apache-2.0' }
        elseif ($relative -match 'nvidia-cuda-toolkit') { 'LicenseRef-NVIDIA-CUDA-Toolkit' }
        else { 'Apache-2.0' }
    $inventory += [ordered]@{
        path=$relative; size=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        kind=if ($_.Extension -in '.exe','.dll') { 'PE' } else { 'data' }
        origin=if ($relative -match '^bin/ggml') { 'ggml' } elseif ($relative -match '^bin/cublas64_') { 'NeMo-Speech.cpp CUDA shim + CUDA static runtime' } else { 'NeMo-Speech.cpp distribution' }
        license=$license
    }
}
[ordered]@{ schema='diagnotes-runtime-inventory-v1'; files=$inventory } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $BundleRoot 'inventory.json') -Encoding utf8NoBOM

$spdxFiles = @($inventory | ForEach-Object {
    [ordered]@{ fileName=$_.path; checksums=@([ordered]@{algorithm='SHA256';checksumValue=$_.sha256}); licenseConcluded=$_.license; licenseInfoInFiles=@($_.license) }
})
[ordered]@{
    spdxVersion='SPDX-2.3'; dataLicense='CC0-1.0'; SPDXID='SPDXRef-DOCUMENT'
    name="$zipStem-sbom"; documentNamespace="https://github.com/dnl0037/diagnotes-nemotron-runtime/sbom/$zipStem/$env:GITHUB_RUN_ID"
    creationInfo=[ordered]@{ created=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); creators=@('Tool: Build-Runtime.ps1') }
    files=$spdxFiles
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $BundleRoot 'sbom.spdx.json') -Encoding utf8NoBOM

$zipPath = Join-Path $ArtifactsRoot "$zipStem.zip"
Compress-Archive -LiteralPath $BundleRoot -DestinationPath $zipPath -CompressionLevel Optimal
$extracted = Join-Path $WorkRoot 'zip-recheck'
Expand-Archive -LiteralPath $zipPath -DestinationPath $extracted
$recheckRoot = Join-Path $extracted $zipStem
if (-not (Test-Path -LiteralPath (Join-Path $recheckRoot 'bin\nemo-speech.exe'))) { throw 'Clean ZIP extraction lacks nemo-speech.exe.' }

$result = [ordered]@{ backend=$Backend; zip=$zipPath; size=(Get-Item $zipPath).Length; sha256=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash; files=$binNames }
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'build-result.json') -Encoding utf8NoBOM
$result | ConvertTo-Json -Depth 6
