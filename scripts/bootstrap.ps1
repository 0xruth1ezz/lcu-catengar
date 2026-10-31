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
# Explicit mbx invocation keeps this setup project-scoped, including in shells
# without mise activation. Rust still comes from rust-toolchain.toml/rustup.
$mbxVersion = (Select-String -LiteralPath (Join-Path $root 'mise.toml') -Pattern '^mr-boxington = "([^"]+)"$').Matches.Groups[1].Value
# The CI action exposes both its target-cache tool and the installed executable.
# Select the first PATH match, just as direct command invocation does.
$mbx = Get-Command mbx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (!$mbx -and (Get-Command mise -ErrorAction SilentlyContinue)) {
    $mbxHome = & mise where "mr-boxington@$mbxVersion" 2>$null
    if ($LASTEXITCODE -eq 0 -and $mbxHome) {
        $mbxPath = Join-Path $mbxHome 'mbx.exe'
        if (Test-Path -LiteralPath $mbxPath) { $mbx = Get-Command $mbxPath }
    }
}
$CatengarCargo = (Get-Command cargo -CommandType Application | Select-Object -First 1).Source
if ($mbx) {
    if ((& $mbx.Source --version) -ne "mbx $mbxVersion") {
        throw "Expected Mr. Boxington $mbxVersion. Run mise install in the repository, or update mbx on PATH."
    }
    $CatengarCargo = $mbx.Source
    if (!$env:MBX_TARGET_VIEWS) { $env:MBX_TARGET_VIEWS = '0' }
    Write-Output "Build cache: Mr. Boxington $mbxVersion"
} else {
    Write-Output 'Build cache: plain Cargo (optional: mise install)'
}
# Cargo downloads only the dependencies needed by the requested build.
Write-Output 'Ready: Rust + pinned NSH (native Windows renderer)'
