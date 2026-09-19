param([switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $SmokeTest) {
    [System.Threading.Mutex]$runningInstance = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\Relay.Personal', [ref]$runningInstance)) {
        $runningInstance.Dispose()
        throw 'Quit Relay from its tray menu, then run Launch.cmd again to build and open the latest code.'
    }
}
$env:DOTNET_CLI_HOME = Join-Path $projectRoot '.tools/cli'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:NUGET_PACKAGES = Join-Path $projectRoot '.tools/packages'
$dotnet = Join-Path $projectRoot '.tools/dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
$developmentPath = Join-Path $projectRoot $(if ($SmokeTest) { 'dist/dev-smoke' } else { 'dist/dev' })
Push-Location -LiteralPath $projectRoot
try {
    Write-Host 'Building your local Relay...'
    & $dotnet publish Relay.csproj -c Release -r win-x64 --self-contained true -p:RestoreLockedMode=true -o $developmentPath
    if ($LASTEXITCODE -ne 0) { throw 'Build failed; Relay was not launched.' }
    Set-Content -LiteralPath (Join-Path $developmentPath 'relay-local-build') -Value 'Local iteration'
    $exe = Join-Path $developmentPath 'Relay.exe'
    if ($SmokeTest) {
        $app = Start-Process -FilePath $exe -ArgumentList '--smoke-test' -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru
        if (-not $app.WaitForExit(120000)) { $app.Kill(); throw 'Local smoke test timed out.' }
        $app.Refresh()
        if ($app.ExitCode -ne 0) { throw 'Local smoke test failed. See artifacts/smoke-test.txt.' }
        Get-Content -LiteralPath 'artifacts/smoke-test.txt'
    } else {
        Start-Process -FilePath $exe -WorkingDirectory $projectRoot
    }
} finally { Pop-Location }
