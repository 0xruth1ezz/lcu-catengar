param([switch]$BuildOnly, [switch]$Diagnose, [switch]$Test)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/bootstrap.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $zig = '.tools/zig-x86_64-windows-0.16.0/zig.exe'
    if ($Test) { & $zig build test-target test-core test-images test-ime test-window test-auth; if ($LASTEXITCODE) { throw 'Tests failed' }; return }
    if ($Diagnose) { & $zig build diagnose; if ($LASTEXITCODE) { throw 'Diagnostics failed' }; return }
    & $zig build -Doptimize=ReleaseSafe
    if ($LASTEXITCODE) { throw 'Build failed' }
    if (!$BuildOnly) { Start-Process -FilePath (Join-Path (Get-Location) 'zig-out/bin/catengar.exe') -WindowStyle Normal }
} finally { Pop-Location }
