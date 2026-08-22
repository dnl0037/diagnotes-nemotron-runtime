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
    if (-not (Test-Path -LiteralPath "$cudaRoot\bin\nvcc.exe")) {
        throw "Pinned CUDA Toolkit $CudaVersion is not present at $cudaRoot"
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
