param([switch]$Package, [switch]$SmokeTest, [switch]$Installer, [string]$ExpectedVersion)
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:DOTNET_CLI_HOME = Join-Path $projectRoot '.tools\cli'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:NUGET_PACKAGES = Join-Path $projectRoot '.tools\packages'
$dotnet = Join-Path $projectRoot '.tools\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
[xml]$project = Get-Content -LiteralPath (Join-Path $projectRoot 'Relay.csproj')
$version = [string]$project.Project.PropertyGroup.Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be major.minor.patch.' }
if ($ExpectedVersion -and $ExpectedVersion -ne $version) { throw "Release tag version $ExpectedVersion does not match project version $version." }
if ($Installer) { $Package = $true; $tools = & (Join-Path $PSScriptRoot 'Get-BuildTools.ps1') }
Push-Location -LiteralPath $projectRoot
try {
    & $dotnet restore --locked-mode
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }
    & $dotnet build -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    if ($SmokeTest) {
        $app = Start-Process -FilePath $dotnet -ArgumentList 'bin\Release\net10.0-windows\Relay.dll', '--smoke-test' -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru
        if (-not $app.WaitForExit(120000)) { $app.Kill(); throw 'Smoke test timed out.' }
        $app.Refresh()
        if ($app.ExitCode -ne 0) { throw 'Smoke test failed. See artifacts\smoke-test.txt.' }
        Get-Content -LiteralPath 'artifacts\smoke-test.txt'
    }
    if ($Package) {
        $packageName = 'Relay-' + $version + '-win-x64'
        $packagePath = Join-Path $projectRoot ('dist\' + $packageName)
        & $dotnet publish -c Release -r win-x64 --self-contained true -p:RestoreLockedMode=true -o $packagePath
        if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
        Copy-Item -LiteralPath 'README.md' -Destination (Join-Path $packagePath 'README.md')
        if (Test-Path -LiteralPath 'docs') { Copy-Item -LiteralPath 'docs' -Destination $packagePath -Recurse -Force }
        $zip = Join-Path $projectRoot ('dist\' + $packageName + '.zip')
        Compress-Archive -LiteralPath $packagePath -DestinationPath $zip -Force
        $assets = @($zip)
        if ($Installer) {
            & $tools.Compiler ('/DAppVersion=' + $version) ('/DPublishDir=' + $packagePath) ('/DBootstrapper=' + $tools.Bootstrapper) ('/O' + (Join-Path $projectRoot 'dist')) (Join-Path $projectRoot 'installer\Relay.iss')
            if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
            $assets += Join-Path $projectRoot ('dist\Relay-' + $version + '-Setup-x64.exe')
        }
        $hashes = foreach ($asset in $assets) { (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [System.IO.Path]::GetFileName($asset) }
        $hashes | Set-Content -LiteralPath 'dist\SHA256SUMS.txt' -Encoding Ascii
    }
} finally { Pop-Location }
