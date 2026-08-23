#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot 'Build-Runtime.ps1'),
    [Parameter(Mandatory)]
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$caseResults = @()
$definitionHash = $null
$failedCases = @()
$infrastructureFailure = $null
$probeRoot = $null
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())

try {
    $resolvedBuildScript = (Resolve-Path -LiteralPath $BuildScriptPath).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $resolvedBuildScript,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -ne 0) { throw 'BUILD_SCRIPT_PARSE' }

    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Write-SanitizedInstallerLog'
    }, $true))
    if ($definitions.Count -ne 1) { throw 'SANITIZER_DEFINITION_COUNT' }

    $definitionText = $definitions[0].Extent.Text
    $definitionBytes = [Text.UTF8Encoding]::new($false).GetBytes($definitionText)
    $definitionHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($definitionBytes))
    . ([ScriptBlock]::Create($definitionText))

    $probeRoot = Join-Path $tempBase ('diagnotes-sanitizer-' + [Guid]::NewGuid().ToString('N'))
    $WorkRoot = Join-Path $probeRoot 'PrivateRoot'
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

    $privateRootLower = $WorkRoot.ToLowerInvariant()
    $privateRootForward = $WorkRoot.Replace('\', '/')
    $privateRootJsonEscaped = $WorkRoot.Replace('\', '\\')
    $cases = @(
        [ordered]@{
            name='absent'; fixture='absent'; content=$null
            validate={ param($actual) $actual -ceq '<empty>' }
        },
        [ordered]@{
            name='zero_bytes'; fixture='empty'; content=$null
            validate={ param($actual) $actual -ceq '<empty>' }
        },
        [ordered]@{
            name='normal_text'; fixture='text'; content="ordinary diagnostic`nsecond safe line"
            validate={ param($actual) $actual -ceq "ordinary diagnostic`nsecond safe line" }
        },
        [ordered]@{
            name='private_path'; fixture='text'
            content="exact=$WorkRoot\one.log`nlower=$privateRootLower\two.log`nforward=$privateRootForward/three.log"
            validate={
                param($actual)
                ([regex]::Matches($actual, [regex]::Escape('<private-path>'))).Count -eq 3 -and
                    -not $actual.Contains($WorkRoot, [StringComparison]::OrdinalIgnoreCase) -and
                    -not $actual.Contains($privateRootForward, [StringComparison]::OrdinalIgnoreCase)
            }
        },
        [ordered]@{
            name='json_escaped_private_path'; fixture='text'
            content=('{"directory":"' + $privateRootJsonEscaped + '\\build","command":"' + $privateRootJsonEscaped.ToUpperInvariant() + '\\tool.exe"}')
            validate={
                param($actual)
                ([regex]::Matches($actual, [regex]::Escape('<private-path>'))).Count -eq 2 -and
                    -not $actual.Contains($privateRootJsonEscaped, [StringComparison]::OrdinalIgnoreCase) -and
                    -not $actual.Contains($WorkRoot, [StringComparison]::OrdinalIgnoreCase)
            }
        },
        [ordered]@{
            name='credential'; fixture='text'
            content="safe-before`nAuthorization: Bearer sentinel-bearer`nAuthorization=Basic sentinel-basic`nBearer sentinel-standalone`n{`"token`":`"sentinel-json`"}`npassword=sentinel password with spaces`nsafe-after"
            validate={
                param($actual)
                -not $actual.Contains('sentinel-', [StringComparison]::Ordinal) -and
                    $actual.Contains('safe-before', [StringComparison]::Ordinal) -and
                    $actual.Contains('safe-after', [StringComparison]::Ordinal) -and
                    ($actual -split "`r?`n").Count -eq 7
            }
        },
        [ordered]@{
            name='sensitive_query'; fixture='text'
            content="safe-before`nhttps://example.test/file?token=query-sentinel&x=1`n/ready?secret=relative-sentinel`nsafe-after"
            validate={
                param($actual)
                -not $actual.Contains('sentinel', [StringComparison]::Ordinal) -and
                    $actual.Contains('https://example.test/file?<redacted-query>', [StringComparison]::Ordinal) -and
                    $actual.Contains('/ready?<redacted-query>', [StringComparison]::Ordinal) -and
                    ($actual -split "`r?`n").Count -eq 4
            }
        }
    )

    foreach ($case in $cases) {
        $inputPath = Join-Path $probeRoot "$($case.name).input.log"
        $outputPath = Join-Path $probeRoot "$($case.name).output.log"
        $passed = $false
        try {
            switch ($case.fixture) {
                'absent' { }
                'empty' { [IO.File]::WriteAllBytes($inputPath, [byte[]]@()) }
                'text' { [IO.File]::WriteAllText($inputPath, $case.content, [Text.UTF8Encoding]::new($false)) }
                default { throw 'UNKNOWN_FIXTURE' }
            }
            Write-SanitizedInstallerLog -InputPath $inputPath -OutputPath $outputPath
            $actual = [IO.File]::ReadAllText($outputPath)
            $passed = [bool](& $case.validate $actual)
        } catch {
            $passed = $false
        }
        $caseResults += [ordered]@{ name=$case.name; passed=$passed }
        if (-not $passed) { $failedCases += $case.name }
    }
} catch {
    $infrastructureFailure = $_.Exception.GetType().Name
} finally {
    if ($null -ne $probeRoot -and (Test-Path -LiteralPath $probeRoot)) {
        $resolvedProbe = [IO.Path]::GetFullPath($probeRoot)
        $expectedPrefix = Join-Path $tempBase 'diagnotes-sanitizer-'
        if ($resolvedProbe.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
        } else {
            $infrastructureFailure = 'PROBE_PATH_BOUNDARY'
        }
    }
}

$passedOverall = $null -eq $infrastructureFailure -and $failedCases.Count -eq 0
$evidence = [ordered]@{
    schema='diagnotes-sanitizer-preflight-v1'
    strict_mode='Latest'
    target_sha256=$definitionHash
    cases=$caseResults
    infrastructure_ok=($null -eq $infrastructureFailure)
    passed=$passedOverall
}
$evidenceJson = $evidence | ConvertTo-Json -Depth 6
$evidenceParent = Split-Path -Parent $EvidencePath
New-Item -ItemType Directory -Path $evidenceParent -Force | Out-Null
[IO.File]::WriteAllText($EvidencePath, $evidenceJson, [Text.UTF8Encoding]::new($false))
$evidenceJson

if ($null -ne $infrastructureFailure) {
    throw "Sanitizer preflight infrastructure failure: $infrastructureFailure"
}
if ($failedCases.Count -ne 0) {
    throw "Sanitizer preflight failed: $($failedCases -join ', ')"
}
