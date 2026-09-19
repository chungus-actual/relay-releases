$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $projectRoot ('.test-data\updater-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$updatesRoot = Join-Path $testRoot 'Updates'
[IO.Directory]::CreateDirectory($updatesRoot) | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
function Test-Update([string]$Case) {
    $appDir = Join-Path $testRoot $Case
    [IO.Directory]::CreateDirectory($appDir) | Out-Null
    $names = @('Relay.exe','Relay.dll','Relay.deps.json','Relay.runtimeconfig.json','z-locked.txt')
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $appDir $name), 'old') }
    [IO.File]::WriteAllText((Join-Path $appDir 'user-file.txt'), 'keep')
    $stage = Join-Path $updatesRoot ([Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $package = Join-Path $stage 'Relay-9.0.0-win-x64.zip'
    $archive = [IO.Compression.ZipFile]::Open($package, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $names) {
            $entry = $archive.CreateEntry('Relay-9.0.0-win-x64/' + $name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write('new') } finally { $writer.Dispose() }
        }
        if ($Case -eq 'traversal') {
            $entry = $archive.CreateEntry('Relay-9.0.0-win-x64/../../escaped.txt')
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write('escape') } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
    $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($Case -eq 'checksum') { $hash = '0' * 64 }
    $job = Join-Path $stage 'job.json'
    @{Directory=$appDir;Executable=(Join-Path $appDir 'Relay.exe');UpdatesRoot=$updatesRoot;Package=$package;Hash=$hash;Version='9.0.0';Kind='portable';ProcessId=0;Started=0;SkipRelaunch=$true} | ConvertTo-Json | Set-Content -LiteralPath $job
    $locked = $null
    $previousModulePath = $env:PSModulePath
    try {
        if ($Case -eq 'rollback') { $locked = [IO.File]::Open((Join-Path $appDir 'z-locked.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
        $env:PSModulePath = Join-Path $testRoot 'empty-modules'
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot 'Apply-Update.ps1') + '"'),'-Job',('"' + $job + '"')) -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Updater fixture timed out.' }
        $process.Refresh()
        $expected = if ($Case -eq 'success') { 0 } else { 1 }
        if ($process.ExitCode -ne $expected) { throw "Unexpected helper exit: $Case $($process.ExitCode)" }
    } finally { $env:PSModulePath = $previousModulePath; if ($locked) { $locked.Dispose() } }
    foreach ($name in $names) {
        $expected = if ($Case -eq 'success') { 'new' } else { 'old' }
        if ([IO.File]::ReadAllText((Join-Path $appDir $name)) -ne $expected) { throw "Wrong $Case contents: $name" }
    }
    if ([IO.File]::ReadAllText((Join-Path $appDir 'user-file.txt')) -ne 'keep') { throw 'User file changed.' }
    if (Test-Path -LiteralPath (Join-Path $updatesRoot 'escaped.txt')) { throw 'Archive escaped staging.' }
    if ($Case -eq 'success' -and (Test-Path -LiteralPath $stage)) { throw 'Successful staging was not cleaned up.' }
    Write-Host "PASS: portable updater $Case"
}
foreach ($case in @('success','checksum','traversal','rollback')) { Test-Update $case }
