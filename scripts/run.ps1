param([switch]$BuildOnly, [switch]$Test, [switch]$Preview, [switch]$Debug, [switch]$Release, [switch]$Diagnose, [switch]$Timings)
$ErrorActionPreference = 'Stop'
if ($Debug -and $Release) { throw 'Choose either -Debug or -Release.' }
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/bootstrap.ps1"
Push-Location $root
try {
    if ($Test) {
        & $CatengarCargo test --locked --all-targets
        if ($LASTEXITCODE) { throw 'Rust tests failed' }
        & $CatengarCargo test --locked -p nsh-platform-windows --lib input::tests::keyboard
        if ($LASTEXITCODE) { throw 'NSH Windows keyboard tests failed' }
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts/test-updater.ps1
        if ($LASTEXITCODE) { throw 'Updater tests failed' }
        return
    }
    $buildArgs = @('build', '--locked', '--bins')
    if ($Release) { $buildArgs += '--release' }
    if ($Timings) { $buildArgs += '--timings' }
    & $CatengarCargo @buildArgs
    if ($LASTEXITCODE) { throw 'Rust build failed' }
    $profile = if ($Release) { 'release' } else { 'debug' }
    $bin = Join-Path $root "target/x86_64-pc-windows-msvc/$profile"
    & "$PSScriptRoot/stage-runtime.ps1" -BuildDir $bin
    if ($Diagnose) { & (Join-Path $bin 'catengar-diagnose.exe'); return }
    if (!$BuildOnly) {
        $appArgs = @('--desktop')
        if ($Preview) { $appArgs += '--preview' }
        Start-Process -FilePath (Join-Path $bin 'catengar.exe') -ArgumentList $appArgs -WindowStyle Hidden
    }
} finally { Pop-Location }
