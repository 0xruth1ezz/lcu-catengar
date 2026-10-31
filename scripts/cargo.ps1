# Forward Cargo arguments without requiring global shims or shell activation.
# Quote '--' when forwarding rustc/test arguments through this PowerShell script.
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    . "$PSScriptRoot/bootstrap.ps1"
    & $CatengarCargo @args
    $code = $LASTEXITCODE
} finally { Pop-Location }
exit $code
