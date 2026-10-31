param([switch]$BuildOnly, [switch]$Test, [switch]$Preview, [switch]$Debug, [switch]$Diagnose)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/bootstrap.ps1"
Push-Location $root
try {
    if ($Test) {
        & cargo test --locked --all-targets
        if ($LASTEXITCODE) { throw 'Rust tests failed' }
        & cargo test --locked -p nsh-platform-windows --lib input::tests::keyboard
        if ($LASTEXITCODE) { throw 'NSH Windows keyboard tests failed' }
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/test-updater.ps1
        if ($LASTEXITCODE) { throw 'Updater tests failed' }
        return
    }
    $buildArgs = @('build', '--locked', '--bins')
    if (!$Debug) { $buildArgs += '--release' }
    & cargo @buildArgs
    if ($LASTEXITCODE) { throw 'Rust build failed' }
    $profile = if ($Debug) { 'debug' } else { 'release' }
    $bin = Join-Path $root "target/x86_64-pc-windows-msvc/$profile"
    & "$PSScriptRoot/stage-runtime.ps1" -BuildDir $bin
    if ($Diagnose) { & (Join-Path $bin 'catengar-diagnose.exe'); return }
    if (!$BuildOnly) {
        $appArgs = @('--desktop')
        if ($Preview) { $appArgs += '--preview' }
        Start-Process -FilePath (Join-Path $bin 'catengar.exe') -ArgumentList $appArgs -WindowStyle Hidden
    }
} finally { Pop-Location }
