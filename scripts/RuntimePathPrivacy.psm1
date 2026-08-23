Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPrivacyMarker {
    param([Parameter(Mandatory)][string]$Value)
    ([regex]::Replace($Value.Replace('\', '/'), '/+', '/')).TrimEnd('/').ToLowerInvariant()
}

function Get-PathPrivacyMarkerSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PhysicalRoots,
        [string[]]$LeafPhysicalRoots = @(),
        [Parameter(Mandatory)][string]$UserProfile,
        [Parameter(Mandatory)][string]$UserName
    )

    $markers = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    function Add-Marker([string]$Id, [string]$Value) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        $normalized = Get-NormalizedPrivacyMarker $Value
        $key = "$Id`0$normalized"
        if ($seen.Add($key)) { $markers.Add([pscustomobject]@{ id=$Id; value=$normalized }) }
    }

    Add-Marker 'explicit-user-profile' $UserProfile
    foreach ($root in $PhysicalRoots) {
        $full = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        Add-Marker 'physical-root' $full
    }
    foreach ($root in $LeafPhysicalRoots) {
        $full = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        Add-Marker 'physical-root-leaf' ([IO.Path]::GetFileName($full))
        $normalized = Get-NormalizedPrivacyMarker $full
        foreach ($anchor in @('/appdata/', '/diagnotes/runtimebuild/')) {
            $position = $normalized.IndexOf($anchor, [StringComparison]::Ordinal)
            if ($position -ge 0) { Add-Marker 'physical-root-derived' $normalized.Substring($position + 1) }
        }
    }
    [pscustomobject]@{ markers=@($markers); username=$UserName.ToLowerInvariant() }
}

function Test-PrivacyTextView {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$MarkerSet
    )

    $normalized = ([regex]::Replace($Text.Replace('\', '/'), '/+', '/')).ToLowerInvariant()
    $categories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($normalized -match '(?i)[a-z]:/+users/+') { [void]$categories.Add('generic-user-profile') }
    foreach ($marker in $MarkerSet.markers) {
        if ($normalized.IndexOf([string]$marker.value, [StringComparison]::Ordinal) -ge 0) {
            [void]$categories.Add([string]$marker.id)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MarkerSet.username)) {
        $escaped = [regex]::Escape([string]$MarkerSet.username)
        if ($normalized -match "(?:^|[\x00\s/|])$escaped(?:$|[\x00\s/|])") {
            [void]$categories.Add('isolated-username')
        }
    }
    @($categories)
}

function Find-PrivatePathByteViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$LiteralPaths,
        [Parameter(Mandatory)][string[]]$PhysicalRoots,
        [string[]]$LeafPhysicalRoots = @(),
        [Parameter(Mandatory)][string]$UserProfile,
        [Parameter(Mandatory)][string]$UserName,
        [string]$RelativeTo
    )

    $markerSet = Get-PathPrivacyMarkerSet -PhysicalRoots $PhysicalRoots -LeafPhysicalRoots $LeafPhysicalRoots -UserProfile $UserProfile -UserName $UserName
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($path in $LiteralPaths) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item -is [IO.DirectoryInfo]) {
            foreach ($file in Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force) { $files.Add($file) }
        }
        else { $files.Add($item) }
    }

    $violations = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $buffer = [byte[]]::new(1MB)
            $carry = [byte[]]::new(0)
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $combined = [byte[]]::new($carry.Length + $read)
                if ($carry.Length) { [Array]::Copy($carry, 0, $combined, 0, $carry.Length) }
                [Array]::Copy($buffer, 0, $combined, $carry.Length, $read)
                $views = @([pscustomobject]@{ encoding='ascii'; text=[Text.Encoding]::ASCII.GetString($combined) })
                foreach ($offset in @(0, 1)) {
                    $length = $combined.Length - $offset
                    if ($length -gt 1) {
                        if (($length % 2) -ne 0) { $length-- }
                        $views += [pscustomobject]@{ encoding="utf16le-offset$offset"; text=[Text.Encoding]::Unicode.GetString($combined, $offset, $length) }
                        $views += [pscustomobject]@{ encoding="utf16be-offset$offset"; text=[Text.Encoding]::BigEndianUnicode.GetString($combined, $offset, $length) }
                    }
                }
                foreach ($view in $views) {
                    foreach ($category in @(Test-PrivacyTextView -Text $view.text -MarkerSet $markerSet)) {
                        [void]$found.Add("$($view.encoding)|$category")
                    }
                }
                $carryLength = [Math]::Min(8192, $combined.Length)
                $carry = [byte[]]::new($carryLength)
                [Array]::Copy($combined, $combined.Length - $carryLength, $carry, 0, $carryLength)
            }
        }
        finally { $stream.Dispose() }

        foreach ($entry in $found) {
            $parts = $entry.Split('|', 2)
            $label = if ($RelativeTo) { [IO.Path]::GetRelativePath($RelativeTo, $file.FullName).Replace('\', '/') } else { $file.Name }
            $violations.Add([pscustomobject]@{ file=$label; encoding=$parts[0]; category=$parts[1] })
        }
    }
    @($violations | Sort-Object file, encoding, category)
}

function Test-PathPrivacyContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$LiteralPaths,
        [Parameter(Mandatory)][string[]]$PhysicalRoots,
        [string[]]$LeafPhysicalRoots = @(),
        [Parameter(Mandatory)][string]$UserProfile,
        [Parameter(Mandatory)][string]$UserName,
        [string]$RelativeTo
    )

    $violations = @(Find-PrivatePathByteViolations -LiteralPaths $LiteralPaths -PhysicalRoots $PhysicalRoots -LeafPhysicalRoots $LeafPhysicalRoots `
        -UserProfile $UserProfile -UserName $UserName -RelativeTo $RelativeTo)
    [pscustomobject]@{
        passed = $violations.Count -eq 0
        scanned_files = @($LiteralPaths | ForEach-Object {
            $item = Get-Item -LiteralPath $_ -Force
            if ($item -is [IO.DirectoryInfo]) { @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force).Count } else { 1 }
        } | Measure-Object -Sum).Sum
        violations = $violations
    }
}

function Test-NeutralPathMarkerPresence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$NeutralMarker
    )

    $needle = (Get-NormalizedPrivacyMarker $NeutralMarker)
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $views = @(
        [Text.Encoding]::ASCII.GetString($bytes),
        [Text.Encoding]::Unicode.GetString($bytes),
        [Text.Encoding]::BigEndianUnicode.GetString($bytes)
    )
    foreach ($view in $views) {
        if ((Get-NormalizedPrivacyMarker $view).IndexOf($needle, [StringComparison]::Ordinal) -ge 0) { return $true }
    }
    return $false
}

function Get-FreeNeutralBuildDrive {
    [CmdletBinding()]
    param()

    $substText = (& subst.exe | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate SUBST drives.' }
    foreach ($letter in @('R','Q','P','O','N','M','L','K')) {
        if (-not (Test-Path -LiteralPath "$letter`:\") -and $substText -notmatch "(?im)^$letter`:\\") {
            return $letter
        }
    }
    throw 'No approved neutral build drive is free.'
}

function Mount-NeutralBuildRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PhysicalRoot)

    $resolvedRoot = [IO.Path]::GetFullPath($PhysicalRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw 'The physical build root must exist before neutral-drive mounting.'
    }
    $rootItem = Get-Item -LiteralPath $resolvedRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The physical build root cannot be a reparse point.'
    }

    $letter = Get-FreeNeutralBuildDrive
    $sentinelName = '.diagnotes-neutral-' + [Guid]::NewGuid().ToString('N') + '.sentinel'
    $sentinelPath = Join-Path $resolvedRoot $sentinelName
    [IO.File]::WriteAllText($sentinelPath, 'diagnotes-neutral-build-root', [Text.UTF8Encoding]::new($false))
    try {
        & subst.exe "$letter`:" $resolvedRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Neutral build drive mount failed.' }
        $neutralRoot = "$letter`:\"
        $neutralSentinel = Join-Path $neutralRoot $sentinelName
        if (-not (Test-Path -LiteralPath $neutralSentinel -PathType Leaf) -or
            [IO.File]::ReadAllText($neutralSentinel) -cne 'diagnotes-neutral-build-root') {
            throw 'Neutral build drive sentinel verification failed.'
        }
        return [pscustomobject]@{
            drive_letter="$letter`:"
            neutral_root=$neutralRoot
            physical_root=$resolvedRoot
            sentinel_name=$sentinelName
            mounted=$true
        }
    }
    catch {
        & subst.exe "$letter`:" /D 2>$null | Out-Null
        if (Test-Path -LiteralPath $sentinelPath -PathType Leaf) { Remove-Item -LiteralPath $sentinelPath -Force }
        throw
    }
}

function Dismount-NeutralBuildRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mount)

    $drive = [string]$Mount.drive_letter
    $neutralRoot = [string]$Mount.neutral_root
    $sentinelName = [string]$Mount.sentinel_name
    if ($drive -notmatch '^[A-Z]:$' -or $neutralRoot -cne ($drive + '\')) {
        throw 'Neutral build mount metadata is invalid.'
    }
    $neutralSentinel = Join-Path $neutralRoot $sentinelName
    if (-not (Test-Path -LiteralPath $neutralSentinel -PathType Leaf) -or
        [IO.File]::ReadAllText($neutralSentinel) -cne 'diagnotes-neutral-build-root') {
        throw 'Neutral build drive no longer resolves to its sentinel.'
    }
    Remove-Item -LiteralPath $neutralSentinel -Force
    & subst.exe $drive /D | Out-Null
    $substText = (& subst.exe | Out-String)
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $neutralRoot) -or
        $substText -match ("(?im)^" + [regex]::Escape($drive) + "\\")) {
        throw 'Neutral build drive did not unmount cooperatively.'
    }
    return [pscustomobject]@{ drive_letter=$drive; unmounted=$true; sentinel_removed=$true }
}

function Assert-NeutralBuildMount {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mount)

    $neutralRoot = [string]$Mount.neutral_root
    $sentinelName = [string]$Mount.sentinel_name
    if ([string]::IsNullOrWhiteSpace($neutralRoot) -or [string]::IsNullOrWhiteSpace($sentinelName)) {
        throw 'Neutral build mount metadata is incomplete.'
    }
    $neutralSentinel = Join-Path $neutralRoot $sentinelName
    if (-not (Test-Path -LiteralPath $neutralSentinel -PathType Leaf) -or
        [IO.File]::ReadAllText($neutralSentinel) -cne 'diagnotes-neutral-build-root') {
        throw 'Neutral build drive sentinel verification failed.'
    }
    return $true
}

Export-ModuleMember -Function @(
    'Get-PathPrivacyMarkerSet', 'Find-PrivatePathByteViolations',
    'Test-PathPrivacyContract', 'Test-NeutralPathMarkerPresence',
    'Get-FreeNeutralBuildDrive', 'Mount-NeutralBuildRoot', 'Dismount-NeutralBuildRoot',
    'Assert-NeutralBuildMount'
)
