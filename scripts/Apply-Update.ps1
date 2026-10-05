param([Parameter(Mandatory=$true)][string]$Job)
$ErrorActionPreference = 'Stop'
$task = Get-Content -LiteralPath $Job -Raw | ConvertFrom-Json
$stage = [IO.Path]::GetFullPath((Split-Path -Parent $Job))
$appDir = [IO.Path]::GetFullPath($task.Directory).TrimEnd('\')
$updatesRoot = [IO.Path]::GetFullPath($task.UpdatesRoot).TrimEnd('\')
if (-not $stage.StartsWith($updatesRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $stage) -notmatch '^[a-f0-9]{32}$') { throw 'Invalid update staging path.' }
if ($appDir -eq [IO.Path]::GetPathRoot($appDir).TrimEnd('\') -or [IO.Path]::GetFullPath($task.Executable) -ne (Join-Path $appDir 'Relay.exe')) { throw 'Invalid application path.' }
$package = [IO.Path]::GetFullPath($task.Package)
if ((Split-Path -Parent $package) -ne $stage -or $task.Hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid update package.' }
$changed = @()
$backup = Join-Path $stage ('backup-' + [Guid]::NewGuid().ToString('N'))
$success = $false
$canRelaunch = $false
function AppPath([string]$Relative) {
    $target = [IO.Path]::GetFullPath((Join-Path $appDir $Relative))
    if (-not $target.StartsWith($appDir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Update path escapes application directory.' }
    $probe = $target
    while ($probe -and $probe.Length -ge $appDir.Length) {
        if ((Test-Path -LiteralPath $probe) -and ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Application path contains a link.' }
        $probe = Split-Path -Parent $probe
    }
    return $target
}
try {
    $stream = [IO.File]::OpenRead($package)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '') }
    finally { $sha256.Dispose(); $stream.Dispose() }
    if ($actualHash -ne $task.Hash) { throw 'Update checksum mismatch.' }
    $payload = $null
    if ($task.Kind -eq 'portable') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $payload = Join-Path $stage ('payload-' + [Guid]::NewGuid().ToString('N'))
        $zip = [IO.Compression.ZipFile]::OpenRead($package)
        try {
            $prefix = "Relay-$($task.Version)-win-x64/"
            $seen = @{}
            $expanded = 0L
            foreach ($entry in $zip.Entries) {
                $expanded += $entry.Length
                if ($expanded -gt 2GB -or $zip.Entries.Count -gt 10000) { throw 'Update archive is too large.' }
                $name = $entry.FullName.Replace('\','/')
                if (-not $name.StartsWith($prefix, [StringComparison]::Ordinal) -or $name.Contains(':') -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Invalid update archive.' }
                $relative = $name.Substring($prefix.Length)
                if ($relative -eq '') { continue }
                if (($relative.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' }).Count -gt 0) { throw 'Invalid archive path.' }
                $destination = [IO.Path]::GetFullPath((Join-Path $payload $relative))
                if (-not $destination.StartsWith($payload + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escapes staging.' }
                if ($seen.ContainsKey($destination)) { throw 'Duplicate archive path.' }
                $seen[$destination] = $true
                if ($name.EndsWith('/')) { [IO.Directory]::CreateDirectory($destination) | Out-Null; continue }
                [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
            }
        } finally { $zip.Dispose() }
        foreach ($required in @('Relay.exe','Relay.dll','Relay.deps.json','Relay.runtimeconfig.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $payload $required))) { throw 'Incomplete update archive.' }
        }
    } elseif ($task.Kind -ne 'installed') { throw 'Unknown update type.' }
    Set-Content -LiteralPath (Join-Path $stage 'ready') -Value 'ready'
    if ($task.ProcessId -gt 0) {
        $running = Get-Process -Id $task.ProcessId -ErrorAction SilentlyContinue
        if ($running -and $running.StartTime.ToUniversalTime().Ticks -eq $task.Started) {
            if (-not $running.WaitForExit(60000)) { throw 'Relay did not close.' }
        }
    }
    $canRelaunch = $true
    if ($task.Kind -eq 'installed') {
        $setup = Start-Process -FilePath $package -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="' + $appDir + '"'),('/LOG="' + (Join-Path $updatesRoot 'installer.log') + '"')) -WindowStyle Hidden -PassThru -Wait
        $setup.Refresh()
        if ($setup.ExitCode -ne 0) { throw "Installer exited with $($setup.ExitCode)." }
    } else {
        foreach ($file in Get-ChildItem -LiteralPath $payload -File -Recurse) {
            $relative = $file.FullName.Substring($payload.Length + 1)
            $destination = AppPath $relative
            $old = Join-Path $backup $relative
            $existed = Test-Path -LiteralPath $destination
            if ($existed) {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $old)) | Out-Null
                Copy-Item -LiteralPath $destination -Destination $old
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            $replacement = $destination + '.relay-update-' + [Guid]::NewGuid().ToString('N')
            try {
                Copy-Item -LiteralPath $file.FullName -Destination $replacement
                if ($existed) { [IO.File]::Replace($replacement, $destination, [NullString]::Value) }
                else { [IO.File]::Move($replacement, $destination) }
                $changed += [pscustomobject]@{ Destination=$destination; Backup=$old; Existed=$existed }
            } finally {
                if (Test-Path -LiteralPath $replacement) { Remove-Item -LiteralPath $replacement -Force }
            }
        }
    }
    $success = $true
    @{Success=$true;Version=$task.Version} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updatesRoot 'result.json')
} catch {
    $failure = $_.Exception.Message
    foreach ($item in ($changed | Sort-Object -Property Destination -Descending)) {
        try {
            if ($item.Existed) { Copy-Item -LiteralPath $item.Backup -Destination $item.Destination -Force }
            elseif (Test-Path -LiteralPath $item.Destination) { Remove-Item -LiteralPath $item.Destination -Force }
        } catch { $failure += ' Rollback: ' + $_.Exception.Message }
    }
    @{Success=$false;Error=$failure} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updatesRoot 'result.json')
} finally {
    if ($canRelaunch -and -not $task.SkipRelaunch -and (Test-Path -LiteralPath $task.Executable)) {
        Start-Process -FilePath $task.Executable -WorkingDirectory $appDir
    }
    if ($success -and $stage.StartsWith($updatesRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $stage) -match '^[a-f0-9]{32}$') {
        try { Remove-Item -LiteralPath $stage -Recurse -Force } catch { }
    }
}
if ($success) { exit 0 } else { exit 1 }
