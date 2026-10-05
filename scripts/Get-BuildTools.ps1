$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolsRoot = Join-Path $projectRoot '.tools'
$compilerRoot = Join-Path $toolsRoot 'inno\compiler'
$compiler = Join-Path $compilerRoot 'ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $download = Join-Path $toolsRoot 'inno\setup.exe'
    New-Item -ItemType Directory -Path (Split-Path $download) -Force | Out-Null
    Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_1/innosetup-6.7.1.exe' -OutFile $download -UseBasicParsing
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne '4D11E8050B6185E0D49BD9E8CC661A7A59F44959A621D31D11033124C4E8A7B0') { throw 'Inno Setup checksum mismatch.' }
    $tool = Start-Process -FilePath $download -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/PORTABLE=1', '/CURRENTUSER', '/NOICONS', ('/DIR="' + $compilerRoot + '"') -WindowStyle Hidden -Wait -PassThru
    if ($tool.ExitCode -ne 0) { throw 'Portable compiler extraction failed.' }
}
$bootstrapper = Join-Path $toolsRoot 'webview2\MicrosoftEdgeWebview2Setup.exe'
if (-not (Test-Path -LiteralPath $bootstrapper)) {
    New-Item -ItemType Directory -Path (Split-Path $bootstrapper) -Force | Out-Null
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $bootstrapper -UseBasicParsing
}
$signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'WebView2 bootstrapper does not have a valid Microsoft signature.' }
[pscustomobject]@{ Compiler = $compiler; Bootstrapper = $bootstrapper }
