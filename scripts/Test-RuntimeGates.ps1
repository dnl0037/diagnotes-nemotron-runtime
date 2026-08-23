#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot 'Build-Runtime.ps1'),
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
    $matches = @()
    foreach ($document in $documents) {
        if ($null -eq $document -or $null -eq $document.PSObject.Properties['verificationResult'] -or
            $null -eq $document.verificationResult.PSObject.Properties['statement']) { continue }
        if ([string]$document.verificationResult.statement.predicateType -cne 'https://slsa.dev/provenance/v1') { continue }
        foreach ($subject in @($document.verificationResult.statement.subject)) {
            if ([string]$subject.name -ceq $ExpectedName -and
                [string]$subject.digest.sha256 -ceq $ExpectedSha256.ToLowerInvariant()) {
                $matches += $subject
            }
        }
    }
    return [pscustomobject]@{ passed=$matches.Count -ge 1; created=$true; reason=if ($matches.Count -ge 1) { 'subject digest verified' } else { 'subject digest mismatch' }; matches=$matches.Count }
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
        'ConvertTo-SanitizedEvidenceText',
        'New-UpstreamBuildArguments',
        'Test-RuntimeIdentityContract',
        'New-ProfileArguments',
        'ConvertFrom-CMakeCacheText',
        'Test-CMakeCacheContract',
        'ConvertFrom-CMakeSetText',
        'ConvertFrom-ExactKeyValueText',
        'Test-CudaVersionJson',
        'Test-NvccVersionText',
        'Test-MicrosoftSignerIdentity',
        'ConvertFrom-DumpbinDependentsText',
        'Get-RuntimeFileClassification',
        'Test-RuntimeBinaryProfile',
        'ConvertFrom-WindowsCommandLine',
        'Test-CompileCommandsContract',
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
        ObservedVersion='nemo-speech-v0.1.0-diagnotes-lid.3'
        ObservedTriplet='x64-windows-static-md'
        ObservedCudaArch='75;80;86;89'
        ObservedVcpkgCommit='9e593bb18ea69cc5095e012465dcd675a822ed0d'
    }
    Add-CaseResult -Group identity-mutation -Name green -Passed (Test-RuntimeIdentityContract @identityGreen).passed
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
        'CMAKE_TOOLCHAIN_FILE:FILEPATH=C:/vcpkg/scripts/buildsystems/vcpkg.cmake',
        'CMAKE_CXX_COMPILER:FILEPATH=C:/VS/cl.exe',
        'CMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL',
        'CMAKE_CUDA_ARCHITECTURES:STRING=75;80;86;89'
    )
    foreach ($fixture in @(
        [pscustomobject]@{ name='lf'; text=($baseCacheLines -join "`n") + "`n" },
        [pscustomobject]@{ name='crlf'; text=($baseCacheLines -join "`r`n") + "`r`n" },
        [pscustomobject]@{ name='eof'; text=($baseCacheLines -join "`n") },
        [pscustomobject]@{ name='comments-order'; text=((@('# comment','', $baseCacheLines[4]) + $baseCacheLines[0..3] + $baseCacheLines[5..($baseCacheLines.Count - 1)]) -join "`n") }
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
        malformed = $baseCacheLines -replace '^CMAKE_TOOLCHAIN_FILE:', 'CMAKE_TOOLCHAIN_FILE :'
        bare_cr = @($baseCacheLines[0..4] + ("$($baseCacheLines[5])`r$($baseCacheLines[6])") + $baseCacheLines[7..($baseCacheLines.Count - 1)])
    }
    foreach ($mutation in $cacheMutations.GetEnumerator()) {
        $actual = Test-CMakeCacheContract -Text ($mutation.Value -join "`n") -RequestedBackend cuda -RequestedTriplet 'x64-windows-static-md' -RequestedCudaArch '75;80;86;89'
        Add-CaseResult -Group cache-negative -Name $mutation.Key -Passed (-not $actual.passed)
    }

    $compileFixtures = @(
        [pscustomobject]@{ name='cl-command'; expected=$true; inspectable=$true; json='[{"directory":"C:/b","command":"\"C:\\VS\\cl.exe\" /nologo /MD /c \"C:\\src\\one.cpp\"","file":"C:/src/one.cpp"}]' },
        [pscustomobject]@{ name='cl-arguments'; expected=$true; inspectable=$true; json='[{"arguments":["C:/VS/cl.exe","/MD","/c","one.cpp"],"file":"one.cpp"}]' },
        [pscustomobject]@{ name='nvcc-equals'; expected=$true; inspectable=$true; json='[{"arguments":["C:/CUDA/nvcc.exe","-Xcompiler=/MD","-c","one.cu"],"file":"one.cu"}]' },
        [pscustomobject]@{ name='nvcc-pair'; expected=$true; inspectable=$true; json='[{"arguments":["nvcc.exe","--compiler-options","/MD","-c","one.cu"],"file":"one.cu"}]' },
        [pscustomobject]@{ name='mt'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MT","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='mtd'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MTd","/c","one.cpp"]}]' },
        [pscustomobject]@{ name='mdd'; expected=$false; inspectable=$true; json='[{"arguments":["cl.exe","/MDd","/c","one.cpp"]}]' },
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
    $expectedCpuProfile = @($baselineProfile[0..3] + '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON' + $baselineProfile[4..($baselineProfile.Count - 1)] + @('-DGGML_CUDA=OFF','-DGGML_VULKAN=OFF','-DNEMO_SPEECH_GGML_PATCHED=OFF'))
    $expectedCudaProfile = @($baselineProfile[0..3] + '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON' + $baselineProfile[4..($baselineProfile.Count - 1)] + @('-DGGML_CUDA=ON','-DGGML_VULKAN=OFF','-DNEMO_SPEECH_CUBLAS_SHIM=ON','-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89'))
    Add-CaseResult -Group semantic-diff -Name 'cpu-baseline-plus-export-only' -Passed (($cpuProfile | ConvertTo-Json -Compress) -ceq ($expectedCpuProfile | ConvertTo-Json -Compress))
    Add-CaseResult -Group semantic-diff -Name 'cuda-baseline-plus-export-only' -Passed (($cudaProfile | ConvertTo-Json -Compress) -ceq ($expectedCudaProfile | ConvertTo-Json -Compress))

    $manifest = @(Get-RuntimeGateManifest)
    $ids = @($manifest | ForEach-Object id)
    Add-CaseResult -Group dag -Name 'stable-unique-ids' -Passed (($ids.Count -eq 18) -and (@($ids | Sort-Object -Unique).Count -eq 18))
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

    foreach ($gateId in @('source-patch','cache','compile-arguments-inspectable','crt','profile','legal','pe-closure','inventory','sbom','zip-extraction','defender-tree','defender-zip','privacy','attestation-created','attestation-digest-verified')) {
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

    $dumpbinGreen = "preamble`r`n  Image has the following dependencies:`r`n`r`n    KERNEL32.dll`r`n    VCRUNTIME140.dll`r`n`r`n  Summary`r`n"
    $dumpbinParsed = ConvertFrom-DumpbinDependentsText -Text $dumpbinGreen
    $dumpbinUnknown = ConvertFrom-DumpbinDependentsText -Text "  Image has the following dependencies:`n`n    KERNEL32.dll`n    not a dll line`n"
    $dumpbinDuplicate = ConvertFrom-DumpbinDependentsText -Text "  Image has the following dependencies:`n`n    KERNEL32.dll`n    KERNEL32.dll`n"
    Add-CaseResult -Group downstream-parsers -Name 'dumpbin-green' -Passed ($dumpbinParsed.passed -and $dumpbinParsed.dependencies.Count -eq 2)
    Add-CaseResult -Group downstream-parsers -Name 'dumpbin-unknown-red' -Passed (-not $dumpbinUnknown.passed)
    Add-CaseResult -Group downstream-parsers -Name 'dumpbin-duplicate-red' -Passed (-not $dumpbinDuplicate.passed)

    Add-CaseResult -Group downstream-parsers -Name 'inventory-known-green' -Passed (Get-RuntimeFileClassification -RelativePath 'bin/nemo-speech.exe').passed
    Add-CaseResult -Group downstream-parsers -Name 'inventory-unknown-red' -Passed (-not (Get-RuntimeFileClassification -RelativePath 'bin/unknown-tool.exe').passed)
    Add-CaseResult -Group downstream-parsers -Name 'profile-cpu-green' -Passed (Test-RuntimeBinaryProfile -Names @('nemo-speech.exe','ggml.dll','ggml-cpu.dll') -RequestedBackend cpu).passed
    Add-CaseResult -Group downstream-parsers -Name 'profile-cuda-green' -Passed (Test-RuntimeBinaryProfile -Names @('nemo-speech.exe','ggml.dll','ggml-cuda.dll','cublas64_12.dll') -RequestedBackend cuda).passed
    Add-CaseResult -Group downstream-parsers -Name 'profile-unknown-red' -Passed (-not (Test-RuntimeBinaryProfile -Names @('nemo-speech.exe','mystery.exe') -RequestedBackend cpu).passed)

    $attestationHash = ('a' * 64)
    $attestationJson = @([ordered]@{ verificationResult=[ordered]@{ statement=[ordered]@{ predicateType='https://slsa.dev/provenance/v1'; subject=@([ordered]@{name='candidate.zip';digest=[ordered]@{sha256=$attestationHash}}) } } }) | ConvertTo-Json -Depth 10
    Add-CaseResult -Group attestation -Name 'subject-digest-green' -Passed (Test-AttestationVerificationDocument -Json $attestationJson -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed
    Add-CaseResult -Group attestation -Name 'digest-mutation-red' -Passed (-not (Test-AttestationVerificationDocument -Json $attestationJson -ExpectedName candidate.zip -ExpectedSha256 ('b' * 64)).passed)
    Add-CaseResult -Group attestation -Name 'absence-red' -Passed (-not (Test-AttestationVerificationDocument -Json '[]' -ExpectedName candidate.zip -ExpectedSha256 $attestationHash).passed)

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
