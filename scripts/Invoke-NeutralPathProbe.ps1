#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProbeRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimePathPrivacy.psm1') -Force

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($FilePath)) failed with exit code $LASTEXITCODE." }
}

function Get-ProbeTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'vswhere.exe is missing.' }
    $json = (& $vswhere -latest -products Microsoft.VisualStudio.Product.BuildTools `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'vswhere failed.' }
    $instances = @($json | ConvertFrom-Json -Depth 20)
    if ($instances.Count -ne 1) { throw 'Expected exactly one latest Build Tools instance.' }
    $vs = [IO.Path]::GetFullPath([string]$instances[0].installationPath).TrimEnd('\')
    $toolsets = @(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory |
        Where-Object Name -match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending)
    if ($toolsets.Count -eq 0) { throw 'MSVC toolset is missing.' }
    $hostBin = Join-Path $toolsets[0].FullName 'bin\Hostx64\x64'
    $result = [pscustomobject]@{
        vs=$vs
        vs_version=[string]$instances[0].catalog.productDisplayVersion
        toolset=$toolsets[0].Name
        vsdevcmd=Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
        cmake=Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        ninja=Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
        cl=Join-Path $hostBin 'cl.exe'
        dumpbin=Join-Path $hostBin 'dumpbin.exe'
    }
    foreach ($name in @('vsdevcmd','cmake','ninja','cl','dumpbin')) {
        if (-not (Test-Path -LiteralPath $result.$name -PathType Leaf)) { throw "Probe tool is missing: $name." }
    }
    $result
}

function Get-CodeViewPdbReference {
    param(
        [Parameter(Mandatory)][string]$DumpbinPath,
        [Parameter(Mandatory)][string]$PePath
    )
    $text = (& $DumpbinPath /headers $PePath 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'dumpbin failed while reading the CodeView record.' }
    $matches = @([regex]::Matches($text, '(?i)Format:\s+RSDS,\s+\{[0-9A-F-]+\},\s+\d+,\s+(?<pdb>(?:[A-Z]:\\)?[^\r\n]*?\.pdb)(?:\r?\n|$)'))
    if ($matches.Count -ne 1) { throw 'Expected exactly one strict RSDS CodeView record.' }
    return $matches[0].Groups['pdb'].Value.Trim()
}

function Import-VsDevEnvironment {
    param([Parameter(Mandatory)][string]$BatchPath)
    $command = '"' + $BatchPath + '" -arch=x64 -host_arch=x64 >nul && set'
    $lines = @(& $env:ComSpec /d /s /c $command)
    if ($LASTEXITCODE -ne 0) { throw 'VsDevCmd environment import failed.' }
    foreach ($line in $lines) {
        $position = $line.IndexOf('=')
        if ($position -gt 0) {
            [Environment]::SetEnvironmentVariable($line.Substring(0,$position), $line.Substring($position + 1), 'Process')
        }
    }
}

function Get-FreeNeutralDrive {
    $substText = (& subst.exe | Out-String)
    foreach ($letter in @('R','Q','P','O','N','M','L','K')) {
        if (-not (Test-Path -LiteralPath "$letter`:\") -and $substText -notmatch "(?im)^$letter`:\\") { return $letter }
    }
    throw 'No approved neutral drive letter is free.'
}

$base = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'DiagNotes\RuntimeBuild')).TrimEnd('\')
$root = [IO.Path]::GetFullPath($ProbeRoot).TrimEnd('\')
if ($root -ceq $base -or -not $root.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ProbeRoot must be a strict child of the managed local runtime-build root.'
}
if (Test-Path -LiteralPath $root) { throw 'ProbeRoot must be fresh.' }
if ((Get-PSDrive ([IO.Path]::GetPathRoot($root).TrimEnd('\').TrimEnd(':'))).Free -lt 100GB) { throw 'Less than 100 GB free.' }

$snapshot = [ordered]@{}
foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) { $snapshot[[string]$entry.Key]=[string]$entry.Value }
$drive = $null
$mounted = $false
$primaryError = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
$outputJson = $null
try {
    $tools = Get-ProbeTools
    Import-VsDevEnvironment -BatchPath $tools.vsdevcmd
    $env:Path = ((Split-Path -Parent $tools.cmake),(Split-Path -Parent $tools.ninja),(Split-Path -Parent $tools.cl),$env:Path -join ';')

    $source = Join-Path $root 'src'
    New-Item -ItemType Directory -Path $source | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'probe.cpp'), @'
extern "C" __declspec(dllexport) const char* diagnotes_probe_source_path() {
    return __FILE__;
}
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'clean.cpp'), @'
extern "C" __declspec(dllexport) int diagnotes_clean_neighbor() {
    return 4;
}
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'main.cpp'), @'
int main() {
    return 0;
}
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'CMakeLists.txt'), @'
cmake_minimum_required(VERSION 3.20)
project(diagnotes_neutral_path_probe LANGUAGES CXX)
add_library(probe SHARED probe.cpp)
add_library(clean_neighbor SHARED clean.cpp)
add_library(probe_module MODULE clean.cpp)
add_executable(probe_exe main.cpp)
target_compile_options(probe PRIVATE /MD)
target_compile_options(clean_neighbor PRIVATE /MD)
target_compile_options(probe_module PRIVATE /MD)
target_compile_options(probe_exe PRIVATE /MD)
'@, [Text.UTF8Encoding]::new($false))

    $controlBuild = Join-Path $root 'control-build'
    Invoke-Checked $tools.cmake -S $source -B $controlBuild -G Ninja '-DCMAKE_BUILD_TYPE:STRING=Release' "-DCMAKE_MAKE_PROGRAM:FILEPATH=$($tools.ninja)"
    Invoke-Checked $tools.cmake --build $controlBuild --config Release --parallel 2
    $controlDll = Join-Path $controlBuild 'probe.dll'
    $controlPrivacy = Test-PathPrivacyContract -LiteralPaths @($controlDll) -PhysicalRoots @($root) -LeafPhysicalRoots @($root) `
        -UserProfile ([Environment]::GetFolderPath('UserProfile')) -UserName ([Environment]::UserName) -RelativeTo $controlBuild
    if ($controlPrivacy.passed -or @($controlPrivacy.violations | Where-Object category -in @('physical-root','generic-user-profile','explicit-user-profile')).Count -eq 0) {
        throw 'Vulnerable control did not reproduce the private absolute path.'
    }

    $drive = Get-FreeNeutralDrive
    $sentinel = Join-Path $root 'neutral-drive-sentinel.txt'
    [IO.File]::WriteAllText($sentinel, 'diagnotes-neutral-probe', [Text.UTF8Encoding]::new($false))
    & subst.exe "$drive`:" $root
    if ($LASTEXITCODE -ne 0) { throw 'Neutral drive mount failed.' }
    $mounted = $true
    $neutralRoot = "$drive`:\"
    if (-not (Test-Path -LiteralPath (Join-Path $neutralRoot 'neutral-drive-sentinel.txt') -PathType Leaf)) {
        throw 'Neutral drive does not resolve to the managed probe root.'
    }

    $neutralSource = Join-Path $neutralRoot 'src'
    $neutralPdbControlBuild = Join-Path $neutralRoot 'neutral-pdb-control'
    $neutralBuild = Join-Path $neutralRoot 'neutral-build'
    $pdbAltPath = '/PDBALTPATH:%_PDB%'
    Invoke-Checked $tools.cmake -S $neutralSource -B $neutralPdbControlBuild -G Ninja '-DCMAKE_BUILD_TYPE:STRING=Release' `
        "-DCMAKE_MAKE_PROGRAM:FILEPATH=$($tools.ninja)" '-DCMAKE_SHARED_LINKER_FLAGS:STRING=/DEBUG' `
        '-DCMAKE_MODULE_LINKER_FLAGS:STRING=/DEBUG' '-DCMAKE_EXE_LINKER_FLAGS:STRING=/DEBUG'
    Invoke-Checked $tools.cmake --build $neutralPdbControlBuild --config Release --parallel 2
    Invoke-Checked $tools.cmake -S $neutralSource -B $neutralBuild -G Ninja '-DCMAKE_BUILD_TYPE:STRING=Release' `
        "-DCMAKE_MAKE_PROGRAM:FILEPATH=$($tools.ninja)" "-DCMAKE_SHARED_LINKER_FLAGS:STRING=/DEBUG $pdbAltPath" `
        "-DCMAKE_MODULE_LINKER_FLAGS:STRING=/DEBUG $pdbAltPath" "-DCMAKE_EXE_LINKER_FLAGS:STRING=/DEBUG $pdbAltPath"
    Invoke-Checked $tools.cmake --build $neutralBuild --config Release --parallel 2
    $neutralDll = Join-Path $neutralBuild 'probe.dll'
    $cleanDll = Join-Path $neutralBuild 'clean_neighbor.dll'
    $neutralPdbControlDll = Join-Path $neutralPdbControlBuild 'probe.dll'
    $neutralPrivacy = Test-PathPrivacyContract -LiteralPaths @(
        $neutralPdbControlDll,$neutralDll,$cleanDll,
        (Join-Path $neutralBuild 'probe_module.dll'),(Join-Path $neutralBuild 'probe_exe.exe')
    ) -PhysicalRoots @($root) -LeafPhysicalRoots @($root) `
        -UserProfile ([Environment]::GetFolderPath('UserProfile')) -UserName ([Environment]::UserName) -RelativeTo $neutralBuild
    if (-not $neutralPrivacy.passed) { throw 'Neutral probe or clean neighbor still contains a private marker.' }
    if (-not (Test-NeutralPathMarkerPresence -LiteralPath $neutralDll -NeutralMarker "$drive`:\src\probe.cpp")) {
        throw 'Neutral __FILE__ marker is absent from the productive probe DLL.'
    }
    $ninjaText = [IO.File]::ReadAllText((Join-Path $neutralBuild 'build.ninja'))
    if ($ninjaText.IndexOf($pdbAltPath, [StringComparison]::Ordinal) -lt 0) {
        throw 'The effective neutral link recipe lacks /PDBALTPATH:%_PDB%.'
    }
    $pdbControlReference = Get-CodeViewPdbReference -DumpbinPath $tools.dumpbin -PePath $neutralPdbControlDll
    $pdbTreatedReference = Get-CodeViewPdbReference -DumpbinPath $tools.dumpbin -PePath $neutralDll
    $expectedControlPrefix = "$drive`:\"
    if (-not [IO.Path]::IsPathFullyQualified($pdbControlReference) -or
        -not $pdbControlReference.StartsWith($expectedControlPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The neutral PDB control did not expose an absolute CodeView reference.'
    }
    if ([IO.Path]::IsPathFullyQualified($pdbTreatedReference) -or
        [IO.Path]::GetFileName($pdbTreatedReference) -cne 'probe.pdb' -or $pdbTreatedReference -cne 'probe.pdb') {
        throw 'PDBALTPATH did not reduce the CodeView reference to the deterministic basename.'
    }

    $evidence = [ordered]@{
        schema='diagnotes-neutral-path-probe-v1'
        status='PASS'
        mechanism='absolute source paths carried by __FILE__-family macros; physical paths in every compile command'
        control=[ordered]@{
            expected='red'; result='red'
            violation_categories=@($controlPrivacy.violations.category | Sort-Object -Unique)
            private_values_recorded=$false
        }
        neutral=[ordered]@{
            strategy='fresh managed root exposed only to build tools through an unused SUBST drive'
            pdb_alt_path='/PDBALTPATH:%_PDB%'
            private_violation_count=$neutralPrivacy.violations.Count
            neutral_file_marker_present=$true
            clean_neighbor_passed=$true
        }
        pdb_causality=[ordered]@{
            same_neutral_source=$true
            debug_records_present=$true
            control_absolute_reference_present=$true
            treated_basename_only=$true
            shared_module_exe_flags_effective=$true
            control_dll_sha256=(Get-FileHash -LiteralPath $neutralPdbControlDll -Algorithm SHA256).Hash
            treated_dll_sha256=(Get-FileHash -LiteralPath $neutralDll -Algorithm SHA256).Hash
            control_build_recipe_sha256=(Get-FileHash -LiteralPath (Join-Path $neutralPdbControlBuild 'build.ninja') -Algorithm SHA256).Hash
            treated_build_recipe_sha256=(Get-FileHash -LiteralPath (Join-Path $neutralBuild 'build.ninja') -Algorithm SHA256).Hash
        }
        scanner=[ordered]@{ encodings=@('ASCII','UTF-16LE','UTF-16BE'); separators=@('backslash','slash','JSON-escaped'); case_insensitive=$true }
        tools=[ordered]@{
            visual_studio=$tools.vs_version; msvc_toolset=$tools.toolset
            cmake=(& $tools.cmake --version | Select-Object -First 1); ninja=(& $tools.ninja --version | Select-Object -First 1)
        }
        physical_paths_recorded=$false
        probe_script_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        scanner_module_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'RuntimePathPrivacy.psm1') -Algorithm SHA256).Hash
    }
    $evidenceJson = $evidence | ConvertTo-Json -Depth 8
    if ($evidenceJson -match '(?i)[A-Z]:\\Users\\' -or $evidenceJson.IndexOf([Environment]::UserName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'Probe evidence is not sanitized.'
    }
    [IO.File]::WriteAllText((Join-Path $root 'probe-evidence.json'), $evidenceJson + "`n", [Text.UTF8Encoding]::new($false))
    $outputJson = $evidenceJson
}
catch { $primaryError = $_ }
finally {
    if ($mounted -and $drive) {
        try {
            & subst.exe "$drive`:" /D | Out-Null
            if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath "$drive`:\")) {
                throw 'Neutral drive did not unmount cooperatively.'
            }
        } catch { $cleanupErrors.Add('neutral-drive-unmount') }
    }
    try {
        $current = [Environment]::GetEnvironmentVariables('Process')
        foreach ($key in @($current.Keys)) {
            if (-not $snapshot.Contains([string]$key)) { [Environment]::SetEnvironmentVariable([string]$key, $null, 'Process') }
        }
        foreach ($entry in $snapshot.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process') }
    } catch { $cleanupErrors.Add('environment-restoration') }
}
if ($primaryError) {
    if ($cleanupErrors.Count -gt 0) { throw "Probe failed; cleanup failures: $($cleanupErrors -join ',')." }
    throw $primaryError
}
if ($cleanupErrors.Count -gt 0) { throw "Probe cleanup failures: $($cleanupErrors -join ',')." }
$outputJson
