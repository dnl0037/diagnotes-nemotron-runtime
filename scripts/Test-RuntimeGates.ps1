#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot 'Build-Runtime.ps1'),
    [string]$CandidateTestPath = (Join-Path $PSScriptRoot 'Test-RuntimeCandidate.ps1'),
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows\build-release.yml'),
    [string]$EvidencePath,
    [ValidateSet('Preflight','FinalizeAttestation')]
    [string]$Mode = 'Preflight',
    [string]$GateResultsPath,
    [string]$ZipPath,
    [string]$VerificationPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimePathPrivacy.psm1') -Force

function Test-AttestationVerificationDocument {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    try { $documents = @($Json | ConvertFrom-Json -Depth 30 -NoEnumerate -ErrorAction Stop) }
    catch { return [pscustomobject]@{ passed=$false; created=$false; reason='invalid verification JSON'; matches=0 } }
    if ($documents.Count -eq 0 -or ($documents.Count -eq 1 -and $documents[0].Count -eq 0)) {
        return [pscustomobject]@{ passed=$false; created=$false; reason='no verified attestations'; matches=0 }
    }
    $expectedSubjects = @()
    $validStatements = 0
    $malformed = $false
    foreach ($document in $documents) {
        if ($null -eq $document -or $null -eq $document.PSObject.Properties['verificationResult'] -or
            $null -eq $document.verificationResult.PSObject.Properties['statement']) { $malformed = $true; continue }
        $statement = $document.verificationResult.statement
        if ([string]$statement.predicateType -cne 'https://slsa.dev/provenance/v1' -or $null -eq $statement.PSObject.Properties['subject']) { $malformed = $true; continue }
        $subjects = @($statement.subject)
        if ($subjects.Count -eq 0) { $malformed = $true; continue }
        $statementValid = $true
        foreach ($subject in $subjects) {
            if ($null -eq $subject -or $null -eq $subject.PSObject.Properties['name'] -or $null -eq $subject.PSObject.Properties['digest'] -or
                $null -eq $subject.digest.PSObject.Properties['sha256'] -or [string]$subject.name -eq '' -or
                [string]$subject.digest.sha256 -notmatch '^(?i:[0-9a-f]{64})$') { $statementValid = $false; break }
        }
        if (-not $statementValid) { $malformed = $true; continue }
        $validStatements++
        foreach ($subject in $subjects) {
            if ([string]$subject.name -ceq $ExpectedName) { $expectedSubjects += $subject }
        }
    }
    $created = $validStatements -gt 0 -and -not $malformed
    $passed = $created -and $expectedSubjects.Count -eq 1 -and [string]$expectedSubjects[0].digest.sha256 -ceq $ExpectedSha256.ToLowerInvariant()
    $reason = if (-not $created) { 'no structurally valid SLSA verification document' } elseif ($expectedSubjects.Count -ne 1) { 'expected subject cardinality mismatch' } elseif (-not $passed) { 'subject digest mismatch' } else { 'subject digest verified exactly once' }
    return [pscustomobject]@{ passed=$passed; created=$created; reason=$reason; matches=$expectedSubjects.Count }
}

if ($Mode -eq 'FinalizeAttestation') {
    foreach ($required in @($GateResultsPath,$ZipPath,$VerificationPath)) {
        if ([string]::IsNullOrWhiteSpace($required) -or -not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw 'Attestation finalization input is missing.'
        }
    }
    $payload = Get-Content -LiteralPath $GateResultsPath -Raw | ConvertFrom-Json -Depth 30
    $candidateGate = @($payload.gates | Where-Object id -eq 'candidate-bytes-ready')
    if ($candidateGate.Count -ne 1 -or $candidateGate[0].status -ne 'PASS') { throw 'Candidate bytes are not ready for attestation.' }
    $zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $verification = Test-AttestationVerificationDocument -Json ([IO.File]::ReadAllText($VerificationPath)) `
        -ExpectedName (Split-Path -Leaf $ZipPath) -ExpectedSha256 $zipHash
    foreach ($gate in @($payload.gates)) {
        switch ($gate.id) {
            'attestation-created' {
                $gate.status = if ($verification.created) { 'PASS' } else { 'FAIL' }
                $gate.reason = if ($verification.created) { 'gh attestation verify returned a signed SLSA provenance document' } else { $verification.reason }
            }
            'attestation-digest-verified' {
                $gate.status = if (-not $verification.created) { 'BLOCKED' } elseif ($verification.passed) { 'PASS' } else { 'FAIL' }
                $gate.reason = if (-not $verification.created) { 'attestation-created prerequisite failed' } else { $verification.reason }
            }
            'candidate-upload-eligible' {
                $gate.status = if ($verification.passed) { 'PASS' } else { 'BLOCKED' }
                $gate.reason = if ($verification.passed) { 'candidate bytes and attestation subject digest passed' } else { 'attestation digest prerequisite failed' }
            }
        }
    }
    $payload.stage = 'attested-candidate'
    $payload | Add-Member -NotePropertyName candidate_sha256 -NotePropertyValue $zipHash -Force
    $json = $payload | ConvertTo-Json -Depth 30
    $temporaryPath = "$GateResultsPath.tmp"
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $GateResultsPath -Force
    if (-not $verification.passed) { throw 'Attestation subject digest verification failed.' }
    $json
    exit 0
}

$caseResults = @()
$infrastructureFailure = $null

function Add-CaseResult {
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Passed)
    $script:caseResults += [pscustomobject]@{ group=$Group; name=$Name; passed=$Passed }
}

try {
    $resolvedBuild = (Resolve-Path -LiteralPath $BuildScriptPath).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($resolvedBuild, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw 'BUILD_SCRIPT_PARSE' }

    $functionNames = @(
        'Get-ProcessEnvironmentMap',
        'Restore-ProcessEnvironmentMap',
        'Test-GitHubActionsEnvironment',
        'Resolve-ValidatedLocalWorkRoot',
        'Resolve-LocalBuildTools',
        'Resolve-MsvcRedistFromCacheContract',
        'Get-CudaComponentFileMap',
        'Test-LocalCudaReuseProof',
        'Resolve-CudaToolkitLicensePath',
        'Resolve-CudaRuntimeDependencyPath',
        'Get-ProcessEnvironmentVariableState',
        'Restore-ProcessEnvironmentVariableState',
        'Test-GgmlPatchSeriesContract',
        'ConvertTo-SanitizedEvidenceText',
        'Test-EvidenceTextPrivacyContract',
        'Get-EvidencePrivacyViolations',
        'New-UpstreamBuildArguments',
        'Test-RuntimeIdentityContract',
        'New-ProfileArguments',
        'ConvertFrom-CMakeCacheText',
        'Test-CMakeCacheContract',
        'ConvertFrom-CMakeSetText',
        'ConvertFrom-ExactKeyValueText',
        'Test-CudaVersionJson',
        'Test-NvccVersionText',
        'ConvertTo-ShortMsvcVersionString',
        'Get-MsvcVersionText',
        'Test-MicrosoftSignerIdentity',
        'Test-MsvcRedistFileContract',
        'Test-IsAllowedMsvcRedistributableName',
        'Resolve-MsvcRedistSourcePath',
        'Remove-PreinstalledMsvcRedistributables',
        'ConvertFrom-DumpbinDependentsText',
        'Get-RuntimeFileClassification',
        'Test-RuntimeBinaryProfile',
        'Test-CanonicalRuntimeRelativePath',
        'Get-RuntimeTreeRecords',
        'ConvertTo-CanonicalRuntimeRecordMap',
        'Test-PayloadMetadataClosure',
        'Test-MsvcRedistClosureContract',
        'New-WindowsSystemDllSet',
        'Resolve-PeClosure',
        'ConvertFrom-WindowsCommandLine',
        'Test-CompileCommandsContract',
        'Test-NinjaPdbAltPathContract',
        'Get-RuntimeGateManifest',
        'Invoke-RuntimeGateGraph',
        'Set-GateObservation',
        'Write-GateResults'
    )
    $definitionTexts = @()
    foreach ($functionName in $functionNames) {
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true))
        if ($definitions.Count -ne 1) { throw "FUNCTION_DEFINITION_COUNT:$functionName" }
        $definitionTexts += $definitions[0].Extent.Text
    }
    . ([ScriptBlock]::Create(($definitionTexts -join "`n`n")))

    $identityGreen = [ordered]@{
        ObservedSourceCommit='4f9676226f667d14608487df744f375db87127f8'
        ObservedPatchSha256='80370907878F346B16AD27933B1CF9109C0C204198702D5307CD4C6434D63E84'
        ObservedPatchBytes=1793
        ObservedVersion='nemo-speech-v0.1.0-diagnotes-lid.4'
        ObservedTriplet='x64-windows-static-md'
        ObservedCudaArch='75;80;86;89'
        ObservedVcpkgCommit='9e593bb18ea69cc5095e012465dcd675a822ed0d'
    }
    Add-CaseResult -Group identity-mutation -Name green -Passed (Test-RuntimeIdentityContract @identityGreen).passed

    $WorkRoot = 'C:\Users\PrivacyFixture\RuntimeBuild'
    $jsonEscapedWorkRoot = $WorkRoot.Replace('\', '\\')
    $sanitizedRawPrivatePath = ConvertTo-SanitizedEvidenceText -Content "$WorkRoot\source\one.cpp"
    $sanitizedJsonPrivatePath = ConvertTo-SanitizedEvidenceText -Content ('{"directory":"' + $jsonEscapedWorkRoot + '\\source"}')
    Add-CaseResult -Group evidence-privacy -Name raw-private-path-sanitized-green -Passed (
        $sanitizedRawPrivatePath -ceq '<private-path>\source\one.cpp' -and
        (Test-EvidenceTextPrivacyContract -Content $sanitizedRawPrivatePath)
    )
    Add-CaseResult -Group evidence-privacy -Name json-escaped-private-path-sanitized-green -Passed (
        $sanitizedJsonPrivatePath -ceq '{"directory":"<private-path>\\source"}' -and
        (Test-EvidenceTextPrivacyContract -Content $sanitizedJsonPrivatePath)
    )
    foreach ($privacyRed in @(
        [pscustomobject]@{ name='raw-private-path-red'; text='C:\Users\fixture\one.log' },
        [pscustomobject]@{ name='json-escaped-private-path-red'; text='{"directory":"C:\\Users\\fixture\\source"}' },
        [pscustomobject]@{ name='json-escaped-case-insensitive-red'; text='{"directory":"c:\\uSeRs\\fixture\\source"}' }
    )) {
        Add-CaseResult -Group evidence-privacy -Name $privacyRed.name -Passed (-not (Test-EvidenceTextPrivacyContract -Content $privacyRed.text))
    }
    Add-CaseResult -Group evidence-privacy -Name users-neighbor-green -Passed (Test-EvidenceTextPrivacyContract -Content '{"directory":"C:\\UsersX\\fixture"}')
    $privacyDirectoryProbe = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-evidence-privacy-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $privacyDirectoryProbe | Out-Null
        $buildResultProbe = Join-Path $privacyDirectoryProbe 'build-result.json'
        [IO.File]::WriteAllText($buildResultProbe, '{"gate_results":"gate-results.json"}', [Text.UTF8Encoding]::new($false))
        Add-CaseResult -Group evidence-privacy -Name post-build-portable-result-green -Passed (@(Get-EvidencePrivacyViolations -Root $privacyDirectoryProbe).Count -eq 0)
        [IO.File]::WriteAllText($buildResultProbe, '{"gate_results":"C:\Users\fixture\gate-results.json"}', [Text.UTF8Encoding]::new($false))
        Add-CaseResult -Group evidence-privacy -Name post-build-raw-path-red -Passed ((@(Get-EvidencePrivacyViolations -Root $privacyDirectoryProbe) | ConvertTo-Json -Compress) -ceq (@('build-result.json') | ConvertTo-Json -Compress))
        [IO.File]::WriteAllText($buildResultProbe, '{"gate_results":"C:\\Users\\fixture\\gate-results.json"}', [Text.UTF8Encoding]::new($false))
        Add-CaseResult -Group evidence-privacy -Name post-build-escaped-path-red -Passed ((@(Get-EvidencePrivacyViolations -Root $privacyDirectoryProbe) | ConvertTo-Json -Compress) -ceq (@('build-result.json') | ConvertTo-Json -Compress))
    } finally {
        $resolvedPrivacyProbe = [IO.Path]::GetFullPath($privacyDirectoryProbe)
        $privacyProbePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-evidence-privacy-'
        if ($resolvedPrivacyProbe.StartsWith($privacyProbePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedPrivacyProbe) { Remove-Item -LiteralPath $resolvedPrivacyProbe -Recurse -Force }
        } else { throw 'Evidence privacy probe cleanup boundary failed.' }
    }
    foreach ($identityMutation in @(
        [pscustomobject]@{name='source';key='ObservedSourceCommit';value='0000000000000000000000000000000000000000'},
        [pscustomobject]@{name='patch-sha';key='ObservedPatchSha256';value=('0' * 64)},
        [pscustomobject]@{name='patch-bytes';key='ObservedPatchBytes';value=1792},
        [pscustomobject]@{name='identity';key='ObservedVersion';value='nemo-speech-v0.1.0-diagnotes-lid.2'},
        [pscustomobject]@{name='triplet';key='ObservedTriplet';value='x64-windows-static'},
        [pscustomobject]@{name='architecture';key='ObservedCudaArch';value='86'},
        [pscustomobject]@{name='vcpkg';key='ObservedVcpkgCommit';value=('f' * 40)}
    )) {
        $mutatedIdentity = [ordered]@{}
        foreach ($entry in $identityGreen.GetEnumerator()) { $mutatedIdentity[$entry.Key] = $entry.Value }
        $mutatedIdentity[$identityMutation.key] = $identityMutation.value
        Add-CaseResult -Group identity-mutation -Name $identityMutation.name -Passed (-not (Test-RuntimeIdentityContract @mutatedIdentity).passed)
    }

    $baseCacheLines = @(
        '// generated fixture',
        'NEMO_SPEECH_BUILD_ASR:BOOL=ON',
        'NEMO_SPEECH_BUILD_HTTP:BOOL=ON',
        'NEMO_SPEECH_BUILD_CLI:BOOL=ON',
        'NEMO_SPEECH_BUILD_DIAR:BOOL=OFF',
        'NEMO_SPEECH_BUILD_TTS:BOOL=OFF',
        'NEMO_SPEECH_BUILD_NMT:BOOL=OFF',
        'NEMO_SPEECH_BUILD_MIC_CAPTURE:BOOL=OFF',
        'VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md',
        'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON',
        'CMAKE_EXE_LINKER_FLAGS:STRING=/PDBALTPATH:%_PDB%',
        'CMAKE_SHARED_LINKER_FLAGS:STRING=/PDBALTPATH:%_PDB%',
        'CMAKE_MODULE_LINKER_FLAGS:STRING=/PDBALTPATH:%_PDB%',
        'CMAKE_TOOLCHAIN_FILE:FILEPATH=C:/vcpkg/scripts/buildsystems/vcpkg.cmake',
        'CMAKE_CXX_COMPILER:STRING=C:/VS/cl.exe',
        'MSVC_REDIST_DIR:PATH=C:/VS/VC/Redist/MSVC/14.44.35112',
        'CMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL',
        'CMAKE_CUDA_ARCHITECTURES:STRING=75;80;86;89'
    )
    foreach ($fixture in @(
        [pscustomobject]@{ name='lf'; text=($baseCacheLines -join "`n") + "`n" },
        [pscustomobject]@{ name='crlf'; text=($baseCacheLines -join "`r`n") + "`r`n" },
        [pscustomobject]@{ name='eof'; text=($baseCacheLines -join "`n") },
        [pscustomobject]@{ name='comments-order'; text=((@('# comment','', $baseCacheLines[4]) + $baseCacheLines[0..3] + $baseCacheLines[5..($baseCacheLines.Count - 1)]) -join "`n") },
        [pscustomobject]@{ name='compiler-filepath'; text=(($baseCacheLines -replace '^CMAKE_CXX_COMPILER:STRING=', 'CMAKE_CXX_COMPILER:FILEPATH=') -join "`n") }
    )) {
        $actual = Test-CMakeCacheContract -Text $fixture.text -RequestedBackend cuda -RequestedTriplet 'x64-windows-static-md' -RequestedCudaArch '75;80;86;89'
        Add-CaseResult -Group cache-positive -Name $fixture.name -Passed $actual.passed
    }

    $cacheMutations = [ordered]@{
        duplicate = $baseCacheLines + 'VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md'
        wrong_type = $baseCacheLines -replace '^VCPKG_TARGET_TRIPLET:STRING=', 'VCPKG_TARGET_TRIPLET:BOOL='
        wrong_value = $baseCacheLines -replace 'x64-windows-static-md', 'x64-windows-static'
        prefix_space = $baseCacheLines -replace '^VCPKG_TARGET_TRIPLET:', ' VCPKG_TARGET_TRIPLET:'
        suffix_space = $baseCacheLines -replace 'x64-windows-static-md$', 'x64-windows-static-md '
        native = $baseCacheLines -replace '75;80;86;89', 'native'
        incomplete_arch = $baseCacheLines -replace '75;80;86;89', '86'
        static_crt = $baseCacheLines -replace 'MultiThreadedDLL', 'MultiThreaded'
        debug_crt = $baseCacheLines -replace 'MultiThreadedDLL', 'MultiThreadedDebugDLL'
        export_off = $baseCacheLines -replace 'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON', 'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=OFF'
        compiler_wrong_type = $baseCacheLines -replace '^CMAKE_CXX_COMPILER:STRING=', 'CMAKE_CXX_COMPILER:BOOL='
        export_uninitialized = $baseCacheLines -replace 'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON', 'CMAKE_EXPORT_COMPILE_COMMANDS:UNINITIALIZED=ON'
        export_wrong_type = $baseCacheLines -replace 'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON', 'CMAKE_EXPORT_COMPILE_COMMANDS:STRING=ON'
        export_missing = @($baseCacheLines | Where-Object { $_ -cne 'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON' })
        export_duplicate = $baseCacheLines + 'CMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON'
        pdbalt_missing = @($baseCacheLines | Where-Object { $_ -notmatch '^CMAKE_SHARED_LINKER_FLAGS:' })
        pdbalt_absolute = $baseCacheLines -replace '^CMAKE_EXE_LINKER_FLAGS:STRING=.*$', 'CMAKE_EXE_LINKER_FLAGS:STRING=/PDB:C:/private/runtime.pdb'
        malformed = $baseCacheLines -replace '^CMAKE_TOOLCHAIN_FILE:', 'CMAKE_TOOLCHAIN_FILE :'
        bare_cr = @($baseCacheLines[0..4] + ("$($baseCacheLines[5])`r$($baseCacheLines[6])") + $baseCacheLines[7..($baseCacheLines.Count - 1)])
        redist_missing = @($baseCacheLines | Where-Object { $_ -notmatch '^MSVC_REDIST_DIR:' })
        redist_duplicate = $baseCacheLines + 'MSVC_REDIST_DIR:PATH=C:/VS/VC/Redist/MSVC/14.44.35112'
        redist_wrong_type = $baseCacheLines -replace '^MSVC_REDIST_DIR:PATH=', 'MSVC_REDIST_DIR:FILEPATH='
        redist_relative = $baseCacheLines -replace '^MSVC_REDIST_DIR:PATH=.*$', 'MSVC_REDIST_DIR:PATH=VC/Redist/MSVC/14.44.35112'
    }
    foreach ($mutation in $cacheMutations.GetEnumerator()) {
        $actual = Test-CMakeCacheContract -Text ($mutation.Value -join "`n") -RequestedBackend cuda -RequestedTriplet 'x64-windows-static-md' -RequestedCudaArch '75;80;86;89'
        Add-CaseResult -Group cache-negative -Name $mutation.Key -Passed (-not $actual.passed)
    }

    $compileFixtures = @(
        [pscustomobject]@{ name='cl-command'; expected=$true; inspectable=$true; json='[{"directory":"C:/b","command":"\"C:\\VS\\cl.exe\" /nologo /MD /c \"C:\\src\\one.cpp\"","file":"C:/src/one.cpp"}]' },
        [pscustomobject]@{ name='cl-arguments'; expected=$true; inspectable=$true; json='[{"arguments":["C:/VS/cl.exe","/MD","/c","one.cpp"],"file":"one.cpp"}]' },
        [pscustomobject]@{ name='cl-dash-tokens'; expected=$true; inspectable=$true; json='[{"arguments":["cl.exe","-MD","-c","one.cpp"]}]' },
        [pscustomobject]@{ name='nvcc-equals'; expected=$true; inspectable=$true; json='[{"arguments":["C:/CUDA/nvcc.exe","-Xcompiler=/MD","-c","one.cu"],"file":"one.cu"}]' },
        [pscustomobject]@{ name='nvcc-pair'; expected=$true; inspectable=$true; json='[{"arguments":["nvcc.exe","--compiler-options","/MD","-c","one.cu"],"file":"one.cu"}]' },
        [pscustomobject]@{ name='nvcc-dash-md'; expected=$true; inspectable=$true; json='[{"arguments":["nvcc.exe","-Xcompiler=-MD","-c","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-own-md-no-forwarding'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-own-md-with-forwarding'; expected=$true; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-Xcompiler=/MD","-c","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-duplicate'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-Xcompiler=/MD","--compiler-options=-MD","-c","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-incomplete'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-Xcompiler","-c","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-response'; expected=$false; inspectable=$false; json='[{"arguments":["nvcc.exe","-Xcompiler=@host.rsp","-c","one.cu"]}]' },
        [pscustomobject]@{ name='mt-slash'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MT","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='mt-dash'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","-MT","-c","one.cpp"]}]' },
        [pscustomobject]@{ name='mtd-slash'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MTd","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='mtd-dash'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","-MTd","-c","one.cpp"]}]' },
        [pscustomobject]@{ name='mdd-slash'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MDd","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='mdd-dash'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","-MDd","-c","one.cpp"]}]' },
        [pscustomobject]@{ name='nvcc-forward-mt-slash'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","-Xcompiler=/MT","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-mt-dash'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","-Xcompiler=-MT","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-mtd-slash'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","--compiler-options","/MTd","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-mtd-dash'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","--compiler-options","-MTd","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-mdd-slash'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","-Xcompiler=/MDd","one.cu"]}]' },
        [pscustomobject]@{ name='nvcc-forward-mdd-dash'; expected=$false; inspectable=$true; json='[{"arguments":["nvcc.exe","-MD","-c","-Xcompiler=-MDd","one.cu"]}]' },
        [pscustomobject]@{ name='md-substring'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MD-similar","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='compile-substring'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MD","/compile","one.cpp"]}]' },
        [pscustomobject]@{ name='missing-md'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='invalid-json'; expected=$false; inspectable=$false; json='[' },
        [pscustomobject]@{ name='zero'; expected=$false; inspectable=$false; json='[]' },
        [pscustomobject]@{ name='non-compiler'; expected=$false; inspectable=$true; json='[{"arguments":["notcl.exe","/MD","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='opaque-response'; expected=$false; inspectable=$false; json='[{"arguments":["cl.exe","@flags.rsp","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='ambiguous-representation'; expected=$false; inspectable=$true; json='[{"command":"cl.exe /MD /c one.cpp","arguments":["cl.exe","/MD","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='missing-compile-action'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MD","one.cpp"]}]' }
    )
    foreach ($fixture in $compileFixtures) {
        $actual = Test-CompileCommandsContract -Json $fixture.json
        Add-CaseResult -Group compile -Name $fixture.name -Passed (($actual.passed -eq $fixture.expected) -and ($actual.inspectable -eq $fixture.inspectable))
    }

    $ninjaPdbFixtures = @(
        [pscustomobject]@{ name='exe-shared-green-static-excluded'; expected=$true; text=@'
build libfixture.lib: CXX_STATIC_LIBRARY_LINKER__fixture_Release one.obj
  LINK_FLAGS = /machine:x64
build fixture.dll: CXX_SHARED_LIBRARY_LINKER__fixture_Release two.obj
  LINK_FLAGS = /machine:x64 /PDBALTPATH:%_PDB%
build fixture.exe: CXX_EXECUTABLE_LINKER__fixture_Release three.obj
  LINK_FLAGS = /machine:x64 /PDBALTPATH:%_PDB%
'@ },
        [pscustomobject]@{ name='exe-missing-red'; expected=$false; text=@'
build fixture.exe: CXX_EXECUTABLE_LINKER__fixture_Release one.obj
  LINK_FLAGS = /machine:x64
'@ },
        [pscustomobject]@{ name='only-static-red'; expected=$false; text=@'
build libfixture.lib: CXX_STATIC_LIBRARY_LINKER__fixture_Release one.obj
  LINK_FLAGS = /machine:x64
'@ }
    )
    foreach ($fixture in $ninjaPdbFixtures) {
        Add-CaseResult -Group pdbalt-ninja -Name $fixture.name -Passed ((Test-NinjaPdbAltPathContract -Text $fixture.text).passed -eq $fixture.expected)
    }

    $legacyCrtCases = @(
        [pscustomobject]@{name='coherent-md';cache=$true;json='[{"arguments":["cl.exe","/MD","/c","one.cpp"]}]';log='link complete';expected=$true},
        [pscustomobject]@{name='old-static-triplet';cache=$false;json='[{"arguments":["cl.exe","/MD","/c","one.cpp"]}]';log='link complete';expected=$false},
        [pscustomobject]@{name='mt-command';cache=$true;json='[{"arguments":["cl.exe","/MT","/c","one.cpp"]}]';log='link complete';expected=$false},
        [pscustomobject]@{name='mixed-command';cache=$true;json='[{"arguments":["cl.exe","/MD","/MT","/c","one.cpp"]}]';log='link complete';expected=$false},
        [pscustomobject]@{name='lnk2038';cache=$true;json='[{"arguments":["cl.exe","/MD","/c","one.cpp"]}]';log='LNK2038 mismatch';expected=$false},
        [pscustomobject]@{name='lnk2005';cache=$true;json='[{"arguments":["cl.exe","/MD","/c","one.cpp"]}]';log='LNK2005 duplicate';expected=$false},
        [pscustomobject]@{name='lnk1169';cache=$true;json='[{"arguments":["cl.exe","/MD","/c","one.cpp"]}]';log='LNK1169 fatal';expected=$false}
    )
    foreach ($fixture in $legacyCrtCases) {
        $compileActual = Test-CompileCommandsContract -Json $fixture.json
        $actual = $fixture.cache -and $compileActual.passed -and $fixture.log -notmatch 'LNK2038|LNK2005|LNK1169'
        Add-CaseResult -Group crt-legacy -Name $fixture.name -Passed ($actual -eq $fixture.expected)
    }

    $environmentNames = @('INCLUDE','LIB','LIBPATH')
    $originalEnvironment = [ordered]@{}
    $fixtureEnvironment = [ordered]@{}
    $environmentScript = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-environment-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $scriptLines = @()
        foreach ($name in $environmentNames) {
            $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            $fixtureEnvironment[$name] = 'diagnotes-' + $name.ToLowerInvariant() + '-' + [Guid]::NewGuid().ToString('N')
            $scriptLines += "`$env:$name = '$($fixtureEnvironment[$name])'"
        }
        [IO.File]::WriteAllText($environmentScript, ($scriptLines -join "`n"), [Text.UTF8Encoding]::new($false))
        & pwsh -NoLogo -NoProfile -NonInteractive -File $environmentScript
        foreach ($name in $environmentNames) {
            Add-CaseResult -Group environment-negative -Name "$name-child-isolated" -Passed ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq $originalEnvironment[$name])
        }
        & $environmentScript
        foreach ($name in $environmentNames) {
            Add-CaseResult -Group environment -Name "$name-in-process-preserved" -Passed ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq $fixtureEnvironment[$name])
        }
    } finally {
        foreach ($name in $environmentNames) {
            if ($null -eq $originalEnvironment[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
            }
            Add-CaseResult -Group restoration -Name $name -Passed ([Environment]::GetEnvironmentVariable($name, 'Process') -ceq $originalEnvironment[$name])
        }
        if (Test-Path -LiteralPath $environmentScript) { Remove-Item -LiteralPath $environmentScript -Force }
    }
    $fullEnvironmentBefore = Get-ProcessEnvironmentMap
    try {
        $env:DIAGNOTES_ENVIRONMENT_PROBE = [Guid]::NewGuid().ToString('N')
        $env:Path = "diagnotes-mutated;$env:Path"
        $env:CUDA_PATH = 'diagnotes-cuda-sentinel'
    } finally {
        Restore-ProcessEnvironmentMap -Snapshot $fullEnvironmentBefore
    }
    $fullEnvironmentAfter = Get-ProcessEnvironmentMap
    Add-CaseResult -Group environment-full -Name exact-map-restored -Passed (($fullEnvironmentAfter | ConvertTo-Json -Compress) -ceq ($fullEnvironmentBefore | ConvertTo-Json -Compress))

    $rootProbeContainer = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-local-root-' + [Guid]::NewGuid().ToString('N'))
    $rootProbeExternal = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-local-root-external-' + [Guid]::NewGuid().ToString('N'))
    try {
        $rootProbeBase = Join-Path $rootProbeContainer 'DiagNotes\RuntimeBuild'
        New-Item -ItemType Directory -Force -Path $rootProbeBase,$rootProbeExternal | Out-Null
        $validRoot = Join-Path $rootProbeBase 'valid-run'
        Add-CaseResult -Group local-root -Name strict-child-green -Passed ((Resolve-ValidatedLocalWorkRoot -RequestedRoot $validRoot -LocalAppDataRoot $rootProbeContainer).root -ceq [IO.Path]::GetFullPath($validRoot))
        foreach ($invalidRoot in @($rootProbeBase,(Join-Path $rootProbeContainer 'outside'),(Join-Path $rootProbeBase '..\escape'),'relative\run','\\server\share\run','\\?\C:\escape')) {
            $rejected = $false
            try { [void](Resolve-ValidatedLocalWorkRoot -RequestedRoot $invalidRoot -LocalAppDataRoot $rootProbeContainer) } catch { $rejected = $true }
            Add-CaseResult -Group local-root -Name ('reject-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($invalidRoot))).Substring(0,8)) -Passed $rejected
        }
        $junction = Join-Path $rootProbeBase 'junction'
        New-Item -ItemType Junction -Path $junction -Target $rootProbeExternal | Out-Null
        $junctionRejected = $false
        try { [void](Resolve-ValidatedLocalWorkRoot -RequestedRoot (Join-Path $junction 'run') -LocalAppDataRoot $rootProbeContainer) } catch { $junctionRejected = $true }
        Add-CaseResult -Group local-root -Name reparse-parent-red -Passed $junctionRejected
        Remove-Item -LiteralPath $junction -Force
        $externalBase = Join-Path $rootProbeExternal 'escaped-base'
        New-Item -ItemType Directory -Path $externalBase | Out-Null
        Remove-Item -LiteralPath $rootProbeBase -Force
        New-Item -ItemType Junction -Path $rootProbeBase -Target $externalBase | Out-Null
        $baseJunctionRejected = $false
        try { [void](Resolve-ValidatedLocalWorkRoot -RequestedRoot (Join-Path $rootProbeBase 'run') -LocalAppDataRoot $rootProbeContainer) } catch { $baseJunctionRejected = $true }
        Add-CaseResult -Group local-root -Name reparse-base-red -Passed $baseJunctionRejected
    } finally {
        foreach ($probe in @($rootProbeContainer,$rootProbeExternal)) {
            $resolvedProbe = [IO.Path]::GetFullPath($probe)
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if ($resolvedProbe.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedProbe).StartsWith('diagnotes-local-root-', [StringComparison]::Ordinal)) {
                if (Test-Path -LiteralPath $resolvedProbe) { Remove-Item -LiteralPath $resolvedProbe -Recurse -Force }
            } else { throw 'Local root probe cleanup boundary failed.' }
        }
    }

    $expectedSystemDllNames = @(
        'ADVAPI32.dll','BCRYPT.dll','BCRYPTPRIMITIVES.dll','CABINET.dll','CFGMGR32.dll','COMCTL32.dll','COMDLG32.dll',
        'CRYPT32.dll','DBGHELP.dll','DNSAPI.dll','GDI32.dll','IMM32.dll','IPHLPAPI.dll','KERNEL32.dll','MSWSOCK.dll',
        'NETAPI32.dll','NORMALIZ.dll','NTDLL.dll','OLE32.dll','OLEAUT32.dll','POWRPROF.dll','PSAPI.dll','RPCRT4.dll',
        'SECUR32.dll','SETUPAPI.dll','SHELL32.dll','SHLWAPI.dll','USER32.dll','USERENV.dll','UCRTBASE.dll','VERSION.dll',
        'WINHTTP.dll','WINMM.dll','WS2_32.dll','WTSAPI32.dll'
    )
    $expectedSystemDlls = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $expectedSystemDllNames) { [void]$expectedSystemDlls.Add($name) }
    $systemDlls = New-WindowsSystemDllSet
    Add-CaseResult -Group system-dll-boundary -Name exact-baseline-plus-dbghelp -Passed (
        $systemDlls.Count -eq 35 -and $systemDlls.SetEquals($expectedSystemDlls) -and
        $systemDlls.Comparer.Equals([StringComparer]::OrdinalIgnoreCase)
    )

    $peBoundaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-pe-dbghelp-' + [Guid]::NewGuid().ToString('N'))
    try {
        $Backend = 'cpu'
        function Get-PeDependencies {
            param([Parameter(Mandatory)][string]$Path)
            return @($script:PeDependencyFixture)
        }
        foreach ($allowCopy in @($true,$false)) {
            $modeName = if ($allowCopy) { 'copy' } else { 'recheck' }
            foreach ($fixture in @(
                [pscustomobject]@{name='dbghelp-green';dependency='DBGHELP.DLL';expected=$true},
                [pscustomobject]@{name='dbgcore-red';dependency='dbgcore.dll';expected=$false},
                [pscustomobject]@{name='dbghelp32-red';dependency='dbghelp32.dll';expected=$false}
            )) {
                $probeRoot = Join-Path $peBoundaryRoot ($modeName + '-' + $fixture.name)
                $probeBin = Join-Path $probeRoot 'bin'
                New-Item -ItemType Directory -Force -Path $probeBin | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $probeBin 'nemo_speech_asr.dll'), [byte[]](1,2,3,4))
                $before = @(Get-RuntimeTreeRecords -Root $probeRoot) | ConvertTo-Json -Depth 5 -Compress
                $script:PeDependencyFixture = $fixture.dependency
                $threw = $false
                $message = ''
                $result = $null
                try { $result = Resolve-PeClosure -Root $probeRoot -AllowMsvcCopy $allowCopy }
                catch { $threw = $true; $message = $_.Exception.Message }
                $after = @(Get-RuntimeTreeRecords -Root $probeRoot) | ConvertTo-Json -Depth 5 -Compress
                $passed = if ($fixture.expected) {
                    -not $threw -and @($result.edges).Count -eq 1 -and
                    [string]$result.edges[0].dependency -ceq 'DBGHELP.DLL' -and
                    [string]$result.edges[0].classification -ceq 'windows-system' -and
                    @($result.copied_msvc).Count -eq 0 -and $before -ceq $after
                } else {
                    $threw -and $message -ceq "Unresolved non-system PE dependency: $($fixture.dependency)" -and $before -ceq $after
                }
                Add-CaseResult -Group system-dll-boundary -Name ($modeName + '-' + $fixture.name) -Passed $passed
            }
        }
    } finally {
        Remove-Item Function:Get-PeDependencies -ErrorAction SilentlyContinue
        Remove-Variable PeDependencyFixture -Scope Script -ErrorAction SilentlyContinue
        $resolvedPeBoundary = [IO.Path]::GetFullPath($peBoundaryRoot)
        $peBoundaryPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-pe-dbghelp-'
        if ($resolvedPeBoundary.StartsWith($peBoundaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedPeBoundary) { Remove-Item -LiteralPath $resolvedPeBoundary -Recurse -Force }
        } else { throw 'PE DbgHelp probe cleanup boundary failed.' }
    }

    $repoRootForProbe = Split-Path -Parent $PSScriptRoot
    $repoStatusBefore = @(git -C $repoRootForProbe status --porcelain=v1 --untracked-files=all) -join "`n"
    $guardRoot = Join-Path $env:LOCALAPPDATA ('DiagNotes\RuntimeBuild\guard-' + [Guid]::NewGuid().ToString('N'))
    $nonGitHubEnvironment = Get-ProcessEnvironmentMap
    try {
        foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { [string]$_ -match '^(?i:GITHUB_|RUNNER_)' })) {
            [Environment]::SetEnvironmentVariable([string]$key, $null, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue
        }
        $noLocalOutput = (& pwsh -NoLogo -NoProfile -NonInteractive -File $resolvedBuild -Backend cpu 2>&1 | Out-String)
        $noLocalExit = $LASTEXITCODE
    } finally { Restore-ProcessEnvironmentMap -Snapshot $nonGitHubEnvironment }
    Add-CaseResult -Group entrypoint-guard -Name nonlocal-outside-github-red -Passed ($noLocalExit -ne 0 -and $noLocalOutput -match 'requires a coherent GitHub Actions environment')
    $guardEnvironment = Get-ProcessEnvironmentMap
    try {
        $env:GITHUB_ACTIONS='true'; $env:GITHUB_RUN_ID='1'; $env:GITHUB_RUN_ATTEMPT='1'; $env:GITHUB_WORKSPACE='C:\runner\work'; $env:GITHUB_SHA=('a' * 40); $env:RUNNER_TEMP='C:\runner\temp'
        $localGithubOutput = (& pwsh -NoLogo -NoProfile -NonInteractive -File $resolvedBuild -Backend cpu -Local -LocalWorkRoot $guardRoot 2>&1 | Out-String)
        $localGithubExit = $LASTEXITCODE
    } finally { Restore-ProcessEnvironmentMap -Snapshot $guardEnvironment }
    Add-CaseResult -Group entrypoint-guard -Name local-under-github-red -Passed ($localGithubExit -ne 0 -and $localGithubOutput -match 'Local mode is forbidden')
    $markerEnvironment = Get-ProcessEnvironmentMap
    try {
        $env:GITHUB_TOKEN = 'fixture-only'
        $localMarkerOutput = (& pwsh -NoLogo -NoProfile -NonInteractive -File $resolvedBuild -Backend cpu -Local -LocalWorkRoot $guardRoot 2>&1 | Out-String)
        $localMarkerExit = $LASTEXITCODE
    } finally { Restore-ProcessEnvironmentMap -Snapshot $markerEnvironment }
    Add-CaseResult -Group entrypoint-guard -Name local-under-any-github-marker-red -Passed ($localMarkerExit -ne 0 -and $localMarkerOutput -match 'Local mode is forbidden')
    Add-CaseResult -Group entrypoint-guard -Name no-root-created -Passed (-not (Test-Path -LiteralPath $guardRoot))
    $repoStatusAfter = @(git -C $repoRootForProbe status --porcelain=v1 --untracked-files=all) -join "`n"
    Add-CaseResult -Group entrypoint-guard -Name repo-untouched -Passed ($repoStatusAfter -ceq $repoStatusBefore)
    if ($env:GITHUB_ACTIONS -cne 'true') {
        $vsWhereProbe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $localToolsProbe = Resolve-LocalBuildTools -VsWherePath $vsWhereProbe
        Add-CaseResult -Group local-toolchain -Name build-tools-17-14 -Passed ($localToolsProbe.product_display_version -match '^17\.14\.' -and $localToolsProbe.toolset_version -ceq '14.44.35207')
        Add-CaseResult -Group local-toolchain -Name cmake-ninja-cl-dumpbin -Passed (@($localToolsProbe.cmake,$localToolsProbe.ninja,$localToolsProbe.cl,$localToolsProbe.dumpbin | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0)
        $actualMsvcVersion = Get-MsvcVersionText -ClPath $localToolsProbe.cl -ExpectedToolsetVersion $localToolsProbe.toolset_version
        Add-CaseResult -Group local-toolchain -Name msvc-version-short-string -Passed (
            $actualMsvcVersion.GetType() -eq [string] -and $actualMsvcVersion -match '^19\.44\.[0-9]{1,5}$' -and
            $actualMsvcVersion.Length -le 15 -and $actualMsvcVersion -notmatch "[`r`n]"
        )
    }

    $cpuArgs = New-UpstreamBuildArguments -RequestedBackend cpu -RequestedConfiguration Release -RequestedBuildRoot B -RequestedTriplet x64-windows-static-md -RequestedCudaArch '75;80;86;89'
    $cudaArgs = New-UpstreamBuildArguments -RequestedBackend cuda -RequestedConfiguration Release -RequestedBuildRoot B -RequestedTriplet x64-windows-static-md -RequestedCudaArch '75;80;86;89'
    $expectedCpu = [ordered]@{ Backend='cpu'; Profile='asr'; Http=$true; Config='Release'; BuildDir='B'; VcpkgTriplet='x64-windows-static-md'; Architecture='x64'; Compiler='msvc'; Jobs=4 }
    $expectedCuda = [ordered]@{ Backend='cuda'; Profile='asr'; Http=$true; Config='Release'; BuildDir='B'; VcpkgTriplet='x64-windows-static-md'; Architecture='x64'; Compiler='msvc'; Jobs=4; CudaArch='75;80;86;89'; CublasShim=$true }
    Add-CaseResult -Group splatting -Name 'cpu-9-of-9' -Passed (($cpuArgs.Count -eq 9) -and (($cpuArgs | ConvertTo-Json -Compress) -ceq ($expectedCpu | ConvertTo-Json -Compress)))
    Add-CaseResult -Group splatting -Name 'cuda-11-of-11' -Passed (($cudaArgs.Count -eq 11) -and (($cudaArgs | ConvertTo-Json -Compress) -ceq ($expectedCuda | ConvertTo-Json -Compress)))

    $cpuProfile = @(New-ProfileArguments -RequestedBackend cpu -RequestedSourceRoot S -RequestedBuildRoot B -RequestedCudaArch '75;80;86;89')
    $cudaProfile = @(New-ProfileArguments -RequestedBackend cuda -RequestedSourceRoot S -RequestedBuildRoot B -RequestedCudaArch '75;80;86;89')
    $baselineProfile = @(
        '-S','S','-B','B',
        '-DNEMO_SPEECH_BUILD_ASR=ON','-DNEMO_SPEECH_BUILD_HTTP=ON','-DNEMO_SPEECH_BUILD_CLI=ON',
        '-DNEMO_SPEECH_BUILD_DIAR=OFF','-DNEMO_SPEECH_BUILD_TTS=OFF','-DNEMO_SPEECH_BUILD_NMT=OFF',
        '-DNEMO_SPEECH_WITH_NMT=OFF','-DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF','-DNEMO_SPEECH_BUILD_GRPC=OFF',
        '-DNEMO_SPEECH_WITH_GRPC=OFF','-DNEMO_SPEECH_BUILD_TESTS=OFF','-DBUILD_TESTING=OFF',
        '-DNEMO_SPEECH_BUILD_EXAMPLES=OFF','-DNEMO_SPEECH_BUILD_TOOLS=OFF'
    )
    $pdbAltProfile = @('-DCMAKE_EXE_LINKER_FLAGS:STRING=/PDBALTPATH:%_PDB%','-DCMAKE_SHARED_LINKER_FLAGS:STRING=/PDBALTPATH:%_PDB%','-DCMAKE_MODULE_LINKER_FLAGS:STRING=/PDBALTPATH:%_PDB%')
    $expectedCpuProfile = @($baselineProfile[0..3] + '-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON' + $baselineProfile[4..($baselineProfile.Count - 1)] + $pdbAltProfile + @('-DGGML_CUDA=OFF','-DGGML_VULKAN=OFF','-DNEMO_SPEECH_GGML_PATCHED=OFF'))
    $expectedCudaProfile = @($baselineProfile[0..3] + '-DCMAKE_EXPORT_COMPILE_COMMANDS:BOOL=ON' + $baselineProfile[4..($baselineProfile.Count - 1)] + $pdbAltProfile + @('-DGGML_CUDA=ON','-DGGML_VULKAN=OFF','-DNEMO_SPEECH_CUBLAS_SHIM=ON','-DCMAKE_CUDA_ARCHITECTURES:STRING=75;80;86;89'))
    Add-CaseResult -Group semantic-diff -Name 'cpu-baseline-plus-export-only' -Passed (($cpuProfile | ConvertTo-Json -Compress) -ceq ($expectedCpuProfile | ConvertTo-Json -Compress))
    Add-CaseResult -Group semantic-diff -Name 'cuda-baseline-plus-export-only' -Passed (($cudaProfile | ConvertTo-Json -Compress) -ceq ($expectedCudaProfile | ConvertTo-Json -Compress))
    Add-CaseResult -Group semantic-diff -Name 'cuda-architectures-retyped-string' -Passed (
        $cudaProfile -ccontains '-DCMAKE_CUDA_ARCHITECTURES:STRING=75;80;86;89' -and
        $cudaProfile -cnotcontains '-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89'
    )

    $cudaLicenseProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-cuda-license-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $cudaLicenseProbeRoot | Out-Null
        $licenseFixtureBytes = [Text.Encoding]::UTF8.GetBytes("End User License Agreement`nfixture`n")
        $licenseFixtureHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($licenseFixtureBytes))
        $licensePath = Join-Path $cudaLicenseProbeRoot 'LICENSE'
        [IO.File]::WriteAllBytes($licensePath, $licenseFixtureBytes)
        $licenseContract = Resolve-CudaToolkitLicensePath -CudaRoot $cudaLicenseProbeRoot -ExpectedSha256 $licenseFixtureHash
        Add-CaseResult -Group cuda-license -Name 'license-name-green' -Passed ($licenseContract.name -ceq 'LICENSE' -and $licenseContract.sha256 -ceq $licenseFixtureHash)
        [IO.File]::WriteAllBytes($licensePath, [Text.Encoding]::UTF8.GetBytes("tampered`n"))
        $tamperedLicenseRejected = $false
        try { [void](Resolve-CudaToolkitLicensePath -CudaRoot $cudaLicenseProbeRoot -ExpectedSha256 $licenseFixtureHash) } catch { $tamperedLicenseRejected = $true }
        Add-CaseResult -Group cuda-license -Name 'tampered-red' -Passed $tamperedLicenseRejected
        Remove-Item -LiteralPath $licensePath -Force
        $missingLicenseRejected = $false
        try { [void](Resolve-CudaToolkitLicensePath -CudaRoot $cudaLicenseProbeRoot -ExpectedSha256 $licenseFixtureHash) } catch { $missingLicenseRejected = $true }
        Add-CaseResult -Group cuda-license -Name 'missing-red' -Passed $missingLicenseRejected
        $eulaPath = Join-Path $cudaLicenseProbeRoot 'EULA.txt'
        [IO.File]::WriteAllBytes($eulaPath, $licenseFixtureBytes)
        $eulaContract = Resolve-CudaToolkitLicensePath -CudaRoot $cudaLicenseProbeRoot -ExpectedSha256 $licenseFixtureHash
        Add-CaseResult -Group cuda-license -Name 'legacy-eula-name-green' -Passed ($eulaContract.name -ceq 'EULA.txt' -and $eulaContract.sha256 -ceq $licenseFixtureHash)
        [IO.File]::WriteAllBytes($licensePath, $licenseFixtureBytes)
        $ambiguousLicenseRejected = $false
        try { [void](Resolve-CudaToolkitLicensePath -CudaRoot $cudaLicenseProbeRoot -ExpectedSha256 $licenseFixtureHash) } catch { $ambiguousLicenseRejected = $true }
        Add-CaseResult -Group cuda-license -Name 'duplicate-path-red' -Passed $ambiguousLicenseRejected
    } finally {
        $resolvedCudaLicenseProbe = [IO.Path]::GetFullPath($cudaLicenseProbeRoot)
        $cudaLicenseProbePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-cuda-license-'
        if ($resolvedCudaLicenseProbe.StartsWith($cudaLicenseProbePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedCudaLicenseProbe) { Remove-Item -LiteralPath $resolvedCudaLicenseProbe -Recurse -Force }
        } else { throw 'CUDA license probe cleanup boundary failed.' }
    }

    $cudaClosureProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-cuda-closure-' + [Guid]::NewGuid().ToString('N'))
    try {
        $cudaFixtureRoot = Join-Path $cudaClosureProbeRoot 'toolkit'
        $cudaFixtureBin = Join-Path $cudaFixtureRoot 'bin'
        New-Item -ItemType Directory -Path $cudaFixtureBin | Out-Null
        $cudaFixtureSource = Join-Path $cudaFixtureBin 'cudart64_12.dll'
        [IO.File]::WriteAllBytes($cudaFixtureSource, [byte[]](1,2,3,4,5))
        Add-CaseResult -Group cuda-pe-closure -Name 'exact-source-green' -Passed ((Resolve-CudaRuntimeDependencyPath -Name 'CUDART64_12.DLL' -CudaRoot $cudaFixtureRoot) -ceq $cudaFixtureSource)
        foreach ($cudaNeighbor in @('cudart64_11.dll','cudart64_12d.dll','nvcuda.dll','cudart64_12.dll.bak')) {
            $neighborRejected = $false
            try { [void](Resolve-CudaRuntimeDependencyPath -Name $cudaNeighbor -CudaRoot $cudaFixtureRoot) } catch { $neighborRejected = $true }
            Add-CaseResult -Group cuda-pe-closure -Name ($cudaNeighbor + '-red') -Passed $neighborRejected
        }

        $Backend = 'cuda'
        function Get-PeDependencies {
            param([Parameter(Mandatory)][string]$Path)
            if ([IO.Path]::GetFileName($Path) -ceq 'nemo_speech_asr.dll') { return @($script:CudaPeDependencyFixture) }
            return @()
        }
        $cudaCopyRoot = Join-Path $cudaClosureProbeRoot 'copy'
        $cudaCopyBin = Join-Path $cudaCopyRoot 'bin'
        New-Item -ItemType Directory -Path $cudaCopyBin | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $cudaCopyBin 'nemo_speech_asr.dll'), [byte[]](9,8,7))
        $script:CudaPeDependencyFixture = 'cudart64_12.dll'
        $cudaCopyClosure = Resolve-PeClosure -Root $cudaCopyRoot -AllowMsvcCopy $true -CudaRoot $cudaFixtureRoot
        $copiedCudaPath = Join-Path $cudaCopyBin 'cudart64_12.dll'
        Add-CaseResult -Group cuda-pe-closure -Name 'copy-imported-runtime-green' -Passed (
            (Test-Path -LiteralPath $copiedCudaPath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $copiedCudaPath -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $cudaFixtureSource -Algorithm SHA256).Hash -and
            @($cudaCopyClosure.copied_cuda).Count -eq 1 -and
            [string]$cudaCopyClosure.edges[0].classification -ceq 'nvidia-cuda-runtime-app-local'
        )
        $cudaRecheckClosure = Resolve-PeClosure -Root $cudaCopyRoot -AllowMsvcCopy $false -CudaRoot $cudaFixtureRoot
        Add-CaseResult -Group cuda-pe-closure -Name 'zip-recheck-green' -Passed (@($cudaRecheckClosure.copied_cuda).Count -eq 0 -and [string]$cudaRecheckClosure.edges[0].classification -ceq 'app-local')

        $cudaMissingRoot = Join-Path $cudaClosureProbeRoot 'missing'
        $cudaMissingBin = Join-Path $cudaMissingRoot 'bin'
        New-Item -ItemType Directory -Path $cudaMissingBin | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $cudaMissingBin 'nemo_speech_asr.dll'), [byte[]](9,8,7))
        $missingCopyRejected = $false
        try { [void](Resolve-PeClosure -Root $cudaMissingRoot -AllowMsvcCopy $false -CudaRoot $cudaFixtureRoot) } catch { $missingCopyRejected = $_.Exception.Message -ceq 'Clean ZIP extraction lacks an app-local CUDA runtime dependency.' }
        Add-CaseResult -Group cuda-pe-closure -Name 'zip-missing-runtime-red' -Passed $missingCopyRejected
    } finally {
        Remove-Item Function:Get-PeDependencies -ErrorAction SilentlyContinue
        Remove-Variable CudaPeDependencyFixture -Scope Script -ErrorAction SilentlyContinue
        $resolvedCudaClosureProbe = [IO.Path]::GetFullPath($cudaClosureProbeRoot)
        $cudaClosureProbePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-cuda-closure-'
        if ($resolvedCudaClosureProbe.StartsWith($cudaClosureProbePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedCudaClosureProbe) { Remove-Item -LiteralPath $resolvedCudaClosureProbe -Recurse -Force }
        } else { throw 'CUDA closure probe cleanup boundary failed.' }
    }

    $ggmlSeriesProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-ggml-contract-' + [Guid]::NewGuid().ToString('N'))
    try {
        $ggmlSeriesRepo = Join-Path $ggmlSeriesProbeRoot 'ggml'
        $ggmlSeriesPatches = Join-Path $ggmlSeriesProbeRoot 'patches'
        New-Item -ItemType Directory -Path $ggmlSeriesRepo,$ggmlSeriesPatches | Out-Null
        & git -C $ggmlSeriesRepo init --quiet 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize ggml contract fixture.' }
        $ggmlFixtureFile = Join-Path $ggmlSeriesRepo 'fixture.txt'
        [IO.File]::WriteAllText($ggmlFixtureFile, "alpha`n", [Text.UTF8Encoding]::new($false))
        & git -C $ggmlSeriesRepo add -- fixture.txt 2>$null
        & git -C $ggmlSeriesRepo -c user.name=DiagNotesFixture -c user.email=fixture.invalid@example.invalid commit --quiet -m base 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit ggml contract fixture.' }
        $ggmlFixtureCommit = (& git -C $ggmlSeriesRepo rev-parse HEAD 2>$null | Out-String).Trim()
        [IO.File]::WriteAllText($ggmlFixtureFile, "alpha`nbeta`n", [Text.UTF8Encoding]::new($false))
        $ggmlFixturePatchText = (& git -C $ggmlSeriesRepo diff -- fixture.txt 2>$null | Out-String).Replace("`r", '')
        $ggmlFixturePatch = Join-Path $ggmlSeriesPatches '0001-fixture.patch'
        [IO.File]::WriteAllText($ggmlFixturePatch, $ggmlFixturePatchText, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($ggmlFixtureFile, "alpha`n", [Text.UTF8Encoding]::new($false))

        $cleanTreeContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
        Add-CaseResult -Group ggml-patch-series -Name 'clean-tree-with-missing-series-red' -Passed (-not $cleanTreeContract.passed)
        & git -C $ggmlSeriesRepo apply -- $ggmlFixturePatch 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to apply ggml contract fixture patch.' }
        $exactTreeContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
        Add-CaseResult -Group ggml-patch-series -Name 'exact-series-green' -Passed (
            $exactTreeContract.passed -and $exactTreeContract.patch_count -eq 1 -and
            $exactTreeContract.expected_tree -ceq $exactTreeContract.current_tree -and
            (@($exactTreeContract.changed_paths) | ConvertTo-Json -Compress) -ceq (@('fixture.txt') | ConvertTo-Json -Compress)
        )
        [IO.File]::WriteAllText((Join-Path $ggmlSeriesRepo 'unexpected.txt'), "unexpected`n", [Text.UTF8Encoding]::new($false))
        Add-CaseResult -Group ggml-patch-series -Name 'extra-path-red' -Passed (-not (Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1).passed)
        Remove-Item -LiteralPath (Join-Path $ggmlSeriesRepo 'unexpected.txt') -Force
        Add-CaseResult -Group ggml-patch-series -Name 'commit-mismatch-red' -Passed (-not (Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit ('f' * 40) -ExpectedPatchCount 1).passed)
        Add-CaseResult -Group ggml-patch-series -Name 'cardinality-red' -Passed (-not (Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 2).passed)
        $misnumberedDirectory = Join-Path $ggmlSeriesProbeRoot 'misnumbered'
        New-Item -ItemType Directory -Path $misnumberedDirectory | Out-Null
        [IO.File]::WriteAllText((Join-Path $misnumberedDirectory '0002-fixture.patch'), $ggmlFixturePatchText, [Text.UTF8Encoding]::new($false))
        Add-CaseResult -Group ggml-patch-series -Name 'sequence-red' -Passed (-not (Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $misnumberedDirectory -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1).passed)

        $originalGitIndexState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
        try {
            Remove-Item -LiteralPath Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
            $absentContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
            $absentState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
            $absentDiff = @(& git -C $ggmlSeriesRepo diff --name-only 2>$null)
            Add-CaseResult -Group git-index-restoration -Name 'absent-restored-as-absence-green' -Passed (
                $absentContract.passed -and -not $absentState.present -and
                (($absentDiff | ConvertTo-Json -Compress) -ceq (@('fixture.txt') | ConvertTo-Json -Compress))
            )

            Set-Item -LiteralPath Env:GIT_INDEX_FILE -Value ''
            $emptyContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
            $emptyState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
            $emptyDiff = @(& git -C $ggmlSeriesRepo diff --name-only 2>$null)
            Add-CaseResult -Group git-index-restoration -Name 'explicit-empty-restored-green' -Passed (
                $emptyContract.passed -and $emptyState.present -and $emptyState.value -ceq '' -and $emptyDiff.Count -eq 0
            )

            $priorIndex = Join-Path $ggmlSeriesProbeRoot 'prior.index'
            Set-Item -LiteralPath Env:GIT_INDEX_FILE -Value $priorIndex
            & git -C $ggmlSeriesRepo read-tree HEAD 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create prior git index fixture.' }
            $valueContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
            $valueState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
            $valueDiff = @(& git -C $ggmlSeriesRepo diff --name-only 2>$null)
            Add-CaseResult -Group git-index-restoration -Name 'prior-value-restored-green' -Passed (
                $valueContract.passed -and $valueState.present -and $valueState.value -ceq $priorIndex -and
                (($valueDiff | ConvertTo-Json -Compress) -ceq (@('fixture.txt') | ConvertTo-Json -Compress))
            )

            $invalidPatchDirectory = Join-Path $ggmlSeriesProbeRoot 'invalid-patch'
            New-Item -ItemType Directory -Path $invalidPatchDirectory | Out-Null
            [IO.File]::WriteAllText((Join-Path $invalidPatchDirectory '0001-invalid.patch'), "not a patch`n", [Text.UTF8Encoding]::new($false))
            Set-Item -LiteralPath Env:GIT_INDEX_FILE -Value $priorIndex
            $exceptionContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $invalidPatchDirectory -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
            $exceptionState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
            $exceptionDiff = @(& git -C $ggmlSeriesRepo diff --name-only 2>$null)
            Add-CaseResult -Group git-index-restoration -Name 'exception-restores-prior-value-red-green' -Passed (
                -not $exceptionContract.passed -and $exceptionState.present -and $exceptionState.value -ceq $priorIndex -and
                (($exceptionDiff | ConvertTo-Json -Compress) -ceq (@('fixture.txt') | ConvertTo-Json -Compress))
            )

            Remove-Item -LiteralPath Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
            $postExceptionContract = Test-GgmlPatchSeriesContract -GgmlRoot $ggmlSeriesRepo -PatchDirectory $ggmlSeriesPatches -ExpectedCommit $ggmlFixtureCommit -ExpectedPatchCount 1
            $postExceptionState = Get-ProcessEnvironmentVariableState -Name 'GIT_INDEX_FILE'
            $postExceptionDiff = @(& git -C $ggmlSeriesRepo diff --name-only 2>$null)
            Add-CaseResult -Group git-index-restoration -Name 'no-state-leak-to-next-invocation-green' -Passed (
                $postExceptionContract.passed -and -not $postExceptionState.present -and
                (($postExceptionDiff | ConvertTo-Json -Compress) -ceq (@('fixture.txt') | ConvertTo-Json -Compress))
            )
        } finally {
            Restore-ProcessEnvironmentVariableState -State $originalGitIndexState
        }
    } finally {
        $resolvedGgmlSeriesProbe = [IO.Path]::GetFullPath($ggmlSeriesProbeRoot)
        $ggmlSeriesProbePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-ggml-contract-'
        if ($resolvedGgmlSeriesProbe.StartsWith($ggmlSeriesProbePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedGgmlSeriesProbe) { Remove-Item -LiteralPath $resolvedGgmlSeriesProbe -Recurse -Force }
        } else { throw 'ggml contract probe cleanup boundary failed.' }
    }

    $toolchainProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-profile-toolchain-' + [Guid]::NewGuid().ToString('N'))
    try {
        $toolchainProbe = Join-Path $toolchainProbeRoot 'vcpkg\scripts\buildsystems\vcpkg.cmake'
        New-Item -ItemType Directory -Path (Split-Path -Parent $toolchainProbe) | Out-Null
        [IO.File]::WriteAllText($toolchainProbe, '# fixture', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $toolchainProbeRoot 'CMakeCache.txt'), "CMAKE_TOOLCHAIN_FILE:UNINITIALIZED=$toolchainProbe`n", [Text.UTF8Encoding]::new($false))
        $reassertedProfile = @(New-ProfileArguments -RequestedBackend cpu -RequestedSourceRoot S -RequestedBuildRoot $toolchainProbeRoot -RequestedCudaArch '75;80;86;89' -ReassertToolchainFromCache)
        Add-CaseResult -Group semantic-diff -Name 'reused-cache-toolchain-retyped-filepath' -Passed ($reassertedProfile -ccontains "-DCMAKE_TOOLCHAIN_FILE:FILEPATH=$toolchainProbe")
        $missingCacheRejected = $false
        try { [void](New-ProfileArguments -RequestedBackend cpu -RequestedSourceRoot S -RequestedBuildRoot (Join-Path $toolchainProbeRoot 'missing') -RequestedCudaArch '75;80;86;89' -ReassertToolchainFromCache) }
        catch { $missingCacheRejected = $_.Exception.Message -match 'did not materialize CMakeCache\.txt' }
        Add-CaseResult -Group semantic-diff -Name 'reused-cache-missing-red' -Passed $missingCacheRejected
    } finally {
        $resolvedToolchainProbe = [IO.Path]::GetFullPath($toolchainProbeRoot)
        $toolchainProbePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-profile-toolchain-'
        if ($resolvedToolchainProbe.StartsWith($toolchainProbePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedToolchainProbe) { Remove-Item -LiteralPath $resolvedToolchainProbe -Recurse -Force }
        } else { throw 'Profile toolchain probe cleanup boundary failed.' }
    }

    $manifest = @(Get-RuntimeGateManifest)
    $ids = @($manifest | ForEach-Object id)
    Add-CaseResult -Group dag -Name 'stable-unique-ids' -Passed (($ids.Count -eq 21) -and (@($ids | Sort-Object -Unique).Count -eq 21))
    $allPass = [ordered]@{}
    foreach ($id in $ids) { $allPass[$id] = [pscustomobject]@{ status='PASS'; reason='fixture green' } }
    $greenResults = @(Invoke-RuntimeGateGraph -Manifest $manifest -Observations $allPass)
    Add-CaseResult -Group dag -Name 'all-pass' -Passed (@($greenResults | Where-Object status -ne PASS).Count -eq 0)

    $failedCache = [ordered]@{}
    foreach ($entry in $allPass.GetEnumerator()) { $failedCache[$entry.Key] = $entry.Value }
    $failedCache['cache'] = [pscustomobject]@{ status='FAIL'; reason='mutated triplet' }
    $failedResults = @(Invoke-RuntimeGateGraph -Manifest $manifest -Observations $failedCache)
    Add-CaseResult -Group dag -Name 'fail-blocked-isolation' -Passed (
        ($failedResults | Where-Object id -eq cache).status -eq 'FAIL' -and
        ($failedResults | Where-Object id -eq vcpkg).status -eq 'BLOCKED' -and
        ($failedResults | Where-Object id -eq profile).status -eq 'PASS' -and
        ($failedResults | Where-Object id -eq candidate-bytes-ready).status -eq 'BLOCKED'
    )

    $opaqueObservations = [ordered]@{}
    foreach ($entry in $allPass.GetEnumerator()) { $opaqueObservations[$entry.Key] = $entry.Value }
    $opaqueObservations['compile-arguments-inspectable'] = [pscustomobject]@{ status='FAIL'; reason='OPAQUE_COMPILE_ARGUMENTS' }
    $opaqueResults = @(Invoke-RuntimeGateGraph -Manifest $manifest -Observations $opaqueObservations)
    Add-CaseResult -Group dag -Name 'opaque-is-fail-crt-blocked' -Passed (
        ($opaqueResults | Where-Object id -eq compile-arguments-inspectable).status -eq 'FAIL' -and
        ($opaqueResults | Where-Object id -eq crt).status -eq 'BLOCKED'
    )

    $unknownRejected = $false
    try {
        [void](Invoke-RuntimeGateGraph -Manifest @([pscustomobject]@{id='x';dependencies=@('missing')}) -Observations @{})
    } catch { $unknownRejected = $true }
    Add-CaseResult -Group dag -Name 'unknown-dependency-rejected' -Passed $unknownRejected

    $duplicateRejected = $false
    try {
        [void](Invoke-RuntimeGateGraph -Manifest @([pscustomobject]@{id='x';dependencies=@()},[pscustomobject]@{id='x';dependencies=@()}) -Observations @{})
    } catch { $duplicateRejected = $true }
    Add-CaseResult -Group dag -Name 'duplicate-id-rejected' -Passed $duplicateRejected

    $evidenceProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-gate-evidence-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $evidenceProbeRoot | Out-Null
        $EvidenceRoot = $evidenceProbeRoot
        $WorkRoot = Join-Path $evidenceProbeRoot 'private-root'
        $Backend = 'cpu'
        $SourceCommit = '4f9676226f667d14608487df744f375db87127f8'
        $RecipeCommit = '23845aa75667094b2a366b9fb98b6e7a7f4af592'
        $ExecutionMode = 'local'
        $gateManifest = @(Get-RuntimeGateManifest)
        $gateObservations = [ordered]@{}
        $gateResultsPath = Join-Path $EvidenceRoot 'gate-results.json'
        Set-GateObservation source-patch PASS 'fixture source'
        Set-GateObservation cache FAIL 'mutated triplet at C:\Users\private\cache.txt'
        Set-GateObservation compile-arguments-inspectable PASS 'independent compile collector continued'
        Set-GateObservation crt PASS 'independent CRT evaluator continued'
        Set-GateObservation profile PASS 'independent profile collector continued'
        Set-GateObservation privacy PASS 'fixture sanitized'
        $negativePayload = Write-GateResults
        $negativeDisk = Get-Content -LiteralPath $gateResultsPath -Raw | ConvertFrom-Json -Depth 20
        Add-CaseResult -Group evidence-order -Name 'negative-materialized-before-result' -Passed (Test-Path -LiteralPath $gateResultsPath -PathType Leaf)
        Add-CaseResult -Group evidence-order -Name 'fail-and-blocked-exact' -Passed (
            ($negativeDisk.gates | Where-Object id -eq cache).status -eq 'FAIL' -and
            ($negativeDisk.gates | Where-Object id -eq vcpkg).status -eq 'BLOCKED'
        )
        Add-CaseResult -Group evidence-order -Name 'independent-gates-continue' -Passed (
            ($negativeDisk.gates | Where-Object id -eq profile).status -eq 'PASS' -and
            ($negativeDisk.gates | Where-Object id -eq crt).status -eq 'PASS'
        )
        Add-CaseResult -Group evidence-order -Name 'private-path-sanitized' -Passed (-not ([IO.File]::ReadAllText($gateResultsPath).Contains('C:\Users\private', [StringComparison]::OrdinalIgnoreCase)) )
    } finally {
        if (Test-Path -LiteralPath $evidenceProbeRoot) {
            $resolvedProbe = [IO.Path]::GetFullPath($evidenceProbeRoot)
            $expectedPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-gate-evidence-'
            if ($resolvedProbe.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
            } else { throw 'Gate evidence probe path boundary failed.' }
        }
    }

    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes('payload')
    $payloadHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes))
    $payloadRecords = @([pscustomobject]@{ path='bin/payload.bin'; size=$payloadBytes.Length; sha256=$payloadHash })
    $inventoryFixture = [ordered]@{ schema='diagnotes-runtime-inventory-v2'; scope='payload-only'; exclusions=@('inventory.json','sbom.spdx.json'); files=@([ordered]@{ path='bin/payload.bin'; size=$payloadBytes.Length; sha256=$payloadHash; kind='data'; origin='fixture'; license='Apache-2.0' }) }
    $sbomFixture = [ordered]@{ spdxVersion='SPDX-2.3'; dataLicense='CC0-1.0'; files=@([ordered]@{ fileName='bin/payload.bin'; checksums=@([ordered]@{algorithm='SHA256';checksumValue=$payloadHash}) }) }
    $inventoryJsonFixture = $inventoryFixture | ConvertTo-Json -Depth 8 -Compress
    $sbomJsonFixture = $sbomFixture | ConvertTo-Json -Depth 8 -Compress
    $utf8Fixture = [Text.UTF8Encoding]::new($false)
    $inventoryFixtureBytes = $utf8Fixture.GetBytes($inventoryJsonFixture)
    $sbomFixtureBytes = $utf8Fixture.GetBytes($sbomJsonFixture)
    $inventoryFixtureHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inventoryFixtureBytes))
    $sbomFixtureHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sbomFixtureBytes))
    $metadataFixture = [ordered]@{ schema='diagnotes-payload-metadata-evidence-v1'; files=@(
        [ordered]@{name='inventory.json';size=$inventoryFixtureBytes.Length;sha256=$inventoryFixtureHash},
        [ordered]@{name='sbom.spdx.json';size=$sbomFixtureBytes.Length;sha256=$sbomFixtureHash}
    ) }
    $metadataJsonFixture = $metadataFixture | ConvertTo-Json -Depth 6 -Compress
    $actualRecords = @($payloadRecords + @(
        [pscustomobject]@{path='inventory.json';size=$inventoryFixtureBytes.Length;sha256=$inventoryFixtureHash},
        [pscustomobject]@{path='sbom.spdx.json';size=$sbomFixtureBytes.Length;sha256=$sbomFixtureHash}
    ))
    Add-CaseResult -Group payload-closure -Name green -Passed (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $actualRecords -InventoryJson $inventoryJsonFixture -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed
    Add-CaseResult -Group payload-closure -Name extra-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords @($actualRecords + [pscustomobject]@{path='extra.bin';size=1;sha256=('A'*64)}) -InventoryJson $inventoryJsonFixture -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    Add-CaseResult -Group payload-closure -Name missing-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords @($actualRecords | Where-Object path -ne 'bin/payload.bin') -InventoryJson $inventoryJsonFixture -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    Add-CaseResult -Group payload-closure -Name tamper-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords @($actualRecords | ForEach-Object { if ($_.path -eq 'bin/payload.bin') { [pscustomobject]@{path=$_.path;size=$_.size;sha256=('B'*64)} } else { $_ } }) -InventoryJson $inventoryJsonFixture -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    Add-CaseResult -Group payload-closure -Name case-collision-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords @($actualRecords + [pscustomobject]@{path='BIN/PAYLOAD.BIN';size=$payloadBytes.Length;sha256=$payloadHash}) -InventoryJson $inventoryJsonFixture -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    $traversalInventory = $inventoryFixture | ConvertTo-Json -Depth 8 -Compress
    $traversalInventory = $traversalInventory.Replace('bin/payload.bin','../payload.bin')
    Add-CaseResult -Group payload-closure -Name traversal-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $actualRecords -InventoryJson $traversalInventory -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    $separatorInventory = $inventoryFixtureJson = $inventoryJsonFixture.Replace('bin/payload.bin','bin\\payload.bin')
    Add-CaseResult -Group payload-closure -Name separator-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $actualRecords -InventoryJson $separatorInventory -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    $divergentSbom = $sbomJsonFixture.Replace($payloadHash, ('C'*64))
    Add-CaseResult -Group payload-closure -Name sbom-divergent-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $actualRecords -InventoryJson $inventoryJsonFixture -SbomJson $divergentSbom -MetadataEvidenceJson $metadataJsonFixture).passed)
    $divergentMetadata = $metadataJsonFixture.Replace($inventoryFixtureHash, ('D'*64))
    Add-CaseResult -Group payload-closure -Name metadata-divergent-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $actualRecords -InventoryJson $inventoryJsonFixture -SbomJson $sbomJsonFixture -MetadataEvidenceJson $divergentMetadata).passed)
    Add-CaseResult -Group payload-closure -Name malformed-inventory-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $payloadRecords -ActualRecords $actualRecords -InventoryJson '{' -SbomJson $sbomJsonFixture -MetadataEvidenceJson $metadataJsonFixture).passed)
    $payloadProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-payload-closure-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $payloadProbeRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $payloadProbeRoot 'payload.bin'), 'payload', [Text.UTF8Encoding]::new($false))
        $physicalPayload = @(Get-RuntimeTreeRecords -Root $payloadProbeRoot)
        $physicalInventoryJson = [ordered]@{ schema='diagnotes-runtime-inventory-v2'; scope='payload-only'; exclusions=@('inventory.json','sbom.spdx.json'); files=$physicalPayload } | ConvertTo-Json -Depth 8 -Compress
        $physicalSbomJson = [ordered]@{ spdxVersion='SPDX-2.3'; dataLicense='CC0-1.0'; files=@($physicalPayload | ForEach-Object { [ordered]@{fileName=$_.path;checksums=@([ordered]@{algorithm='SHA256';checksumValue=$_.sha256})} }) } | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText((Join-Path $payloadProbeRoot 'inventory.json'), $physicalInventoryJson, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $payloadProbeRoot 'sbom.spdx.json'), $physicalSbomJson, [Text.UTF8Encoding]::new($false))
        $physicalMetadata = [ordered]@{ schema='diagnotes-payload-metadata-evidence-v1'; files=@('inventory.json','sbom.spdx.json' | ForEach-Object { $item=Get-Item -LiteralPath (Join-Path $payloadProbeRoot $_); [ordered]@{name=$_;size=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash} }) } | ConvertTo-Json -Depth 6 -Compress
        $physicalActual = @(Get-RuntimeTreeRecords -Root $payloadProbeRoot)
        Add-CaseResult -Group payload-closure -Name physical-tree-green -Passed (Test-PayloadMetadataClosure -PayloadRecords $physicalPayload -ActualRecords $physicalActual -InventoryJson $physicalInventoryJson -SbomJson $physicalSbomJson -MetadataEvidenceJson $physicalMetadata).passed
        [IO.File]::WriteAllText((Join-Path $payloadProbeRoot 'extra.bin'), 'extra', [Text.UTF8Encoding]::new($false))
        Add-CaseResult -Group payload-closure -Name physical-extra-red -Passed (-not (Test-PayloadMetadataClosure -PayloadRecords $physicalPayload -ActualRecords @(Get-RuntimeTreeRecords -Root $payloadProbeRoot) -InventoryJson $physicalInventoryJson -SbomJson $physicalSbomJson -MetadataEvidenceJson $physicalMetadata).passed)
    } finally {
        $resolvedPayloadProbe = [IO.Path]::GetFullPath($payloadProbeRoot)
        $payloadProbePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-payload-closure-'
        if ($resolvedPayloadProbe.StartsWith($payloadProbePrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedPayloadProbe -Recurse -Force }
        else { throw 'Payload probe path boundary failed.' }
    }

    foreach ($gateId in @('source-patch','cache','compile-arguments-inspectable','crt','profile','legal','pe-closure','inventory','sbom','payload-closure','path-privacy-prepackage','zip-extraction','defender-tree','defender-zip','path-privacy','privacy','attestation-created','attestation-digest-verified')) {
        $mutated = [ordered]@{}
        foreach ($entry in $allPass.GetEnumerator()) { $mutated[$entry.Key] = $entry.Value }
        $mutated[$gateId] = [pscustomobject]@{ status='FAIL'; reason="mutated $gateId" }
        $mutationResults = @(Invoke-RuntimeGateGraph -Manifest $manifest -Observations $mutated)
        Add-CaseResult -Group gate-mutation -Name $gateId -Passed (
            ($mutationResults | Where-Object id -eq $gateId).status -eq 'FAIL' -and
            ($mutationResults | Where-Object id -eq candidate-upload-eligible).status -ne 'PASS'
        )
    }

    $tripletGreen = ConvertFrom-CMakeSetText -Text "# triplet`r`nset(VCPKG_LIBRARY_LINKAGE static)`r`nset(VCPKG_CRT_LINKAGE dynamic)`r`n"
    $tripletDuplicate = ConvertFrom-CMakeSetText -Text "set(VCPKG_CRT_LINKAGE dynamic)`nset(VCPKG_CRT_LINKAGE static)"
    Add-CaseResult -Group downstream-parsers -Name 'triplet-structural-green' -Passed ($tripletGreen.errors.Count -eq 0 -and $tripletGreen.entries['VCPKG_CRT_LINKAGE'] -ceq 'dynamic')
    Add-CaseResult -Group downstream-parsers -Name 'triplet-duplicate-red' -Passed ($tripletDuplicate.errors.Count -eq 1)

    foreach ($keyValueFixture in @(
        [pscustomobject]@{name='kv-lf';text="VCToolsRedistDir=C:\r`nVCToolsVersion=14.0`n";expected=$true},
        [pscustomobject]@{name='kv-crlf';text="VCToolsRedistDir=C:\r`r`nVCToolsVersion=14.0`r`n";expected=$true},
        [pscustomobject]@{name='kv-eof';text="VCToolsRedistDir=C:\r`nVCToolsVersion=14.0";expected=$true},
        [pscustomobject]@{name='kv-duplicate';text="VCToolsVersion=14.0`nVCToolsVersion=14.1";expected=$false},
        [pscustomobject]@{name='kv-malformed';text="VCToolsVersion =14.0";expected=$false}
    )) {
        $actual = ConvertFrom-ExactKeyValueText -Text $keyValueFixture.text
        Add-CaseResult -Group downstream-parsers -Name $keyValueFixture.name -Passed (($actual.errors.Count -eq 0) -eq $keyValueFixture.expected)
    }

    $cudaVersionGreen = Test-CudaVersionJson -Json '{"cuda":{"name":"CUDA SDK","version":"12.8.0"}}'
    $cudaVersionRed = Test-CudaVersionJson -Json '{"cuda":{"name":"CUDA SDK","version":"12.9.0"}}'
    Add-CaseResult -Group downstream-parsers -Name 'cuda-version-json-green' -Passed $cudaVersionGreen.passed
    Add-CaseResult -Group downstream-parsers -Name 'cuda-version-json-red' -Passed (-not $cudaVersionRed.passed)

    $CudaInstallerUrl = 'https://developer.download.nvidia.com/compute/cuda/12.8.0/network_installers/cuda_12.8.0_windows_network.exe'
    $CudaInstallerSha256 = '89E7C44B526B6E30EC5089F221E918090D11F1D5B33C48FBFE08C6AC13F8A95C'
    $CudaInstallerMd5 = '1D7E1CF4047F2B8D9A8096E18EBEA1C7'
    $cudaProofRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-cuda-proof-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $cudaProofRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $cudaProofRoot 'version.json'), '{"cuda":{"name":"CUDA SDK","version":"12.8.0"}}', [Text.UTF8Encoding]::new($false))
        $cudaProofFiles = @()
        foreach ($relative in @((Get-CudaComponentFileMap).Values | ForEach-Object { $_ } | ForEach-Object { $_ })) {
            $path = Join-Path $cudaProofRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, $relative, [Text.UTF8Encoding]::new($false))
            $cudaProofFiles += [ordered]@{path=$relative.Replace('\','/');size=(Get-Item $path).Length;sha256=(Get-FileHash $path -Algorithm SHA256).Hash}
        }
        $cudaProofPath = Join-Path $cudaProofRoot 'proof.json'
        $cudaProof = [ordered]@{
            schema='diagnotes-local-cuda-install-proof-v1'; installer_url=$CudaInstallerUrl; installer_sha256=$CudaInstallerSha256; installer_md5=$CudaInstallerMd5
            arguments=@('-s','-n','nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
            components=@('nvcc_12.8','cudart_12.8','cublas_12.8','cublas_dev_12.8','thrust_12.8')
            display_driver_requested=$false; driver_inventory_unchanged=$true; nvidia_service_task_state_unchanged=$true; lingering_installer_processes=@()
            version_json_sha256=(Get-FileHash (Join-Path $cudaProofRoot 'version.json') -Algorithm SHA256).Hash; files=$cudaProofFiles
        }
        $cudaProof | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cudaProofPath -Encoding utf8NoBOM
        Add-CaseResult -Group cuda-reuse -Name consented-proof-green -Passed (Test-LocalCudaReuseProof -CudaRoot $cudaProofRoot -ProofPath $cudaProofPath).passed
        Add-CaseResult -Group cuda-reuse -Name missing-proof-red -Passed (-not (Test-LocalCudaReuseProof -CudaRoot $cudaProofRoot -ProofPath (Join-Path $cudaProofRoot 'missing.json')).passed)
        $displayProof = [ordered]@{}; foreach ($entry in $cudaProof.GetEnumerator()) { $displayProof[$entry.Key]=$entry.Value }; $displayProof.display_driver_requested = $true
        $displayProof | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cudaProofPath -Encoding utf8NoBOM
        Add-CaseResult -Group cuda-reuse -Name display-driver-red -Passed (-not (Test-LocalCudaReuseProof -CudaRoot $cudaProofRoot -ProofPath $cudaProofPath).passed)
        $cudaProof | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cudaProofPath -Encoding utf8NoBOM
        [IO.File]::AppendAllText((Join-Path $cudaProofRoot 'bin\nvcc.profile'), 'tamper')
        Add-CaseResult -Group cuda-reuse -Name file-tamper-red -Passed (-not (Test-LocalCudaReuseProof -CudaRoot $cudaProofRoot -ProofPath $cudaProofPath).passed)
    } finally {
        $resolvedCudaProof = [IO.Path]::GetFullPath($cudaProofRoot)
        $cudaProofPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-cuda-proof-'
        if ($resolvedCudaProof.StartsWith($cudaProofPrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedCudaProof -Recurse -Force }
        else { throw 'CUDA proof cleanup boundary failed.' }
    }

    $nvccLine = 'Cuda compilation tools, release 12.8, V12.8.93'
    foreach ($nvccFixture in @(
        [pscustomobject]@{name='nvcc-lf';text="header`n$nvccLine`n";expected=$true},
        [pscustomobject]@{name='nvcc-crlf';text="header`r`n$nvccLine`r`n";expected=$true},
        [pscustomobject]@{name='nvcc-eof';text="header`n$nvccLine";expected=$true},
        [pscustomobject]@{name='nvcc-duplicate';text="$nvccLine`n$nvccLine";expected=$false},
        [pscustomobject]@{name='nvcc-wrong';text='Cuda compilation tools, release 12.9, V12.9.1';expected=$false}
    )) {
        $actual = Test-NvccVersionText -Text $nvccFixture.text
        Add-CaseResult -Group downstream-parsers -Name $nvccFixture.name -Passed ($actual.passed -eq $nvccFixture.expected)
    }

    Add-CaseResult -Group downstream-parsers -Name 'signer-microsoft-green' -Passed (Test-MicrosoftSignerIdentity -Status Valid -Subject 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US')
    Add-CaseResult -Group downstream-parsers -Name 'signer-substring-red' -Passed (-not (Test-MicrosoftSignerIdentity -Status Valid -Subject 'CN=Microsoft Evil, O=Contoso Corporation, C=US'))
    Add-CaseResult -Group downstream-parsers -Name 'signer-status-red' -Passed (-not (Test-MicrosoftSignerIdentity -Status HashMismatch -Subject 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'))
    Add-CaseResult -Group downstream-parsers -Name 'redist-unsigned-red' -Passed (-not (Test-MicrosoftSignerIdentity -Status NotSigned -Subject 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'))
    Add-CaseResult -Group downstream-parsers -Name 'redist-other-signer-red' -Passed (-not (Test-MicrosoftSignerIdentity -Status Valid -Subject 'CN=Microsoft Windows, O=Contoso Corporation, C=US'))
    $redistPathGreenEntries = (ConvertFrom-CMakeCacheText -Text "CMAKE_CXX_COMPILER:STRING=C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe`nMSVC_REDIST_DIR:PATH=C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC/14.44.35112").entries
    Add-CaseResult -Group redist-path -Name same-install-family-string-green -Passed (Resolve-MsvcRedistFromCacheContract -Entries $redistPathGreenEntries).passed
    $redistPathFileEntries = (ConvertFrom-CMakeCacheText -Text "CMAKE_CXX_COMPILER:FILEPATH=C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe`nMSVC_REDIST_DIR:PATH=C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC/14.44.35112").entries
    Add-CaseResult -Group redist-path -Name same-install-family-filepath-green -Passed (Resolve-MsvcRedistFromCacheContract -Entries $redistPathFileEntries).passed
    $redistWrongCompilerType = (ConvertFrom-CMakeCacheText -Text "CMAKE_CXX_COMPILER:BOOL=C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe`nMSVC_REDIST_DIR:PATH=C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC/14.44.35112").entries
    Add-CaseResult -Group redist-path -Name compiler-type-red -Passed (-not (Resolve-MsvcRedistFromCacheContract -Entries $redistWrongCompilerType).passed)
    $redistOtherInstall = (ConvertFrom-CMakeCacheText -Text "CMAKE_CXX_COMPILER:FILEPATH=C:/VS-A/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe`nMSVC_REDIST_DIR:PATH=C:/VS-B/VC/Redist/MSVC/14.44.35112").entries
    Add-CaseResult -Group redist-path -Name other-install-red -Passed (-not (Resolve-MsvcRedistFromCacheContract -Entries $redistOtherInstall).passed)
    $redistOtherFamily = (ConvertFrom-CMakeCacheText -Text "CMAKE_CXX_COMPILER:FILEPATH=C:/VS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe`nMSVC_REDIST_DIR:PATH=C:/VS/VC/Redist/MSVC/14.43.35112").entries
    Add-CaseResult -Group redist-path -Name other-family-red -Passed (-not (Resolve-MsvcRedistFromCacheContract -Entries $redistOtherFamily).passed)
    $redistCopiedTree = (ConvertFrom-CMakeCacheText -Text "CMAKE_CXX_COMPILER:FILEPATH=C:/VS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe`nMSVC_REDIST_DIR:PATH=C:/VS/copied/14.44.35112").entries
    Add-CaseResult -Group redist-path -Name copied-tree-red -Passed (-not (Resolve-MsvcRedistFromCacheContract -Entries $redistCopiedTree).passed)
    $redistHash = ('A' * 64)
    $microsoftSubject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'
    $redistFileGreen = @{ SourceSha256=$redistHash; BundleSha256=$redistHash; SourceSignatureStatus='Valid'; SourceSignerSubject=$microsoftSubject; BundleSignatureStatus='Valid'; BundleSignerSubject=$microsoftSubject }
    Add-CaseResult -Group redist-closure -Name file-green -Passed (Test-MsvcRedistFileContract @redistFileGreen).passed
    $redistTampered = @{} + $redistFileGreen; $redistTampered.BundleSha256 = ('B' * 64)
    Add-CaseResult -Group redist-closure -Name bytes-tampered-red -Passed (-not (Test-MsvcRedistFileContract @redistTampered).passed)
    $redistUnsigned = @{} + $redistFileGreen; $redistUnsigned.BundleSignatureStatus = 'NotSigned'
    Add-CaseResult -Group redist-closure -Name unsigned-red -Passed (-not (Test-MsvcRedistFileContract @redistUnsigned).passed)
    $redistOtherSigner = @{} + $redistFileGreen; $redistOtherSigner.BundleSignerSubject = 'CN=Contoso, O=Contoso Corporation, C=US'
    Add-CaseResult -Group redist-closure -Name other-signer-red -Passed (-not (Test-MsvcRedistFileContract @redistOtherSigner).passed)
    $redistMicrosoftSignerMismatch = @{} + $redistFileGreen; $redistMicrosoftSignerMismatch.BundleSignerSubject = 'CN=Microsoft Windows Publisher, O=Microsoft Corporation, C=US'
    Add-CaseResult -Group redist-closure -Name microsoft-signer-mismatch-red -Passed (-not (Test-MsvcRedistFileContract @redistMicrosoftSignerMismatch).passed)
    Add-CaseResult -Group redist-closure -Name set-green -Passed (Test-MsvcRedistClosureContract -PresentNames @('vcruntime140.dll') -ImportedNames @('VCRUNTIME140.dll')).passed
    Add-CaseResult -Group redist-closure -Name orphan-red -Passed (-not (Test-MsvcRedistClosureContract -PresentNames @('vcruntime140.dll','msvcp140_atomic_wait.dll') -ImportedNames @('vcruntime140.dll')).passed)
    Add-CaseResult -Group redist-closure -Name missing-import-red -Passed (-not (Test-MsvcRedistClosureContract -PresentNames @('vcruntime140.dll') -ImportedNames @('vcruntime140.dll','msvcp140_atomic_wait.dll')).passed)
    Add-CaseResult -Group redist-closure -Name duplicate-red -Passed (-not (Test-MsvcRedistClosureContract -PresentNames @('vcruntime140.dll','VCRUNTIME140.dll') -ImportedNames @('vcruntime140.dll')).passed)
    Add-CaseResult -Group redist-closure -Name vcomp-case-duplicate-red -Passed (-not (Test-MsvcRedistClosureContract -PresentNames @('vcomp140.dll','VCOMP140.DLL') -ImportedNames @('VCOMP140.DLL')).passed)
    $redistMinimizeRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-redist-minimize-' + [Guid]::NewGuid().ToString('N'))
    try {
        $redistMinimizeBin = Join-Path $redistMinimizeRoot 'bin'
        New-Item -ItemType Directory -Path $redistMinimizeBin | Out-Null
        foreach ($name in @('msvcp140.dll','vcomp140.dll','nemo-speech.exe')) {
            [IO.File]::WriteAllBytes((Join-Path $redistMinimizeBin $name), [byte[]](1))
        }
        [IO.File]::WriteAllBytes((Join-Path $redistMinimizeRoot 'vcruntime140.dll'), [byte[]](1))
        $removedRedist = @(Remove-PreinstalledMsvcRedistributables -Root $redistMinimizeRoot)
        Add-CaseResult -Group redist-closure -Name preinstalled-exact-set-removed -Passed ((@($removedRedist | Sort-Object) -join ',') -ceq 'msvcp140.dll,vcomp140.dll')
        Add-CaseResult -Group redist-closure -Name non-redist-bin-preserved -Passed (Test-Path -LiteralPath (Join-Path $redistMinimizeBin 'nemo-speech.exe') -PathType Leaf)
        Add-CaseResult -Group redist-closure -Name outside-bin-preserved -Passed (Test-Path -LiteralPath (Join-Path $redistMinimizeRoot 'vcruntime140.dll') -PathType Leaf)
    } finally {
        $resolvedRedistMinimize = [IO.Path]::GetFullPath($redistMinimizeRoot)
        $redistMinimizePrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-redist-minimize-'
        if ($resolvedRedistMinimize.StartsWith($redistMinimizePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedRedistMinimize) { Remove-Item -LiteralPath $resolvedRedistMinimize -Recurse -Force }
        } else { throw 'Redist minimization probe cleanup boundary failed.' }
    }

    $dumpbinGreen = "preamble`r`n  Image has the following dependencies:`r`n`r`n    KERNEL32.dll`r`n    VCRUNTIME140.dll`r`n    VCOMP140.DLL`r`n`r`n  Summary`r`n"
    $dumpbinParsed = ConvertFrom-DumpbinDependentsText -Text $dumpbinGreen
    $dumpbinUnknown = ConvertFrom-DumpbinDependentsText -Text "  Image has the following dependencies:`n`n    KERNEL32.dll`n    not a dll line`n"
    $dumpbinDuplicate = ConvertFrom-DumpbinDependentsText -Text "  Image has the following dependencies:`n`n    KERNEL32.dll`n    KERNEL32.dll`n"
    Add-CaseResult -Group downstream-parsers -Name 'dumpbin-green' -Passed ($dumpbinParsed.passed -and $dumpbinParsed.dependencies.Count -eq 3 -and $dumpbinParsed.dependencies[2] -ceq 'VCOMP140.DLL')
    Add-CaseResult -Group downstream-parsers -Name 'dumpbin-unknown-red' -Passed (-not $dumpbinUnknown.passed)
    Add-CaseResult -Group downstream-parsers -Name 'dumpbin-duplicate-red' -Passed (-not $dumpbinDuplicate.passed)

    Add-CaseResult -Group downstream-parsers -Name 'inventory-known-green' -Passed (Get-RuntimeFileClassification -RelativePath 'bin/nemo-speech.exe').passed
    Add-CaseResult -Group downstream-parsers -Name 'inventory-asr-green' -Passed (Get-RuntimeFileClassification -RelativePath 'bin/nemo_speech_asr.dll').passed
    Add-CaseResult -Group downstream-parsers -Name 'inventory-asr-c-green' -Passed (Get-RuntimeFileClassification -RelativePath 'bin/nemo_speech_asr_c.dll').passed
    Add-CaseResult -Group downstream-parsers -Name 'inventory-redist-atomic-green' -Passed (Get-RuntimeFileClassification -RelativePath 'bin/MSVCP140_ATOMIC_WAIT.DLL').passed
    Add-CaseResult -Group downstream-parsers -Name 'inventory-redist-codecvt-green' -Passed (Get-RuntimeFileClassification -RelativePath 'bin/MsVcP140_CoDeCvT_iDs.DlL').passed
    $redistClassificationExpected = [pscustomobject]@{ origin='Microsoft Visual C++ Redist from effective MSVC toolchain'; license='LicenseRef-Microsoft-Visual-Cpp-Runtime' }
    foreach ($vcompPath in @('bin/vcomp140.dll','bin/VCOMP140.DLL','bin/VcOmP140.DlL')) {
        $vcompClassification = Get-RuntimeFileClassification -RelativePath $vcompPath
        Add-CaseResult -Group downstream-parsers -Name ('inventory-redist-vcomp-' + $vcompPath.Substring(4) + '-green') -Passed (
            $vcompClassification.passed -and $vcompClassification.origin -ceq $redistClassificationExpected.origin -and
            $vcompClassification.license -ceq $redistClassificationExpected.license
        )
    }
    Add-CaseResult -Group redist-path -Name 'vcomp-openmp-source-green' -Passed ((Resolve-MsvcRedistSourcePath -Name 'VCOMP140.DLL' -RedistVersionRoot 'C:\VS\VC\Redist\MSVC\14.44.35112') -ceq 'C:\VS\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.OpenMP\vcomp140.dll')
    $vcompNeighborRejected = $false
    try { [void](Resolve-MsvcRedistSourcePath -Name 'vcomp141.dll' -RedistVersionRoot 'C:\VS\VC\Redist\MSVC\14.44.35112') } catch { $vcompNeighborRejected = $true }
    Add-CaseResult -Group redist-path -Name 'vcomp-neighbor-red' -Passed $vcompNeighborRejected
    Add-CaseResult -Group downstream-parsers -Name 'inventory-unknown-red' -Passed (-not (Get-RuntimeFileClassification -RelativePath 'bin/unknown-tool.exe').passed)
    Add-CaseResult -Group downstream-parsers -Name 'inventory-redist-similar-red' -Passed (-not (Get-RuntimeFileClassification -RelativePath 'bin/msvcp140_atomic_wait_extra.dll').passed)
    foreach ($upstreamSharePath in @(
        'share/doc/nemo-speech/README.md','share/doc/nemo-speech/CONTRIBUTING.md',
        'share/doc/nemo-speech/docs/asr/configuration.md','share/nemo-speech/config/asr.example.yaml',
        'share/nemo-speech/config/README.md','share/nemo-speech/model-index.json'
    )) {
        $upstreamShareClassification = Get-RuntimeFileClassification -RelativePath $upstreamSharePath
        Add-CaseResult -Group downstream-parsers -Name ('inventory-upstream-share-' + [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($upstreamSharePath)) + '-green') -Passed (
            $upstreamShareClassification.passed -and $upstreamShareClassification.origin -ceq 'NeMo-Speech.cpp distribution' -and
            $upstreamShareClassification.license -ceq 'Apache-2.0'
        )
    }
    foreach ($invalidUpstreamSharePath in @(
        'share/doc/nemo-speech/payload.exe','share/doc/nemo-speech/docs/../LICENSE',
        'share/nemo-speech/config/secret.yaml','share/nemo-speech/config/asr.example.yaml.bak',
        'share/nemo-speech/model-index.json.bak'
    )) {
        Add-CaseResult -Group downstream-parsers -Name ('inventory-upstream-share-' + [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($invalidUpstreamSharePath)) + '-red') -Passed (
            -not (Get-RuntimeFileClassification -RelativePath $invalidUpstreamSharePath).passed
        )
    }
    foreach ($invalidVcompPath in @(
        'BIN/VCOMP140.DLL','bin\VCOMP140.DLL','bin/sub/VCOMP140.DLL','bin//VCOMP140.DLL',
        'C:/bin/VCOMP140.DLL','bin/../VCOMP140.DLL','bin/VCOMP140.DLL.bak','bin/VCOMP141.DLL',
        'bin/VCOMP140_1.DLL','bin/VCOMP140d.DLL'
    )) {
        Add-CaseResult -Group downstream-parsers -Name ('inventory-vcomp-boundary-' + [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($invalidVcompPath)) + '-red') -Passed (
            -not (Get-RuntimeFileClassification -RelativePath $invalidVcompPath).passed
        )
    }

    $syntheticMsvcBanner = "Microsoft (R) C/C++ compiler version 19.44.35221 for x64`r`nCopyright (C) Microsoft Corporation."
    $shortMsvcVersion = ConvertTo-ShortMsvcVersionString -Text $syntheticMsvcBanner -ExitCode 0 -ExpectedToolsetVersion '14.44.35207'
    Add-CaseResult -Group msvc-version -Name synthetic-green -Passed ($shortMsvcVersion.GetType() -eq [string] -and $shortMsvcVersion -ceq '19.44.35221')
    $serializedMsvc = ([ordered]@{ msvc=$shortMsvcVersion } | ConvertTo-Json -Compress)
    Add-CaseResult -Group msvc-version -Name serialized-small-green -Passed (
        $serializedMsvc -ceq '{"msvc":"19.44.35221"}' -and $serializedMsvc.Length -lt 64 -and
        $serializedMsvc -notmatch 'ErrorRecord|InvocationInfo|Users\\|[`r`n]'
    )
    try { Get-Item -LiteralPath 'Z:\diagnotes-fixture-does-not-exist' -ErrorAction Stop } catch { $fixtureErrorRecord = $_ }
    $invalidMsvcInputs = @(
        [pscustomobject]@{ name='error-record-red'; value=[object]$fixtureErrorRecord; exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='invocation-info-red'; value=[object]$fixtureErrorRecord.InvocationInfo; exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='custom-object-red'; value=[object]([pscustomobject]@{ text=$syntheticMsvcBanner }); exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='array-red'; value=[object]@($syntheticMsvcBanner); exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='duplicate-version-red'; value=[object]($syntheticMsvcBanner + "`n19.44.35221"); exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='x86-red'; value=[object]'Microsoft compiler version 19.44.35221 for x86'; exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='minor-mismatch-red'; value=[object]'Microsoft compiler version 19.43.35221 for x64'; exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='nonzero-exit-red'; value=[object]$syntheticMsvcBanner; exit=2; toolset='14.44.35207' },
        [pscustomobject]@{ name='empty-red'; value=[object]''; exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='oversized-red'; value=[object]($syntheticMsvcBanner + ('x' * 4096)); exit=0; toolset='14.44.35207' },
        [pscustomobject]@{ name='private-path-red'; value=[object]($syntheticMsvcBanner + "`nC:\Users\fixture"); exit=0; toolset='14.44.35207' }
    )
    foreach ($invalidMsvcInput in $invalidMsvcInputs) {
        $msvcRejected = $false
        try {
            [void](ConvertTo-ShortMsvcVersionString -Text $invalidMsvcInput.value -ExitCode $invalidMsvcInput.exit -ExpectedToolsetVersion $invalidMsvcInput.toolset)
        } catch { $msvcRejected = $true }
        Add-CaseResult -Group msvc-version -Name $invalidMsvcInput.name -Passed $msvcRejected
    }
    $cpuProfileNames = @('nemo-speech.exe','nemo_speech_asr.dll','nemo_speech_asr_c.dll','ggml.dll','ggml-cpu.dll','msvcp140_atomic_wait.dll','msvcp140_codecvt_ids.dll')
    $cudaProfileNames = @('nemo-speech.exe','nemo_speech_asr.dll','nemo_speech_asr_c.dll','ggml.dll','ggml-cuda.dll','cublas64_12.dll','msvcp140_atomic_wait.dll','msvcp140_codecvt_ids.dll')
    Add-CaseResult -Group downstream-parsers -Name 'profile-cpu-green' -Passed (Test-RuntimeBinaryProfile -Names $cpuProfileNames -RequestedBackend cpu).passed
    Add-CaseResult -Group downstream-parsers -Name 'profile-cuda-green' -Passed (Test-RuntimeBinaryProfile -Names $cudaProfileNames -RequestedBackend cuda).passed
    Add-CaseResult -Group downstream-parsers -Name 'profile-asr-missing-red' -Passed (-not (Test-RuntimeBinaryProfile -Names @($cpuProfileNames | Where-Object { $_ -cne 'nemo_speech_asr.dll' }) -RequestedBackend cpu).passed)
    Add-CaseResult -Group downstream-parsers -Name 'profile-asr-c-missing-red' -Passed (-not (Test-RuntimeBinaryProfile -Names @($cpuProfileNames | Where-Object { $_ -cne 'nemo_speech_asr_c.dll' }) -RequestedBackend cpu).passed)
    Add-CaseResult -Group downstream-parsers -Name 'profile-unknown-red' -Passed (-not (Test-RuntimeBinaryProfile -Names @($cpuProfileNames + 'mystery.exe') -RequestedBackend cpu).passed)
    foreach ($cudaContaminant in @('ggml-cuda.dll','cublas64_12.dll','cublasLt64_12.dll','cudart64_12.dll')) {
        Add-CaseResult -Group cpu-profile -Name "$cudaContaminant-red" -Passed (-not (Test-RuntimeBinaryProfile -Names @($cpuProfileNames + $cudaContaminant) -RequestedBackend cpu).passed)
    }
    $physicalDbghelpRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-profile-dbghelp-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $physicalDbghelpRoot | Out-Null
        foreach ($name in @($cpuProfileNames + 'dbghelp.dll')) { [IO.File]::WriteAllBytes((Join-Path $physicalDbghelpRoot $name), [byte[]](1)) }
        $physicalNames = @(Get-ChildItem -LiteralPath $physicalDbghelpRoot -File | ForEach-Object Name)
        Add-CaseResult -Group system-dll-boundary -Name physical-dbghelp-profile-red -Passed (-not (Test-RuntimeBinaryProfile -Names $physicalNames -RequestedBackend cpu).passed)
    } finally {
        $resolvedPhysicalDbghelp = [IO.Path]::GetFullPath($physicalDbghelpRoot)
        $physicalDbghelpPrefix = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) 'diagnotes-profile-dbghelp-'
        if ($resolvedPhysicalDbghelp.StartsWith($physicalDbghelpPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-Path -LiteralPath $resolvedPhysicalDbghelp) { Remove-Item -LiteralPath $resolvedPhysicalDbghelp -Recurse -Force }
        } else { throw 'Physical DbgHelp profile cleanup boundary failed.' }
    }

    $attestationHash = ('a' * 64)
    $attestationJson = @([ordered]@{ verificationResult=[ordered]@{ statement=[ordered]@{ predicateType='https://slsa.dev/provenance/v1'; subject=@([ordered]@{name='candidate.zip';digest=[ordered]@{sha256=$attestationHash}}) } } }) | ConvertTo-Json -Depth 10
    Add-CaseResult -Group attestation -Name 'subject-digest-green' -Passed (Test-AttestationVerificationDocument -Json $attestationJson -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed
    Add-CaseResult -Group attestation -Name 'digest-mutation-red' -Passed (-not (Test-AttestationVerificationDocument -Json $attestationJson -ExpectedName candidate.zip -ExpectedSha256 ('b' * 64)).passed)
    Add-CaseResult -Group attestation -Name 'absence-red' -Passed (-not (Test-AttestationVerificationDocument -Json '[]' -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed)
    Add-CaseResult -Group attestation -Name 'invalid-json-red' -Passed (-not (Test-AttestationVerificationDocument -Json '[' -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed)
    Add-CaseResult -Group attestation -Name 'statement-absent-red' -Passed (-not (Test-AttestationVerificationDocument -Json '[{"verificationResult":{}}]' -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).created)
    Add-CaseResult -Group attestation -Name 'predicate-wrong-red' -Passed (-not (Test-AttestationVerificationDocument -Json ('[{"verificationResult":{"statement":{"predicateType":"other","subject":[{"name":"candidate.zip","digest":{"sha256":"' + $attestationHash + '"}}]}}}]') -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).created)
    Add-CaseResult -Group attestation -Name 'subject-malformed-red' -Passed (-not (Test-AttestationVerificationDocument -Json '[{"verificationResult":{"statement":{"predicateType":"https://slsa.dev/provenance/v1","subject":[{"name":"candidate.zip","digest":{}}]}}}]' -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).created)
    $duplicateAttestation = @([ordered]@{ verificationResult=[ordered]@{ statement=[ordered]@{ predicateType='https://slsa.dev/provenance/v1'; subject=@(
        [ordered]@{name='candidate.zip';digest=[ordered]@{sha256=$attestationHash}},
        [ordered]@{name='candidate.zip';digest=[ordered]@{sha256=$attestationHash}}
    ) } } }) | ConvertTo-Json -Depth 10
    Add-CaseResult -Group attestation -Name 'duplicate-subject-red' -Passed (-not (Test-AttestationVerificationDocument -Json $duplicateAttestation -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed)
    $conflictAttestation = @([ordered]@{ verificationResult=[ordered]@{ statement=[ordered]@{ predicateType='https://slsa.dev/provenance/v1'; subject=@(
        [ordered]@{name='candidate.zip';digest=[ordered]@{sha256=$attestationHash}},
        [ordered]@{name='candidate.zip';digest=[ordered]@{sha256=('b' * 64)}}
    ) } } }) | ConvertTo-Json -Depth 10
    Add-CaseResult -Group attestation -Name 'conflicting-subject-red' -Passed (-not (Test-AttestationVerificationDocument -Json $conflictAttestation -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed)

    $candidateSelfTestOutput = (& pwsh -NoProfile -File $CandidateTestPath -SelfTest 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Runtime candidate self-test process failed.' }
    $candidateSelfTest = $candidateSelfTestOutput | ConvertFrom-Json -Depth 10
    foreach ($candidateCase in @($candidateSelfTest.cases)) {
        Add-CaseResult -Group candidate-acceptance -Name ([string]$candidateCase.name) -Passed ([bool]$candidateCase.passed)
    }
    Add-CaseResult -Group candidate-acceptance -Name 'self-test-summary-green' -Passed ([bool]$candidateSelfTest.passed)
    $candidateSelfTestOutput = $null

    $workflowText = Get-Content -LiteralPath $WorkflowPath -Raw
    Add-CaseResult -Group workflow-static -Name 'no-release-primitives' -Passed ($workflowText -notmatch '(?im)\b(?:gh\s+release|softprops/action-gh-release|create-release|isDraft|prerelease)\b')
    Add-CaseResult -Group workflow-static -Name 'candidate-names-only' -Passed ($workflowText -match 'candidate-\$\{\{ matrix\.backend \}\}' -and $workflowText -notmatch '(?m)^\s*name:\s*runtime-')
    Add-CaseResult -Group workflow-static -Name 'gates-before-build' -Passed ($workflowText.IndexOf('Test-RuntimeGates.ps1') -ge 0 -and $workflowText.IndexOf('Test-RuntimeGates.ps1') -lt $workflowText.IndexOf('Build-Runtime.ps1'))
    Add-CaseResult -Group workflow-static -Name 'attestation-before-candidate' -Passed ($workflowText.IndexOf('attest-build-provenance') -ge 0 -and $workflowText.IndexOf('attest-build-provenance') -lt $workflowText.LastIndexOf('candidate-${{ matrix.backend }}'))
} catch {
    $infrastructureFailure = $_.Exception.Message
}

$failedCases = @($caseResults | Where-Object { -not $_.passed })
$groups = [ordered]@{}
foreach ($group in @($caseResults.group | Sort-Object -Unique)) {
    $members = @($caseResults | Where-Object group -eq $group)
    $groups[$group] = [pscustomobject]@{ passed=@($members | Where-Object passed).Count; total=$members.Count }
}
$passed = $null -eq $infrastructureFailure -and $failedCases.Count -eq 0
$evidence = [ordered]@{
    schema='diagnotes-runtime-gates-preflight-v1'
    target=(Split-Path -Leaf $BuildScriptPath)
    groups=$groups
    cases=$caseResults
    infrastructure_failure=$infrastructureFailure
    passed=$passed
}
$json = $evidence | ConvertTo-Json -Depth 10
if ($EvidencePath) {
    $parent = Split-Path -Parent $EvidencePath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllText($EvidencePath, $json, [Text.UTF8Encoding]::new($false))
}
$json
if (-not $passed) {
    $names = @($failedCases | ForEach-Object { "$($_.group)/$($_.name)" }) -join ', '
    throw "Runtime gates preflight failed: $names; infrastructure=$infrastructureFailure"
}
