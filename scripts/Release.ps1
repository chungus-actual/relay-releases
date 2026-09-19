$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location -LiteralPath $projectRoot
try {
    [xml]$project = Get-Content -LiteralPath 'Relay.csproj'
    $version = [string]$project.Project.PropertyGroup.Version
    if ([version]$version -ge [version]'0.6.3') { throw 'For unified releases, follow docs/development.md and use scripts/Publish-Release.py.' }
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be major.minor.patch.' }
    if (-not (Test-Path -LiteralPath ("docs\releases\$version.md"))) { throw 'Add release notes before tagging.' }
    $changes = git status --porcelain
    if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Commit all changes before releasing.' }
    $branch = git branch --show-current
    if ($branch -ne 'main') { throw 'Release from main.' }
    git fetch origin main
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify origin/main.' }
    $head = git rev-parse HEAD
    $remote = git rev-parse origin/main
    if ($head -ne $remote) { throw 'Push main before releasing.' }
    git tag -a "v$version" -m "Relay $version"
    if ($LASTEXITCODE -ne 0) { throw 'Could not create version tag; it may already exist.' }
    git push origin "v$version"
    if ($LASTEXITCODE -ne 0) { throw "Tag push failed. Retry git push origin v$version; do not replace published tags." }
    Write-Host "Release pipeline started for v$version. Waiting for verified packages…"
    & (Join-Path $PSScriptRoot 'Publish-Releases.ps1') -Version $version -Wait
} finally { Pop-Location }
