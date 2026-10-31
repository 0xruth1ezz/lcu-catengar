$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$localCargo = Join-Path $root '.tools/cargo'
if (Test-Path -LiteralPath (Join-Path $localCargo 'bin/cargo.exe')) {
    $env:CARGO_HOME = $localCargo
    $env:RUSTUP_HOME = Join-Path $root '.tools/rustup'
    $env:PATH = "$localCargo\bin;$env:PATH"
}
if (!(Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'Install Rust from https://rustup.rs (MSVC toolchain), then retry.'
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) {
    throw 'Install Visual Studio Build Tools with Desktop development with C++ and the Windows SDK.'
}
$env:RUST_MIN_STACK = '268435456'
Push-Location $root
try {
    & cargo fetch --locked
    if ($LASTEXITCODE) { throw 'Cargo dependency download failed' }
} finally { Pop-Location }
Write-Output 'Ready: Rust + pinned NSH (native Windows renderer)'
