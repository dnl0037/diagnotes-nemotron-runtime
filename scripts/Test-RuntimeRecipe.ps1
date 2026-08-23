#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot 'Build-Runtime.ps1'),
    [string]$GateTestPath = (Join-Path $PSScriptRoot 'Test-RuntimeGates.ps1'),
    [string]$CandidateTestPath = (Join-Path $PSScriptRoot 'Test-RuntimeCandidate.ps1'),
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows\build-release.yml'),
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildText = Get-Content -LiteralPath $BuildScriptPath -Raw
$gateText = Get-Content -LiteralPath $GateTestPath -Raw
$candidateText = Get-Content -LiteralPath $CandidateTestPath -Raw
$workflowText = Get-Content -LiteralPath $WorkflowPath -Raw
$workflowSha256 = (Get-FileHash -LiteralPath $WorkflowPath -Algorithm SHA256).Hash
$parseResults = @()
foreach ($path in @($BuildScriptPath,$GateTestPath,$CandidateTestPath,$PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $path), [ref]$tokens, [ref]$parseErrors)
    $parseResults += [pscustomobject]@{ path=(Split-Path -Leaf $path); errors=@($parseErrors).Count }
}
$classificationStart = $buildText.IndexOf('function Get-RuntimeFileClassification')
$classificationEnd = $buildText.IndexOf('function Test-RuntimeBinaryProfile')
$classificationText = if ($classificationStart -ge 0 -and $classificationEnd -gt $classificationStart) {
    $buildText.Substring($classificationStart, $classificationEnd - $classificationStart)
} else { '' }

$checks = @(
    [pscustomobject]@{ name='powershell-parses'; passed=(@($parseResults | Where-Object errors -ne 0).Count -eq 0) },
    [pscustomobject]@{ name='lid3-only'; passed=($buildText -match 'nemo-speech-v0\.1\.0-diagnotes-lid\.3' -and $buildText -notmatch 'lid\.2') },
    [pscustomobject]@{ name='static-md-pin'; passed=($buildText -match '\$VcpkgTriplet\s*=\s*''x64-windows-static-md''' -and $buildText -notmatch 'VcpkgTriplet\s*=\s*''x64-windows-static''') },
    [pscustomobject]@{ name='compile-db-exported'; passed=($buildText -match '-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON' -and $buildText -notmatch "'-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'" -and $buildText -match 'compile_commands\.json') },
    [pscustomobject]@{ name='exact-crt-token-contract'; passed=($buildText -match "'/MT','-MT','/MTd','-MTd','/MDd','-MDd'" -and $buildText -match "'-MD'" -and $buildText -match "'-c'") },
    [pscustomobject]@{ name='exact-runtime-profile-contract'; passed=($buildText -match 'nemo_speech_asr\.dll' -and $buildText -match 'nemo_speech_asr_c\.dll' -and $buildText -match 'msvcp140_atomic_wait\.dll' -and $buildText -match 'msvcp140_codecvt_ids\.dll') },
    [pscustomobject]@{ name='no-ninja-command-classifier'; passed=($buildText -notmatch 'ninja\s+-C\s+\$BuildRoot\s+-t\s+commands' -and $buildText -notmatch 'ninja-commands') },
    [pscustomobject]@{ name='structured-cache-contract'; passed=($buildText -match 'function ConvertFrom-CMakeCacheText' -and $buildText -match 'function Test-CMakeCacheContract') },
    [pscustomobject]@{ name='gate-dag-and-results'; passed=($buildText -match 'function Get-RuntimeGateManifest' -and $buildText -match 'gate-results\.json' -and $buildText -match "'PASS','FAIL'") },
    [pscustomobject]@{ name='privacy-covers-json-escaped-paths'; passed=($buildText -match 'function Test-EvidenceTextPrivacyContract' -and $buildText -match '\\\\\{1,2\}Users\\\\\{1,2\}' -and $gateText -match 'json-escaped-private-path-red' -and $gateText -match 'json-escaped-private-path-sanitized-green') },
    [pscustomobject]@{ name='privacy-rechecked-after-build-result'; passed=(
        $buildText -match 'function Get-EvidencePrivacyViolations' -and
        $buildText -match 'gate_results=\(Split-Path -Leaf \$gateResultsPath\)' -and
        $buildText -match '\$postBuildPrivacyViolations\s*=\s*@\(Get-EvidencePrivacyViolations' -and
        $buildText.IndexOf('$postBuildPrivacyViolations') -gt $buildText.IndexOf("'build-result.json'")
    ) },
    [pscustomobject]@{ name='payload-closure-integrated'; passed=($buildText -match 'function Test-PayloadMetadataClosure' -and $buildText -match "scope='payload-only'" -and $buildText -match "exclusions=@\('inventory\.json','sbom\.spdx\.json'\)" -and $buildText -match "id='payload-closure'; dependencies=@\('inventory','sbom'\)" -and $buildText -match "id='zip-extraction'; dependencies=@\('payload-closure'\)" -and $buildText.IndexOf('if (Test-GateObservationPassed payload-closure)') -ge 0 -and $buildText.IndexOf('if (Test-GateObservationPassed payload-closure)') -lt $buildText.IndexOf('Compress-Archive')) },
    [pscustomobject]@{ name='detached-metadata-contract'; passed=($buildText -match 'diagnotes-payload-metadata-evidence-v1' -and $buildText -match 'Join-Path \$EvidenceRoot ''payload-metadata\.json''' -and $buildText -match 'serialized metadata divergence') },
    [pscustomobject]@{ name='nvcc-forwarded-crt-only'; passed=($buildText -match 'if \(\$isNvcc\) \{ @\(\$forwarded\.ToArray\(\)\) \}' -and $buildText -match 'ambiguous CRT forwarding') },
    [pscustomobject]@{ name='redist-closure-exhaustive'; passed=($buildText -match 'function Test-MsvcRedistFileContract' -and $buildText -match 'function Test-MsvcRedistClosureContract' -and $buildText -match 'presentMsvc') },
    [pscustomobject]@{ name='cpu-rejects-cuda-dlls'; passed=($buildText -match 'CPU contains CUDA binary' -and $buildText -match 'cublasLt64_' -and $buildText -match 'cudart64_') },
    [pscustomobject]@{ name='attestation-exact-structure'; passed=($gateText -match 'validStatements' -and $gateText -match 'expectedSubjects\.Count -eq 1' -and $gateText -match 'expected subject cardinality mismatch') },
    [pscustomobject]@{ name='behavior-only-in-ast-harness'; passed=($gateText -match 'FunctionDefinitionAst' -and $buildText -notmatch 'function Test-CrtFixture' -and $gateText -notmatch 'function Test-CrtFixture') },
    [pscustomobject]@{ name='candidate-workflow-only'; passed=($workflowText -match 'candidate-\$\{\{ matrix\.backend \}\}' -and $workflowText -notmatch '(?m)^\s*name:\s*runtime-') },
    [pscustomobject]@{ name='workflow-preflight-before-build'; passed=($workflowText.IndexOf('Test-RuntimeGates.ps1') -ge 0 -and $workflowText.IndexOf('Test-RuntimeGates.ps1') -lt $workflowText.IndexOf('Build-Runtime.ps1')) }
    [pscustomobject]@{ name='local-mode-explicit-and-guarded'; passed=($buildText -match '\[switch\]\$Local' -and $buildText -match 'Local mode is forbidden when any GitHub Actions marker is present' -and $buildText -match 'Non-local mode requires a coherent GitHub Actions environment') }
    [pscustomobject]@{ name='local-root-and-tools-bounded'; passed=($buildText -match 'LOCALAPPDATA\\DiagNotes\\RuntimeBuild' -and $buildText -match 'Resolve-ValidatedLocalWorkRoot' -and $buildText -match 'Resolve-LocalBuildTools' -and $buildText -match 'if \(-not \(Test-Path -LiteralPath \$localRootContract\.root\)\)') }
    [pscustomobject]@{ name='local-cuda-supervised-180'; passed=($buildText -match 'WaitForExit\(180 \* 60 \* 1000\)' -and $buildText -match 'taskkill\.exe /PID \$cudaChild\.Id /T /F') }
    [pscustomobject]@{ name='zip-recheck-run-scoped'; passed=($buildText -match '\$extracted\s*=\s*Join-Path \(Split-Path -Parent \$PackageRoot\) ''zip-recheck''' -and $buildText -notmatch '\$extracted\s*=\s*Join-Path \$WorkRoot ''zip-recheck''') }
    [pscustomobject]@{ name='candidate-acceptance-model-and-privacy'; passed=(
        $candidateText -match 'function Test-FixedModelContract' -and
        $candidateText -match 'A5C435F294EEA8F88CE68DD27B8C3BFEA7F777CB2FBBA04FCD30EAA555F429AE' -and
        $candidateText -match 'function Test-PublicAcceptanceEvidenceContract' -and
        $candidateText -match 'evidence-escaped-path-red' -and
        $candidateText -match '\$recognized\s*=\s*\$null'
    ) }
    [pscustomobject]@{ name='candidate-acceptance-runtime-contract'; passed=(
        $candidateText -match 'function Test-ReadyAcceptanceContract' -and
        $candidateText -match 'runtime_capabilities' -and
        $candidateText -match 'realtime-language-v1' -and
        $candidateText -match 'function Invoke-RealtimeFixture' -and
        $candidateText -match 'conversation\.item\.input_audio_transcription\.completed' -and
        $candidateText -match 'function Test-CausalBackendContract' -and
        $candidateText -match 'compute capability\\s\+8\\\.6'
    ) }
    [pscustomobject]@{ name='redist-from-effective-cache'; passed=($buildText -match 'Resolve-MsvcRedistFromCacheContract' -and $buildText -match "source='CMakeCache\.txt'" -and $buildText -notmatch 'VCToolsRedistDir|vcvarsCommand') }
    [pscustomobject]@{ name='openmp-redist-exact'; passed=($buildText -match '\$Name -ieq ''vcomp140\.dll''' -and $buildText -match 'Microsoft\.VC143\.OpenMP\\vcomp140\.dll' -and $buildText -match 'Resolve-MsvcRedistSourcePath' -and $buildText -notmatch 'vcomp14\[0-9\]') }
    [pscustomobject]@{ name='redist-minimized-to-import-closure'; passed=($buildText -match 'function Remove-PreinstalledMsvcRedistributables' -and $buildText -match '\$preinstalledMsvcRemoved\s*=\s*@\(Remove-PreinstalledMsvcRedistributables' -and $buildText -match 'preinstalled_msvc_removed=\$preinstalledMsvcRemoved') }
    [pscustomobject]@{ name='local-cuda-reuse-consented'; passed=($buildText -match 'Test-LocalCudaReuseProof' -and $buildText -match 'diagnotes-local-cuda-install-proof-v1' -and $buildText -match 'Display\.Driver') }
    [pscustomobject]@{ name='cuda-license-exact-and-versioned'; passed=(
        $buildText -match '\$CudaLicenseSha256\s*=\s*''E2C71BABFD18A8E69542DD7E9CA018F9CAA438094001A58E6BC4D8C999BF0D07''' -and
        $buildText -match 'function Resolve-CudaToolkitLicensePath' -and
        $buildText -match "@\('LICENSE','EULA\.txt'\)" -and
        $buildText -match 'Pinned CUDA Toolkit license path is ambiguous' -and
        $buildText -match 'Copy-Item -LiteralPath \$cudaLicense\.path'
    ) }
    [pscustomobject]@{ name='cuda-runtime-pe-closure-exact'; passed=(
        $buildText -match 'function Resolve-CudaRuntimeDependencyPath' -and
        $buildText -match "@\('cudart64_12\.dll','cublas64_12\.dll','cublasLt64_12\.dll'\)" -and
        $buildText -match 'nvidia-cuda-runtime-app-local' -and
        $buildText -match 'App-local CUDA runtime dependency hash mismatch' -and
        $buildText -match 'Clean ZIP extraction lacks an app-local CUDA runtime dependency' -and
        $gateText -match 'copy-imported-runtime-green' -and $gateText -match 'zip-missing-runtime-red'
    ) }
    [pscustomobject]@{ name='dbghelp-system-dependency-exact'; passed=($buildText -match 'function New-WindowsSystemDllSet' -and $buildText -match "'DBGHELP\.dll'" -and $buildText -match '\$systemDlls\s*=\s*New-WindowsSystemDllSet' -and $buildText -match '\$systemDlls\.Contains\(\$dependency\)' -and $classificationText -notmatch '(?i)dbghelp') }
    [pscustomobject]@{ name='redist-classification-canonical-case-insensitive-closed'; passed=(
        $classificationText -match 'Test-CanonicalRuntimeRelativePath -Path \$RelativePath' -and
        $buildText -match '\$normalized\s*=\s*\$Name\.ToUpperInvariant\(\)' -and
        $buildText -match '\$normalized\s*=\s*\$Name\.ToUpperInvariant\(\)' -and
        $buildText -match "'MSVCP140_ATOMIC_WAIT\.DLL','MSVCP140_CODECVT_IDS\.DLL','VCOMP140\.DLL'" -and
        $classificationText -match "\^bin/\(\?<name>\[\^/\]\+\(\?i:\\\.dll\)\)\$" -and
        $classificationText -notmatch '\.Replace\('
    ) }
    [pscustomobject]@{ name='msvc-version-short-deterministic-string'; passed=(
        $buildText -match 'function ConvertTo-ShortMsvcVersionString' -and
        $buildText -match 'function Get-MsvcVersionText' -and
        $buildText -match 'ReadToEndAsync\(\)' -and $buildText -match 'WaitForExit\(10 \* 1000\)' -and
        $buildText -match '\$process\.Kill\(\$true\)' -and $buildText -match 'msvc=\$msvcVersionText' -and
        $buildText -notmatch 'msvc=\(& \$clPath 2>&1'
    ) }
    [pscustomobject]@{ name='installed-upstream-share-classified'; passed=(
        $classificationText -match 'share/doc/nemo-speech/\(\?:README\|CONTRIBUTING\)' -and
        $classificationText -match 'share/doc/nemo-speech/docs/' -and
        $classificationText -match 'share/nemo-speech/config/' -and
        $classificationText -match 'share/nemo-speech/model-index'
    ) }
    [pscustomobject]@{ name='cuda-architectures-cache-type-stable'; passed=(
        $buildText -match 'CMAKE_CUDA_ARCHITECTURES:STRING=\$RequestedCudaArch' -and
        $buildText -notmatch 'CMAKE_CUDA_ARCHITECTURES=\$RequestedCudaArch'
    ) }
    [pscustomobject]@{ name='cuda-reuse-exact-ggml-series'; passed=(
        $buildText -match 'function Test-GgmlPatchSeriesContract' -and
        $buildText -match 'function Get-ProcessEnvironmentVariableState' -and
        $buildText -match 'function Restore-ProcessEnvironmentVariableState' -and
        $buildText -match 'Remove-Item -LiteralPath "Env:\$name"' -and
        $gateText -match 'absent-restored-as-absence-green' -and
        $gateText -match 'explicit-empty-restored-green' -and
        $gateText -match 'exception-restores-prior-value-red-green' -and
        $gateText -match 'no-state-leak-to-next-invocation-green' -and
        $buildText -match "@\(' M ggml',' M server/http/http_server\.cpp'\)" -and
        $buildText -match 'current ggml tree is not the exact pinned patch series' -and
        $buildText -match 'expected_tree=\$ggmlPatchSeriesContract\.expected_tree' -and
        $buildText -match 'git -C \$SourceRoot diff --binary -- server/http/http_server\.cpp'
    ) }
    [pscustomobject]@{ name='workflow-fase-c-timeout-exact'; passed=(@([regex]::Matches($workflowText, '(?m)^\s*timeout-minutes:\s*120\s*$')).Count -eq 1 -and $workflowText -notmatch 'timeout-minutes:\s*55' -and $workflowText -notmatch '(?i)-Local(?:WorkRoot|Cuda)?\b') }
)

$passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
$evidence = [ordered]@{
    schema='diagnotes-runtime-recipe-preflight-v2'
    parsers=$parseResults
    contract_checks=$checks
    passed=$passed
}
$json = $evidence | ConvertTo-Json -Depth 8
if ($EvidencePath) {
    $parent = Split-Path -Parent $EvidencePath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllText($EvidencePath, $json, [Text.UTF8Encoding]::new($false))
}
$json
if (-not $passed) { throw 'Runtime recipe static preflight failed.' }
