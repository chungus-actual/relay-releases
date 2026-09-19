$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw 'Installer lifecycle tests run on an isolated CI runner, not your normal Windows account.' }
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
[xml]$project = Get-Content -LiteralPath (Join-Path $projectRoot 'Relay.csproj')
$version = [string]$project.Project.PropertyGroup.Version
$installer = Join-Path $projectRoot ('dist\Relay-' + $version + '-Setup-x64.exe')
$installPath = Join-Path $projectRoot '.test-data\installed-relay'
$exe = Join-Path $installPath 'Relay.exe'
$uninstaller = Join-Path $installPath 'unins000.exe'
$startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupCommand = '"' + $exe + '" --startup'
$profile = Join-Path $env:LOCALAPPDATA 'Relay'
$marker = Join-Path $profile 'installer-preservation-test.txt'
function Run-Checked([string]$File, [string[]]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(180000)) { $process.Kill(); throw "Timed out: $File" }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Process failed ($($process.ExitCode)): $File" }
}
$installArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/DIR="' + $installPath + '"'))
Run-Checked $installer ($installArgs + ('/LOG="' + (Join-Path $projectRoot 'artifacts\installer-install.log') + '"'))
if (-not (Test-Path -LiteralPath $exe)) { throw 'Installed executable missing.' }
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Relay.lnk'
if (-not (Test-Path -LiteralPath $shortcutPath)) { throw 'Start-menu shortcut missing.' }
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
if ($shortcut.TargetPath -ne $exe) { throw 'Start-menu shortcut targets the wrong executable.' }
Run-Checked $exe @('--smoke-test')
New-Item -ItemType Directory -Path $profile -Force | Out-Null
Set-Content -LiteralPath $marker -Value 'preserve this profile'
if (-not (Test-Path -LiteralPath $startupKey)) { New-Item -Path $startupKey -Force | Out-Null }
if (Get-ItemProperty -LiteralPath $startupKey -Name Relay -ErrorAction SilentlyContinue) { throw "Unexpected pre-existing Relay startup registration." }
Set-ItemProperty -LiteralPath $startupKey -Name Relay -Value $startupCommand
# Exercise the same installer handoff used by the app, inside the disposable CI account.
$updatesRoot = Join-Path $projectRoot '.test-data\installer-updates'
$stage = Join-Path $updatesRoot ([Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
$package = Join-Path $stage ([IO.Path]::GetFileName($installer))
Copy-Item -LiteralPath $installer -Destination $package
$job = Join-Path $stage 'job.json'
@{Directory=$installPath;Executable=$exe;UpdatesRoot=$updatesRoot;Package=$package;Hash=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash;Version=$version;Kind='installed';ProcessId=0;Started=0;SkipRelaunch=$true} | ConvertTo-Json | Set-Content -LiteralPath $job
try {
    Run-Checked (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot 'Apply-Update.ps1') + '"'),'-Job',('"' + $job + '"'))
} finally {
    foreach ($name in @('result.json','installer.log')) {
        $report = Join-Path $updatesRoot $name
        if (Test-Path -LiteralPath $report) {
            Copy-Item -LiteralPath $report -Destination (Join-Path $projectRoot ('artifacts\update-' + $name + '.txt')) -Force
            if ($name -eq 'result.json') { Get-Content -LiteralPath $report }
        }
    }
}
if (-not (Test-Path -LiteralPath $exe) -or -not ((Get-Content -LiteralPath (Join-Path $updatesRoot 'result.json') -Raw | ConvertFrom-Json).Success)) { throw 'Installed update failed.' }
if ((Get-ItemPropertyValue -LiteralPath $startupKey -Name Relay) -ne $startupCommand) { throw 'Reinstall changed startup registration.' }
Run-Checked $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
if (Test-Path -LiteralPath $exe) { throw 'Uninstall left the application executable.' }
if (Test-Path -LiteralPath $shortcutPath) { throw 'Uninstall left the Start-menu shortcut.' }
if (-not (Test-Path -LiteralPath $marker)) { throw 'Uninstall removed the user profile.' }
if (Get-ItemProperty -LiteralPath $startupKey -Name Relay -ErrorAction SilentlyContinue) { throw 'Uninstall left its startup registration.' }
Remove-Item -LiteralPath $marker
Write-Host 'PASS: install, shortcut launch target, installed-app smoke, reinstall, startup cleanup, profile-preserving uninstall.'
