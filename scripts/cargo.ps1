# Forward Cargo arguments without requiring global shims or shell activation.
# Quote '--' when forwarding rustc/test arguments through this PowerShell script.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/bootstrap.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & $CatengarCargo @args
    $code = $LASTEXITCODE
} finally { Pop-Location }
exit $code
