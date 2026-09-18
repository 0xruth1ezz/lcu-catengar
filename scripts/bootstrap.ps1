$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$toolDir = Join-Path $root '.tools'
New-Item -ItemType Directory -Path $toolDir -Force | Out-Null

function Get-VerifiedArchive($url, $path, $sha256) {
    if (!(Test-Path -LiteralPath $path)) { Invoke-WebRequest $url -OutFile $path }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() -ne $sha256) {
        throw "Checksum mismatch: $path. Remove this archive and retry."
    }
}

$zig = Join-Path $toolDir 'zig-x86_64-windows-0.16.0/zig.exe'
if (!(Test-Path -LiteralPath $zig)) {
    $zip = Join-Path $toolDir 'zig.zip'
    Get-VerifiedArchive 'https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip' $zip '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e'
    Expand-Archive -LiteralPath $zip -DestinationPath $toolDir -Force
}
$revision = '6b053188dc8ac415f602618be12717889cb0a986'
if (!(Test-Path -LiteralPath (Join-Path $toolDir 'native/build.zig'))) {
    $zip = Join-Path $toolDir 'native.zip'
    Get-VerifiedArchive "https://codeload.github.com/vercel-labs/native/zip/$revision" $zip 'b0858472a2380396b5d621f76b551447b2c72a63548c7b1c69d61473be13e685'
    Expand-Archive -LiteralPath $zip -DestinationPath $toolDir -Force
    Rename-Item -LiteralPath (Join-Path $toolDir "native-$revision") -NewName native
}
& "$PSScriptRoot/patch-native.ps1"
Write-Output "Ready: Zig 0.16.0 + vercel-labs/native $revision"
