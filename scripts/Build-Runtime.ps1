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

    # The installer wrapper is blocked on a named event until its process has
    # been assigned to a kill-on-close Job Object. This makes the 20-minute
    # limit cover the wrapper, bootstrapper, and ordinary descendants without
    # changing the pinned installer or its exact component allowlist.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DiagNotesWindowsJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
        public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returnedLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = 0x00002000;
        int size = Marshal.SizeOf(limits);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, 9, buffer, (uint)size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        } catch { CloseHandle(job); throw; }
        finally { Marshal.FreeHGlobal(buffer); }
        return job;
    }
    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static uint ActiveProcesses(IntPtr job) {
        int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            if (!QueryInformationJobObject(job, 1, buffer, (uint)size, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var value = (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(
                buffer, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
            return value.ActiveProcesses;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static void Terminate(IntPtr job) {
        if (!TerminateJobObject(job, 124))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@

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
        $content = if (Test-Path -LiteralPath $InputPath) {
            Get-Content -LiteralPath $InputPath -Raw -ErrorAction Stop
        } else { '' }
        foreach ($privateRoot in @($env:RUNNER_TEMP, $env:GITHUB_WORKSPACE, $env:USERPROFILE, $WorkRoot)) {
            if ($privateRoot) { $content = $content.Replace($privateRoot, '<private-path>') }
        }
        $content = $content -replace '(?i)(authorization|bearer|token|secret|password)\s*[:=]\s*\S+', '$1=<redacted>'
        $content = $content -replace '(https?://[^\s?]+)\?\S+', '$1?<redacted-query>'
        if (-not $content) { $content = '<empty>' }
        $content | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    }

    $coordinationId = [Guid]::NewGuid().ToString('N')
    $coordinationRoot = Join-Path $WorkRoot "cuda-installer-$coordinationId"
    New-Item -ItemType Directory -Force -Path $coordinationRoot | Out-Null
    $wrapperPath = Join-Path $coordinationRoot 'Invoke-CudaInstaller.ps1'
    $resultPath = Join-Path $coordinationRoot 'result.json'
    $wrapperStdout = Join-Path $coordinationRoot 'wrapper.stdout.log'
    $wrapperStderr = Join-Path $coordinationRoot 'wrapper.stderr.log'
    $installerStdout = Join-Path $coordinationRoot 'installer.stdout.log'
    $installerStderr = Join-Path $coordinationRoot 'installer.stderr.log'
    $eventName = "Local\DiagNotesCudaInstaller-$coordinationId"

    @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$result = [ordered]@{ status='coordinator_error'; started_utc=$null; ended_utc=$null; bootstrapper_exit_code=$null; wrapper_expected_exit_code=125; error_type=$null; error_message=$null }
try {
    $gate = [Threading.EventWaitHandle]::OpenExisting($env:DN_CUDA_EVENT)
    try {
        if (-not $gate.WaitOne(60000)) { throw 'Installer coordination event was not released.' }
    } finally { $gate.Dispose() }
    $result.started_utc = [DateTimeOffset]::UtcNow.ToString('O')
    $arguments = @('-s','-n','nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
    $process = Start-Process -FilePath $env:DN_CUDA_INSTALLER -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $env:DN_CUDA_INSTALLER_STDOUT -RedirectStandardError $env:DN_CUDA_INSTALLER_STDERR
    $result.ended_utc = [DateTimeOffset]::UtcNow.ToString('O')
    $result.bootstrapper_exit_code = $process.ExitCode
    $result.wrapper_expected_exit_code = if ($process.ExitCode -eq 0) { 0 } else { 1 }
    $result.status = if ($process.ExitCode -eq 0) { 'completed' } else { 'bootstrapper_failed' }
} catch {
    $result.ended_utc = [DateTimeOffset]::UtcNow.ToString('O')
    $result.error_type = $_.Exception.GetType().FullName
    $result.error_message = $_.Exception.Message
}
$temporary = "$($env:DN_CUDA_RESULT).tmp"
[IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporary -Destination $env:DN_CUDA_RESULT
exit $result.wrapper_expected_exit_code
'@ | Set-Content -LiteralPath $wrapperPath -Encoding utf8NoBOM

    $installerArguments = @('-s','-n','nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
    if (($installerArguments -join ' ') -match '(?i)Display\.Driver' -or $installerArguments.Count -ne 7) {
        throw 'CUDA installer argument allowlist changed or includes Display.Driver.'
    }

    $driverBeforePath = Join-Path $coordinationRoot 'drivers-before.txt'
    $driverAfterPath = Join-Path $coordinationRoot 'drivers-after.txt'
    (& pnputil.exe /enum-drivers 2>&1 | Out-String) | Set-Content -LiteralPath $driverBeforePath -Encoding utf8NoBOM
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inventory Windows driver packages before CUDA installation.' }
    $driverBeforeHash = (Get-FileHash -LiteralPath $driverBeforePath -Algorithm SHA256).Hash
    $nvidiaStateBefore = Get-NvidiaState
    $logSnapshotBefore = Get-InstallerLogSnapshot

    $env:DN_CUDA_EVENT = $eventName
    $env:DN_CUDA_INSTALLER = $installer
    $env:DN_CUDA_RESULT = $resultPath
    $env:DN_CUDA_INSTALLER_STDOUT = $installerStdout
    $env:DN_CUDA_INSTALLER_STDERR = $installerStderr
    $createdNew = $false
    $gate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName, [ref]$createdNew)
    if (-not $createdNew) { $gate.Dispose(); throw 'CUDA installer coordination event unexpectedly existed.' }
    $jobHandle = [IntPtr]::Zero
    $wrapper = $null
    $releasedAt = $null
    $observedAt = $null
    $timedOut = $false
    $coordinationFailure = $null
    try {
        $jobHandle = [DiagNotesWindowsJob]::CreateKillOnClose()
        $wrapper = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$wrapperPath) -PassThru -WindowStyle Hidden -RedirectStandardOutput $wrapperStdout -RedirectStandardError $wrapperStderr
        [DiagNotesWindowsJob]::Assign($jobHandle, $wrapper.Handle)
        if ([DiagNotesWindowsJob]::ActiveProcesses($jobHandle) -lt 1) { throw 'CUDA installer Job Object contains no wrapper process.' }
        $releasedAt = [DateTimeOffset]::UtcNow
        [void]$gate.Set()
        if (-not $wrapper.WaitForExit(20 * 60 * 1000)) {
            $timedOut = $true
            $observedAt = [DateTimeOffset]::UtcNow
            [DiagNotesWindowsJob]::Terminate($jobHandle)
            $drainDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
            while ([DiagNotesWindowsJob]::ActiveProcesses($jobHandle) -ne 0 -and [DateTimeOffset]::UtcNow -lt $drainDeadline) {
                Start-Sleep -Milliseconds 250
            }
            if ([DiagNotesWindowsJob]::ActiveProcesses($jobHandle) -ne 0) { throw 'CUDA installer Job Object did not drain after timeout.' }
            throw 'CUDA installer process tree exceeded the authorized 20-minute limit.'
        }
        $observedAt = [DateTimeOffset]::UtcNow
        if ([DiagNotesWindowsJob]::ActiveProcesses($jobHandle) -ne 0) { throw 'CUDA installer Job Object was not empty after wrapper completion.' }
    } catch {
        $coordinationFailure = $_
        if ($null -eq $observedAt) { $observedAt = [DateTimeOffset]::UtcNow }
    } finally {
        $gate.Dispose()
        if ($jobHandle -ne [IntPtr]::Zero) { [void][DiagNotesWindowsJob]::CloseHandle($jobHandle) }
    }

    Write-SanitizedInstallerLog -InputPath $wrapperStdout -OutputPath (Join-Path $EvidenceRoot 'cuda-installer-wrapper-stdout.log')
    Write-SanitizedInstallerLog -InputPath $wrapperStderr -OutputPath (Join-Path $EvidenceRoot 'cuda-installer-wrapper-stderr.log')
    Write-SanitizedInstallerLog -InputPath $installerStdout -OutputPath (Join-Path $EvidenceRoot 'cuda-installer-stdout.log')
    Write-SanitizedInstallerLog -InputPath $installerStderr -OutputPath (Join-Path $EvidenceRoot 'cuda-installer-stderr.log')

    if ($null -ne $coordinationFailure) {
        $failedCoordination = [ordered]@{
            schema='diagnotes-cuda-installer-v1'; status='coordination_failed'
            released_utc=if ($releasedAt) { $releasedAt.ToString('O') } else { $null }
            observed_utc=$observedAt.ToString('O'); timeout_seconds=1200; timed_out=$timedOut
            failure=$coordinationFailure.Exception.Message
        }
        $failedCoordination | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'cuda-installer-result.json') -Encoding utf8NoBOM
        $failedCoordination | ConvertTo-Json -Depth 5
        throw $coordinationFailure.Exception.Message
    }
    if ($timedOut -or -not (Test-Path -LiteralPath $resultPath)) { throw 'CUDA installer produced no complete coordination result.' }
    $installerResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($installerResult.status -notin @('completed','bootstrapper_failed')) {
        [ordered]@{
            schema='diagnotes-cuda-installer-v1'; status='wrapper_failed'
            released_utc=$releasedAt.ToString('O'); observed_utc=$observedAt.ToString('O')
            timeout_seconds=1200; timed_out=$false; wrapper_exit_code=$wrapper.ExitCode
            wrapper_error_type=$installerResult.error_type; wrapper_error_message=$installerResult.error_message
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'cuda-installer-result.json') -Encoding utf8NoBOM
        throw 'CUDA installer coordinator failed before obtaining a bootstrapper result.'
    }
    if ($wrapper.ExitCode -ne $installerResult.wrapper_expected_exit_code) { throw 'CUDA wrapper and atomic result exit codes disagree.' }
    $installerStarted = [DateTimeOffset]::Parse($installerResult.started_utc)
    $installerEnded = [DateTimeOffset]::Parse($installerResult.ended_utc)
    if ($installerStarted -lt $releasedAt -or $installerEnded -lt $installerStarted -or $installerEnded -gt $observedAt) {
        throw 'CUDA installer result timestamps fall outside the coordinated process window.'
    }

    (& pnputil.exe /enum-drivers 2>&1 | Out-String) | Set-Content -LiteralPath $driverAfterPath -Encoding utf8NoBOM
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inventory Windows driver packages after CUDA installation.' }
    $driverAfterHash = (Get-FileHash -LiteralPath $driverAfterPath -Algorithm SHA256).Hash
    $nvidiaStateAfter = Get-NvidiaState
    $logSnapshotAfter = Get-InstallerLogSnapshot
    $changedNativeLogs = @($logSnapshotAfter.Keys | Where-Object {
        -not $logSnapshotBefore.ContainsKey($_) -or $logSnapshotBefore[$_] -ne $logSnapshotAfter[$_]
    } | Sort-Object)
    $nativeLogEvidence = @()
    $nativeLogIndex = 0
    foreach ($nativeLog in $changedNativeLogs) {
        $nativeLogIndex++
        $sanitizedName = "cuda-installer-native-$nativeLogIndex.log"
        Write-SanitizedInstallerLog -InputPath $nativeLog -OutputPath (Join-Path $EvidenceRoot $sanitizedName)
        $nativeLogEvidence += [ordered]@{ evidence=$sanitizedName; size=(Get-Item -LiteralPath $nativeLog).Length; sha256=(Get-FileHash -LiteralPath $nativeLog -Algorithm SHA256).Hash }
    }

    $nvidiaStateBeforeJson = $nvidiaStateBefore | ConvertTo-Json -Depth 8 -Compress
    $nvidiaStateAfterJson = $nvidiaStateAfter | ConvertTo-Json -Depth 8 -Compress
    $lingeringInstallers = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)cuda.*(setup|install)|nvidia.*(setup|install)' })
    $installerEvidence = [ordered]@{
        schema='diagnotes-cuda-installer-v1'; installer_url=$CudaInstallerUrl
        installer_sha256=$installerSha; installer_md5=$installerMd5
        arguments=$installerArguments; display_driver_requested=$false
        released_utc=$releasedAt.ToString('O'); started_utc=$installerResult.started_utc
        ended_utc=$installerResult.ended_utc; observed_exit_utc=$observedAt.ToString('O')
        timeout_seconds=1200; timed_out=$timedOut
        bootstrapper_exit_code=$installerResult.bootstrapper_exit_code
        wrapper_exit_code=$wrapper.ExitCode
        driver_inventory_before_sha256=$driverBeforeHash
        driver_inventory_after_sha256=$driverAfterHash
        nvidia_service_task_state_unchanged=($nvidiaStateBeforeJson -ceq $nvidiaStateAfterJson)
        lingering_installer_processes=@($lingeringInstallers | Select-Object -ExpandProperty ProcessName)
        sanitized_native_logs=$nativeLogEvidence
    }
    $installerEvidencePath = Join-Path $EvidenceRoot 'cuda-installer-result.json'
    $installerEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $installerEvidencePath -Encoding utf8NoBOM
    $installerEvidence | ConvertTo-Json -Depth 8

    if ($installerResult.bootstrapper_exit_code -ne 0) { throw "Pinned CUDA installer failed with exit code $($installerResult.bootstrapper_exit_code)." }
    if ($driverBeforeHash -ne $driverAfterHash) { throw 'Windows driver package inventory changed during CUDA installation.' }
    if ($nvidiaStateBeforeJson -cne $nvidiaStateAfterJson) { throw 'NVIDIA service or scheduled-task inventory changed during CUDA installation.' }
    if ($lingeringInstallers.Count -ne 0) { throw 'A CUDA/NVIDIA installer process remained after the coordinated tree completed.' }

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
            [ordered]@{ path=$_.Replace('\','/'); size=(Get-Item -LiteralPath $path).Length; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
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

    if (-not (Test-Path -LiteralPath "$cudaRoot\bin\nvcc.exe")) {
        throw "Pinned minimal CUDA Toolkit install did not produce $cudaRoot\bin\nvcc.exe"
    }
    $env:CUDA_PATH = $cudaRoot
    $env:CUDA_PATH_V12_8 = $cudaRoot
    $env:Path = "$cudaRoot\bin;$env:Path"
    $nvccVersion = (& "$cudaRoot\bin\nvcc.exe" --version 2>&1 | Out-String)
    if ($nvccVersion -notmatch 'release 12\.8') { throw "Unexpected nvcc: $nvccVersion" }
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
