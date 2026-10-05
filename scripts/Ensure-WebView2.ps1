$ErrorActionPreference = 'Stop'
$tools = & (Join-Path $PSScriptRoot 'Get-BuildTools.ps1')
$client = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
function Test-Runtime {
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
            $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $runtimeKey = $key.OpenSubKey($client)
                if ($runtimeKey) { try { $version = $runtimeKey.GetValue('pv'); if ($version -and $version -ne '0.0.0.0') { return $true } } finally { $runtimeKey.Dispose() } }
            } finally { $key.Dispose() }
        }
    }
    return $false
}
if (-not (Test-Runtime)) {
    $install = Start-Process -FilePath $tools.Bootstrapper -ArgumentList '/silent', '/install' -WindowStyle Hidden -Wait -PassThru
    if ($install.ExitCode -notin @(0,3010) -or -not (Test-Runtime)) { throw 'WebView2 Runtime installation failed.' }
}
Write-Host 'WebView2 Runtime is available.'
