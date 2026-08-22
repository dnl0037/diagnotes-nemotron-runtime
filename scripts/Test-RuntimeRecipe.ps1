#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot 'Build-Runtime.ps1'),
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows\build-release.yml'),
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildText = Get-Content -LiteralPath $BuildScriptPath -Raw
$workflowText = Get-Content -LiteralPath $WorkflowPath -Raw
$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $BuildScriptPath),
    [ref]$tokens,
    [ref]$parseErrors
)

function Test-CrtFixture {
    param([string]$Cache, [string]$Commands, [string]$Log)
    return $Cache -match '(?m)^VCPKG_TARGET_TRIPLET:[^=]+=x64-windows-static-md$' -and
        $Cache -notmatch '(?m)^VCPKG_TARGET_TRIPLET:[^=]+=x64-windows-static$' -and
        $Commands -match '(?i)(?:^|[=\s"''])/MD(?:$|[\s"''])' -and
        $Commands -notmatch '(?i)(?:^|[=\s"''])/MTd?(?:$|[\s"''])' -and
        $Commands -notmatch '(?i)(?:^|[=\s"''])/MDd(?:$|[\s"''])' -and
        $Log -notmatch 'LNK2038|LNK2005|LNK1169'
}

$fixtures = @(
    [ordered]@{ name='coherent-md'; expected=$true; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md"; commands='cl /c /MD source.cpp'; log='link complete' },
    [ordered]@{ name='old-static-triplet'; expected=$false; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static"; commands='cl /c /MD source.cpp'; log='link complete' },
    [ordered]@{ name='mt-command'; expected=$false; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md"; commands='cl /c /MT source.cpp'; log='link complete' },
    [ordered]@{ name='mixed-command'; expected=$false; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md"; commands='cl /c /MD /MT source.cpp'; log='link complete' },
    [ordered]@{ name='lnk2038'; expected=$false; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md"; commands='cl /c /MD source.cpp'; log='LNK2038 mismatch' },
    [ordered]@{ name='lnk2005'; expected=$false; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md"; commands='cl /c /MD source.cpp'; log='LNK2005 duplicate' },
    [ordered]@{ name='lnk1169'; expected=$false; cache="VCPKG_TARGET_TRIPLET:STRING=x64-windows-static-md"; commands='cl /c /MD source.cpp'; log='LNK1169 fatal' }
)
$fixtureResults = @($fixtures | ForEach-Object {
    $actual = Test-CrtFixture -Cache $_.cache -Commands $_.commands -Log $_.log
    [ordered]@{ name=$_.name; expected=$_.expected; actual=$actual; passed=($actual -eq $_.expected) }
})

$environmentFixtureName = 'DIAGNOTES_RECIPE_ENV_' + [Guid]::NewGuid().ToString('N')
$environmentFixtureValue = [Guid]::NewGuid().ToString('N')
$environmentFixtureScript = Join-Path ([IO.Path]::GetTempPath()) ($environmentFixtureName + '.ps1')
try {
    [IO.File]::WriteAllText(
        $environmentFixtureScript,
        "`$env:$environmentFixtureName = '$environmentFixtureValue'",
        [Text.UTF8Encoding]::new($false)
    )
    & pwsh -NoProfile -File $environmentFixtureScript
    $childProcessPreservedEnvironment =
        [Environment]::GetEnvironmentVariable($environmentFixtureName, 'Process') -eq $environmentFixtureValue
    & $environmentFixtureScript
    $inProcessPreservedEnvironment =
        [Environment]::GetEnvironmentVariable($environmentFixtureName, 'Process') -eq $environmentFixtureValue
} finally {
    Remove-Item -LiteralPath "env:$environmentFixtureName" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $environmentFixtureScript -Force -ErrorAction SilentlyContinue
}

$profileBlock = [regex]::Match($buildText, '(?s)\$profileArgs\s*=\s*@\((.*?)\)\s*if \(\$Backend').Groups[1].Value
$checks = @(
    [ordered]@{ name='powershell-parses'; passed=(@($parseErrors).Count -eq 0) },
    [ordered]@{ name='lid3-only'; passed=($buildText -match "nemo-speech-v0\.1\.0-diagnotes-lid\.3" -and $buildText -notmatch 'lid\.2') },
    [ordered]@{ name='static-md-only'; passed=($buildText -match '\$VcpkgTriplet\s*=\s*''x64-windows-static-md''' -and $buildText -notmatch "'-VcpkgTriplet', 'x64-windows-static'") },
    [ordered]@{ name='no-late-static-crt'; passed=($profileBlock -notmatch 'MultiThreaded|CMAKE_MSVC_RUNTIME_LIBRARY') },
    [ordered]@{ name='upstream-in-process'; passed=($buildText -match '(?m)^& \$upstreamBuild @buildArgs$' -and $buildText -notmatch 'Invoke-Checked\s+pwsh\s+\$upstreamBuild') },
    [ordered]@{ name='vcvars-environment-red-green'; passed=(-not $childProcessPreservedEnvironment -and $inProcessPreservedEnvironment) },
    [ordered]@{ name='legal-evidence-pinned'; passed=($buildText -match 'VsLicenseSha256' -and $buildText -match 'VsRedistListSha256' -and $buildText -match 'Visual-Studio-2022-Redistribution') },
    [ordered]@{ name='pe-and-defender-gates'; passed=($buildText -match 'Resolve-PeClosure' -and $buildText -match 'Get-MpComputerStatus' -and $buildText -match 'defender\.json') },
    [ordered]@{ name='clean-unique-root'; passed=($buildText -match 'GITHUB_RUN_ATTEMPT' -and $buildText -match 'Unique clean work root already exists') },
    [ordered]@{ name='workflow-timeout-and-cardinality'; passed=($workflowText -match 'timeout-minutes:\s*45' -and $workflowText -match '\$zips\.Count -ne 1') }
)

$passed = @($fixtureResults | Where-Object { -not $_.passed }).Count -eq 0 -and
    @($checks | Where-Object { -not $_.passed }).Count -eq 0
$evidence = [ordered]@{
    schema='diagnotes-runtime-recipe-preflight-v1'
    fixtures=$fixtureResults
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
if (-not $passed) { throw 'Runtime recipe preflight failed.' }
