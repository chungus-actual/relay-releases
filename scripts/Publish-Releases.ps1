param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [switch]$Wait
)
if ([version]$Version -ge [version]'0.6.3') {
    throw 'Unified releases require both platforms. Use scripts/Publish-Release.py on the signing Mac; see docs/development.md.'
}
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = Join-Path $projectRoot '.tools\github-cli\portable\bin\gh.exe' }
if (-not (Test-Path -LiteralPath $gh)) { throw 'GitHub CLI is required.' }
$previousGithubConfig = $env:GH_CONFIG_DIR
$localGithubConfig = Join-Path $projectRoot '.tools\github-auth'
if (-not $env:GH_CONFIG_DIR -and (Test-Path -LiteralPath (Join-Path $localGithubConfig 'hosts.yml'))) { $env:GH_CONFIG_DIR = $localGithubConfig }
try {
$source = 'chungus-actual/relay'
$public = 'chungus-actual/relay-releases'
$tag = "v$Version"
function Find-Release([string]$Repository, [string]$Fields) {
    # Windows PowerShell treats native stderr as an error even when redirected.
    $ErrorActionPreference = 'Continue'
    $json = & $gh release view $tag --repo $Repository --json $Fields 2>$null
    if ($LASTEXITCODE -eq 0) { return ($json | ConvertFrom-Json) }
    return $null
}
# Run with the operator's gh login. No GitHub credential is shipped in Relay or copied into CI.
$deadline = [DateTime]::UtcNow.AddMinutes(30)
do {
    $release = Find-Release $source 'isDraft,assets'
    $found = $null -ne $release -and -not $release.isDraft -and $release.assets.Count -ge 3
    if ($found) { break }
    if (-not $Wait -or [DateTime]::UtcNow -gt $deadline) { throw "Private release $tag is not ready. Retry Publish-Releases.ps1 -Version $Version -Wait." }
    Start-Sleep -Seconds 10
} while ($true)
$directory = Join-Path $projectRoot ('dist\public-' + $Version + '-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$names = @("Relay-$Version-Setup-x64.exe", "Relay-$Version-win-x64.zip", 'SHA256SUMS.txt')
foreach ($name in $names) {
    & $gh release download $tag --repo $source --pattern $name --dir $directory
    if ($LASTEXITCODE -ne 0) { throw "Could not download $name." }
}
$checksums = Get-Content -LiteralPath (Join-Path $directory 'SHA256SUMS.txt')
foreach ($name in $names[0..1]) {
    $lines = @($checksums | Where-Object { $_ -match ('^[a-fA-F0-9]{64}\s+\*?' + [Regex]::Escape($name) + '$') })
    if ($lines.Count -ne 1) { throw "Missing or duplicate checksum: $name." }
    $expected = $lines[0].Substring(0, 64)
    if ((Get-FileHash -LiteralPath (Join-Path $directory $name) -Algorithm SHA256).Hash -ne $expected) { throw "Checksum failed: $name." }
}
$existing = Find-Release $public 'isDraft'
if ($null -ne $existing) {
    if (-not $existing.isDraft) { throw "Public $tag already exists; published releases are immutable." }
} else {
    & $gh release create $tag --repo $public --title "Relay $Version" --notes-file (Join-Path $projectRoot ('docs\releases\' + $Version + '.md')) --draft
    if ($LASTEXITCODE -ne 0) { throw 'Could not create public release draft.' }
}
foreach ($name in $names) {
    & $gh release upload $tag (Join-Path $directory $name) --repo $public --clobber
    if ($LASTEXITCODE -ne 0) { throw "Could not upload $name; public release remains a draft." }
}
$uploaded = (& $gh release view $tag --repo $public --json assets | ConvertFrom-Json).assets
if ($LASTEXITCODE -ne 0 -or $uploaded.Count -ne 3) { throw 'Public asset list is incomplete or unexpected.' }
foreach ($name in $names) {
    $asset = @($uploaded | Where-Object name -eq $name)
    $hash = (Get-FileHash -LiteralPath (Join-Path $directory $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($asset.Count -ne 1 -or $asset[0].digest -ne ('sha256:' + $hash)) { throw "Uploaded digest mismatch: $name." }
}
& $gh release edit $tag --repo $public --draft=false --latest
if ($LASTEXITCODE -ne 0) { throw 'Could not publish verified release.' }
Write-Host "Published https://github.com/$public/releases/tag/$tag"

} finally { $env:GH_CONFIG_DIR = $previousGithubConfig }
