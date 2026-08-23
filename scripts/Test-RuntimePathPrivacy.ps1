#Requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimePathPrivacy.psm1') -Force

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('diagnotes-path-privacy-' + [Guid]::NewGuid().ToString('N'))
$physicalRoot = Join-Path $testRoot 'physical-build-root'
$fixtures = Join-Path $testRoot 'fixtures'
New-Item -ItemType Directory -Path $physicalRoot, $fixtures | Out-Null
$profile = [Environment]::GetFolderPath('UserProfile')
$user = [Environment]::UserName
$utf8 = [Text.UTF8Encoding]::new($false)

$cases = @(
    [pscustomobject]@{ name='pdb-absolute-ascii.bin'; bytes=$utf8.GetBytes("$physicalRoot\bin\probe.pdb"); category='physical-root' },
    [pscustomobject]@{ name='file-absolute-ascii.bin'; bytes=$utf8.GetBytes("$physicalRoot\src\probe.cpp"); category='physical-root' },
    [pscustomobject]@{ name='slash-alternate-ascii.bin'; bytes=$utf8.GetBytes(($profile.Replace('\','/') + '/src/probe.cpp')); category='explicit-user-profile' },
    [pscustomobject]@{ name='case-alternate-ascii.bin'; bytes=$utf8.GetBytes(($profile.ToUpperInvariant() + '\SRC\PROBE.CPP')); category='explicit-user-profile' },
    [pscustomobject]@{ name='json-escaped-ascii.bin'; bytes=$utf8.GetBytes(($profile.Replace('\','\\') + '\\src\\probe.cpp')); category='explicit-user-profile' },
    [pscustomobject]@{ name='utf16le.bin'; bytes=[Text.Encoding]::Unicode.GetBytes("$profile\src\probe.cpp"); category='explicit-user-profile' },
    [pscustomobject]@{ name='utf16be.bin'; bytes=[Text.Encoding]::BigEndianUnicode.GetBytes(($profile.Replace('\','/') + '/src/probe.cpp')); category='explicit-user-profile' },
    [pscustomobject]@{ name='isolated-username.bin'; bytes=$utf8.GetBytes("prefix|$user|suffix"); category='isolated-username' },
    [pscustomobject]@{ name='profile-without-local-user.bin'; bytes=$utf8.GetBytes('C:\Users\another-profile\artifact.dll'); category='generic-user-profile' },
    [pscustomobject]@{ name='physical-root-without-profile.bin'; bytes=$utf8.GetBytes('/opaque/physical-build-root/build/probe.obj'); category='physical-root-leaf' }
)

$results = [Collections.Generic.List[object]]::new()
try {
    foreach ($case in $cases) {
        $path = Join-Path $fixtures $case.name
        [IO.File]::WriteAllBytes($path, $case.bytes)
        $contract = Test-PathPrivacyContract -LiteralPaths @($path) -PhysicalRoots @($physicalRoot) -LeafPhysicalRoots @($physicalRoot) `
            -UserProfile $profile -UserName $user -RelativeTo $fixtures
        $passed = -not $contract.passed -and @($contract.violations | Where-Object category -eq $case.category).Count -gt 0
        if (-not $passed) { throw "Sensitivity fixture failed: $($case.name)." }
        $results.Add([pscustomobject]@{ name=$case.name; expected=$case.category; result='PASS' })
    }

    $cleanPath = Join-Path $fixtures 'clean-neighbor.bin'
    [IO.File]::WriteAllBytes($cleanPath, $utf8.GetBytes('R:\neutral\src\probe.cpp; MSI-compatible; no physical build marker'))
    $clean = Test-PathPrivacyContract -LiteralPaths @($cleanPath) -PhysicalRoots @($physicalRoot) -LeafPhysicalRoots @($physicalRoot) `
        -UserProfile $profile -UserName $user -RelativeTo $fixtures
    if (-not $clean.passed) { throw 'Specificity fixture produced a false positive.' }
    $results.Add([pscustomobject]@{ name='clean-neighbor'; expected='no-violation'; result='PASS' })

    $evidenceJson = $results | ConvertTo-Json -Depth 5
    if ($evidenceJson.IndexOf($profile, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $evidenceJson -match '(?i)[A-Z]:\\Users\\') {
        throw 'Scanner evidence leaked a private path.'
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('diagnotes-path-privacy-', [StringComparison]::Ordinal)) {
        [IO.Directory]::Delete($resolved, $true)
    }
}

[pscustomobject]@{
    status='PASS'
    sensitivity_cases=$cases.Count
    specificity_cases=1
    encodings=@('ASCII','UTF-16LE','UTF-16BE')
    separators=@('backslash','slash','JSON-escaped')
    evidence_sanitized=$true
    results=$results
} | ConvertTo-Json -Depth 8
