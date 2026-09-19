param([ValidateRange(60,86400)][int]$Seconds = 600, [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $NoBuild) { & (Join-Path $PSScriptRoot 'Build.ps1') }
$env:DOTNET_CLI_HOME = Join-Path $projectRoot '.tools\cli'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:NUGET_PACKAGES = Join-Path $projectRoot '.tools\packages'
$dotnet = Join-Path $projectRoot '.tools\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet -ErrorAction Stop).Source }
Push-Location -LiteralPath $projectRoot
try {
    $arguments = 'bin\Release\net10.0-windows\Relay.dll --soak-test --soak-seconds ' + $Seconds
    $test = Start-Process -FilePath $dotnet -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -Wait -PassThru
    $resultPath = Get-Content -LiteralPath 'artifacts\latest-memory-soak.txt'
    Get-Content -LiteralPath (Join-Path $resultPath 'result.txt')
    if ($test.ExitCode -ne 0) { throw "Memory soak failed. See $resultPath" }
} finally { Pop-Location }
