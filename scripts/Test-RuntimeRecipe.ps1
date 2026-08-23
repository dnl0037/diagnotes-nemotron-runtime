#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot 'Build-Runtime.ps1'),
    [string]$GateTestPath = (Join-Path $PSScriptRoot 'Test-RuntimeGates.ps1'),
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows\build-release.yml'),
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildText = Get-Content -LiteralPath $BuildScriptPath -Raw
$gateText = Get-Content -LiteralPath $GateTestPath -Raw
$workflowText = Get-Content -LiteralPath $WorkflowPath -Raw
$parseResults = @()
foreach ($path in @($BuildScriptPath,$GateTestPath,$PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $path), [ref]$tokens, [ref]$parseErrors)
    $parseResults += [pscustomobject]@{ path=(Split-Path -Leaf $path); errors=@($parseErrors).Count }
}

$checks = @(
    [pscustomobject]@{ name='powershell-parses'; passed=(@($parseResults | Where-Object errors -ne 0).Count -eq 0) },
    [pscustomobject]@{ name='lid3-only'; passed=($buildText -match 'nemo-speech-v0\.1\.0-diagnotes-lid\.3' -and $buildText -notmatch 'lid\.2') },
    [pscustomobject]@{ name='static-md-pin'; passed=($buildText -match '\$VcpkgTriplet\s*=\s*''x64-windows-static-md''' -and $buildText -notmatch 'VcpkgTriplet\s*=\s*''x64-windows-static''') },
    [pscustomobject]@{ name='compile-db-exported'; passed=($buildText -match '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON' -and $buildText -match 'compile_commands\.json') },
    [pscustomobject]@{ name='no-ninja-command-classifier'; passed=($buildText -notmatch 'ninja\s+-C\s+\$BuildRoot\s+-t\s+commands' -and $buildText -notmatch 'ninja-commands') },
    [pscustomobject]@{ name='structured-cache-contract'; passed=($buildText -match 'function ConvertFrom-CMakeCacheText' -and $buildText -match 'function Test-CMakeCacheContract') },
    [pscustomobject]@{ name='gate-dag-and-results'; passed=($buildText -match 'function Get-RuntimeGateManifest' -and $buildText -match 'gate-results\.json' -and $buildText -match "'PASS','FAIL'") },
    [pscustomobject]@{ name='behavior-only-in-ast-harness'; passed=($gateText -match 'FunctionDefinitionAst' -and $buildText -notmatch 'function Test-CrtFixture' -and $gateText -notmatch 'function Test-CrtFixture') },
    [pscustomobject]@{ name='candidate-workflow-only'; passed=($workflowText -match 'candidate-\$\{\{ matrix\.backend \}\}' -and $workflowText -notmatch '(?m)^\s*name:\s*runtime-') },
    [pscustomobject]@{ name='workflow-preflight-before-build'; passed=($workflowText.IndexOf('Test-RuntimeGates.ps1') -ge 0 -and $workflowText.IndexOf('Test-RuntimeGates.ps1') -lt $workflowText.IndexOf('Build-Runtime.ps1')) }
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
